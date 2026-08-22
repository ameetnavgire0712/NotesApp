// agent_v2/tools.ts
// ===========================================================================
// Tool implementations for the v2 agent.
//
// Each tool is a thin wrapper over EXISTING worker code (count_and_group,
// list_notes, summarize_many, rag-search forward closure). The planner LLM
// chooses which to call; this file just executes them and returns
// JSON-serialisable results.
// ===========================================================================

import type { ExecutionContext } from '@cloudflare/workers-types';
import type { RagSearchEnv } from '../rag-search';
import type { Scratchpad } from '../agent/types';
import { resolveTimeWindow } from '../agent/time_window';
import { runListNotes, type ListNotesNote } from '../agent/tools/list_notes';
import { runSummarizeMany, type SummarizeNote } from '../agent/tools/summarize_many';
import type { LeanVectorSearchFn } from './lean_search';
import type {
  ListNotesArgs,
  CountNotesArgs,
  VectorSearchArgs,
  FetchNoteArgs,
  SummarizeArgs,
  AskUserArgs,
} from './schemas';

// ---------------------------------------------------------------------------
// Result-card shape passed back to the Flutter client
// (mirrors what /rag-search-auth returns, so existing UI code works).
// ---------------------------------------------------------------------------
export interface ResultCard {
  note_id: string;
  title: string;
  description?: string;
  content_preview?: string;
  created_at?: string;
  file_type?: string;
  tag?: string;
  score?: number;
  /**
   * Stable 1-based citation index shared with the planner. Only set on
   * cards emitted by `vector_search`. Consumed by the client to number
   * carousel cards and resolve inline [N] citation chips.
   */
  citation_index?: number;
}

export interface ToolRunContext {
  env: RagSearchEnv;
  ctx: ExecutionContext;
  userId: string;
  requestId: string;
  /** Tag selection explicitly made in the dashboard. This is a hard filter. */
  selectedTags?: string[];
  /** Lean retrieval primitive (embed + hybrid + rerank, no LLM gates). */
  leanVectorSearch: LeanVectorSearchFn;
  /**
   * Legacy fallback closure that calls /rag-search-auth (full pipeline).
   * Retained for safety but vector_search now prefers leanVectorSearch.
   */
  forwardToClassic: () => Promise<Response>;
  /**
   * Global 1-based citation index per note_id, shared across every
   * vector_search call in this turn. Ensures a planner that runs two
   * refinement searches still sees stable, non-colliding [N] markers:
   * a note that appeared as [3] in call 1 stays [3] in call 2. The
   * handler renders `browseCards` sorted by this index so the carousel
   * position matches what the planner cited.
   */
  citationIndexById: Map<string, number>;
  /**
   * How many retrieval tools (list_notes | count_notes | vector_search)
   * have already run this turn. Enforced as a HARD cap of 1 across all
   * three — see `denyIfRetrievalAlreadyRan`. Prevents cascades like
   * `list_notes → vector_search` (which cause mixed source pools and
   * out-of-order badge numbers on the client) and `list_notes ×3`
   * (which drop cards from the earlier calls). The planner's system
   * prompt asks for a single retrieval; this belt-and-braces enforces it.
   */
  retrievalCallCount: number;
}

// If a retrieval tool already ran this turn, return an error stub that
// tells the planner to synthesise from what it already has instead of
// firing another retrieval. Called at the top of every retrieval tool.
function denyIfRetrievalAlreadyRan(c: ToolRunContext, toolName: string): { error: string } | null {
  if ((c.retrievalCallCount ?? 0) >= 1) {
    return {
      error: `A retrieval tool already ran this turn — write the final answer from that previous result. Do not call ${toolName} again.`,
    };
  }
  return null;
}

