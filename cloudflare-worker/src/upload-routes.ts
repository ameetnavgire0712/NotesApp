/**
 * Upload Routes for Cloudflare Worker
 * 
 * Migrated from Fly.io Python FastAPI upload server.
 * Handles file uploads, screenshots, and quick notes with background processing.
 * 
 * Pipeline: Validate → Azure Blob → TensorLake (via file_url) → HTML cleanup (Groq) 
 *           → Title gen (Groq) → Chunking → Embeddings (Workers AI) 
 *           → Supabase insert → Vectorize upsert → Cache invalidation
 * 
 * Uses Durable Objects for long-running uploads (TensorLake can take >30s).
 * This avoids the 30-second wall-clock limit on free Workers plan.
 */

import { validateAuth, AuthResult, AuthEnv } from './auth';

// ============================================================================
// Constants
// ============================================================================
const MAX_TOTAL_STORAGE_BYTES = 100 * 1024 * 1024; // 100 MB per user
const MAX_SINGLE_FILE_BYTES = 20 * 1024 * 1024;    // 20 MB per file

// Semantic chunker config
const MAX_CHUNK_WORDS = 400;
const MIN_CHUNK_WORDS = 100;
const FALLBACK_CHUNK_SIZE = 500;    // naive fallback for non-markdown
const FALLBACK_OVERLAP = 50;

const PLAIN_TEXT_EXTENSIONS = new Set([
  '.txt', '.md', '.markdown', '.csv', '.json', '.xml', '.yaml', '.yml',
  '.log', '.ini', '.cfg', '.conf', '.py', '.js', '.ts', '.html', '.css',
  '.sql', '.sh', '.bat', '.ps1', '.env', '.gitignore', '.dockerignore',
]);

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
};

// ============================================================================
// Interfaces
// ============================================================================
export interface UploadEnv {
  AI: Ai;
  VECTORIZE: Vectorize;
  EMBEDDING_MODEL: string;
  GROQ_API_KEY: string;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
  SUPABASE_JWT_SECRET: string;
  WORKER_API_KEY: string;
  AZURE_STORAGE_CONNECTION_STRING: string;
  AZURE_STORAGE_CONTAINER: string;
  TENSORLAKE_API_KEY: string;
  LOG_ENABLED?: string;
  SEARCH_CACHE: KVNamespace;
  TAGS_CACHE: KVNamespace;
  // Durable Object binding for long-running uploads
  UPLOAD_PROCESSOR: DurableObjectNamespace;
}

interface UploadTraceEntry {
  trace_id: string;
  user_id: string;
  upload_type: 'file' | 'screenshot' | 'quick_note';
  original_filename?: string;
  file_type?: string;
  file_size_bytes?: number;
  tag?: string;
  status: 'accepted' | 'processing' | 'completed' | 'failed' | 'cancelled';

  // Timestamps
  request_received_at: string;
  processing_started_at?: string;
  blob_upload_started_at?: string;
  blob_upload_completed_at?: string;
  conversion_started_at?: string;
  conversion_completed_at?: string;
  html_cleanup_started_at?: string;
  html_cleanup_completed_at?: string;
  title_gen_started_at?: string;
  title_gen_completed_at?: string;
  embedding_started_at?: string;
  embedding_completed_at?: string;
  db_insert_started_at?: string;
  db_insert_completed_at?: string;
  vectorize_started_at?: string;
  vectorize_completed_at?: string;
  completed_at?: string;

  // Timing durations (ms)
  timing_total_ms?: number;
  timing_blob_upload_ms?: number;
  timing_conversion_ms?: number;
  timing_html_cleanup_ms?: number;
  timing_title_gen_ms?: number;
  timing_embedding_ms?: number;
  timing_db_insert_ms?: number;
  timing_vectorize_ms?: number;

  // Results
  title_generated?: string;
  chunk_count?: number;
  vector_count?: number;
  note_id?: string;
  blob_url?: string;
  conversion_method?: string; // 'tensorlake' | 'plain_text' | 'direct'
  content_length?: number;

  // Storage quota
  user_storage_before_bytes?: number;
  user_storage_after_bytes?: number;

  // Errors
  error_message?: string;
  pipeline_errors?: string[];

  // Auth
  auth_method?: string;
}

// ============================================================================
// Utility: Generate unique trace ID
// ============================================================================
function generateTraceId(): string {
  return `ut_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
}

// ============================================================================
// Utility: Check if source URL is from a blocked site
// ============================================================================
function isBlockedSourceUrl(url: string): string | null {
  const blockedSites = [
    { pattern: /youtube\.com|youtu\.be/i, name: 'YouTube' },
    { pattern: /instagram\.com/i, name: 'Instagram' },
    { pattern: /linkedin\.com/i, name: 'LinkedIn' },
    { pattern: /twitter\.com|x\.com/i, name: 'Twitter/X' },
    { pattern: /msn\.com/i, name: 'MSN' },
    { pattern: /facebook\.com/i, name: 'Facebook' },
    { pattern: /tiktok\.com/i, name: 'TikTok' },
  ];
  
  try {
    const hostname = new URL(url).hostname.toLowerCase();
    for (const site of blockedSites) {
      if (site.pattern.test(hostname)) {
        return `${site.name} pages cannot be saved. These sites contain mostly multimedia content that doesn't convert well to notes.`;
      }
    }
  } catch {
    // Invalid URL, let it pass - will fail elsewhere if truly invalid
  }
  return null;
}

// ============================================================================
// Azure Blob Storage - REST API with Shared Key auth
// ============================================================================
function parseConnectionString(connStr: string): { accountName: string; accountKey: string } {
  const parts = connStr.split(';');
  let accountName = '';
  let accountKey = '';
  for (const part of parts) {
    if (part.startsWith('AccountName=')) accountName = part.substring(12);
    if (part.startsWith('AccountKey=')) accountKey = part.substring(11);
  }
  return { accountName, accountKey };
}

async function createSharedKeyAuth(
  accountName: string,
  accountKey: string,
  method: string,
  url: string,
  headers: Record<string, string>,
  contentLength: number
): Promise<string> {
  // Build canonical headers (x-ms-* sorted)
  const xmsHeaders = Object.entries(headers)
    .filter(([k]) => k.toLowerCase().startsWith('x-ms-'))
    .sort(([a], [b]) => a.toLowerCase().localeCompare(b.toLowerCase()))
    .map(([k, v]) => `${k.toLowerCase()}:${v}`)
    .join('\n');

  // Build canonical resource
  const urlObj = new URL(url);
  const canonicalResource = `/${accountName}${urlObj.pathname}`;

  // Build string to sign
  const contentType = headers['Content-Type'] || '';
  const stringToSign = [
    method,                    // HTTP method
    '',                        // Content-Encoding
    '',                        // Content-Language
    contentLength.toString(),  // Content-Length
    '',                        // Content-MD5
    contentType,               // Content-Type
    '',                        // Date
    '',                        // If-Modified-Since
    '',                        // If-Match
    '',                        // If-None-Match
    '',                        // If-Unmodified-Since
    '',                        // Range
    xmsHeaders,                // Canonical headers
    canonicalResource,         // Canonical resource
  ].join('\n');

  // Sign with HMAC-SHA256
  const keyBytes = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)));

  return `SharedKey ${accountName}:${signatureB64}`;
}

