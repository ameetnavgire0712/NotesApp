// agent/tools/list_notes.ts
// ===========================================================================
// Phase 5.5 — deterministic list tool.
//
// For queries like "find all linkedin posts this week" / "show me my reels
// from yesterday" we want hard SQL filters on file_type + created_at, not a
// vector-similarity search. This tool runs a single PostgREST select with
// the structured filters extracted in understand.ts.
// ===========================================================================

import type { ToolContext, TimeWindow } from '../types';
import { resolveTimeWindow } from '../time_window';

export interface ListNotesInput {
  topic?: string;
  window?: TimeWindow;
  file_types?: string[];
  tags?: string[];
  /** Hard cap on rows returned. Default 25, max 100. */
  limit?: number;
}

export interface ListNotesNote {
  note_id: string;
  title: string;
  content_preview: string;
  description: string;
  created_at: string;
  tag?: string;
  file_type?: string;
}

export interface ListNotesOutput {
  notes: ListNotesNote[];
  total_matched: number;
  duration_ms: number;
}

const PREVIEW_CHARS = 600;

export async function runListNotes(
  input: ListNotesInput,
  ctx: ToolContext,
): Promise<ListNotesOutput> {
  const t0 = Date.now();
  const { env } = ctx;
  const userId = ctx.scratchpad.user_id;
  const limit = Math.min(Math.max(input.limit ?? 25, 1), 100);

  const params = new URLSearchParams();
  params.set('user_id', `eq.${userId}`);
  params.append('status', 'neq.deleted');

  if (input.window) {
    const tr = resolveTimeWindow(input.window);
    if (tr) {
      params.append('created_at', `gte.${tr.gte}`);
      if (tr.lt) params.append('created_at', `lt.${tr.lt}`);
    }
  }

  // file_type filter (PostgREST `in` for OR-of-equals).
  if (input.file_types && input.file_types.length > 0) {
    const list = input.file_types.map(s => `"${s}"`).join(',');
    params.append('file_type', `in.(${list})`);
  }

  // tag filter.
  if (input.tags && input.tags.length > 0) {
    const list = input.tags.map(s => `"${s}"`).join(',');
    params.append('tag', `in.(${list})`);
  }

  params.set('select', 'id,title,content_markdown,description,tag,file_type,created_at');
  params.set('order', 'created_at.desc');
  params.set('limit', String(limit));

  let url = `${env.SUPABASE_URL}/rest/v1/notes?${params.toString()}`;

  // Optional keyword narrowing.
  const trimmedTopic = (input.topic || '').trim();
  if (trimmedTopic.length >= 2) {
    const safeTopic = trimmedTopic.replace(/[%_]/g, '\\$&');
    const pattern = `*${safeTopic}*`;
    url += `&or=(title.ilike.${pattern},content_markdown.ilike.${pattern},description.ilike.${pattern})`;
  }

  // Total count (for the "found N" header).
  const countResp = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      Prefer: 'count=exact',
      Range: '0-0',
    },
  });
  let total = 0;
  if (countResp.ok) {
    const cr = countResp.headers.get('Content-Range') || '';
    total = parseInt(cr.split('/')[1] || '0', 10) || 0;
  }

  // Actual rows.
  const resp = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    },
  });
  if (!resp.ok) {
    throw new Error(`list_notes fetch failed: ${resp.status} ${await resp.text()}`);
  }
  const rows: any[] = await resp.json();

  const notes: ListNotesNote[] = rows.map(r => {
    const desc = (r.description || '').toString();
    const body = (r.content_markdown || '').toString() || desc;
    return {
      note_id: r.id,
      title: (r.title || '').toString(),
      content_preview: body.slice(0, PREVIEW_CHARS),
      description: desc,
      created_at: r.created_at,
      tag: r.tag,
      file_type: r.file_type,
    };
  });

  return { notes, total_matched: total || notes.length, duration_ms: Date.now() - t0 };
}

// ---------------------------------------------------------------------------
// Answer renderer — deterministic, no LLM.
// ---------------------------------------------------------------------------
export function renderListAnswer(
  out: ListNotesOutput,
  spec: { window?: TimeWindow; file_types?: string[]; topic?: string; tags?: string[] },
): string {
  const total = out.total_matched;
  const ftLabel = formatFileTypes(spec.file_types);
  const winLabel = spec.window ? humanWindow(spec.window) : null;
  const topicLabel = (spec.topic && spec.topic.length >= 2) ? `about **${spec.topic}**` : null;
  const tagLabel = (spec.tags && spec.tags.length > 0) ? `tagged \`${spec.tags.join(', ')}\`` : null;

  const scopeBits = [ftLabel ? `**${ftLabel}**` : null, topicLabel, tagLabel, winLabel ? `from ${winLabel}` : null]
    .filter(Boolean)
    .join(' ');

  if (total === 0) {
    return `I couldn't find any ${scopeBits || 'notes matching that filter'}. Try a different filter or time range.`;
  }
  const noun = total === 1 ? 'note' : 'notes';
  const head = scopeBits
    ? `I found **${total}** ${scopeBits} ${noun === 'note' ? '' : ''}`.replace(/\s+$/, '')
    : `I found **${total}** ${noun}`;
  // Cleaner: "I found **3** **linkedin** notes from this week."
  const sentence = `I found **${total}** ${ftLabel ? `${ftLabel} ` : ''}${noun}${
    topicLabel ? ` ${topicLabel}` : ''
  }${winLabel ? ` from ${winLabel}` : ''}${tagLabel ? ` ${tagLabel}` : ''}.`;
  return sentence;
  // Note: `head` was built for an alternative phrasing; sentence is what we ship.
}

function formatFileTypes(fts?: string[]): string | null {
  if (!fts || fts.length === 0) return null;
  // Normalise display names.
  const map: Record<string, string> = {
    instagram: 'Instagram',
    youtube: 'YouTube',
    twitter: 'Twitter',
    linkedin: 'LinkedIn',
    reddit: 'Reddit',
    facebook: 'Facebook',
    webpage: 'web',
    uploaded_file: 'uploaded',
    quick_note: 'quick',
    image: 'image',
  };
  const names = fts.map(f => map[f] || f);
  if (names.length === 1) return names[0];
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  return `${names.slice(0, -1).join(', ')}, and ${names[names.length - 1]}`;
}

function humanWindow(w: TimeWindow): string {
  switch (w) {
    case 'today': return 'today';
    case 'yesterday': return 'yesterday';
    case 'this_week': return 'this week';
    case 'last_week': return 'last week';
    case 'this_month': return 'this month';
    case 'last_month': return 'last month';
    case 'last_7d': return 'the last 7 days';
    case 'last_30d': return 'the last 30 days';
    case 'last_90d': return 'the last 90 days';
    case 'last_180d': return 'the last 6 months';
    case 'all_time': return 'all time';
  }
}
