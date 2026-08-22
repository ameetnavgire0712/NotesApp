// agent_v2/lean_search.ts
// =============================================================================
// Lean vector retrieval for the v2 planner.
//
// Calls performHybridSearch (embed + vector + keyword + rerank) directly and
// returns formatted result cards plus a cumulative exclude list for "search
// deeper" pagination. SKIPS the LLM gates that live in /rag-search-auth:
//   - spell-check LLM
//   - planSearchGate (decide-if-search-needed) LLM
//   - intent classifier LLM
//   - chat-history-aware query rewriter LLM
//   - synthesis (final-answer) LLM
//
// The v2 planner replaces all of those: it decides when to search, what to
// search for, and writes the final answer itself. This function is the
// retrieval primitive the planner calls when it needs chunks.
//
// Used by:
//   - tool_vector_search (planner-driven path)
//   - handleAgentV2Search search-deeper short-circuit (deterministic
//     pagination — no planner involvement)
// =============================================================================

import type { ExecutionContext } from '@cloudflare/workers-types';
import { sendSearchTrace, type SearchTraceEntry, type SearchTraceEnv } from '../search-trace';
import { writeVerifierTrace, type VerifierCandidateInput } from '../verifier-trace';

// Mirrors index.ts::HybridSearchParams / HybridSearchResult so we don't have
// to export those types from index.ts. If those shapes change, update here.
export interface HybridSearchParams {
  query: string;
  originalQuery?: string;
  user_id: string;
  tag?: string;
  limit: number;
  rerank: boolean;
  retrieval_limit?: number;
  exclude_note_ids?: string[];
}

export interface HybridSearchResult {
  matches: Array<Record<string, any>>;
  timing: {
    embedding_ms: number;
    parallel_search_ms: number;
    keyword_ms: number;
    rerank_ms: number;
  };
  embedding_cached: boolean;
  total_candidates?: number;
  // Every note_id that vector OR keyword search surfaced this round, BEFORE
  // the reranker filtered them. Used to build the Search Deeper exclude list.
  candidate_note_ids?: string[];
  // Rich trace payload assembled by performHybridSearch in index.ts (vector /
  // keyword / combined / reranked candidate arrays, reranker input preview,
  // per-stage counts). Populated when index.ts returns it — kept optional
  // so older code paths still typecheck.
  trace_data?: Record<string, any>;
}

export type HybridSearchFn = (
  params: HybridSearchParams,
  env: any,
  ctx: ExecutionContext,
) => Promise<HybridSearchResult>;

// Card shape mirrors what /rag-search-auth returns so the Flutter / dashboard
// UI code path is unchanged. Kept compatible with agent_v2/tools.ts::ResultCard.
export interface LeanResultCard {
  note_id: string;
  title: string;
  chunk_content: string;
  description?: string;
  content_preview?: string;
  tag?: string;
  similarity_score: number;
  rerank_score?: number;
  keyword_score: number;
  source: string;
  chunk_type: string;
  source_text: string;
  blob_url?: string;
  created_at?: string;
  file_type?: string;
  score?: number;
}

export interface LeanSearchResponse {
  /** Verifier-approved cards. These are safe to show as the first page. */
  results: LeanResultCard[];
  /**
   * Retrieval-tier candidates that did NOT pass the LLM relevance verifier
   * (or fell outside the verification window). They still cleared the
   * rerank floor (~0.4), so they're topically related but weaker matches.
   * Handed to the client as a "See more" pool so the user can opt in to
   * lower-confidence hits instead of hitting a dead end when the verifier
   * is strict.
   */
  rejectedResults: LeanResultCard[];
  search_deeper: {
    available: boolean;
    exclude_note_ids: string[];
    total_so_far: number;
  };
  timing_ms: number;
  embedding_cached: boolean;
  /**
   * Populated when the LLM relevance verifier failed (HTTP error, malformed
   * JSON, unparseable response, etc.). Empty/undefined on success. The
   * handler surfaces this to the user as a friendly "something went wrong"
   * message instead of silently returning zero results — a verifier crash
   * and a legitimate "nothing relevant" verdict must be distinguishable.
   */
  verifier_error?: string;
  /**
   * Snapshot of the retrieval trace so the caller (agent v2 handler) can
   * persist a search_traces row that mirrors what the classic
   * /rag-search-auth pipeline writes. Contains the merged trace_data from
   * performHybridSearch plus verification counts. undefined if the
   * underlying hybrid call didn't produce a trace payload.
   */
  hybrid_trace?: Record<string, any>;
}

/**
 * Optional per-request context that unlocks search_traces persistence.
 * When provided (populated by the /agent-v2-search-auth handler in index.ts
 * at closure-construction time), each vector_search invocation writes a
 * fresh row to search_traces via sendSearchTrace. Omitted → no side effect
 * and the function behaves exactly like the historical lean pipeline.
 *
 * A per-invocation correlation_id is minted so the frontend detail-view
 * lookup `/api/v1/logs/search-trace/:id` returns the correct row when the
 * planner fires vector_search more than once in the same request.
 */