async function uploadToAzureBlob(
  fileData: ArrayBuffer,
  userId: string,
  fileType: string,
  filename: string,
  contentType: string,
  env: UploadEnv
): Promise<{ blobUrl: string; blobName: string }> {
  const { accountName, accountKey } = parseConnectionString(env.AZURE_STORAGE_CONNECTION_STRING);
  const container = env.AZURE_STORAGE_CONTAINER;

  // Generate blob name: {user_id}/{file_type}/{timestamp}_{uuid}.{ext}
  const ext = filename.includes('.') ? filename.split('.').pop() : 'bin';
  const timestamp = Date.now();
  const uuid = crypto.randomUUID();
  const blobName = `${userId}/${fileType}/${timestamp}_${uuid}.${ext}`;

  const url = `https://${accountName}.blob.core.windows.net/${container}/${blobName}`;
  const xmsDate = new Date().toUTCString();
  const xmsVersion = '2020-10-02';

  const headers: Record<string, string> = {
    'Content-Type': contentType,
    'x-ms-blob-type': 'BlockBlob',
    'x-ms-date': xmsDate,
    'x-ms-version': xmsVersion,
  };

  const authHeader = await createSharedKeyAuth(
    accountName, accountKey, 'PUT', url, headers, fileData.byteLength
  );

  const response = await fetch(url, {
    method: 'PUT',
    headers: {
      ...headers,
      'Authorization': authHeader,
      'Content-Length': fileData.byteLength.toString(),
    },
    body: fileData,
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Azure Blob upload failed: ${response.status} - ${errorText}`);
  }

  return { blobUrl: url, blobName };
}

// ============================================================================
// TensorLake Document Conversion (via file_url)
// ============================================================================
const TENSORLAKE_BASE = 'https://api.tensorlake.ai/documents/v2';

/**
 * Generate a SAS (Shared Access Signature) URL for an Azure Blob.
 * The SAS URL allows TensorLake to read the file directly from Azure Blob.
 */
async function generateBlobSasUrl(
  blobUrl: string,
  env: UploadEnv,
  expiryMinutes: number = 30,
): Promise<string> {
  const { accountName, accountKey } = parseConnectionString(env.AZURE_STORAGE_CONNECTION_STRING);

  const urlObj = new URL(blobUrl);
  // path = /{container}/{blobName}
  const pathParts = urlObj.pathname.split('/').filter(Boolean);
  const container = pathParts[0];
  const blobName = pathParts.slice(1).join('/');

  const version = '2020-10-02';
  const now = new Date();
  const start = new Date(now.getTime() - 5 * 60 * 1000); // 5 min ago
  const expiry = new Date(now.getTime() + expiryMinutes * 60 * 1000);

  const sp = 'r';           // permissions: read
  const sr = 'b';           // signed resource: blob
  const st = start.toISOString().replace(/\.\d{3}Z$/, 'Z');
  const se = expiry.toISOString().replace(/\.\d{3}Z$/, 'Z');
  const spr = 'https';

  // String to sign for Service SAS
  const stringToSign = [
    sp,                                          // signedPermissions
    st,                                          // signedStart
    se,                                          // signedExpiry
    `/blob/${accountName}/${container}/${blobName}`, // canonicalizedResource
    '',                                          // signedIdentifier
    '',                                          // signedIP
    spr,                                         // signedProtocol
    version,                                     // signedVersion
    sr,                                          // signedResource
    '',                                          // signedSnapshotTime
    '',                                          // rscc (cache-control)
    '',                                          // rscd (content-disposition)
    '',                                          // rsce (content-encoding)
    '',                                          // rscl (content-language)
    '',                                          // rsct (content-type)
  ].join('\n');

  const keyBytes = Uint8Array.from(atob(accountKey), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  const sig = btoa(String.fromCharCode(...new Uint8Array(signature)));

  const params = new URLSearchParams({
    sv: version, st, se, sr, sp, spr, sig,
  });

  return `${blobUrl}?${params.toString()}`;
}

function getMimeType(filename: string): string {
  const ext = filename.toLowerCase().split('.').pop() || '';
  const mimeMap: Record<string, string> = {
    pdf: 'application/pdf', doc: 'application/msword',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xls: 'application/vnd.ms-excel',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    ppt: 'application/vnd.ms-powerpoint',
    pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
    webp: 'image/webp', bmp: 'image/bmp', tiff: 'image/tiff',
    html: 'text/html', txt: 'text/plain', csv: 'text/csv',
    json: 'application/json', xml: 'application/xml',
  };
  return mimeMap[ext] || 'application/octet-stream';
}

/**
 * Convert a file to text/markdown via TensorLake API using file_url.
 * 
 * 2-step process (skips multipart upload):
 *   1. POST /read  — pass file_url (SAS URL), get parse_id
 *   2. GET  /parse/:id — poll until status === "successful"
 *
 * The file must already be uploaded to Azure Blob with a SAS URL.
 */
async function convertWithTensorLake(
  fileUrl: string,
  filename: string,
  apiKey: string,
): Promise<string> {
  console.log(`[TensorLake] Converting via file_url: ${filename}`);

  // ── Step 1: Start parse job with file_url ────────────────────────────
  const parseResp = await fetch(`${TENSORLAKE_BASE}/read`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ file_url: fileUrl }),
  });

  if (!parseResp.ok) {
    const errText = await parseResp.text();
    throw new Error(`TensorLake parse start failed: ${parseResp.status} - ${errText.substring(0, 200)}`);
  }

  const parseData: any = await parseResp.json();
  const parseId = parseData.parse_id || parseData.task_id;
  if (!parseId) throw new Error('TensorLake did not return a parse_id');
  console.log(`[TensorLake] Parse started: ${parseId}`);

  // ── Step 2: Poll for results ─────────────────────────────────────────
  // Adaptive delays: fast initially, slower over time (~10 min max)
  const getDelay = (attempt: number): number => {
    if (attempt < 3) return 100;
    if (attempt < 8) return 300;
    if (attempt < 15) return 500;
    if (attempt < 40) return 1000;
    if (attempt < 80) return 2000;
    return 5000;
  };

  for (let attempt = 0; attempt < 150; attempt++) {
    await new Promise(r => setTimeout(r, getDelay(attempt)));

    const pollResp = await fetch(`${TENSORLAKE_BASE}/parse/${parseId}`, {
      headers: { 'Authorization': `Bearer ${apiKey}` },
    });

    if (!pollResp.ok) {
      const errText = await pollResp.text();
      console.error(`[TensorLake] Poll ${attempt} FAILED: HTTP ${pollResp.status} - ${errText.substring(0, 200)}`);
      throw new Error(`TensorLake poll failed: ${pollResp.status} - ${errText.substring(0, 200)}`);
    }

    // Get raw text first to log it
    const rawText = await pollResp.text();
    let pollData: any;
    try {
      pollData = JSON.parse(rawText);
    } catch (e) {
      console.error(`[TensorLake] Poll ${attempt} JSON parse error: ${rawText.substring(0, 500)}`);
      throw new Error(`TensorLake returned invalid JSON: ${rawText.substring(0, 200)}`);
    }

    const status = (pollData.status || '').toLowerCase();
    
    // Log EVERY poll for debugging (first 10, then every 5th)
    if (attempt < 10 || attempt % 5 === 0) {
      const keys = Object.keys(pollData).join(',');
      const hasChunks = !!(pollData.chunks?.length);
      const hasPages = !!(pollData.pages?.length);
      const hasDocMd = !!(pollData.document_markdown);
      console.log(`[TensorLake] Poll ${attempt}: status="${status}" keys=[${keys}] chunks=${hasChunks} pages=${hasPages} docMd=${hasDocMd}`);
    }

    // TensorLake returns HTTP 200 with status="processing" while still working
    if (status === 'processing' || status === 'pending' || status === 'queued') {
      continue;
    }

    // Log the transition to non-processing status
    console.log(`[TensorLake] Poll ${attempt}: status="${status}" - CHECKING FOR CONTENT`);

    if (status === 'successful' || status === 'completed' || status === 'success' || pollData.result) {
      // Extract content — prefer document_markdown, then chunks, then pages
      // document_markdown is the cleanest output
      const docMarkdown = pollData?.document_markdown || pollData?.result?.document_markdown;
      if (docMarkdown && docMarkdown.trim()) {
        console.log(`[TensorLake] Done: ${docMarkdown.length} chars from document_markdown`);
        return docMarkdown;
      }

      const chunks = pollData?.chunks || pollData?.result?.chunks || [];
      if (chunks.length > 0) {
        const content = chunks.map((c: any) => c.content || c.text || '').join('\n\n');
        if (content.trim()) {
          console.log(`[TensorLake] Done: ${content.length} chars from ${chunks.length} chunks`);
          return content;
        }
      }

      // Fallback: extract from pages (structured format)
      const pages = pollData?.pages || pollData?.result?.pages || [];
      if (pages.length > 0) {
        const pageTexts: string[] = [];
        for (const page of pages) {
          // Try page_fragments first (new format)
          if (page.page_fragments) {
            for (const frag of page.page_fragments) {
              const text = frag?.content?.content || frag?.content || frag?.text || '';
              if (text) pageTexts.push(text);
            }
          } else {
            // Old format: direct content/text
            const text = page.content || page.text || '';
            if (text) pageTexts.push(text);
          }
        }
        if (pageTexts.length > 0) {
          const content = pageTexts.join('\n\n');
          console.log(`[TensorLake] Done: ${content.length} chars from ${pages.length} pages`);
          return content;
        }
      }

      const md = pollData?.markdown || pollData?.result?.markdown;
      if (md) return md;

      throw new Error('TensorLake returned empty content');
    }

    if (status === 'failed' || pollData.error) {
      throw new Error(`TensorLake conversion failed: ${pollData.error || 'Unknown error'}`);
    }
  }

  throw new Error('Document conversion timed out. Try a smaller file or a different format.');
}

// ============================================================================
// Groq LLM - HTML Cleanup
// ============================================================================
async function cleanHtmlWithLlm(html: string, env: UploadEnv): Promise<string> {
  const truncated = html.substring(0, 30000);

  const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${env.GROQ_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'llama-3.3-70b-versatile',
      messages: [
        {
          role: 'system',
          content: `Convert HTML to clean markdown for semantic search.

Rules:
1. Convert HTML tables to markdown tables or readable list format
2. Preserve ALL information - do NOT summarize
3. Remove all HTML tags - output pure markdown/text
4. Remove empty paragraphs and excessive whitespace
5. Keep headings, lists, contact info, skills, dates, names

Output ONLY the converted markdown.`,
        },
        { role: 'user', content: truncated },
      ],
      temperature: 0,
      max_tokens: 8000,
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Groq HTML cleanup failed: ${response.status} - ${errText}`);
  }

  const result = await response.json() as any;
  return result.choices?.[0]?.message?.content || html;
}