// ===========================================================================
// 1. list_notes
// ===========================================================================
export async function tool_list_notes(args: ListNotesArgs, c: ToolRunContext) {
  // F1: hard cap. See ToolRunContext.retrievalCallCount for rationale.
  const deny = denyIfRetrievalAlreadyRan(c, 'list_notes');
  if (deny) return { ...deny, notes: [], total_matched: 0, duration_ms: 0, _cards: [] };
  c.retrievalCallCount = (c.retrievalCallCount ?? 0) + 1;
  // F2: defensive — the map is already empty at turn start (loop.ts
  // seeds a fresh Map per turn), but clearing here makes the "cards are
  // numbered 1..N starting from this retrieval" invariant explicit.
  c.citationIndexById.clear();

  // Reuse existing runListNotes — it already accepts the same filter shape.
  const scratchpadShim: Scratchpad = {
    trace_id: 'v2',
    user_id: c.userId,
    query: '',
    structured: {} as any,
    candidates: [],
    evidence: [],
    partials: [],
    confidence: 0,
    steps: [],
  };
  const out = await runListNotes(
    {
      topic: args.topic,
      window: args.time_window,
      file_types: args.file_types,
      // A UI tag selection is an access-independent hard filter. Do not let
      // the planner omit it or substitute another tag.
      tags: c.selectedTags?.length ? c.selectedTags : args.tags,
      limit: args.limit,
    },
    { env: c.env, scratchpad: scratchpadShim, requestId: c.requestId },
  );

  const cards: ResultCard[] = out.notes.map(toCard);
  // Assign / reuse a stable global 1-based citation index per note_id so
  // the planner's inline [N] markers scroll to the correct client card
  // regardless of which retrieval tool produced them.
  const idxMap = c.citationIndexById;
  const withIndex = cards.map((card) => {
    let idx = card.note_id ? idxMap.get(card.note_id) : undefined;
    if (idx === undefined && card.note_id) {
      idx = idxMap.size + 1;
      idxMap.set(card.note_id, idx);
    }
    return { card: { ...card, citation_index: idx }, index: idx ?? 0 };
  });
  return {
    notes: withIndex.map(({ card, index }) => ({
      index,
      note_id: card.note_id,
      title: card.title,
      file_type: card.file_type,
      tag: card.tag,
      created_at: card.created_at,
    })),
    total_matched: out.total_matched,
    duration_ms: out.duration_ms,
    _cards: withIndex.map(({ card }) => card),
  };
}

// ===========================================================================
// 2. count_notes
// ===========================================================================
export async function tool_count_notes(args: CountNotesArgs, c: ToolRunContext) {
  // F1: count_notes also occupies the single retrieval slot. Prevents
  // "count_notes → list_notes" cascade fallback recipes.
  const deny = denyIfRetrievalAlreadyRan(c, 'count_notes');
  if (deny) return { ...deny, total: 0, time_label: null };
  c.retrievalCallCount = (c.retrievalCallCount ?? 0) + 1;

  const params = new URLSearchParams();
  params.set('user_id', `eq.${c.userId}`);
  params.append('status', 'neq.deleted');

  let timeLabel: string | undefined;
  if (args.time_window) {
    const tr = resolveTimeWindow(args.time_window);
    if (tr) {
      params.append('created_at', `gte.${tr.gte}`);
      if (tr.lt) params.append('created_at', `lt.${tr.lt}`);
      timeLabel = tr.label;
    }
  }
  if (args.file_types && args.file_types.length > 0) {
    const list = args.file_types.map(s => `"${s}"`).join(',');
    params.append('file_type', `in.(${list})`);
  }
  const tags = c.selectedTags?.length ? c.selectedTags : args.tags;
  if (tags && tags.length > 0) {
    const list = tags.map(s => `"${s}"`).join(',');
    params.append('tag', `in.(${list})`);
  }

  const headers = {
    apikey: c.env.SUPABASE_SERVICE_KEY,
    Authorization: `Bearer ${c.env.SUPABASE_SERVICE_KEY}`,
  };

  if (!args.group_by) {
    const cp = new URLSearchParams(params);
    cp.set('select', 'id');
    cp.set('limit', '1');
    const r = await fetch(`${c.env.SUPABASE_URL}/rest/v1/notes?${cp.toString()}`, {
      headers: { ...headers, Prefer: 'count=exact', Range: '0-0' },
    });
    if (!r.ok) throw new Error(`count_notes: ${r.status} ${await r.text()}`);
    const cr = r.headers.get('Content-Range') || '';
    const total = parseInt(cr.split('/')[1] || '0', 10) || 0;
    return { total, time_label: timeLabel ?? null };
  }

  // grouped
  const gp = new URLSearchParams(params);
  const fields = args.group_by === 'tag' ? 'id,tag' : 'id,file_type,tag,created_at';
  gp.set('select', fields);
  gp.set('limit', '5000');
  const r = await fetch(`${c.env.SUPABASE_URL}/rest/v1/notes?${gp.toString()}`, { headers });
  if (!r.ok) throw new Error(`count_notes group: ${r.status} ${await r.text()}`);
  const rows: any[] = await r.json();
  const counts = new Map<string, number>();
  for (const row of rows) {
    let key: string;
    switch (args.group_by) {
      case 'tag':       key = (row.tag || 'untagged').toString(); break;
      case 'file_type': key = (row.file_type || 'unknown').toString(); break;
      case 'date_day':  key = (row.created_at || '').slice(0, 10) || 'unknown'; break;
      default:          key = 'unknown';
    }
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  const groups = Array.from(counts.entries())
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 20);
  return { total: rows.length, groups, time_label: timeLabel ?? null };
}

