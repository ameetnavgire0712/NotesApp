// agent/tools/bucket_filter.ts
// ===========================================================================
// Phase 4 retrieval primitive: fetch notes that match a topic keyword and
// fall inside a time window. Deterministic — no embeddings, no LLM.
//
// Why not call /rag-search-auth internally?
//   Classic search has no time-window parameter, and bolting one on would
//   require touching rag-search.ts (which we won't do per the isolation
//   rule). For the compare recipe, a keyword-on-title-or-content match is
//   sufficient — we just need representative notes from each bucket.
// ===========================================================================

import type { ToolContext, TimeWindow } from '../types';
import { resolveTimeWindow } from '../time_window';

export interface BucketFilterInput {
  topic: string;
  window: TimeWindow;
  /** Hard cap on rows returned. */
  limit?: number;
}

export interface BucketNote {
  note_id: string;
  title: string;
  content_preview: string;
  created_at: string;
  tag?: string;
  file_type?: string;
}

export interface BucketFilterOutput {
  window: TimeWindow;
  topic: string;
  notes: BucketNote[];
  total_in_window: number;
  matched_in_window: number;
}

/**
 * Fetch up to `limit` notes whose title OR content matches the topic
 * (case-insensitive substring) and whose created_at falls in `window`.
 */
export async function runBucketFilter(
  input: BucketFilterInput,
  ctx: ToolContext,
): Promise<BucketFilterOutput> {
  const { env } = ctx;
  const userId = ctx.scratchpad.user_id;
  const limit = Math.min(Math.max(input.limit ?? 25, 1), 100);

  const tr = resolveTimeWindow(input.window);
  const baseParams = new URLSearchParams();
  baseParams.set('user_id', `eq.${userId}`);
  // Skip soft-deleted notes (status column added in earlier migration).
  baseParams.append('status', 'neq.deleted');
  if (tr) {
    baseParams.append('created_at', `gte.${tr.gte}`);
    if (tr.lt) baseParams.append('created_at', `lt.${tr.lt}`);
  }

  const headers = {
    apikey: env.SUPABASE_SERVICE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
  };

  // ---- 1) Total notes in window (for trace context) ---------------------
  const totalUrl = `${env.SUPABASE_URL}/rest/v1/notes?${baseParams.toString()}&select=id&limit=1`;
  const totalResp = await fetch(totalUrl, {
    headers: { ...headers, Prefer: 'count=exact', Range: '0-0' },
  });
  let totalInWindow = 0;
  if (totalResp.ok) {
    const cr = totalResp.headers.get('Content-Range') || '';
    totalInWindow = parseInt(cr.split('/')[1] || '0', 10) || 0;
  }

  // ---- 2) Keyword match on title OR content_markdown OR description -----
  // If topic is empty/short, skip the OR filter and fetch every note in the
  // window — caller is asking "compare everything between these two periods".
  const matchParams = new URLSearchParams(baseParams);
  matchParams.set('select', 'id,title,content_markdown,description,tag,file_type,created_at');
  matchParams.set('order', 'created_at.desc');
  matchParams.set('limit', String(limit));
  let matchUrl = `${env.SUPABASE_URL}/rest/v1/notes?${matchParams.toString()}`;
  const trimmedTopic = (input.topic || '').trim();
  if (trimmedTopic.length >= 2) {
    const safeTopic = trimmedTopic.replace(/[%_]/g, '\\$&');
    const pattern = `*${safeTopic}*`;
    const orFilter = `or=(title.ilike.${pattern},content_markdown.ilike.${pattern},description.ilike.${pattern})`;
    matchUrl = `${matchUrl}&${orFilter}`;
  }
  const matchResp = await fetch(matchUrl, { headers });
  if (!matchResp.ok) {
    throw new Error(`bucket_filter postgrest failed: ${matchResp.status} ${await matchResp.text()}`);
  }
  const rows: any[] = await matchResp.json();

  const notes: BucketNote[] = rows.map(r => {
    const body =
      (r.content_markdown && r.content_markdown.toString()) ||
      (r.description && r.description.toString()) ||
      '';
    return {
      note_id: r.id,
      title: (r.title || '').toString(),
      content_preview: body.slice(0, 600),
      created_at: r.created_at,
      tag: r.tag,
      file_type: r.file_type,
    };
  });

  return {
    window: input.window,
    topic: input.topic,
    notes,
    total_in_window: totalInWindow,
    matched_in_window: notes.length,
  };
}