// ============================================================================
// Groq LLM - Title Generation
// ============================================================================
async function generateTitleWithLlm(
  content: string,
  filename: string | undefined,
  env: UploadEnv
): Promise<string> {
  const contentPreview = content.substring(0, 4000);
  const filenameHint = filename ? `\nOriginal filename: ${filename}` : '';

  const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${env.GROQ_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'llama-3.3-70b-versatile',
      messages: [
        {
          role: 'system',
          content: 'You are a document analysis expert. Generate concise, descriptive titles.',
        },
        {
          role: 'user',
          content: `Analyze this document and generate a descriptive title/summary that captures what it contains. This will be used for document retrieval and search.
${filenameHint}
Document content:
---
${contentPreview}
---

Requirements for the title:
1. Start with the document type and main subject (e.g., "Resume of Amit Navgire - ...")
2. Include the person's name if identifiable
3. Summarize key topics: roles, skills, companies, expertise areas, or main themes
4. Be specific enough that someone searching could find this document
5. Length: 150-250 characters (detailed but concise)
6. Do NOT include quotes around the title
7. Use natural language, not bullet points

Generate ONLY the title, nothing else:`,
        },
      ],
      temperature: 0.3,
      max_tokens: 100,
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Groq title gen failed: ${response.status} - ${errText}`);
  }

  const result = await response.json() as any;
  let title = result.choices?.[0]?.message?.content?.trim() || '';
  // Cap title at 300 chars and remove surrounding quotes
  title = title.replace(/^["']|["']$/g, '').substring(0, 300);
  return title || filename || 'Untitled Document';
}

// ============================================================================
// Markdown-Aware Semantic Chunker
// Splits by heading structure, preserves [Section > Subsection] context prefix,
// merges small sections. Falls back to naive word-based for non-markdown.
// ============================================================================

interface Section {
  heading: string;
  content: string;
  level: number;
  parentContext: string;
}

/** Detect if text has meaningful markdown heading structure */
function hasMarkdownStructure(text: string): boolean {
  const headingCount = (text.match(/^#{1,6}\s+.+/gm) || []).length;
  return headingCount >= 3;
}

/** Parse markdown into sections with heading hierarchy */
function parseSections(text: string): Section[] {
  const lines = text.split('\n');
  const sections: Section[] = [];
  let currentHeading: string | null = null;
  let currentLevel = 0;
  let currentLines: string[] = [];
  const headingStack: Array<[number, string]> = [];

  for (const line of lines) {
    const match = line.match(/^(#{1,6})\s+(.*)/);
    if (match) {
      // Flush previous section
      if (currentHeading !== null || currentLines.length > 0) {
        const content = currentLines.join('\n').trim();
        if (content) {
          const ctx = headingStack.map(([, h]) => h).join(' > ');
          sections.push({
            heading: currentHeading || '',
            content,
            level: currentLevel,
            parentContext: ctx,
          });
        }
      }

      const level = match[1].length;
      const headingText = match[2].trim();

      // Pop stack to maintain hierarchy
      while (headingStack.length > 0 && headingStack[headingStack.length - 1][0] >= level) {
        headingStack.pop();
      }
      headingStack.push([level, headingText]);

      currentHeading = headingText;
      currentLevel = level;
      currentLines = [];
    } else {
      currentLines.push(line);
    }
  }

  // Flush final section
  if (currentLines.length > 0) {
    const content = currentLines.join('\n').trim();
    if (content) {
      const ctx = headingStack.map(([, h]) => h).join(' > ');
      sections.push({
        heading: currentHeading || '',
        content,
        level: currentLevel,
        parentContext: ctx,
      });
    }
  }

  return sections;
}

/** Build context prefix like [Parent > Child > Subsection] */
function buildPrefix(ctx: string, heading: string): string {
  if (ctx && heading && !ctx.includes(heading)) {
    return `[${ctx} > ${heading}]`;
  } else if (ctx) {
    return `[${ctx}]`;
  } else if (heading) {
    return `[${heading}]`;
  }
  return '';
}

/** Merge adjacent small chunks to meet MIN_CHUNK_WORDS, up to 5 passes */
function mergeSmallChunks(chunks: string[]): string[] {
  let result = [...chunks];
  for (let pass = 0; pass < 5; pass++) {
    const merged: string[] = [];
    let i = 0;
    while (i < result.length) {
      const chunk = result[i];
      const wc = chunk.split(/\s+/).length;

      // Try forward merge with next chunk
      if (wc < MIN_CHUNK_WORDS && i + 1 < result.length) {
        const combined = chunk + '\n\n' + result[i + 1];
        if (combined.split(/\s+/).length <= MAX_CHUNK_WORDS) {
          merged.push(combined);
          i += 2;
          continue;
        }
      }
      // Try backward merge with previous chunk
      if (wc < MIN_CHUNK_WORDS && merged.length > 0) {
        const combined = merged[merged.length - 1] + '\n\n' + chunk;
        if (combined.split(/\s+/).length <= MAX_CHUNK_WORDS) {
          merged[merged.length - 1] = combined;
          i += 1;
          continue;
        }
      }
      merged.push(chunk);
      i += 1;
    }
    result = merged;
    if (result.every(c => c.split(/\s+/).length >= MIN_CHUNK_WORDS)) break;
  }
  return result;
}

/** Naive word-based chunking (fallback for non-markdown content) */
function naiveChunkText(text: string): string[] {
  const words = text.split(/\s+/).filter(w => w.length > 0);
  if (words.length <= FALLBACK_CHUNK_SIZE) {
    return [text.trim()];
  }
  const chunks: string[] = [];
  let start = 0;
  while (start < words.length) {
    const end = Math.min(start + FALLBACK_CHUNK_SIZE, words.length);
    chunks.push(words.slice(start, end).join(' '));
    start = end - FALLBACK_OVERLAP;
    if (start >= words.length - FALLBACK_OVERLAP) break;
  }
  return chunks;
}

/** Main chunking function: uses semantic if markdown, naive otherwise */
function chunkText(text: string): string[] {
  const trimmed = text.trim();
  if (!trimmed) return [];

  const words = trimmed.split(/\s+/).filter(w => w.length > 0);
  // Small documents: return as-is
  if (words.length <= MIN_CHUNK_WORDS) {
    return [trimmed];
  }

  // Non-markdown: fall back to naive chunking
  if (!hasMarkdownStructure(trimmed)) {
    console.log('[Upload] No markdown structure detected, using naive chunking');
    return naiveChunkText(trimmed);
  }

  // Markdown-aware semantic chunking
  console.log('[Upload] Markdown structure detected, using semantic chunking');
  const sections = parseSections(trimmed);
  const rawChunks: string[] = [];

  for (const section of sections) {
    const prefix = buildPrefix(section.parentContext, section.heading);
    const sectionWords = section.content.split(/\s+/);

    if (sectionWords.length <= MAX_CHUNK_WORDS) {
      // Section fits in one chunk
      rawChunks.push(prefix ? `${prefix}\n${section.content}` : section.content);
    } else {
      // Split large section by paragraphs
      const paragraphs = section.content.split(/\n\n+/);
      let currentParas: string[] = [];
      let currentWc = 0;

      for (const para of paragraphs) {
        const paraWc = para.split(/\s+/).length;

        if (paraWc > MAX_CHUNK_WORDS) {
          // Flush accumulated paragraphs
          if (currentParas.length > 0) {
            const chunkContent = currentParas.join('\n\n');
            rawChunks.push(prefix ? `${prefix}\n${chunkContent}` : chunkContent);
            currentParas = [];
            currentWc = 0;
          }
          // Word-split oversized paragraph
          const pWords = para.split(/\s+/);
          for (let j = 0; j < pWords.length; j += MAX_CHUNK_WORDS) {
            const sub = pWords.slice(j, j + MAX_CHUNK_WORDS).join(' ');
            rawChunks.push(prefix ? `${prefix}\n${sub}` : sub);
          }
        } else if (currentWc + paraWc > MAX_CHUNK_WORDS) {
          // Flush and start new accumulation
          const chunkContent = currentParas.join('\n\n');
          rawChunks.push(prefix ? `${prefix}\n${chunkContent}` : chunkContent);
          currentParas = [para];
          currentWc = paraWc;
        } else {
          currentParas.push(para);
          currentWc += paraWc;
        }
      }
      // Flush remaining
      if (currentParas.length > 0) {
        const chunkContent = currentParas.join('\n\n');
        rawChunks.push(prefix ? `${prefix}\n${chunkContent}` : chunkContent);
      }
    }
  }

  // Merge small adjacent chunks
  const finalChunks = mergeSmallChunks(rawChunks);
  console.log(`[Upload] Semantic chunking: ${sections.length} sections -> ${rawChunks.length} raw -> ${finalChunks.length} merged chunks`);
  return finalChunks;
}

// ============================================================================
// Detect if content needs HTML cleanup
// ============================================================================
function needsHtmlCleanup(content: string): boolean {
  const htmlTagCount = (content.match(/<[a-z][\s\S]*?>/gi) || []).length;
  const hasStructuralTags = /<(table|thead|tbody|tr|td|th|div|span|section|article|nav|header|footer)\b/i.test(content);
  return hasStructuralTags || htmlTagCount > 10;
}

// ============================================================================
// Storage Quota Check
// ============================================================================
async function checkStorageQuota(
  userId: string,
  env: UploadEnv
): Promise<{ totalBytes: number; allowed: boolean; message?: string }> {
  try {
    // Query Supabase for total storage used by this user (only successful uploads in notes table)
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/rpc/get_user_storage_bytes`,
      {
        method: 'POST',
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ p_user_id: userId }),
      }
    );

    if (!response.ok) {
      // Fallback: query notes table directly
      console.warn('[Quota] RPC failed, falling back to direct query');
      const fallbackResp = await fetch(
        `${env.SUPABASE_URL}/rest/v1/notes?user_id=eq.${userId}&select=metadata`,
        {
          headers: {
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
        }
      );

      if (!fallbackResp.ok) {
        console.error('[Quota] Fallback query also failed');
        return { totalBytes: 0, allowed: true }; // Allow on error - don't block users
      }

      const notes = await fallbackResp.json() as Array<{ metadata: any }>;
      let totalBytes = 0;
      for (const note of notes) {
        const sizeBytes = note.metadata?.size_bytes;
        if (typeof sizeBytes === 'number') totalBytes += sizeBytes;
      }

      return {
        totalBytes,
        allowed: totalBytes < MAX_TOTAL_STORAGE_BYTES,
        message: totalBytes >= MAX_TOTAL_STORAGE_BYTES
          ? `Storage limit reached. You've used ${(totalBytes / 1024 / 1024).toFixed(1)}MB of ${MAX_TOTAL_STORAGE_BYTES / 1024 / 1024}MB allowed.`
          : undefined,
      };
    }

    const totalBytes = (await response.json()) as number;
    return {
      totalBytes,
      allowed: totalBytes < MAX_TOTAL_STORAGE_BYTES,
      message: totalBytes >= MAX_TOTAL_STORAGE_BYTES
        ? `Storage limit reached. You've used ${(totalBytes / 1024 / 1024).toFixed(1)}MB of ${MAX_TOTAL_STORAGE_BYTES / 1024 / 1024}MB allowed.`
        : undefined,
    };
  } catch (err) {
    console.error('[Quota] Error checking quota:', err);
    return { totalBytes: 0, allowed: true }; // Allow on error
  }
}