// ===========================================================================
// 3. vector_search — calls the lean retrieval primitive directly.
//
// The planner is responsible for: spell-fix (it sees the raw query and can
// rephrase in its own next call), deciding-if-search-needed, intent
// classification, and final synthesis. This tool ONLY does retrieval +
// rerank and returns ranked chunks. No LLM gates run inside.
// ===========================================================================
export async function tool_vector_search(args: VectorSearchArgs, c: ToolRunContext) {
  // F1: hard cap. Shared with list_notes / count_notes — one retrieval
  // per turn total. A second call risked duplicating the source pool
  // and desynchronising client-side numbered carousel + citation chips.
  const deny = denyIfRetrievalAlreadyRan(c, 'vector_search');
  if (deny) return { ...deny, results_count: 0, top_results: [], _cards: [] };
  c.retrievalCallCount = (c.retrievalCallCount ?? 0) + 1;
  // F2: clear the citation map so this retrieval's cards are numbered 1..N.
  c.citationIndexById.clear();
  // `vector_search` is the discovery tool. Always retrieve a full browse
  // set even when the planner explicitly asks for its former default of 8;
  // the handler, not the planner, controls the initial 10-card page.
  const k = Math.max(20, Math.min(args.k ?? 20, 50));
  const lean = await c.leanVectorSearch(
    args.query,
    k,
    args.exclude_note_ids,
    c.selectedTags?.length ? c.selectedTags : undefined,
  );

  const cards: ResultCard[] = lean.results.map((r): ResultCard => ({
    note_id: r.note_id,
    title: r.title,
    description: r.description,
    content_preview: r.content_preview ?? r.chunk_content.slice(0, 400),
    created_at: r.created_at,
    file_type: r.file_type,
    tag: r.tag,
    score: r.score,
  }));

  // Retrieval candidates the verifier rejected. Same shape as `cards` so
  // the response layer can splice them into the "See more" pool without
  // any per-tool special casing. These are still above the rerank floor
  // (~0.4) — they're topically relevant but weaker matches. Kept separate
  // from `cards` so the first page never surfaces unverified content.
  const rejectedCards: ResultCard[] = lean.rejectedResults.map((r): ResultCard => ({
    note_id: r.note_id,
    title: r.title,
    description: r.description,
    content_preview: r.content_preview ?? r.chunk_content.slice(0, 400),
    created_at: r.created_at,
    file_type: r.file_type,
    tag: r.tag,
    score: r.score,
  }));

  // Assign / reuse a global 1-based index per note_id shared across all
  // vector_search calls in this turn. Same note that showed up as [3] in
  // an earlier call keeps that index — the planner's [N] markers stay
  // stable and always resolve to the same card in the client carousel.
  const idxMap = c.citationIndexById;
  const withIndex = cards.map((card) => {
    let idx = card.note_id ? idxMap.get(card.note_id) : undefined;
    if (idx === undefined && card.note_id) {
      idx = idxMap.size + 1;
      idxMap.set(card.note_id, idx);
    }
    return { card, index: idx ?? 0 };
  });

  return {
    results_count: cards.length,
    // 1-indexed positions the planner MUST cite as [1], [2], ... in the
    // final answer. Indices are stable across the whole turn (shared
    // across vector_search refinements). Client renders the numbered
    // carousel in this same order, so [N] scrolls to card at position N.
    top_results: withIndex.slice(0, k).map(({ card, index }) => ({
      index,
      note_id: card.note_id,
      title: card.title,
      score: card.score,
      content_preview: card.content_preview,
    })),
    timing_ms: lean.timing_ms,
    // If the LLM relevance verifier failed, surface a note the planner can
    // see so it doesn't confidently claim "no results found". The handler
    // reads _verifier_error separately to write the user-facing message.
    ...(lean.verifier_error ? { verifier_error: lean.verifier_error } : {}),
    // The planner sees only `top_results` (limited by k), but the response
    // layer needs the complete, already reranked and relevance-checked set
    // so clients can page it without launching another retrieval.
    _cards: withIndex.map(({ card, index }) => ({ ...card, citation_index: index })),
    _rejected_cards: rejectedCards,
    // Surface the FULL pre-rerank candidate pool note_ids so Search Deeper
    // excludes everything vector + keyword search already considered (not
    // just the rerank survivors). Stripped from the planner-visible result.
    _candidate_note_ids: lean.search_deeper.exclude_note_ids,
    _verifier_error: lean.verifier_error,
  };
}