export interface LeanTraceContext {
  requestId: string;              // top-level worker request id
  client_source?: string;
  request_path: string;           // e.g. '/agent-v2-search-auth'
  auth_user_email?: string;
  auth_method?: string;
  timing_auth_ms?: number;
  request_received_at?: string;
  auth_started_at?: string;
  auth_completed_at?: string;
  /**
   * The user's original typed query, BEFORE the agent-v2 planner rewrote it
   * into the tool-call `query` argument. Persisted into `search_traces.query`
   * so the dashboard's text-search lookup matches what the user typed. The
   * (possibly rewritten) `args.query` is stored in `search_traces.query_corrected`.
   * If omitted, we fall back to `args.query` for both fields (behaviour prior
   * to this change).
   */
  original_query?: string;
}

/** Closure shape passed around the v2 agent. Keeps env/ctx/userId bound. */
export type LeanVectorSearchFn = (
  query: string,
  k?: number,
  excludeNoteIds?: string[],
  tag?: string | string[],
) => Promise<LeanSearchResponse>;

export async function performLeanVectorSearch(
  args: {
    query: string;
    user_id: string;
    k?: number;
    tag?: string | string[];
    exclude_note_ids?: string[];
  },
  hybridSearchFn: HybridSearchFn,
  env: any,
  ctx: ExecutionContext,
  traceContext?: LeanTraceContext,
): Promise<LeanSearchResponse> {
  const tags = Array.isArray(args.tag)
    ? [...new Set(args.tag.map(tag => tag.trim()).filter(Boolean))]
    : args.tag?.trim() ? [args.tag.trim()] : [];

  // Vectorize supports one metadata equality filter per query. Fan out when
  // the dashboard has multiple selected tags, then merge the tag-scoped
  // results. This keeps the UI's multi-select semantics as an OR while never
  // allowing an unselected tag into the candidate pool.
  if (tags.length > 1) {
    const searches = await Promise.all(
      tags.map(tag => performLeanVectorSearch(
        { ...args, tag },
        hybridSearchFn,
        env,
        ctx,
        traceContext,
      )),
    );
    const k = Math.max(1, Math.min(args.k ?? 20, 50));
    const byNoteId = new Map<string, LeanResultCard>();
    for (const search of searches) {
      for (const result of search.results) {
        const existing = byNoteId.get(result.note_id);
        if (!existing || (result.score ?? 0) > (existing.score ?? 0)) {
          byNoteId.set(result.note_id, result);
        }
      }
    }
    const results = Array.from(byNoteId.values())
      .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
      .slice(0, k);
    // Merge rejected pools across tags. Dedupe against verified so a card
    // approved under one tag doesn't show up as rejected under another.
    const verifiedIds = new Set(results.map(r => r.note_id));
    const rejectedById = new Map<string, LeanResultCard>();
    for (const search of searches) {
      for (const result of search.rejectedResults) {
        if (verifiedIds.has(result.note_id)) continue;
        const existing = rejectedById.get(result.note_id);
        if (!existing || (result.score ?? 0) > (existing.score ?? 0)) {
          rejectedById.set(result.note_id, result);
        }
      }
    }
    const rejectedResults = Array.from(rejectedById.values())
      .sort((a, b) => (b.score ?? 0) - (a.score ?? 0));
    const excludeNoteIds = Array.from(new Set(
      searches.flatMap(search => search.search_deeper.exclude_note_ids),
    ));
    return {
      results,
      rejectedResults,
      search_deeper: {
        available: results.length > 0,
        exclude_note_ids: excludeNoteIds,
        total_so_far: excludeNoteIds.length,
      },
      timing_ms: Math.max(...searches.map(search => search.timing_ms)),
      embedding_cached: searches.every(search => search.embedding_cached),
      // If ANY per-tag verifier failed, propagate that so the handler can
      // still surface a friendly error to the user even if some tags
      // succeeded. Multi-tag partial success is rare enough that "first
      // observed error wins" is fine.
      verifier_error: searches.find(s => s.verifier_error)?.verifier_error,
      // Best-effort: surface the first fan-out's trace so the caller has
      // something to inspect. Each fan-out already wrote its own
      // search_traces row inside the recursive call, so this is just for
      // in-memory chaining.
      hybrid_trace: searches[0]?.hybrid_trace,
    };
  }

  const tag = tags[0];
  const t0 = Date.now();
  const limit = Math.max(1, Math.min(args.k ?? 20, 50));
  const excludes = args.exclude_note_ids ?? [];

  const hybrid = await hybridSearchFn(
    {
      query: args.query,
      user_id: args.user_id,
      tag,
      limit,
      rerank: true,
      exclude_note_ids: excludes.length > 0 ? excludes : undefined,
    },
    env,
    ctx,
  );

  const results: LeanResultCard[] = hybrid.matches.map((m) => {
    const chunk = String(m.content || m.chunk_text || '');
    return {
      note_id: String(m.note_id || ''),
      title: String(m.title || 'Untitled'),
      chunk_content: chunk,
      content_preview: chunk.slice(0, 400),
      description: m.chunk_type === 'document' ? String(m.description || '') : undefined,
      tag: m.tag as string | undefined,
      similarity_score: Number(m.similarity || m.rerank_score || 0),
      rerank_score: m.rerank_score as number | undefined,
      keyword_score: Number(m.keyword_score || 0),
      source: 'hybrid',
      chunk_type: String(m.chunk_type || 'chunk'),
      source_text: String(m.source_text || (m.chunk_type === 'document' ? 'doc_preview' : 'chunk_text')),
      blob_url: m.blob_url as string | undefined,
      created_at: m.created_at as string | undefined,
      file_type: m.file_type as string | undefined,
      score: Number(m.rerank_score ?? m.similarity ?? 0),
    };
  });

  // ---------------------------------------------------------------------
  // Dedup by note_id BEFORE relevance verification.
  //
  // hybrid.matches contains one row per (note_id, chunk_type) tuple — up to
  // `chunks_per_doc_limit` (currently 3) chunks from the same note can
  // survive rerank. If we don't collapse them, the same note surfaces as 2
  // or 3 separate cards in the Flutter UI (e.g. an Instagram reel appearing
  // 3x because its description + document + chunk embeddings all matched).
  // Mirror rag-search.ts:3256 exactly: keep the highest-scoring chunk per
  // note_id, then re-sort. Verification and the final response layer both
  // work on unique-per-note data after this.
  // ---------------------------------------------------------------------
  const uniqueByNote = new Map<string, LeanResultCard>();
  for (const r of results) {
    const existing = uniqueByNote.get(r.note_id);
    const currentScore = r.rerank_score ?? r.similarity_score ?? 0;
    const existingScore = existing
      ? (existing.rerank_score ?? existing.similarity_score ?? 0)
      : -1;
    if (!existing || currentScore > existingScore) {
      uniqueByNote.set(r.note_id, r);
    }
  }
  const dedupedResults = Array.from(uniqueByNote.values()).sort((a, b) => {
    const sa = a.rerank_score ?? a.similarity_score ?? 0;
    const sb = b.rerank_score ?? b.similarity_score ?? 0;
    return sb - sa;
  });
  if (dedupedResults.length !== results.length) {
    console.log(
      `[lean_search] dedup: ${results.length} chunks → ${dedupedResults.length} unique notes`,
    );
  }

  // Pre-compute the per-round correlation_id BEFORE the verifier LLM call so
  // the verifier_traces row can share the same correlation_id as the
  // search_traces row we'll write below. Same id + same parent lets the
  // dashboard join the two tables for a full "why was X rejected" view.
  const roundSuffix = traceContext
    ? `h${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`
    : '';
  const roundCorrelationId = traceContext
    ? `${traceContext.requestId}_${roundSuffix}`
    : '';

  // ---------------------------------------------------------------------
  // LLM relevance verification.
  //
  // Reranker keeps anything above ~0.4, but that's a topical floor — it
  // still returns docs that just brush the topic. This pass asks an LLM
  // which of the top candidates are ACTUALLY relevant so the UI only
  // shows useful sources.
  //
  // verifyLeanRelevance handles all its own error branches (network, HTTP,
  // parse, empty response) — each writes its own verifier_traces row with
  // verdict='error' and returns { verified: [], rejected: top, error: ... }.
  // We surface `verifier_error` up through LeanSearchResponse so the handler
  // can show a friendly "something went wrong" message instead of silently
  // returning zero results (which is indistinguishable from a legitimate
  // "nothing relevant" verdict).
  //
  // Default `verified` to EMPTY, not the full pool. If the verifier ever
  // throws unexpectedly (shouldn't happen — every error path returns), we
  // want the user to see nothing rather than a garbage-dump of unfiltered
  // rerank hits (which historically leaked clearly-irrelevant notes).
  // ---------------------------------------------------------------------
  let verified: LeanResultCard[] = [];
  let rejected: LeanResultCard[] = dedupedResults;
  let verifierError: string | undefined;
  try {
    const verdict = await verifyLeanRelevance(args.query, dedupedResults, env, traceContext ? {
      correlation_id: roundCorrelationId,
      parent_request_id: traceContext.requestId,
      user_id: args.user_id,
      ctx,
    } : undefined);
    verified = verdict.verified;
    rejected = verdict.rejected;
    verifierError = verdict.error;
  } catch (e) {
    // Defensive: verifyLeanRelevance now handles its own errors and never
    // throws, but keep this as a last-resort so a future refactor can't
    // silently drop candidates onto the user.
    const errMsg = e instanceof Error ? e.message : String(e);
    console.warn('[lean_search] unexpected verifier exception:', errMsg);
    verified = [];
    rejected = dedupedResults;
    verifierError = `unexpected: ${errMsg}`;
    if (traceContext) {
      ctx.waitUntil(
        writeVerifierTrace(env, {
          correlation_id: roundCorrelationId,
          parent_request_id: traceContext.requestId,
          user_id: args.user_id,
          query: args.query,
          candidates_input: dedupedResults.map((r, i) => ({
            index: i + 1,
            note_id: r.note_id,
            title: r.title ?? null,
            tag: r.tag ?? null,
            description: r.description ?? null,
            content_preview: (r.chunk_content || '').slice(0, 500),
            rerank_score: r.rerank_score ?? null,
            keyword_score: r.keyword_score ?? null,
          })),
          llm_response: null,
          verified_indices: [],
          rejected_indices: [],
          verdict: 'error',
          model: GROQ_RELEVANCE_MODEL,
          latency_ms: null,
          error_message: errMsg,
          source: 'agent_v2_lean',
        }).catch(() => {}),
      );
    }
  }

  // Cumulative exclude list for the next "Search Deeper" round.
  //
  // We exclude every note_id that vector OR keyword search surfaced this
  // round — NOT just the ones that survived the reranker. Otherwise a doc
  // the reranker rejected in round 1 (e.g. an Axis Bank statement when the
  // user queried "IDFC bank details") could resurface in round 2 with a
  // higher rerank score because the round-1 winners are gone, even though
  // we already decided it wasn't relevant. Using the full pre-rerank pool
  // guarantees Search Deeper draws from genuinely fresh notes.
  //
  // EXCEPTION: candidates ranked beyond VERIFY_CAP were dropped this round
  // without ever reaching the verifier (no decision was made about them).
  // We intentionally OMIT their note_ids from the exclude list so they
  // can naturally resurface on the next Search Deeper round and get a
  // fair verifier pass then.
  const beyondCapNoteIds = new Set<string>();
  for (const r of dedupedResults.slice(VERIFY_CAP)) {
    if (r.note_id) beyondCapNoteIds.add(r.note_id);
  }
  const seen = new Set<string>(excludes);
  const fullPool = hybrid.candidate_note_ids ?? results.map((r) => r.note_id);
  for (const id of fullPool) if (id && !beyondCapNoteIds.has(id)) seen.add(id);
  // Defensive: also include rerank-survivor ids (no-op if candidate_note_ids
  // was provided, useful if an older HybridSearchResult ever lacks it).
  for (const r of results) if (r.note_id && !beyondCapNoteIds.has(r.note_id)) seen.add(r.note_id);
  const cumulativeExcludes = Array.from(seen);

  // "Available" heuristic: matches the regular agent_v2 path in handler.ts
  // ("available whenever we returned at least one card"). The previous
  // `results.length >= min(limit, 5)` rule hid the Search Deeper button
  // whenever a round returned <5 verified results — which is exactly the
  // case where the user is most likely to want to keep digging.
  const available = verified.length > 0;

  const timing_ms = Date.now() - t0;

  // -------------------------------------------------------------------------
  // Persist a search_traces row for this hybrid retrieval round.
  //
  // Historically only /rag-search-auth (rag-search.ts) wrote to search_traces,
  // so agent v2 traffic (i.e. Flutter chat, browser agent) was invisible in
  // the admin activity-logs dashboard even though every retrieval round ran
  // performHybridSearch and produced the same trace payload. Writing here
  // means every agent v2 vector_search invocation shows up in the same
  // dashboard as classic searches with identical candidate + timing detail.
  //
  // Guarded on traceContext so unit tests and any legacy caller that omits
  // it are unaffected. Uses a per-round correlation_id so multiple
  // vector_search calls in the same top-level request each get their own
  // detail-view fetch key (`/api/v1/logs/search-trace/:id`).
  // -------------------------------------------------------------------------
  const hybrid_trace = buildHybridTracePayload(hybrid.trace_data, verified, rejected);
  if (traceContext) {
    // roundCorrelationId was pre-computed before the verifier call so both
    // the verifier_traces row and this search_traces row share the same id.
    const searchStartedAt = new Date(t0).toISOString();
    const responseSentAt = new Date().toISOString();
    // Prefer the user's typed query as the trace's `query` column so the
    // dashboard's search-by-text finds this row. The rewritten query the
    // planner passed to vector_search goes into `query_corrected` (only if
    // it actually differs from the original — otherwise we leave it null).
    const originalQuery = traceContext.original_query ?? args.query;
    const rewrittenQuery =
      traceContext.original_query && traceContext.original_query !== args.query
        ? args.query
        : undefined;
    const traceEntry: SearchTraceEntry = {
      correlation_id: roundCorrelationId,
      // Every round of this request shares this — the dashboard groups by
      // parent_request_id to render the multi-round request as a single tile.
      parent_request_id: traceContext.requestId,
      user_id: args.user_id,
      query: originalQuery,
      query_corrected: rewrittenQuery,
      request_received_at: traceContext.request_received_at,
      auth_started_at: traceContext.auth_started_at,
      auth_completed_at: traceContext.auth_completed_at,
      search_started_at: searchStartedAt,
      response_sent_at: responseSentAt,
      timing_total_ms: timing_ms,
      timing_auth_ms: traceContext.timing_auth_ms,
      timing_embedding_ms: hybrid.timing?.embedding_ms,
      timing_vector_search_ms: hybrid.timing?.parallel_search_ms,
      timing_keyword_search_ms: hybrid.timing?.keyword_ms,
      timing_rerank_ms: hybrid.timing?.rerank_ms,
      timing_worker_ms: timing_ms,
      auth_method: traceContext.auth_method,
      auth_user_email: traceContext.auth_user_email,
      embedding_cached: hybrid.embedding_cached,
      search_cached: false,
      vector_candidates: (hybrid_trace as any).vector_candidates,
      keyword_candidates: (hybrid_trace as any).keyword_candidates,
      combined_candidates: (hybrid_trace as any).combined_candidates,
      reranked_candidates: (hybrid_trace as any).reranked_candidates,
      reranker_input_preview: (hybrid_trace as any).reranker_input_preview,
      relevance_verified_candidates: (hybrid_trace as any).relevance_verified_candidates,
      final_results: verified.map(r => ({
        note_id: r.note_id,
        title: r.title,
        rerank_score: r.rerank_score,
        similarity_score: r.similarity_score,
        chunk_type: r.chunk_type,
        source: r.source,
        source_text: r.source_text,
      })),
      vector_count: (hybrid_trace as any).vector_candidates?.length || 0,
      excluded_note_ids_count: excludes.length,
      keyword_count: (hybrid_trace as any).keyword_candidates?.length || 0,
      keyword_query: (hybrid_trace as any).keyword_query,
      keyword_query_normalized: (hybrid_trace as any).keyword_query_normalized,
      keyword_only_injected: (hybrid_trace as any).keyword_only_injected || 0,
      title_match_count: (hybrid_trace as any).title_match_count || 0,
      description_match_count: (hybrid_trace as any).description_match_count || 0,
      title_only_injected: (hybrid_trace as any).title_only_injected || 0,
      desc_only_injected: (hybrid_trace as any).desc_only_injected || 0,
      title_with_content_injected: (hybrid_trace as any).title_with_content_injected || 0,
      desc_with_content_injected: (hybrid_trace as any).desc_with_content_injected || 0,
      combined_count: (hybrid_trace as any).combined_candidates?.length || 0,
      reranked_count: (hybrid_trace as any).reranked_candidates?.length || 0,
      relevance_verified_count: verified.length,
      final_count: verified.length,
      // What the Flutter/extension client actually renders: verified cards
      // are the primary results, rejected cards are the "See more" browse
      // tail. app_visible_count is the number the dashboard reports so the
      // admin metric matches what the user saw on their screen (hydration
      // is done post-retrieval in tool_fetch_note; not counted here).
      browse_pool_count: rejected.length,
      app_visible_count: verified.length + rejected.length,
      chunks_before_grouping: (hybrid_trace as any).chunks_before_grouping,
      chunks_after_grouping: (hybrid_trace as any).chunks_after_grouping,
      unique_documents: (hybrid_trace as any).unique_documents,
      chunks_per_doc_limit: (hybrid_trace as any).chunks_per_doc_limit,
      min_vector_threshold: 0.15,
      min_rerank_threshold: 0.30,
      source_worker: 'cloudflare-worker',
      request_path: traceContext.request_path,
      client_source: traceContext.client_source || 'unknown',
      tool_invoked: 'hybrid_search',
      path_taken: 'hybrid',
      error_occurred: false,
      answer_generated: false,
    };
    sendSearchTrace(traceEntry, env as SearchTraceEnv, ctx);
  }

  return {
    results: verified,
    rejectedResults: rejected,
    search_deeper: {
      available,
      exclude_note_ids: cumulativeExcludes,
      total_so_far: cumulativeExcludes.length,
    },
    timing_ms,
    embedding_cached: hybrid.embedding_cached,
    hybrid_trace,
    verifier_error: verifierError,
  };
}