// ============================================================================
// Upload Trace Logging
// ============================================================================

/**
 * Insert the initial trace row into Supabase.
 * MUST be awaited before processUpload starts, to prevent the race condition
 * where PATCH runs before the row exists (PATCH on zero rows returns 204 = silent no-op).
 */
async function insertUploadTrace(
  trace: UploadTraceEntry,
  env: UploadEnv,
): Promise<boolean> {
  if (env.LOG_ENABLED !== 'true') return false;

  try {
    const response = await fetch(`${env.SUPABASE_URL}/rest/v1/upload_traces`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Prefer': 'return=minimal',
      },
      body: JSON.stringify({
        trace_id: trace.trace_id,
        user_id: trace.user_id,
        upload_type: trace.upload_type,
        original_filename: trace.original_filename,
        file_type: trace.file_type,
        file_size_bytes: trace.file_size_bytes,
        tag: trace.tag,
        status: trace.status,
        request_received_at: trace.request_received_at,
        user_storage_before_bytes: trace.user_storage_before_bytes,
        auth_method: trace.auth_method,
      }),
    });
    if (!response.ok) {
      console.error('[UploadTrace] Failed to insert:', response.status, await response.text());
      return false;
    }
    console.log(`[UploadTrace] Inserted trace ${trace.trace_id}`);
    return true;
  } catch (err) {
    console.error('[UploadTrace] Error inserting trace:', err);
    return false;
  }
}

async function updateUploadTrace(
  traceId: string,
  updates: Partial<UploadTraceEntry>,
  env: UploadEnv
): Promise<void> {
  const patchBody = JSON.stringify(updates);

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await fetch(
        `${env.SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.${traceId}`,
        {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            'Prefer': 'return=representation',
          },
          body: patchBody,
        }
      );

      if (!response.ok) {
        const errText = await response.text();
        console.error(`[UploadTrace] PATCH failed: ${response.status} - ${errText.substring(0, 200)}`);
        return;
      }

      // Check if rows were actually updated (empty array = row didn't exist)
      const result = await response.json() as any[];
      if (result.length === 0) {
        console.warn(`[UploadTrace] PATCH matched 0 rows for ${traceId} (attempt ${attempt + 1})`);
        if (attempt === 0) {
          // Row might not exist yet — wait and retry
          await new Promise(r => setTimeout(r, 500));
          continue;
        }
        console.error(`[UploadTrace] PATCH still matched 0 rows after retry for ${traceId}`);
      } else {
        return; // Success
      }
    } catch (err) {
      console.error(`[UploadTrace] Error updating trace (attempt ${attempt + 1}):`, err);
    }
  }
}

// ============================================================================
// Cache Invalidation (after upload completes)
// ============================================================================
async function invalidateUserCaches(userId: string, env: UploadEnv): Promise<void> {
  try {
    // Invalidate search cache by bumping version
    await env.SEARCH_CACHE.put(`version_${userId}`, Date.now().toString());
    console.log(`[Cache] Invalidated search cache for user ${userId.substring(0, 8)}`);

    // Invalidate tags cache
    await env.TAGS_CACHE.delete(`tags_${userId}`);
    console.log(`[Cache] Invalidated tags cache for user ${userId.substring(0, 8)}`);
  } catch (err) {
    console.error('[Cache] Error invalidating caches:', err);
  }
}