// ===========================================================================
// 4. fetch_note
// ===========================================================================
export async function tool_fetch_note(args: FetchNoteArgs, c: ToolRunContext) {
  const params = new URLSearchParams();
  params.set('id', `eq.${args.note_id}`);
  params.set('user_id', `eq.${c.userId}`);
  params.set('select', 'id,title,description,content_markdown,tag,file_type,created_at,metadata');
  params.set('limit', '1');
  const r = await fetch(`${c.env.SUPABASE_URL}/rest/v1/notes?${params.toString()}`, {
    headers: {
      apikey: c.env.SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${c.env.SUPABASE_SERVICE_KEY}`,
    },
  });
  if (!r.ok) throw new Error(`fetch_note: ${r.status} ${await r.text()}`);
  const rows: any[] = await r.json();
  if (rows.length === 0) {
    return {
      error: 'note_not_found',
      note_id: args.note_id,
      hint: 'This note_id is not in the user\'s collection. You probably hallucinated it. Use ONLY ids returned from previous tool calls. If you don\'t have an id, run list_notes or vector_search first.',
    };
  }
  const n = rows[0];
  // source_url is not a top-level column on notes — it lives in metadata
  // (sometimes nested under metadata.social). See api-endpoints.ts L637.
  const meta = (n.metadata && typeof n.metadata === 'object') ? n.metadata : {};
  const social = (meta.social && typeof meta.social === 'object') ? meta.social : {};
  const sourceUrl = social.source_url || meta.source_url || undefined;
  const card: ResultCard = {
    note_id: n.id,
    title: n.title,
    description: n.description,
    content_preview: (n.content_markdown || n.description || '').slice(0, 800),
    created_at: n.created_at,
    file_type: n.file_type,
    tag: n.tag,
  };
  return {
    note: {
      note_id: n.id,
      title: n.title,
      description: n.description,
      content: (n.content_markdown || '').slice(0, 4000),
      tag: n.tag,
      file_type: n.file_type,
      created_at: n.created_at,
      source_url: sourceUrl,
    },
    _cards: [card],
  };
}

// ===========================================================================
// 5. summarize
// ===========================================================================
export async function tool_summarize(args: SummarizeArgs, c: ToolRunContext) {
  // Path A — explicit note_ids: fetch then map-reduce summarize.
  if (args.note_ids && args.note_ids.length > 0) {
    const idList = args.note_ids.map(id => `"${id}"`).join(',');
    const params = new URLSearchParams();
    params.set('id', `in.(${idList})`);
    params.set('user_id', `eq.${c.userId}`);
    params.set('select', 'id,title,content_markdown,description,tag,file_type,created_at');
    params.set('limit', String(args.note_ids.length));
    const r = await fetch(`${c.env.SUPABASE_URL}/rest/v1/notes?${params.toString()}`, {
      headers: {
        apikey: c.env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${c.env.SUPABASE_SERVICE_KEY}`,
      },
    });
    if (!r.ok) throw new Error(`summarize fetch: ${r.status} ${await r.text()}`);
    const rows: any[] = await r.json();
    if (rows.length === 0) {
      return { answer: 'No matching notes found to summarize.', notes_count: 0, _cards: [] };
    }
    const notes: SummarizeNote[] = rows.map(n => ({
      note_id: n.id,
      title: n.title || '',
      content_preview: ((n.content_markdown || n.description || '') as string).slice(0, 800),
      created_at: n.created_at,
      tag: n.tag,
      file_type: n.file_type,
    }));
    // Reuse summarize_many's reduce step via a synthetic single-batch path:
    // when filters were the source. For id-based path, we inline a small
    // map-reduce by calling Groq directly.
    const answer = await summarizeNotesInline(notes, c.env);
    const cards: ResultCard[] = notes.map(toCard);
    return {
      answer,
      notes_count: notes.length,
      notes: notes.map(n => ({ note_id: n.note_id, title: n.title })),
      _cards: cards,
    };
  }

  // Path B — filter-based: reuse existing runSummarizeMany.
  // (Zod schema's .refine() guarantees at least one of {note_ids, topic} is set.)
  const topic = (args.topic || '').trim();
  const window = args.time_window ?? 'all_time';
  const scratchpadShim: Scratchpad = {
    trace_id: 'v2',
    user_id: c.userId,
    query: topic,
    structured: {} as any,
    candidates: [],
    evidence: [],
    partials: [],
    confidence: 0,
    steps: [],
  };
  const out = await runSummarizeMany(
    { topic, window, limit: args.limit },
    { env: c.env, scratchpad: scratchpadShim, requestId: c.requestId },
  );
  const cards: ResultCard[] = out.notes.map(toCard);
  return {
    answer: out.answer,
    notes_count: out.notes_count,
    notes: out.notes.map(n => ({ note_id: n.note_id, title: n.title })),
    _cards: cards,
  };
}