/**
 * Merge the retrieval trace produced by performHybridSearch with post-hoc
 * verification counts so downstream consumers (search_traces write, callers
 * inspecting lean.hybrid_trace) get a single object with everything the
 * classic /rag-search-auth trace stores. Returns a shallow clone — never
 * mutates the trace_data argument.
 */
function buildHybridTracePayload(
  traceData: Record<string, any> | undefined,
  verified: LeanResultCard[],
  rejected: LeanResultCard[],
): Record<string, any> {
  const base: Record<string, any> = { ...(traceData || {}) };
  base.relevance_verified_candidates = verified.map(v => ({
    note_id: v.note_id,
    title: v.title,
    tag: v.tag,
    rerank_score: v.rerank_score,
    similarity_score: v.similarity_score,
    passed_verification: true,
    chunk_type: v.chunk_type,
    source_text: v.source_text,
  })).concat(
    rejected.map(r => ({
      note_id: r.note_id,
      title: r.title,
      tag: r.tag,
      rerank_score: r.rerank_score,
      similarity_score: r.similarity_score,
      passed_verification: false,
      chunk_type: r.chunk_type,
      source_text: r.source_text,
    })),
  );
  return base;
}

// =============================================================================
// LLM relevance verification.
//
// Previously used OpenAI's gpt-4.1-mini via api.openai.com. Output-token
// throughput there was the whole latency budget (7-9s for 15 candidates
// with per-candidate reason text), so we migrated to Groq's
// `openai/gpt-oss-120b`. That model is a native reasoning model with
// internal CoT — it thinks BEFORE emitting the JSON verdict, which means
// we get chain-of-thought quality without paying for a "reason" field in
// output tokens. `reasoning_effort: "low"` keeps latency in the ~1.5-2s
// range while preserving CoT for the actual decision.
//
// We migrated off Groq once before (Qwen 3.6 blowing 2048-token budgets on
// reasoning preambles). gpt-oss-120b is different: OpenAI-tuned, strict
// JSON adherence, and reasoning tokens are handled by the model server
// rather than dumped into the response body.
// =============================================================================