// ============================================================================
// Core Upload Pipeline (runs in background via ctx.waitUntil)
// ============================================================================
async function processUpload(
  trace: UploadTraceEntry,
  fileData: ArrayBuffer | null,
  markdownContent: string | null,
  env: UploadEnv
): Promise<void> {
  const pipelineErrors: string[] = [];
  const startTime = Date.now();
  trace.processing_started_at = new Date().toISOString();

  // Immediately mark trace as 'processing' so we know processUpload started
  try {
    await updateUploadTrace(trace.trace_id, {
      status: 'processing',
      processing_started_at: trace.processing_started_at,
    }, env);
  } catch (e) {
    console.error('[Upload] Failed to update trace to processing:', e);
  }

  try {
    let content = markdownContent || '';
    let blobUrl: string | undefined;
    let blobName: string | undefined;
    const filename = trace.original_filename || 'document';
    const fileExt = '.' + (filename.split('.').pop()?.toLowerCase() || '');
    const isPlainText = PLAIN_TEXT_EXTENSIONS.has(fileExt);

    // ====== Step 1: Azure Blob Upload, then TensorLake Conversion ======
    // Upload to blob first, then TensorLake fetches it via SAS URL
    if (fileData && fileData.byteLength > 0) {
      // Step 1a: Upload to Azure Blob Storage
      trace.blob_upload_started_at = new Date().toISOString();
      const blobStart = Date.now();
      try {
        const result = await uploadToAzureBlob(
          fileData, trace.user_id, trace.upload_type,
          filename, getMimeType(filename), env
        );
        trace.timing_blob_upload_ms = Date.now() - blobStart;
        trace.blob_upload_completed_at = new Date().toISOString();
        blobUrl = result.blobUrl;
        blobName = result.blobName;
        trace.blob_url = blobUrl;
        console.log(`[Upload] Blob uploaded: ${blobName} (${trace.timing_blob_upload_ms}ms)`);

        // Trace update: blob uploaded, starting TensorLake
        await updateUploadTrace(trace.trace_id, {
          blob_url: trace.blob_url,
          blob_upload_started_at: trace.blob_upload_started_at,
          blob_upload_completed_at: trace.blob_upload_completed_at,
          timing_blob_upload_ms: trace.timing_blob_upload_ms,
        }, env);
      } catch (err) {
        trace.timing_blob_upload_ms = Date.now() - blobStart;
        pipelineErrors.push(`Blob upload: ${err}`);
        console.error('[Upload] Blob upload failed:', err);
      }

      // Step 1b: Convert with TensorLake (via file_url from Azure Blob)
      if (isPlainText) {
        // Plain text - read directly, no TensorLake needed
        trace.conversion_started_at = new Date().toISOString();
        const convStart = Date.now();
        try {
          content = new TextDecoder().decode(fileData);
          trace.conversion_method = 'plain_text';
        } catch (err) {
          pipelineErrors.push(`Text decode: ${err}`);
        }
        trace.timing_conversion_ms = Date.now() - convStart;
        trace.conversion_completed_at = new Date().toISOString();
      } else if (!blobUrl) {
        // Blob upload failed — can't use file_url approach
        pipelineErrors.push('TensorLake conversion skipped: blob upload failed (no URL available)');
      } else if (trace.upload_type === 'screenshot') {
        // Screenshots - use TensorLake for OCR via file_url
        trace.conversion_started_at = new Date().toISOString();
        
        // Trace update: starting TensorLake (before the long poll)
        await updateUploadTrace(trace.trace_id, {
          conversion_started_at: trace.conversion_started_at,
        }, env);
        
        const convStart = Date.now();
        try {
          const sasUrl = await generateBlobSasUrl(blobUrl, env);
          content = await convertWithTensorLake(sasUrl, filename, env.TENSORLAKE_API_KEY);
          trace.conversion_method = 'tensorlake';
        } catch (err) {
          pipelineErrors.push(`TensorLake conversion: ${err}`);
          console.error('[Upload] TensorLake failed:', err);
          content = ''; // Will fail later if content is empty
        }
        trace.timing_conversion_ms = Date.now() - convStart;
        trace.conversion_completed_at = new Date().toISOString();

        // Trace update: TensorLake done
        await updateUploadTrace(trace.trace_id, {
          conversion_method: trace.conversion_method,
          conversion_started_at: trace.conversion_started_at,
          conversion_completed_at: trace.conversion_completed_at,
          timing_conversion_ms: trace.timing_conversion_ms,
        }, env);
      } else {
        // Documents (PDF, DOCX, etc.) - use TensorLake via file_url
        trace.conversion_started_at = new Date().toISOString();
        
        // Trace update: starting TensorLake (before the long poll)
        await updateUploadTrace(trace.trace_id, {
          conversion_started_at: trace.conversion_started_at,
        }, env);
        
        const convStart = Date.now();
        try {
          const sasUrl = await generateBlobSasUrl(blobUrl, env);
          content = await convertWithTensorLake(sasUrl, filename, env.TENSORLAKE_API_KEY);
          trace.conversion_method = 'tensorlake';
        } catch (err) {
          pipelineErrors.push(`TensorLake conversion: ${err}`);
          console.error('[Upload] TensorLake failed:', err);
          // For HTML files, try reading as text directly
          if (fileExt === '.html' || fileExt === '.htm') {
            try {
              content = new TextDecoder().decode(fileData);
              trace.conversion_method = 'direct_html';
            } catch (decErr) {
              pipelineErrors.push(`HTML fallback: ${decErr}`);
            }
          }
        }
        trace.timing_conversion_ms = Date.now() - convStart;
        trace.conversion_completed_at = new Date().toISOString();

        // Trace update: TensorLake done
        await updateUploadTrace(trace.trace_id, {
          conversion_method: trace.conversion_method,
          conversion_started_at: trace.conversion_started_at,
          conversion_completed_at: trace.conversion_completed_at,
          timing_conversion_ms: trace.timing_conversion_ms,
        }, env);
      }
    }

    // Check if we have content to work with
    if (!content || content.trim().length === 0) {
      throw new Error('No content extracted from document. The file may be empty or unsupported.');
    }

    trace.content_length = content.length;

    // Intermediate trace update: conversion done, about to start LLM + embedding steps
    try {
      await updateUploadTrace(trace.trace_id, {
        blob_url: trace.blob_url,
        conversion_method: trace.conversion_method,
        conversion_started_at: trace.conversion_started_at,
        conversion_completed_at: trace.conversion_completed_at,
        timing_blob_upload_ms: trace.timing_blob_upload_ms,
        timing_conversion_ms: trace.timing_conversion_ms,
        content_length: trace.content_length,
      }, env);
    } catch (e) {
      console.error('[Upload] Failed to update trace after conversion:', e);
    }

    // ====== Step 2: HTML Cleanup (if needed) ======
    if (needsHtmlCleanup(content)) {
      trace.html_cleanup_started_at = new Date().toISOString();
      const cleanStart = Date.now();
      try {
        content = await cleanHtmlWithLlm(content, env);
        console.log(`[Upload] HTML cleanup done: ${content.length} chars`);
      } catch (err) {
        pipelineErrors.push(`HTML cleanup: ${err}`);
        console.error('[Upload] HTML cleanup failed, using raw content:', err);
      }
      trace.timing_html_cleanup_ms = Date.now() - cleanStart;
      trace.html_cleanup_completed_at = new Date().toISOString();
      
      // Trace update: HTML cleanup done
      await updateUploadTrace(trace.trace_id, {
        html_cleanup_completed_at: trace.html_cleanup_completed_at,
        timing_html_cleanup_ms: trace.timing_html_cleanup_ms,
      }, env).catch(() => {});
    }

    // ====== Step 3: Title Generation ======
    trace.title_gen_started_at = new Date().toISOString();
    const titleStart = Date.now();
    let title: string;
    try {
      title = await generateTitleWithLlm(content, trace.original_filename, env);
      trace.title_generated = title;
      console.log(`[Upload] Title: ${title.substring(0, 80)}...`);
    } catch (err) {
      pipelineErrors.push(`Title generation: ${err}`);
      title = trace.original_filename || 'Untitled Document';
      trace.title_generated = title;
      console.error('[Upload] Title generation failed, using filename:', err);
    }
    trace.timing_title_gen_ms = Date.now() - titleStart;
    trace.title_gen_completed_at = new Date().toISOString();
    
    // Trace update: Title gen done
    await updateUploadTrace(trace.trace_id, {
      title_gen_completed_at: trace.title_gen_completed_at,
      timing_title_gen_ms: trace.timing_title_gen_ms,
      title_generated: trace.title_generated,
    }, env).catch(() => {});

    // ====== Step 4: Chunking ======
    const chunks = chunkText(content);
    trace.chunk_count = chunks.length;
    console.log(`[Upload] Chunked into ${chunks.length} chunks`);

    // ====== Step 5: Embedding Generation ======
    trace.embedding_started_at = new Date().toISOString();
    const embedStart = Date.now();
    let embeddings: number[][];
    try {
      // Generate embeddings for document summary (first 1000 words) + all chunks
      const docSummary = content.split(/\s+/).slice(0, 1000).join(' ');
      const textsToEmbed = [docSummary, ...chunks];

      // Note: For storage embeddings, DON'T use "Represent this sentence..." prefix
      // That prefix is only for search queries
      const response = await env.AI.run(env.EMBEDDING_MODEL as any, {
        text: textsToEmbed,
      });
      embeddings = (response as any).data;
      console.log(`[Upload] Generated ${embeddings.length} embeddings`);
    } catch (err) {
      throw new Error(`Embedding generation failed: ${err}`);
    }
    trace.timing_embedding_ms = Date.now() - embedStart;
    trace.embedding_completed_at = new Date().toISOString();
    
    // Trace update: Embeddings done
    await updateUploadTrace(trace.trace_id, {
      embedding_completed_at: trace.embedding_completed_at,
      timing_embedding_ms: trace.timing_embedding_ms,
      chunk_count: trace.chunk_count,
    }, env).catch(() => {});

    // ====== Step 6: Supabase DB Insert ======
    trace.db_insert_started_at = new Date().toISOString();
    
    // Trace update: DB insert starting (critical checkpoint before ctx.waitUntil timeout)
    await updateUploadTrace(trace.trace_id, {
      db_insert_started_at: trace.db_insert_started_at,
    }, env).catch(() => {});
    
    const dbStart = Date.now();
    let noteId: string;
    try {
      const fileType = trace.upload_type === 'screenshot' ? 'screenshot'
        : trace.upload_type === 'quick_note' ? 'quick_note'
        : 'uploaded_file';

      const noteData = {
        user_id: trace.user_id,
        title: title,
        content_markdown: content,
        tag: trace.tag || 'General',
        file_type: fileType,
        original_filename: trace.original_filename,
        blob_url: blobUrl,
        embedding: `[${embeddings[0].join(',')}]`, // Document-level embedding
        status: 'incomplete',  // Will be set to 'active' after vectorize completes
        metadata: {
          blob_name: blobName,
          size_bytes: trace.file_size_bytes || content.length,
          chunk_count: chunks.length,
          conversion_method: trace.conversion_method || 'direct',
          upload_source: 'worker',
        },
      };

      const insertResp = await fetch(`${env.SUPABASE_URL}/rest/v1/notes`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          'Prefer': 'return=representation',
        },
        body: JSON.stringify(noteData),
      });

      if (!insertResp.ok) {
        const errText = await insertResp.text();
        throw new Error(`Supabase insert failed: ${insertResp.status} - ${errText}`);
      }

      const inserted = await insertResp.json() as Array<{ id: string }>;
      noteId = inserted[0].id;
      trace.note_id = noteId;
      console.log(`[Upload] Note inserted: ${noteId}`);
    } catch (err) {
      throw new Error(`Database insert failed: ${err}`);
    }
    trace.timing_db_insert_ms = Date.now() - dbStart;
    trace.db_insert_completed_at = new Date().toISOString();

    // ====== Step 7: Vectorize Upsert (chunk vectors) ======
    trace.vectorize_started_at = new Date().toISOString();
    const vecStart = Date.now();
    try {
      const vectors: VectorizeVector[] = [];

      // Document-level vector
      vectors.push({
        id: `${noteId}_doc`,
        values: embeddings[0],
        metadata: {
          note_id: noteId,
          user_id: trace.user_id,
          title: title.substring(0, 200),
          tag: trace.tag || 'General',
          chunk_type: 'document',
          chunk_index: 0,
        } as Record<string, VectorizeVectorMetadata>,
      });

      // Chunk vectors
      for (let i = 0; i < chunks.length; i++) {
        vectors.push({
          id: `${noteId}_chunk_${i}`,
          values: embeddings[i + 1], // +1 because embeddings[0] is doc summary
          metadata: {
            note_id: noteId,
            user_id: trace.user_id,
            title: title.substring(0, 200),
            tag: trace.tag || 'General',
            chunk_type: 'chunk',
            chunk_index: i,
            chunk_text: chunks[i].substring(0, 500),
          } as Record<string, VectorizeVectorMetadata>,
        });
      }

      // Batch upsert (max 1000 per batch)
      for (let i = 0; i < vectors.length; i += 1000) {
        const batch = vectors.slice(i, i + 1000);
        await env.VECTORIZE.upsert(batch);
      }

      trace.vector_count = vectors.length;
      console.log(`[Upload] Upserted ${vectors.length} vectors to Vectorize`);
    } catch (err) {
      pipelineErrors.push(`Vectorize upsert: ${err}`);
      console.error('[Upload] Vectorize upsert failed:', err);
      // Don't throw - note is already in DB
    }
    trace.timing_vectorize_ms = Date.now() - vecStart;
    trace.vectorize_completed_at = new Date().toISOString();

    // ====== Step 8: Mark Note as Active ======
    // Note is now fully processed and searchable
    try {
      const updateResp = await fetch(
        `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}`,
        {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            'apikey': env.SUPABASE_SERVICE_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
          },
          body: JSON.stringify({ status: 'active' }),
        }
      );
      if (!updateResp.ok) {
        pipelineErrors.push(`Note status update failed: ${await updateResp.text()}`);
      } else {
        console.log(`[Upload] Note ${noteId} marked as active`);
      }
    } catch (err) {
      pipelineErrors.push(`Note status update: ${err}`);
    }

    // ====== Step 9: Cache Invalidation ======
    await invalidateUserCaches(trace.user_id, env);

    // ====== Step 10: Update storage quota ======
    const quotaAfter = await checkStorageQuota(trace.user_id, env);
    trace.user_storage_after_bytes = quotaAfter.totalBytes;

    // Mark complete
    trace.status = 'completed';
    trace.completed_at = new Date().toISOString();
    trace.timing_total_ms = Date.now() - startTime;
    trace.pipeline_errors = pipelineErrors.length > 0 ? pipelineErrors : undefined;

    console.log(`[Upload] ✅ Complete: ${trace.trace_id} in ${trace.timing_total_ms}ms (${pipelineErrors.length} warnings)`);

  } catch (err) {
    trace.status = 'failed';
    trace.error_message = String(err);
    trace.completed_at = new Date().toISOString();
    trace.timing_total_ms = Date.now() - startTime;
    trace.pipeline_errors = pipelineErrors.length > 0 ? pipelineErrors : undefined;
    console.error(`[Upload] ❌ Failed: ${trace.trace_id} - ${err}`);
  }

  // Update the trace in Supabase with final status
  await updateUploadTrace(trace.trace_id, {
    status: trace.status,
    processing_started_at: trace.processing_started_at,
    blob_upload_started_at: trace.blob_upload_started_at,
    blob_upload_completed_at: trace.blob_upload_completed_at,
    conversion_started_at: trace.conversion_started_at,
    conversion_completed_at: trace.conversion_completed_at,
    html_cleanup_started_at: trace.html_cleanup_started_at,
    html_cleanup_completed_at: trace.html_cleanup_completed_at,
    title_gen_started_at: trace.title_gen_started_at,
    title_gen_completed_at: trace.title_gen_completed_at,
    embedding_started_at: trace.embedding_started_at,
    embedding_completed_at: trace.embedding_completed_at,
    db_insert_started_at: trace.db_insert_started_at,
    db_insert_completed_at: trace.db_insert_completed_at,
    vectorize_started_at: trace.vectorize_started_at,
    vectorize_completed_at: trace.vectorize_completed_at,
    completed_at: trace.completed_at,
    timing_total_ms: trace.timing_total_ms,
    timing_blob_upload_ms: trace.timing_blob_upload_ms,
    timing_conversion_ms: trace.timing_conversion_ms,
    timing_html_cleanup_ms: trace.timing_html_cleanup_ms,
    timing_title_gen_ms: trace.timing_title_gen_ms,
    timing_embedding_ms: trace.timing_embedding_ms,
    timing_db_insert_ms: trace.timing_db_insert_ms,
    timing_vectorize_ms: trace.timing_vectorize_ms,
    title_generated: trace.title_generated,
    chunk_count: trace.chunk_count,
    vector_count: trace.vector_count,
    note_id: trace.note_id,
    blob_url: trace.blob_url,
    conversion_method: trace.conversion_method,
    content_length: trace.content_length,
    user_storage_after_bytes: trace.user_storage_after_bytes,
    error_message: trace.error_message,
    pipeline_errors: trace.pipeline_errors,
  }, env);
}