// ===========================================================================
// 6. ask_user
// ===========================================================================
export async function tool_ask_user(args: AskUserArgs, _c: ToolRunContext) {
  return {
    type: 'clarification',
    question: args.question,
    options: args.options ?? [],
  };
}

// ===========================================================================
// Helpers
// ===========================================================================

function toCard(n: ListNotesNote | SummarizeNote): ResultCard {
  return {
    note_id: n.note_id,
    title: n.title,
    description: (n as any).description,
    content_preview: n.content_preview,
    created_at: n.created_at,
    file_type: n.file_type,
    tag: n.tag,
  };
}

/** Minimal inline summarizer for the note_ids branch. */
async function summarizeNotesInline(
  notes: SummarizeNote[],
  env: RagSearchEnv,
): Promise<string> {
  const parts = notes.map((n, i) =>
    `[${i + 1}] ${n.title}\n${n.content_preview.slice(0, 600)}`
  ).join('\n\n');
  const prompt = `You are summarizing the user's saved notes.\n\nNotes:\n${parts}\n\nWrite a concise, helpful summary in 3-6 sentences. Group by theme if natural. Refer to notes by their titles when useful.`;
  const r = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${env.GROQ_API_KEY}`,
    },
    body: JSON.stringify({
      model: 'llama-3.3-70b-versatile',
      messages: [{ role: 'user', content: prompt }],
      temperature: 0.2,
      max_tokens: 600,
    }),
  });
  if (!r.ok) throw new Error(`summarize inline groq: ${r.status} ${await r.text()}`);
  const data: any = await r.json();
  return data.choices?.[0]?.message?.content?.trim() || '';
}

// ===========================================================================
// Dispatcher
// ===========================================================================
export async function executeTool(
  name: string,
  args: any,
  c: ToolRunContext,
): Promise<{ ok: boolean; result: any; cards?: ResultCard[]; rejectedCards?: ResultCard[]; candidateNoteIds?: string[]; verifierError?: string }> {
  try {
    let raw: any;
    switch (name) {
      case 'list_notes':     raw = await tool_list_notes(args, c); break;
      case 'count_notes':    raw = await tool_count_notes(args, c); break;
      case 'vector_search':  raw = await tool_vector_search(args, c); break;
      case 'fetch_note':     raw = await tool_fetch_note(args, c); break;
      case 'summarize':      raw = await tool_summarize(args, c); break;
      case 'ask_user':       raw = await tool_ask_user(args, c); break;
      default: return { ok: false, result: { error: `unknown tool: ${name}` } };
    }
    // Strip internal fields (_cards, _rejected_cards, _candidate_note_ids,
    // _verifier_error) before sending back to the planner. Planner still
    // sees the top-level `verifier_error` field on tool_vector_search so it
    // can tailor its answer, but the response-layer plumbing lives on the
    // returned object below.
    const { _cards, _rejected_cards, _candidate_note_ids, _verifier_error, ...visible } = raw;
    return {
      ok: true,
      result: visible,
      cards: _cards as ResultCard[] | undefined,
      rejectedCards: _rejected_cards as ResultCard[] | undefined,
      candidateNoteIds: _candidate_note_ids as string[] | undefined,
      verifierError: _verifier_error as string | undefined,
    };
  } catch (err) {
    return { ok: false, result: { error: err instanceof Error ? err.message : String(err) } };
  }
}
