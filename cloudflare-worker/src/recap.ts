/**
 * Recap — daily / weekly / monthly slideshow of saved notes
 *
 * Endpoints:
 *   GET    /api/v1/recap?period=day|week|month[&date=YYYY-MM-DD][&refresh=1]
 *   POST   /api/v1/recap/save        { period, period_start, title?, payload }
 *   GET    /api/v1/recap/saved
 *   DELETE /api/v1/recap/saved/:id
 *
 * Also exports `generateRecapForUser` used by the scheduled() cron handler in
 * index.ts to pre-warm caches once a week.
 */

import { AuthResult } from './auth';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
};

export interface RecapEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  AZURE_STORAGE_CONNECTION_STRING?: string;
  AZURE_STORAGE_CONTAINER?: string;
  AZURE_THUMBNAILS_CONTAINER?: string;
}

type Period = 'day' | 'week' | 'month';

// ─────────────────────────────────────────────────────────────────────────────
// Date helpers (all UTC)
// ─────────────────────────────────────────────────────────────────────────────
function ymd(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function startOfDay(d: Date): Date {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
}

/**
 * Resolve a period window. If `dateStr` is provided (YYYY-MM-DD), it is
 * interpreted as a day inside the desired window. Otherwise we use "now".
 *
 *   day   = the single day at `dateStr` (or yesterday if no date provided)
 *   week  = the 7-day window ending at `dateStr` inclusive (or yesterday).
 *           e.g. for the Sunday cron it covers Mon..Sun.
 *   month = the 30-day window ending at `dateStr` inclusive.
 */
export function resolveWindow(period: Period, dateStr?: string): { start: Date; end: Date } {
  const anchor = dateStr
    ? startOfDay(new Date(`${dateStr}T00:00:00Z`))
    : startOfDay(new Date(Date.now() - 24 * 60 * 60 * 1000)); // default: yesterday

  if (period === 'day') {
    const end = new Date(anchor.getTime() + 24 * 60 * 60 * 1000 - 1);
    return { start: anchor, end };
  }
  if (period === 'week') {
    const start = new Date(anchor.getTime() - 6 * 24 * 60 * 60 * 1000);
    const end = new Date(anchor.getTime() + 24 * 60 * 60 * 1000 - 1);
    return { start, end };
  }
  // month
  const start = new Date(anchor.getTime() - 29 * 24 * 60 * 60 * 1000);
  const end = new Date(anchor.getTime() + 24 * 60 * 60 * 1000 - 1);
  return { start, end };
}

// ─────────────────────────────────────────────────────────────────────────────
// Supabase helpers
// ─────────────────────────────────────────────────────────────────────────────
function sbHeaders(env: RecapEnv): Record<string, string> {
  return {
    apikey: env.SUPABASE_SERVICE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
  };
}

async function sbFetch(env: RecapEnv, path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(`${env.SUPABASE_URL}${path}`, {
    ...init,
    headers: {
      ...sbHeaders(env),
      'Content-Type': 'application/json',
      ...(init.headers as Record<string, string> | undefined),
    },
  });
}

function parseAzureConnectionString(conn: string): { accountName: string; accountKey: string } | null {
  let accountName = '';
  let accountKey = '';
  for (const part of conn.split(';')) {
    if (part.startsWith('AccountName=')) {
      accountName = part.substring('AccountName='.length);
    } else if (part.startsWith('AccountKey=')) {
      accountKey = part.substring('AccountKey='.length);
    }
  }
  if (!accountName || !accountKey) return null;
  return { accountName, accountKey };
}

function extractBlobNameFromUrl(blobUrl: string, container: string): string | null {
  try {
    const parsed = new URL(blobUrl);
    const path = parsed.pathname.replace(/^\/+/, '');
    const prefix = `${container}/`;
    if (!path.startsWith(prefix)) return null;
    return path.substring(prefix.length);
  } catch {
    return null;
  }
}

async function generateAzureSasForBlobName(
  blobName: string,
  env: RecapEnv,
  expiryMinutes: number = 60,
): Promise<string | null> {
  if (!env.AZURE_STORAGE_CONNECTION_STRING || !env.AZURE_STORAGE_CONTAINER) {
    return null;
  }

  const parsed = parseAzureConnectionString(env.AZURE_STORAGE_CONNECTION_STRING);
  if (!parsed) return null;

  const { accountName, accountKey } = parsed;
  const containerName = env.AZURE_STORAGE_CONTAINER;

  const now = new Date();
  const start = new Date(now.getTime() - 5 * 60 * 1000);
  const expiry = new Date(now.getTime() + expiryMinutes * 60 * 1000);
  const fmt = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

  const signedStart = fmt(start);
  const signedExpiry = fmt(expiry);
  const version = '2020-02-10';
  const permissions = 'r';
  const canonicalizedResource = `/blob/${accountName}/${containerName}/${blobName}`;

  const stringToSign = [
    permissions,
    signedStart,
    signedExpiry,
    canonicalizedResource,
    '',
    '',
    '',
    version,
    'b',
    '',
    '',
    '',
    '',
    '',
    '',
  ].join('\n');

  const keyBuffer = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
  const hmacKey = await crypto.subtle.importKey(
    'raw',
    keyBuffer,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sigBuffer = await crypto.subtle.sign('HMAC', hmacKey, new TextEncoder().encode(stringToSign));
  const signature = btoa(String.fromCharCode(...new Uint8Array(sigBuffer)));

  const qs = new URLSearchParams({
    sv: version,
    st: signedStart,
    se: signedExpiry,
    sr: 'b',
    sp: permissions,
    sig: signature,
  });

  const base = `https://${accountName}.blob.core.windows.net/${containerName}/${blobName}`;
  return `${base}?${qs.toString()}`;
}

async function ensureSignedAzureUrl(url: string | null | undefined, env: RecapEnv): Promise<string | null> {
  if (!url || !env.AZURE_STORAGE_CONTAINER) return url ?? null;
  if (url.includes('sig=')) return url;
  if (!url.includes('.blob.core.windows.net/')) return url;

  const publicThumbContainer = (env.AZURE_THUMBNAILS_CONTAINER || '').trim();
  if (publicThumbContainer && extractBlobNameFromUrl(url, publicThumbContainer)) return url;

  const blobName = extractBlobNameFromUrl(url, env.AZURE_STORAGE_CONTAINER);
  if (!blobName) return url;

  const sas = await generateAzureSasForBlobName(blobName, env, 60);
  return sas || url;
}

// ─────────────────────────────────────────────────────────────────────────────
// Note normalization (mirrors categorize_recap.py)
// ─────────────────────────────────────────────────────────────────────────────
function parseMeta(n: any): Record<string, any> {
  let md = n.metadata;
  if (typeof md === 'string') {
    try { md = JSON.parse(md); } catch { md = {}; }
  }
  return md && typeof md === 'object' ? md : {};
}

function deriveThumb(n: any): string | null {
  const md = parseMeta(n);
  const originalFilename = ((n.original_filename || md.original_filename || '') as string).toLowerCase();
  const imageExts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg'];

  // Match the My Snaps thumbnail contract exactly:
  // worker/API-provided thumbnail fields first, then image blob fallback.
  const candidates: any[] = [
    md.thumbnail_url,
    md.preview_image_url,
    md.thumbnail_blob_url,
    md.screenshot_url,
  ];
  for (const c of candidates) {
    if (typeof c === 'string' && /^https?:\/\//i.test(c)) return stabilizeThumbUrl(c);
  }

  const ft = (n.file_type || '').toString();

  if ((ft === 'image' || ft === 'screenshot') && typeof n.blob_url === 'string' && /^https?:\/\//i.test(n.blob_url)) {
    return n.blob_url as string;
  }

  if (ft === 'uploaded_file' && typeof n.blob_url === 'string' && /^https?:\/\//i.test(n.blob_url)) {
    if (imageExts.some(ext => originalFilename.endsWith(ext))) {
      return n.blob_url as string;
    }
  }

  return null;
}

// Hosts whose image URLs are signed/short-lived or require special headers
// (Instagram, Facebook CDN). Route them through wsrv.nl which proxies and
// caches the bytes, giving us a stable URL the Flutter client can load.
const _UNSTABLE_HOSTS = /(?:^|\.)(cdninstagram\.com|fbcdn\.net|fbsbx\.com|twimg\.com|licdn\.com|redditmedia\.com|redd\.it)$/i;

function stabilizeThumbUrl(url: string): string {
  try {
    const u = new URL(url);
    if (_UNSTABLE_HOSTS.test(u.hostname)) {
      // wsrv.nl wants the URL without the scheme; use `ssl:` prefix for https.
      const stripped = url.replace(/^https?:\/\//i, '');
      return `https://wsrv.nl/?url=ssl:${encodeURIComponent(stripped)}&w=1200&output=jpg&we=1&l=6`;
    }
  } catch { /* noop */ }
  return url;
}

function isGeneratedSocialScreenshot(url: string | null | undefined): boolean {
  if (!url) return false;
  try {
    const u = new URL(url);
    if (u.hostname === 'www.google.com' && u.pathname === '/s2/favicons') {
      const domain = (u.searchParams.get('domain') || '').toLowerCase();
      return domain.includes('instagram.com') ||
        domain.includes('facebook.com') ||
        domain.includes('linkedin.com') ||
        domain.includes('twitter.com') ||
        domain.includes('x.com') ||
        domain.includes('reddit.com');
    }

    if (u.hostname !== 's.wordpress.com' || !u.pathname.startsWith('/mshots/v1/')) return false;
    const decoded = decodeURIComponent(u.pathname.substring('/mshots/v1/'.length)).toLowerCase();
    return decoded.includes('instagram.com') ||
      decoded.includes('facebook.com') ||
      decoded.includes('linkedin.com') ||
      decoded.includes('twitter.com') ||
      decoded.includes('x.com') ||
      decoded.includes('reddit.com');
  } catch {
    return false;
  }
}

function deriveSourceUrl(n: any): string {
  const md = parseMeta(n);
  const social = (md.social && typeof md.social === 'object') ? md.social : {};
  return (
    (typeof social.source_url === 'string' && social.source_url) ||
    (typeof md.source_url === 'string' && md.source_url) ||
    (typeof n.blob_url === 'string' && n.blob_url) ||
    ''
  );
}

function looksUntitled(t: string): boolean {
  const v = (t || '').trim().toLowerCase();
  return v === '' || v === 'untitled';
}

const IMAGE_EXTS = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg'];
const DOC_EXTS = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.csv', '.txt'];

function normalizeText(value: string): string {
  return (value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function originalFilenameOf(n: any): string {
  const md = parseMeta(n);
  return ((n.original_filename || md.original_filename || '') as string).toLowerCase();
}

function hasAnyExt(name: string, exts: string[]): boolean {
  return exts.some(ext => name.endsWith(ext));
}

function canonicalSourceKey(url: string): string {
  try {
    const u = new URL(url);
    const host = u.hostname.toLowerCase();
    const path = u.pathname.replace(/\/+$/, '').toLowerCase();
    const videoId = u.searchParams.get('v');
    if (videoId) return `${host}${path}?v=${videoId.toLowerCase()}`;
    return `${host}${path}`;
  } catch {
    return normalizeText(url);
  }
}

function dedupeKey(n: any): string {
  const source = deriveSourceUrl(n);
  const title = normalizeText((n.short_title || n.title || '') as string);
  const originalFilename = originalFilenameOf(n);
  const ft = (n.file_type || '').toString().toLowerCase();

  if (source && !/blob\.core\.windows\.net/i.test(source)) {
    return `src:${canonicalSourceKey(source)}`;
  }
  if (originalFilename) {
    return `file:${ft}:${originalFilename}`;
  }
  if (title) {
    return `title:${ft}:${title}`;
  }
  return `id:${n.id}`;
}

type DeterministicCategory = {
  name: string;
  color: string;
  note_ids: string[];
};

type TopicDef = {
  name: string;
  color: string;
  pattern: RegExp;
};

const CATEGORY_COLORS: Record<string, string> = {
  '🤖 AI & Tech': '#7c3aed',
  '💰 Finance & Business': '#f59e0b',
  '🏥 Health & Medical': '#ef4444',
  '🍳 Food & Recipes': '#f97316',
  '✈️ Travel & Places': '#06b6d4',
  '🏠 Home & Products': '#10b981',
  '🎬 Entertainment & Culture': '#ec4899',
  '🔎 Reading & Links': '#0ea5e9',
  '📸 Photos & Uploads': '#22c55e',
  '📄 Personal Docs': '#64748b',
  '📝 Notes & Ideas': '#8b5cf6',
};

const TOPIC_DEFS: TopicDef[] = [
  { name: '🤖 AI & Tech', color: '#7c3aed', pattern: /\b(ai|artificial intelligence|openai|chatgpt|gpt|llm|claude|copilot|groq|notion ai|prompt|developer|coding|software|tech|microsoft ai)\b/i },
  { name: '💰 Finance & Business', color: '#f59e0b', pattern: /\b(bank|statement|portfolio|holdings|mutual fund|finance|financial|pricing|price list|sales|business|consulting|company|invoice|bill|market|stock|account|sow)\b/i },
  { name: '🏥 Health & Medical', color: '#ef4444', pattern: /\b(mri|diagnostic|diagnostics|report|prescription|orthopaedic|doctor|hospital|medical|health|scan|clinic)\b/i },
  { name: '🍳 Food & Recipes', color: '#f97316', pattern: /\b(recipe|recipes|cook|cooking|dish|food|cafe|restaurant|meal|kitchen)\b/i },
  { name: '✈️ Travel & Places', color: '#06b6d4', pattern: /\b(travel|visa|europe|trip|flight|hotel|tour|udaipur|place|destination|city|cafe in)\b/i },
  { name: '🏠 Home & Products', color: '#10b981', pattern: /\b(home|gate|windsor|ev|product|products|interior|furniture|appliance|salem)\b/i },
  { name: '🎬 Entertainment & Culture', color: '#ec4899', pattern: /\b(entertainment|movie|music|song|viral|nostalgic|culturally|culture|bollywood)\b/i },
];

function categorizeDeterministically(notes: any[]): DeterministicCategory[] {
  const buckets = new Map<string, DeterministicCategory>();

  const ensureBucket = (name: string, color: string): DeterministicCategory => {
    const existing = buckets.get(name);
    if (existing) return existing;
    const created = { name, color, note_ids: [] };
    buckets.set(name, created);
    return created;
  };

  for (const n of notes) {
    const fileType = (n.file_type || '').toString().toLowerCase();
    const originalFilename = originalFilenameOf(n);
    const sourceUrl = deriveSourceUrl(n).toLowerCase();
    const text = normalizeText([
      n.short_title,
      n.title,
      n.description,
      n.tag,
      originalFilename,
      sourceUrl,
    ].filter(Boolean).join(' '));

    const isImageLike = fileType === 'image' || fileType === 'screenshot' ||
      (fileType === 'uploaded_file' && hasAnyExt(originalFilename, IMAGE_EXTS));
    const isDocLike = fileType === 'uploaded_file' ||
      fileType === 'pdf' ||
      ((fileType === '' || fileType === 'file') && hasAnyExt(originalFilename, DOC_EXTS));
    let chosen: { name: string; color: string } | null = null;
    for (const topic of TOPIC_DEFS) {
      if (topic.pattern.test(text)) {
        chosen = { name: topic.name, color: topic.color };
        break;
      }
    }

    if (!chosen) {
      if (isImageLike) {
        chosen = { name: '📸 Photos & Uploads', color: '#22c55e' };
      } else if (isDocLike) {
        chosen = { name: '📄 Personal Docs', color: '#64748b' };
      } else if (fileType === 'webpage' || fileType === 'youtube') {
        chosen = { name: '🔎 Reading & Links', color: '#0ea5e9' };
      } else {
        chosen = { name: '📝 Notes & Ideas', color: '#8b5cf6' };
      }
    }

    ensureBucket(chosen.name, chosen.color).note_ids.push(n.id as string);
  }

  return Array.from(buckets.values())
    .filter(bucket => bucket.note_ids.length > 0)
    .sort((a, b) => b.note_ids.length - a.note_ids.length);
}

function categorizeFromStoredCategory(notes: any[]): DeterministicCategory[] {
  const buckets = new Map<string, DeterministicCategory>();
  for (const note of notes) {
    const name = typeof note.category === 'string' ? note.category.trim() : '';
    if (!name) continue;
    const color = CATEGORY_COLORS[name] || '#8b5cf6';
    const existing = buckets.get(name);
    if (existing) {
      existing.note_ids.push(note.id as string);
    } else {
      buckets.set(name, { name, color, note_ids: [note.id as string] });
    }
  }
  return Array.from(buckets.values())
    .filter(bucket => bucket.note_ids.length > 0)
    .sort((a, b) => b.note_ids.length - a.note_ids.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// Core: build a recap payload for a (user, period, window).
// ─────────────────────────────────────────────────────────────────────────────
export interface RecapPayload {
  user_id: string;
  period: Period;
  period_start: string; // YYYY-MM-DD
  period_end: string;   // YYYY-MM-DD
  generated_at: string;
  total_notes: number;
  total_unfiltered: number;
  empty: boolean;
  degraded?: boolean;
  categories: Array<{
    name: string;
    color: string;
    count: number;
    cover_thumb: string | null;
    slides: Array<{
      id: string;
      title: string;
      full_title: string;
      description: string;
      tag: string;
      file_type: string;
      thumbnail: string | null;
      blob_url: string | null;
      original_filename: string | null;
      source_url: string;
      created_at: string | null;
    }>;
  }>;
}

export async function buildRecapPayload(
  env: RecapEnv,
  userId: string,
  period: Period,
  dateStr?: string,
): Promise<RecapPayload> {
  const { start, end } = resolveWindow(period, dateStr);

  // Fetch notes in window
  const selectFields = 'id,title,short_title,category,tag,file_type,original_filename,blob_url,description,metadata,created_at';
  const fallbackSelectFields = 'id,title,short_title,tag,file_type,original_filename,blob_url,description,metadata,created_at';
  const startIso = start.toISOString().replace('+', '%2B');
  const endIso = end.toISOString().replace('+', '%2B');
  const url =
    `/rest/v1/notes?select=${selectFields}` +
    `&user_id=eq.${userId}` +
    `&status=in.(active,incomplete)` +
    `&created_at=gte.${encodeURIComponent(startIso)}` +
    `&created_at=lte.${encodeURIComponent(endIso)}` +
    `&order=created_at.desc&limit=500`;

  let r = await sbFetch(env, url);
  if (!r.ok) {
    const txt = await r.text();
    const missingCategoryColumn = txt.includes('category') && (txt.includes('column') || txt.includes('schema cache'));
    if (missingCategoryColumn) {
      const fallbackUrl = url.replace(`select=${selectFields}`, `select=${fallbackSelectFields}`);
      r = await sbFetch(env, fallbackUrl);
      if (!r.ok) {
        const fallbackText = await r.text();
        throw new Error(`Supabase notes fetch ${r.status}: ${fallbackText.slice(0, 300)}`);
      }
    } else {
      throw new Error(`Supabase notes fetch ${r.status}: ${txt.slice(0, 300)}`);
    }
  }
  const allNotes = (await r.json() as any[]) || [];

  // Filter: drop test/opt_test tag, drop untitled
  const filtered = allNotes.filter((n: any) => {
    const tag = (n.tag || '').toLowerCase();
    if (tag === 'test' || tag === 'opt_test') return false;
    const t = n.short_title || n.title || '';
    if (looksUntitled(t)) return false;
    return true;
  });

  const periodStart = ymd(start);
  const periodEnd = ymd(end);
  const now = new Date().toISOString();

  if (filtered.length === 0) {
    return {
      user_id: userId,
      period,
      period_start: periodStart,
      period_end: periodEnd,
      generated_at: now,
      total_notes: 0,
      total_unfiltered: allNotes.length,
      empty: true,
      categories: [],
    };
  }

  const limited = filtered.slice(0, 200);
  const deduped: any[] = [];
  const seenKeys = new Set<string>();
  for (const note of limited) {
    const key = dedupeKey(note);
    if (seenKeys.has(key)) continue;
    seenKeys.add(key);
    deduped.push(note);
  }

  let cats: { name: string; color: string; note_ids: string[] }[];
  let degraded = false;
  const storedCategoryNotes = deduped.filter((note: any) => typeof note.category === 'string' && note.category.trim().length > 0);
  const uncategorizedNotes = deduped.filter((note: any) => !(typeof note.category === 'string' && note.category.trim().length > 0));

  cats = categorizeFromStoredCategory(storedCategoryNotes);

  if (uncategorizedNotes.length > 0) {
    cats.push(...categorizeDeterministically(uncategorizedNotes));
    degraded = true;
  }

  const merged = new Map<string, { name: string; color: string; note_ids: string[] }>();
  for (const cat of cats) {
    const existing = merged.get(cat.name);
    if (existing) {
      existing.note_ids.push(...cat.note_ids);
    } else {
      merged.set(cat.name, { name: cat.name, color: cat.color, note_ids: [...cat.note_ids] });
    }
  }
  cats = Array.from(merged.values()).sort((a, b) => b.note_ids.length - a.note_ids.length);

  // Enrich with thumb + source_url
  const byId = new Map<string, any>();
  for (const n of deduped) byId.set(n.id, n);

  const enriched = (await Promise.all(cats.map(async c => {
    const slides = await Promise.all((c.note_ids || [])
      .map(id => byId.get(id))
      .filter(Boolean)
      .map(async (n: any) => {
        const fileType = (n.file_type || '') as string;
        const rawThumb = deriveThumb(n);
        const rawBlobUrl = (n.blob_url || null) as string | null;
        const rawSourceUrl = deriveSourceUrl(n);
        const isImageLike = fileType === 'image' || fileType === 'screenshot';
        return {
          id: n.id as string,
          title: ((n.short_title || n.title || 'Untitled') as string).trim(),
          full_title: ((n.title || '') as string).trim(),
          description: ((n.description || '') as string).trim().slice(0, 280),
          tag: (n.tag || '') as string,
          file_type: fileType,
          thumbnail: await ensureSignedAzureUrl(rawThumb, env),
          blob_url: await ensureSignedAzureUrl(rawBlobUrl, env),
          original_filename: (n.original_filename || null) as string | null,
          source_url: isImageLike ? ((await ensureSignedAzureUrl(rawSourceUrl, env)) || '') : rawSourceUrl,
          created_at: (n.created_at || null) as string | null,
        };
      }));
    return {
      name: c.name,
      color: c.color || '#3b82f6',
      count: slides.length,
      cover_thumb: slides.find(s => s.thumbnail)?.thumbnail || null,
      slides,
    };
  }))).filter(c => c.count > 0);

  enriched.sort((a, b) => b.count - a.count);

  return {
    user_id: userId,
    period,
    period_start: periodStart,
    period_end: periodEnd,
    generated_at: now,
    total_notes: enriched.reduce((s, c) => s + c.count, 0),
    total_unfiltered: allNotes.length,
    empty: false,
    categories: enriched,
    degraded,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Cache helpers
// ─────────────────────────────────────────────────────────────────────────────
async function readCache(env: RecapEnv, userId: string, period: Period, periodStart: string): Promise<RecapPayload | null> {
  const url =
    `/rest/v1/recap_cache?select=payload` +
    `&user_id=eq.${userId}` +
    `&period=eq.${period}` +
    `&period_start=eq.${periodStart}` +
    `&limit=1`;
  const r = await sbFetch(env, url);
  if (!r.ok) return null;
  const rows = (await r.json() as any[]) || [];
  if (rows.length === 0) return null;
  return rows[0].payload as RecapPayload;
}

async function rehydrateCachedRecapThumbnails(env: RecapEnv, payload: RecapPayload): Promise<RecapPayload> {
  const ids = Array.from(new Set(
    (payload.categories || [])
      .flatMap(c => c.slides || [])
      .map(s => s.id)
      .filter(id => typeof id === 'string' && id.length > 0),
  ));
  if (ids.length === 0) return payload;

  const selectFields = 'id,file_type,original_filename,blob_url,metadata';
  const idList = ids
    .map(id => id.replace(/[^A-Za-z0-9_-]/g, ''))
    .filter(Boolean)
    .join(',');
  if (!idList) return payload;
  const r = await sbFetch(
    env,
    `/rest/v1/notes?select=${selectFields}&id=in.(${encodeURIComponent(idList)})`,
  );
  if (!r.ok) return payload;

  const rows = (await r.json() as any[]) || [];
  const byId = new Map<string, any>();
  for (const row of rows) {
    if (row?.id) byId.set(row.id as string, row);
  }
  if (byId.size === 0) return payload;

  let changed = false;
  const categories = await Promise.all((payload.categories || []).map(async category => {
    const slides = await Promise.all((category.slides || []).map(async slide => {
      const note = byId.get(slide.id);
      if (!note) return slide;

      const rawThumb = deriveThumb(note);
      const thumb = await ensureSignedAzureUrl(rawThumb, env);
      const rawBlobUrl = (note.blob_url || null) as string | null;
      const blobUrl = await ensureSignedAzureUrl(rawBlobUrl, env);
      const existingThumb = isGeneratedSocialScreenshot(slide.thumbnail) ? null : slide.thumbnail;
      const nextThumb = thumb || existingThumb || null;
      const nextBlobUrl = blobUrl || slide.blob_url || null;

      if (nextThumb !== slide.thumbnail || nextBlobUrl !== slide.blob_url) {
        changed = true;
        return { ...slide, thumbnail: nextThumb, blob_url: nextBlobUrl };
      }
      return slide;
    }));

    const coverThumb = slides.find(s => s.thumbnail)?.thumbnail || category.cover_thumb || null;
    if (coverThumb !== category.cover_thumb) changed = true;
    return { ...category, cover_thumb: coverThumb, slides };
  }));

  if (!changed) return payload;
  const updated = { ...payload, categories };
  await writeCache(env, updated).catch(e => console.log('[recap] cache thumbnail rehydrate write failed', String(e)));
  return updated;
}

async function writeCache(env: RecapEnv, payload: RecapPayload): Promise<void> {
  const body = [{
    user_id: payload.user_id,
    period: payload.period,
    period_start: payload.period_start,
    period_end: payload.period_end,
    total_notes: payload.total_notes,
    payload,
    generated_at: payload.generated_at,
  }];
  await sbFetch(env, `/rest/v1/recap_cache?on_conflict=user_id,period,period_start`, {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify(body),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Public: cron entry point
// ─────────────────────────────────────────────────────────────────────────────
export async function generateRecapForUser(
  env: RecapEnv,
  userId: string,
  period: Period,
  dateStr?: string,
): Promise<RecapPayload> {
  const payload = await buildRecapPayload(env, userId, period, dateStr);
  // Only cache successful (non-empty, non-degraded) payloads. A degraded
  // payload is the single-bucket fallback that should be re-tried next time.
  if (!payload.empty && !payload.degraded) {
    await writeCache(env, payload).catch(e => console.log('[recap] cache write failed', String(e)));
  }
  return payload;
}

/**
 * Find users who saved at least one non-test note in the last `days` days.
 * Used by the cron scheduler to fan out.
 */
export async function listActiveUserIds(env: RecapEnv, days: number = 14): Promise<string[]> {
  const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
  // PostgREST doesn't aggregate easily — fetch distinct user_ids via a thin select.
  // We rely on a small page size + manual dedupe.
  const url =
    `/rest/v1/notes?select=user_id&status=eq.active` +
    `&created_at=gte.${encodeURIComponent(cutoff)}` +
    `&limit=10000`;
  const r = await sbFetch(env, url);
  if (!r.ok) return [];
  const rows = (await r.json() as any[]) || [];
  const set = new Set<string>();
  for (const row of rows) if (row.user_id) set.add(row.user_id as string);
  return [...set];
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP handlers
// ─────────────────────────────────────────────────────────────────────────────
function jsonResp(body: any, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

function unauthorized(): Response {
  return jsonResp({ error: 'Unauthorized' }, 401);
}

export async function handleRecapGet(request: Request, auth: AuthResult, env: RecapEnv): Promise<Response> {
  if (!auth.authenticated || !auth.user_id) return unauthorized();
  const url = new URL(request.url);
  const period = (url.searchParams.get('period') || 'week') as Period;
  if (!['day', 'week', 'month'].includes(period)) {
    return jsonResp({ error: 'invalid period' }, 400);
  }
  const dateStr = url.searchParams.get('date') || undefined;
  const refresh = url.searchParams.get('refresh') === '1';

  const { start } = resolveWindow(period, dateStr);
  const periodStart = ymd(start);

  if (!refresh) {
    const cached = await readCache(env, auth.user_id, period, periodStart);
    if (cached) {
      const hydrated = await rehydrateCachedRecapThumbnails(env, cached);
      return jsonResp({ ...hydrated, cached: true });
    }
  }

  try {
    const payload = await generateRecapForUser(env, auth.user_id, period, dateStr);
    return jsonResp({ ...payload, cached: false });
  } catch (e) {
    console.log('[recap] generate failed', String(e));
    return jsonResp({ error: String(e) }, 500);
  }
}

export async function handleRecapSave(request: Request, auth: AuthResult, env: RecapEnv): Promise<Response> {
  if (!auth.authenticated || !auth.user_id) return unauthorized();
  let body: any;
  try { body = await request.json(); } catch { return jsonResp({ error: 'invalid_json' }, 400); }

  const period = body.period as Period;
  if (!['day', 'week', 'month'].includes(period)) return jsonResp({ error: 'invalid period' }, 400);
  const payload = body.payload;
  if (!payload || typeof payload !== 'object') return jsonResp({ error: 'missing payload' }, 400);

  const periodStart = (payload.period_start || body.period_start) as string;
  const periodEnd = (payload.period_end || body.period_end) as string;
  if (!periodStart || !periodEnd) return jsonResp({ error: 'missing period_start/end' }, 400);

  const coverThumb = (() => {
    const cats = (payload.categories || []) as any[];
    for (const c of cats) if (c.cover_thumb) return c.cover_thumb as string;
    return null;
  })();

  const row = {
    user_id: auth.user_id,
    period,
    period_start: periodStart,
    period_end: periodEnd,
    title: (body.title as string) || null,
    cover_thumb: coverThumb,
    total_notes: (payload.total_notes as number) || 0,
    payload,
  };

  const r = await sbFetch(env, `/rest/v1/recap_collections`, {
    method: 'POST',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify([row]),
  });

  if (!r.ok) {
    const txt = await r.text();
    return jsonResp({ error: `save failed: ${txt.slice(0, 300)}` }, 500);
  }
  const rows = (await r.json() as any[]) || [];
  return jsonResp({ ok: true, saved: rows[0] || null });
}

export async function handleRecapListSaved(_request: Request, auth: AuthResult, env: RecapEnv): Promise<Response> {
  if (!auth.authenticated || !auth.user_id) return unauthorized();
  const url =
    `/rest/v1/recap_collections` +
    `?select=id,period,period_start,period_end,title,cover_thumb,total_notes,saved_at` +
    `&user_id=eq.${auth.user_id}` +
    `&order=saved_at.desc&limit=100`;
  const r = await sbFetch(env, url);
  if (!r.ok) return jsonResp({ error: 'list failed' }, 500);
  const rows = (await r.json() as any[]) || [];
  return jsonResp({ items: rows });
}

export async function handleRecapGetSaved(id: string, auth: AuthResult, env: RecapEnv): Promise<Response> {
  if (!auth.authenticated || !auth.user_id) return unauthorized();
  const url =
    `/rest/v1/recap_collections` +
    `?select=*&id=eq.${id}&user_id=eq.${auth.user_id}&limit=1`;
  const r = await sbFetch(env, url);
  if (!r.ok) return jsonResp({ error: 'fetch failed' }, 500);
  const rows = (await r.json() as any[]) || [];
  if (rows.length === 0) return jsonResp({ error: 'not found' }, 404);
  return jsonResp(rows[0]);
}

export async function handleRecapDeleteSaved(id: string, auth: AuthResult, env: RecapEnv): Promise<Response> {
  if (!auth.authenticated || !auth.user_id) return unauthorized();
  const url = `/rest/v1/recap_collections?id=eq.${id}&user_id=eq.${auth.user_id}`;
  const r = await sbFetch(env, url, { method: 'DELETE' });
  if (!r.ok) return jsonResp({ error: 'delete failed' }, 500);
  return jsonResp({ ok: true });
}