const GROQ_RELEVANCE_MODEL = 'openai/gpt-oss-120b';
const GROQ_CHAT_URL = 'https://api.groq.com/openai/v1/chat/completions';

// Cap the number of candidates sent to the LLM verifier per round. Anything
// past this rank is neither shown nor verified this round — but is also
// NOT added to the Search Deeper exclude list, so it can naturally
// resurface on the next round (see cumulativeExcludes in performLeanVectorSearch).
export const VERIFY_CAP = 15;

interface RelevanceVerdict {
  verified: LeanResultCard[];
  rejected: LeanResultCard[];
  /**
   * Populated when the verifier failed unrecoverably (HTTP error, unparseable
   * JSON from the LLM, etc.). When set, `verified` is empty and `rejected`
   * holds the un-verified candidate window so callers can decide what to
   * surface. Absent on success (including legitimate "nothing relevant").
   */
  error?: string;
}

async function verifyLeanRelevance(
  query: string,
  results: LeanResultCard[],
  env: any,
  // Task D: optional trace context. When provided we persist one row to
  // public.verifier_traces so the eval harness can replay the exact prompt
  // inputs and grade the LLM output offline. Kept optional so unit tests
  // and non-agent-v2 callers don't have to fake IDs. ctx is required so the
  // async POST is scheduled via ctx.waitUntil() and doesn't get cancelled
  // when the parent request response is sent.
  traceCtx?: {
    correlation_id: string;
    parent_request_id?: string;
    user_id?: string;
    ctx: ExecutionContext;
  },
): Promise<RelevanceVerdict> {
  if (results.length === 0) return { verified: results, rejected: [] };
  // NOTE: We previously skipped verification when results.length === 1
  // ("every hybrid hit is already gated by rerank>=0.4"). That backfired on
  // the Search Deeper fast path: after excluding the only truly-relevant
  // note, vector search still returns SOMETHING with rerank ~0.4 (any
  // tangentially-related doc), and the skip let it through unchallenged.
  // Always verify — the LLM call is cheap relative to surfacing garbage.

  // Verify every retrieved candidate — not just the top 10. Previously the
  // verifier only saw the first 10 rerank survivors and passed the tail
  // through unchecked; with k raised to 20–50 for Show-More paging, the
  // unverified tail was leaking clearly off-topic notes (e.g. a finance
  // note surfacing on a "movies to watch" query). Cap the prompt at
  // VERIFY_CAP to keep it well within the LLM's context and latency budget.
  //
  // Candidates beyond VERIFY_CAP are dropped from THIS round entirely —
  // not shown, not verified — but they are deliberately excluded from the
  // Search Deeper exclude list in performLeanVectorSearch so the next
  // Search Deeper round can pick them up fresh.
  const top = results.slice(0, VERIFY_CAP);
  const candidatesText = top.map((r, i) => {
    // Fields are ordered Description → Content → Title to mirror the prompt's
    // relevance-weighting instructions. Tag is intentionally NOT included —
    // tags are noisy (user-set, often mislabeled) and were biasing the
    // verifier away from correct matches (a Reel about a movie with
    // tag=food was being rejected).
    const parts = [
      `${i + 1}. Description: ${r.description || '—'}`,
      `   Content: ${(r.chunk_content || 'No content').slice(0, 800)}`,
      `   Title: ${r.title || '—'}`,
    ];
    if ((r.keyword_score || 0) > 0) {
      parts.push(`   [KEYWORD MATCH: This document's full content contains the exact search terms. Only a preview is shown above.]`);
    }
    return parts.join('\n');
  }).join('\n\n');

  const prompt = `You are a search-relevance analyst. Given a user's search
query and a list of candidate documents, decide for EACH candidate whether
it is relevant to the query and briefly justify your decision.

Writing a reason for every candidate is REQUIRED — it forces you to
actually look at the document rather than pattern-matching on the query.
Cite a specific phrase from the document whenever possible.

User's search query:
  "${query}"

Each candidate document (numbered 1..N) has these fields, listed from most
to least important for judging relevance:
  - Description  (user-written; strongest signal when present)
  - Content      (chunk pulled by the retriever; may be truncated)
  - Title        (often auto-generated for social posts, so weaker signal)

IMPORTANT — the pipeline sometimes stores the user's own description at
the START of the Content field with the literal prefix "User description:
<text>" (this happens when the Description field itself is empty). When
you see that prefix, treat the text after it as if it were the
Description field — it is the strongest relevance signal, even if the
rest of Content looks generic (e.g. "Instagram Reel", "Untitled"). For
example, Content = "User description: horror movies\n\n# Instagram Reel"
for query "movies to watch" IS relevant — the user labelled it as movies.

${candidatesText}

How to judge each document:

1. Read the query. Note any narrowing words (genre, name, category, type).
   e.g. "horror movies" narrows "movies"; "IDFC statement" narrows
   "statement"; "vegan pasta recipes" narrows "recipes".

2. Read Description, Content, and Title together. Weight earlier fields
   more heavily. Ignore the Tag field.

3. A document that showcases a SPECIFIC INSTANCE of the query's subject IS
   relevant to a broad-category query. Examples:
     - Query "furniture" or "home decor" → a reel about a specific chair,
       sofa, wardrobe, door, wall panel, nameplate, wall art, or light
       fixture IS relevant. Home-decor content is mostly made of individual
       items, not category overviews.
     - Query "movies to watch" → a post recommending one specific film IS
       relevant.
     - Query "recipes" → a video showing one specific dish IS relevant.

4. ADJACENT-CATEGORY inclusion: when the query is a broad watch/read/eat
   recommendation ("movies to watch", "shows", "books", "food"), also
   treat content from immediately adjacent categories as relevant, because
   the user's real intent is "what should I consume next?":
     - Query "movies to watch" → a TV show / web series recommendation IS
       relevant (both are watchable entertainment picks). A Bollywood
       dialogue reel featuring named films/actors IS relevant.
     - Query "recipes" → a plated-food photo or food-review post IS
       relevant (still tells the user what to cook/try).
     - Query "books" → a reading-list or book-quote post IS relevant.
   Only reject adjacent-category content when the query itself
   explicitly narrows it out (e.g. "MOVIES not shows", "vegan recipes
   only") \u2014 otherwise LEAN INCLUSIVE.

5. Only mark irrelevant when the document is about a CLEARLY DIFFERENT
   subject (e.g. a graphic-design tools post for a home-decor query \u2014
   "designer" there means graphic designer, not interior designer; a
   travel reel for a movies query).

6. If the query has narrowing words, the document must reflect them \u2014
   otherwise it is irrelevant.

7. When in doubt, PREFER INCLUSION. The user is better served by an
   extra loosely-related card than by a "no results" screen.

Output format — return EXACTLY this JSON shape, one entry per candidate,
in the same order as the input, with NO other text:

{
  "verdicts": [
    { "index": 1, "relevant": true,  "reason": "≤10 words" },
    { "index": 2, "relevant": false, "reason": "≤10 words" }
  ]
}

The "reason" field is REQUIRED for every candidate — never blank, never
"NONE". Keep it to 10 words or fewer. Quote a specific phrase from the
document when possible.`;

  const verifierStart = Date.now();
  const body = {
    model: GROQ_RELEVANCE_MODEL,
    messages: [
      { role: 'system', content: 'You are a search-relevance analyst. Respond ONLY with the JSON object described. No prose, no markdown fences.' },
      { role: 'user', content: prompt },
    ],
    temperature: 0,
    max_tokens: 2048,
    // gpt-oss-120b is a reasoning model. `medium` gives us thorough CoT
    // on the relevance decision — recovering the field-parsing behaviour
    // gpt-4.1-mini had (e.g. spotting "User description:" prefixes and
    // hashtag context signals) that `low` was missing. Reasoning tokens
    // don't count against max_tokens on Groq — the model emits them
    // internally and only the final JSON reaches the response body.
    // Latency at medium is ~2-3s vs ~1-1.5s at low; still much faster
    // than gpt-4.1-mini's 7-9s.
    reasoning_effort: 'medium',
    response_format: { type: 'json_object' },
  };

  // Build candidatesInput once so every trace-write branch (success, empty,
  // parse error, HTTP error, network error) can use the same payload.
  // content_preview length matches what the LLM sees in the prompt (800)
  // so eval reruns are exact.
  const candidatesInput: VerifierCandidateInput[] = top.map((r, i) => ({
    index: i + 1,
    note_id: r.note_id,
    title: r.title ?? null,
    tag: r.tag ?? null,
    description: r.description ?? null,
    content_preview: (r.chunk_content || '').slice(0, 800),
    rerank_score: r.rerank_score ?? null,
    keyword_score: r.keyword_score ?? null,
  }));

  const writeTrace = (
    verifiedIdx: number[],
    rejectedIdx: number[],
    verdict: 'some' | 'none' | 'error',
    llmResponse: string | null,
    latencyMs: number | null,
    errorMessage?: string,
  ) => {
    if (!traceCtx) return;
    // waitUntil keeps the POST alive past the parent response — without it
    // Workers cancels in-flight fetches and the trace row vanishes.
    traceCtx.ctx.waitUntil(
      writeVerifierTrace(env, {
        correlation_id: traceCtx.correlation_id,
        parent_request_id: traceCtx.parent_request_id,
        user_id: traceCtx.user_id,
        query,
        candidates_input: candidatesInput,
        llm_response: llmResponse,
        verified_indices: verifiedIdx,
        rejected_indices: rejectedIdx,
        verdict,
        model: GROQ_RELEVANCE_MODEL,
        latency_ms: latencyMs,
        error_message: errorMessage,
        source: 'agent_v2_lean',
      }).catch(() => {}),
    );
  };

  // ---- HTTP call. Every failure path logs to verifier_traces and returns
  //      an error verdict so the user gets a clear message instead of an
  //      empty result set that looks identical to "nothing was relevant". ----
  let resp: Response;
  try {
    resp = await fetch(GROQ_CHAT_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${env.GROQ_API_KEY}`,
      },
      body: JSON.stringify(body),
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.warn('[lean_search] verifier network error:', msg);
    const allIdx = candidatesInput.map(c => c.index);
    writeTrace([], allIdx, 'error', null, Date.now() - verifierStart, `network: ${msg}`);
    return { verified: [], rejected: top, error: `network: ${msg}` };
  }

  if (!resp.ok) {
    const errText = await resp.text().catch(() => '<unreadable>');
    console.warn('[lean_search] verifier http error:', resp.status, errText);
    const allIdx = candidatesInput.map(c => c.index);
    const errMsg = `http ${resp.status}: ${errText.slice(0, 400)}`;
    writeTrace([], allIdx, 'error', null, Date.now() - verifierStart, errMsg);
    return { verified: [], rejected: top, error: errMsg };
  }

  const data: any = await resp.json().catch(() => null);
  const raw = String(data?.choices?.[0]?.message?.content || '').trim();
  const verifierLatency = Date.now() - verifierStart;

  if (!raw) {
    console.warn('[lean_search] verifier empty response');
    const allIdx = candidatesInput.map(c => c.index);
    writeTrace([], allIdx, 'error', raw, verifierLatency, 'empty response');
    return { verified: [], rejected: top, error: 'empty response from verifier' };
  }

  // Parse the structured JSON verdict. Format contract (v5):
  //   { "verdicts": [
  //       { "index": 1, "relevant": true,  "reason": "..." },
  //       { "index": 2, "relevant": false, "reason": "..." }
  //     ] }
  //
  // Every candidate should appear exactly once. Missing entries are
  // treated as "not relevant" (safer to under-approve than to leak noise).
  //
  // If the LLM returns anything we can't structurally parse we treat that
  // as a verifier ERROR (not "nothing relevant") — the two states have
  // different downstream user messages and we must not conflate them.
  const passedIndices = new Set<number>();
  let parseError: string | undefined;
  try {
    const parsed = JSON.parse(raw);
    const verdicts = Array.isArray(parsed?.verdicts) ? parsed.verdicts : [];
    if (verdicts.length === 0) {
      parseError = 'no verdicts array in response';
    } else {
      for (const v of verdicts) {
        const i = Number(v?.index);
        if (!Number.isFinite(i) || i < 1 || i > top.length) continue;
        if (Boolean(v?.relevant)) passedIndices.add(i - 1);
      }
    }
  } catch (e) {
    parseError = e instanceof Error ? e.message : String(e);
    console.warn('[lean_search] verifier JSON parse failed:', parseError);
  }

  if (parseError) {
    const allIdx = candidatesInput.map(c => c.index);
    writeTrace([], allIdx, 'error', raw, verifierLatency, `json_parse: ${parseError}`);
    return { verified: [], rejected: top, error: `parse: ${parseError}` };
  }

  if (passedIndices.size === 0) {
    const allIdx = candidatesInput.map(c => c.index);
    writeTrace([], allIdx, 'none', raw, verifierLatency);
    return { verified: [], rejected: top };
  }

  // Split the verification window into verified (approved) and rejected
  // (retrieved but not approved by the LLM). The handler surfaces the
  // rejected pool through the "See more" affordance so users can still
  // reach weaker matches when the verifier is strict — without polluting
  // the first page.
  const verified: LeanResultCard[] = [];
  const rejected: LeanResultCard[] = [];
  const verifiedIdxOneBased: number[] = [];
  const rejectedIdxOneBased: number[] = [];
  top.forEach((r, i) => {
    if (passedIndices.has(i)) {
      verified.push(r);
      verifiedIdxOneBased.push(i + 1);
    } else {
      rejected.push(r);
      rejectedIdxOneBased.push(i + 1);
    }
  });
  writeTrace(verifiedIdxOneBased, rejectedIdxOneBased, 'some', raw, verifierLatency);
  return { verified, rejected };
}