// ============================================================================
// OLD SYNCHRONOUS HANDLERS REMOVED
// The synchronous handlers (handleUploadFile, handleUploadScreenshot, 
// handleUploadQuickNote) have been replaced by Durable Object versions
// (handleUploadFileWithDO, handleUploadScreenshotWithDO, handleUploadQuickNoteWithDO)
// which bypass the 30-second wall-clock timeout limit.
// See upload-processor.ts for the Durable Object implementation.
// ============================================================================

// ============================================================================
// Route Handler: GET /api/v1/upload/status/:trace_id
// ============================================================================
export async function handleUploadStatus(
  traceId: string,
  authResult: AuthResult,
  env: UploadEnv,
  requestUrl?: URL
): Promise<Response> {
  if (!authResult.authenticated) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }

  // Allow passing user_id as query param (for admin dashboard viewing other users' traces)
  // Otherwise fall back to authenticated user's ID
  const userId = requestUrl?.searchParams.get('user_id') || authResult.user_id;
  
  if (!userId) {
    return new Response(
      JSON.stringify({ error: 'User ID required' }),
      { status: 400, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }

  try {
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.${traceId}&user_id=eq.${userId}&select=trace_id,status,current_step,upload_type,original_filename,file_size_bytes,title_generated,note_id,error_message,step_errors,timing_total_ms,timing_blob_upload_ms,timing_conversion_ms,timing_html_cleanup_ms,timing_title_gen_ms,timing_embedding_ms,timing_db_insert_ms,timing_vectorize_ms,completed_at,pipeline_errors,chunk_count,vector_count,conversion_method,user_storage_before_bytes,user_storage_after_bytes`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!response.ok) {
      return new Response(
        JSON.stringify({ error: 'Failed to fetch upload status' }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    const traces = await response.json() as any[];
    if (traces.length === 0) {
      return new Response(
        JSON.stringify({ error: 'Upload trace not found' }),
        { status: 404, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    return new Response(
      JSON.stringify(traces[0]),
      { status: 200, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `Status check failed: ${err}` }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }
}

// ============================================================================
// Route Handler: GET /api/v1/upload/quota
// ============================================================================
export async function handleUploadQuota(
  authResult: AuthResult,
  env: UploadEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }

  try {
    const quota = await checkStorageQuota(authResult.user_id, env);
    return new Response(
      JSON.stringify({
        user_id: authResult.user_id,
        storage_used_bytes: quota.totalBytes,
        storage_used_mb: (quota.totalBytes / 1024 / 1024).toFixed(1),
        storage_limit_bytes: MAX_TOTAL_STORAGE_BYTES,
        storage_limit_mb: (MAX_TOTAL_STORAGE_BYTES / 1024 / 1024).toFixed(0),
        storage_remaining_bytes: Math.max(0, MAX_TOTAL_STORAGE_BYTES - quota.totalBytes),
        storage_remaining_mb: (Math.max(0, MAX_TOTAL_STORAGE_BYTES - quota.totalBytes) / 1024 / 1024).toFixed(1),
        max_single_file_mb: (MAX_SINGLE_FILE_BYTES / 1024 / 1024).toFixed(0),
      }),
      { status: 200, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `Quota check failed: ${err}` }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }
}

// ============================================================================
// Helper: Convert ArrayBuffer to Base64
// ============================================================================
function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

// ============================================================================
// Route Handler: POST /api/v1/upload/cancel/:trace_id
// Cancel an in-progress upload
// ============================================================================
export async function handleCancelUpload(
  traceId: string,
  authResult: AuthResult,
  env: UploadEnv
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }

  try {
    // Verify the trace belongs to this user
    const traceResp = await fetch(
      `${env.SUPABASE_URL}/rest/v1/upload_traces?trace_id=eq.${traceId}&user_id=eq.${authResult.user_id}&select=trace_id,status`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      }
    );

    if (!traceResp.ok) {
      return new Response(
        JSON.stringify({ error: 'Failed to verify upload ownership' }),
        { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    const traces = await traceResp.json() as any[];
    if (traces.length === 0) {
      return new Response(
        JSON.stringify({ error: 'Upload not found or not owned by you' }),
        { status: 404, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    const trace = traces[0];
    if (trace.status === 'completed' || trace.status === 'failed' || trace.status === 'cancelled') {
      return new Response(
        JSON.stringify({ 
          error: 'Upload already finished',
          status: trace.status,
        }),
        { status: 400, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    // Get DO stub using trace_id as the ID
    const doId = env.UPLOAD_PROCESSOR.idFromName(traceId);
    const doStub = env.UPLOAD_PROCESSOR.get(doId);

    // Send cancel request to DO
    const cancelResp = await doStub.fetch(new Request('https://do/cancel', {
      method: 'POST',
    }));

    if (!cancelResp.ok) {
      const errData = await cancelResp.json() as any;
      return new Response(
        JSON.stringify({ error: errData.error || 'Cancel failed' }),
        { status: cancelResp.status, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    const result = await cancelResp.json();
    return new Response(
      JSON.stringify(result),
      { status: 200, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  } catch (err) {
    console.error('[Upload] Cancel error:', err);
    return new Response(
      JSON.stringify({ error: `Cancel failed: ${err}` }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }
}

// ============================================================================
// Route Handler: POST /api/v1/upload/file (Durable Object version)
// Uses Durable Object for long-running processing - no 30s timeout!
// ============================================================================
export async function handleUploadFileWithDO(
  request: Request,
  authResult: AuthResult,
  env: UploadEnv
): Promise<Response> {
  const traceId = generateTraceId();
  const receivedAt = new Date().toISOString();

  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: authResult.error || 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }

  const userId = authResult.user_id;

  try {
    const formData = await request.formData();
    const file = formData.get('file') as File | null;
    const tag = (formData.get('tag') as string) || 'General';
    const sourceUrl = formData.get('source_url') as string | null;

    // Check if source_url is from a blocked site (multimedia-heavy, not suitable for text extraction)
    if (sourceUrl) {
      const blockedSiteError = isBlockedSourceUrl(sourceUrl);
      if (blockedSiteError) {
        return new Response(
          JSON.stringify({ 
            error: blockedSiteError,
            code: 'BLOCKED_SITE',
          }),
          { status: 400, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
        );
      }
    }

    if (!file || file.size === 0) {
      return new Response(
        JSON.stringify({ error: 'No file provided or file is empty' }),
        { status: 400, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    // Check single file size limit
    if (file.size > MAX_SINGLE_FILE_BYTES) {
      return new Response(
        JSON.stringify({
          error: `File too large. Maximum size is ${MAX_SINGLE_FILE_BYTES / 1024 / 1024}MB. Your file is ${(file.size / 1024 / 1024).toFixed(1)}MB.`,
          code: 'FILE_TOO_LARGE',
        }),
        { status: 413, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    // Check storage quota
    const quota = await checkStorageQuota(userId, env);
    if (!quota.allowed) {
      return new Response(
        JSON.stringify({
          error: quota.message,
          code: 'STORAGE_LIMIT_REACHED',
          storage_used_mb: (quota.totalBytes / 1024 / 1024).toFixed(1),
          storage_limit_mb: (MAX_TOTAL_STORAGE_BYTES / 1024 / 1024).toFixed(0),
        }),
        { status: 413, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    // Check if adding this file would exceed quota
    if (quota.totalBytes + file.size > MAX_TOTAL_STORAGE_BYTES) {
      const remaining = MAX_TOTAL_STORAGE_BYTES - quota.totalBytes;
      return new Response(
        JSON.stringify({
          error: `Not enough storage. You have ${(remaining / 1024 / 1024).toFixed(1)}MB remaining, but this file is ${(file.size / 1024 / 1024).toFixed(1)}MB.`,
          code: 'INSUFFICIENT_STORAGE',
          storage_used_mb: (quota.totalBytes / 1024 / 1024).toFixed(1),
          storage_remaining_mb: (remaining / 1024 / 1024).toFixed(1),
        }),
        { status: 413, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    // Read file data and convert to base64 for DO
    const fileData = await file.arrayBuffer();
    const fileDataBase64 = arrayBufferToBase64(fileData);

    // Get DO stub using trace_id as the ID (allows direct cancel by trace_id)
    const doId = env.UPLOAD_PROCESSOR.idFromName(traceId);
    const doStub = env.UPLOAD_PROCESSOR.get(doId);

    // Start processing in DO
    const startResp = await doStub.fetch(new Request('https://do/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        trace_id: traceId,
        user_id: userId,
        upload_type: 'file',
        original_filename: file.name,
        file_type: file.type || getMimeType(file.name),
        file_size_bytes: file.size,
        tag,
        auth_method: authResult.auth_method,
        user_storage_before_bytes: quota.totalBytes,
        file_data_base64: fileDataBase64,
      }),
    }));

    if (!startResp.ok) {
      const errData = await startResp.json() as any;
      throw new Error(errData.error || 'Failed to start upload processing');
    }

    // Return immediately
    return new Response(
      JSON.stringify({
        success: true,
        message: 'Upload accepted. Processing in background (Durable Object).',
        trace_id: traceId,
        filename: file.name,
        size_bytes: file.size,
        storage_used_mb: (quota.totalBytes / 1024 / 1024).toFixed(1),
      }),
      { status: 202, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  } catch (err) {
    console.error('[Upload] Error handling file upload (DO):', err);
    return new Response(
      JSON.stringify({ error: `Upload failed: ${err}` }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }
}

// ============================================================================
// Route Handler: POST /api/v1/upload/screenshot (Durable Object version)
// ============================================================================
export async function handleUploadScreenshotWithDO(
  request: Request,
  authResult: AuthResult,
  env: UploadEnv
): Promise<Response> {
  const traceId = generateTraceId();

  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: authResult.error || 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }

  const userId = authResult.user_id;

  try {
    const formData = await request.formData();
    const file = formData.get('file') as File | null;
    const tag = (formData.get('tag') as string) || 'Screenshots';

    if (!file || file.size === 0) {
      return new Response(
        JSON.stringify({ error: 'No screenshot provided or file is empty' }),
        { status: 400, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    if (file.size > MAX_SINGLE_FILE_BYTES) {
      return new Response(
        JSON.stringify({
          error: `Screenshot too large. Maximum size is ${MAX_SINGLE_FILE_BYTES / 1024 / 1024}MB.`,
          code: 'FILE_TOO_LARGE',
        }),
        { status: 413, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    const quota = await checkStorageQuota(userId, env);
    if (!quota.allowed || quota.totalBytes + file.size > MAX_TOTAL_STORAGE_BYTES) {
      return new Response(
        JSON.stringify({
          error: quota.message || `Not enough storage for this screenshot.`,
          code: 'STORAGE_LIMIT_REACHED',
          storage_used_mb: (quota.totalBytes / 1024 / 1024).toFixed(1),
        }),
        { status: 413, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    // Read file data and convert to base64
    const fileData = await file.arrayBuffer();
    const fileDataBase64 = arrayBufferToBase64(fileData);

    // Get DO stub
    const doId = env.UPLOAD_PROCESSOR.idFromName(traceId);
    const doStub = env.UPLOAD_PROCESSOR.get(doId);

    // Start processing
    const startResp = await doStub.fetch(new Request('https://do/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        trace_id: traceId,
        user_id: userId,
        upload_type: 'screenshot',
        original_filename: file.name || 'screenshot.png',
        file_type: file.type || 'image/png',
        file_size_bytes: file.size,
        tag,
        auth_method: authResult.auth_method,
        user_storage_before_bytes: quota.totalBytes,
        file_data_base64: fileDataBase64,
      }),
    }));

    if (!startResp.ok) {
      const errData = await startResp.json() as any;
      throw new Error(errData.error || 'Failed to start upload processing');
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Screenshot accepted. Processing in background (Durable Object).',
        trace_id: traceId,
        filename: file.name,
        size_bytes: file.size,
      }),
      { status: 202, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  } catch (err) {
    console.error('[Upload] Error handling screenshot (DO):', err);
    return new Response(
      JSON.stringify({ error: `Upload failed: ${err}` }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }
}

// ============================================================================
// Route Handler: POST /api/v1/upload/quick-note (Durable Object version)
// ============================================================================
export async function handleUploadQuickNoteWithDO(
  request: Request,
  authResult: AuthResult,
  env: UploadEnv
): Promise<Response> {
  const traceId = generateTraceId();

  if (!authResult.authenticated || !authResult.user_id) {
    return new Response(
      JSON.stringify({ error: authResult.error || 'Unauthorized' }),
      { status: 401, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }

  const userId = authResult.user_id;

  try {
    const body = await request.json() as { content?: string; tag?: string; title?: string };

    if (!body.content || body.content.trim().length === 0) {
      return new Response(
        JSON.stringify({ error: 'Note content is required' }),
        { status: 400, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    const contentBytes = new TextEncoder().encode(body.content).length;
    if (contentBytes > MAX_SINGLE_FILE_BYTES) {
      return new Response(
        JSON.stringify({
          error: `Note content too large. Maximum size is ${MAX_SINGLE_FILE_BYTES / 1024 / 1024}MB.`,
          code: 'FILE_TOO_LARGE',
        }),
        { status: 413, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    const quota = await checkStorageQuota(userId, env);
    if (!quota.allowed || quota.totalBytes + contentBytes > MAX_TOTAL_STORAGE_BYTES) {
      return new Response(
        JSON.stringify({
          error: quota.message || 'Storage limit reached.',
          code: 'STORAGE_LIMIT_REACHED',
          storage_used_mb: (quota.totalBytes / 1024 / 1024).toFixed(1),
        }),
        { status: 413, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
      );
    }

    // Format quick note as markdown
    const markdown = body.title
      ? `# ${body.title}\n\n${body.content}`
      : body.content;

    // Get DO stub
    const doId = env.UPLOAD_PROCESSOR.idFromName(traceId);
    const doStub = env.UPLOAD_PROCESSOR.get(doId);

    // Start processing (quick notes don't need file data)
    const startResp = await doStub.fetch(new Request('https://do/start', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        trace_id: traceId,
        user_id: userId,
        upload_type: 'quick_note',
        original_filename: body.title || 'Quick Note',
        file_type: 'text/markdown',
        file_size_bytes: contentBytes,
        tag: body.tag || 'Quick Notes',
        auth_method: authResult.auth_method,
        user_storage_before_bytes: quota.totalBytes,
        markdown_content: markdown,
      }),
    }));

    if (!startResp.ok) {
      const errData = await startResp.json() as any;
      throw new Error(errData.error || 'Failed to start upload processing');
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Quick note accepted. Processing in background (Durable Object).',
        trace_id: traceId,
      }),
      { status: 202, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  } catch (err) {
    console.error('[Upload] Error handling quick note (DO):', err);
    return new Response(
      JSON.stringify({ error: `Upload failed: ${err}` }),
      { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } }
    );
  }
}

// ============================================================================
// Debug Route: Test TensorLake directly
// ============================================================================
export async function handleTestTensorLake(
  request: Request,
  env: UploadEnv
): Promise<Response> {
  try {
    const testUrl = 'https://www.w3.org/WAI/WCAG21/Techniques/pdf/img/table-word.pdf';
    
    // Step 1: Start parse
    const parseResp = await fetch(`${TENSORLAKE_BASE}/read`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${env.TENSORLAKE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ file_url: testUrl }),
    });
    
    const parseData: any = await parseResp.json();
    const parseId = parseData.parse_id;
    
    if (!parseResp.ok || !parseId) {
      return new Response(JSON.stringify({
        step: 'parse_start',
        status: parseResp.status,
        error: parseData,
      }), { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
    }
    
    // Step 2: Poll (max 30 seconds)
    for (let i = 0; i < 15; i++) {
      await new Promise(r => setTimeout(r, 2000));
      
      const pollResp = await fetch(`${TENSORLAKE_BASE}/parse/${parseId}`, {
        headers: { 'Authorization': `Bearer ${env.TENSORLAKE_API_KEY}` },
      });
      
      const pollData: any = await pollResp.json();
      const status = pollData.status?.toLowerCase();
      
      if (status === 'successful') {
        const chunks = pollData.chunks || [];
        return new Response(JSON.stringify({
          success: true,
          parse_id: parseId,
          status: status,
          poll_attempts: i + 1,
          chunks_count: chunks.length,
          first_chunk_preview: chunks[0]?.content?.substring(0, 200) || '(empty)',
          response_keys: Object.keys(pollData),
        }), { status: 200, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
      }
      
      if (status === 'failure' || status === 'failed') {
        return new Response(JSON.stringify({
          success: false,
          parse_id: parseId,
          status: status,
          error: pollData.error,
        }), { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
      }
    }
    
    return new Response(JSON.stringify({
      success: false,
      error: 'Timeout after 30s',
      parse_id: parseId,
    }), { status: 408, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
    
  } catch (err) {
    return new Response(JSON.stringify({
      error: String(err),
    }), { status: 500, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
  }
}
