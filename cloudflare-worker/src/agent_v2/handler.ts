// agent_v2/handler.ts
// ===========================================================================
// Entry point for /agent-v2-search-auth — the function-calling planner agent.
//
// Replaces (in v2) the regex router + 5-lane dispatch in agent/handler.ts.
// Auth + quota are handled by index.ts before this is called.
// ===========================================================================

import type { ExecutionContext } from '@cloudflare/workers-types';
import type { RagSearchEnv } from '../rag-search';
import {
  loadChatSession,
  addUserMessage,
  addBotSummary,
  deleteChatSession,
  type ChatSessionEnv,
} from '../chat-session';
import { writeAgentTrace } from '../agent/trace';
import type { Scratchpad } from '../agent/types';
import { runAgentLoop, type PriorTurn } from './loop';
import type { LeanVectorSearchFn } from './lean_search';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
};

export interface AgentV2RequestBody {
  query: string;
  user_id: string;
  client_source?: string;
  tag_filter?: string | string[];
  new_session?: boolean;
  exclude_note_ids?: string[];
  max_results?: number;
  [key: string]: unknown;
}

export type ForwardToClassic = () => Promise<Response>;

const MAX_PRIOR_TURNS = 8;

export async function handleAgentV2Search(
  body: AgentV2RequestBody,
  env: RagSearchEnv,
  ctx: ExecutionContext,
  requestId: string,
  forwardToClassic: ForwardToClassic,
  leanVectorSearch: LeanVectorSearchFn,
): Promise<Response> {
  const t0 = Date.now();
  const traceId = `av2_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
  const clientSource = (body.client_source as string | undefined) || 'unknown';
  const newSession = body.new_session === true;
  const selectedTags = normalizeTagFilters(body.tag_filter);

  // -----------------------------------------------------------------
  // FAST PATH: Search Deeper round.
  //
  // The user clicked "Search Deeper" on a prior result set. There's no
  // new intent for the planner to interpret — just paginate the same
  // query honoring the cumulative exclude list. We bypass the planner
  // (and therefore all of its LLM calls) and call lean retrieval
  // directly. Chat session is NOT touched (this isn't a new turn).
  // -----------------------------------------------------------------
  if (Array.isArray(body.exclude_note_ids) && body.exclude_note_ids.length > 0) {
    try {
      const k = Math.max(1, Math.min(body.max_results ?? 10, 50));
      const lean = await leanVectorSearch(body.query, k, body.exclude_note_ids, selectedTags);
      // If relevance verification dropped everything, tell the UI explicitly
      // so it shows "no more results" instead of an empty source bubble.
      const isEmpty = !lean.results || lean.results.length === 0;

      // Hydrate each surviving result with metadata.source_url so Flutter's
      // _openSourceDocument can launch the original link directly. Without
      // this, the fast path returned only chunk fields and the client fell
      // through to /notes/{id} (which then errored out as "can't open").
      // Mirrors what tool_fetch_note does in the regular planner path.
      const hydrated = isEmpty
        ? []
        : await hydrateSourceUrls(lean.results, body.user_id, env);

      const responseBody = {
        answer: isEmpty ? 'No more relevant results found.' : '',
        results: hydrated,
        query_type: 'agent_v2_search_deeper',
        search_deeper: isEmpty
          ? { ...lean.search_deeper, available: false }
          : lean.search_deeper,
        agent: {
          trace_id: traceId,
          route: 'agent_v2_search_deeper',
          duration_ms: Date.now() - t0,
          iterations: 0,
          tool_calls: [{ name: 'vector_search', ok: true, ms: lean.timing_ms }],
          finished_reason: 'search_deeper',
        },
      };

      // Trace the Search Deeper round so it shows up in agent_traces. Without
      // this, the round was completely invisible in logs and impossible to
      // debug. Use the same scratchpad shape as the regular path so existing
      // analytics queries keep working.
      const sdScratchpad: Scratchpad = {
        trace_id: traceId,
        user_id: body.user_id,
        query: body.query,
        structured: {
          operation: 'search_deeper',
          topic: null,
          filter: { exclude_note_ids: body.exclude_note_ids, tag_filter: selectedTags },
          ambiguity: 0,
          notes: 'agent_v2 search-deeper fast path (planner bypassed)',
        } as any,
        candidates: [],
        evidence: hydrated.map((c: any) => ({ note_id: c.note_id, title: c.title })),
        partials: [responseBody.answer.slice(0, 500)],
        confidence: isEmpty ? 0 : 1,
        steps: [{ tool: 'vector_search', ms: lean.timing_ms, ok: true }],
      };
      ctx.waitUntil(
        writeAgentTrace(env, {
          trace_id: traceId,
          parent_request_id: requestId,
          user_id: body.user_id,
          query: body.query,
          client_source: body.client_source,
          route: 'agent_v2_search_deeper',
          scratchpad: sdScratchpad,
          recipe: ['vector_search'],
          duration_ms: Date.now() - t0,
          status: 'completed',
        }).catch(e => console.error(`[${requestId}] v2 search-deeper trace write failed:`, e)),
      );

      return new Response(JSON.stringify(responseBody), {
        status: 200,
        headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
      });
    } catch (err) {
      console.error(`[${requestId}] v2 search-deeper short-circuit failed:`, err);
      // Fall through to the full planner path on error.
    }
  }

  const chatEnv: ChatSessionEnv = {
    CHAT_SESSIONS: env.CHAT_SESSIONS,
    GROQ_API_KEY: env.GROQ_API_KEY,
  };

  // ---------------------------------------------------------------------
  // Session: load prior turns (if any), then record user message.
  // The planner LLM does its OWN follow-up resolution from chat history,
  // so no separate rewriter call is needed here.
  // ---------------------------------------------------------------------
  if (newSession) {
    try { await deleteChatSession(body.user_id, chatEnv, clientSource); }
    catch (e) { console.error(`[${requestId}] v2: deleteChatSession failed:`, e); }
  }

  let priorTurns: PriorTurn[] = [];
  try {
    const session = await loadChatSession(body.user_id, chatEnv, clientSource);
    if (session) {
      priorTurns = session.messages
        .filter(m => m.role === 'user' || m.role === 'assistant')
        .slice(-MAX_PRIOR_TURNS)
        .map(m => ({ role: m.role as 'user' | 'assistant', content: m.content }));
    }
  } catch (e) {
    console.error(`[${requestId}] v2: loadChatSession failed:`, e);
  }

  try { await addUserMessage(body.user_id, body.query, chatEnv, clientSource); }
  catch (e) { console.error(`[${requestId}] v2: addUserMessage failed:`, e); }

  // ---------------------------------------------------------------------
  // Run the planner loop
  // ---------------------------------------------------------------------
  let loopResult;
  let status: 'completed' | 'error' = 'completed';
  let errorMessage: string | undefined;

  try {
    loopResult = await runAgentLoop({
      userQuery: body.query,
      priorTurns,
      ctx,
      env,
      userId: body.user_id,
      requestId,
      leanVectorSearch,
      forwardToClassic,
      selectedTags,
    });
  } catch (err) {
    status = 'error';
    errorMessage = err instanceof Error ? err.message : String(err);
    console.error(`[${requestId}] v2 loop crashed:`, err);
    loopResult = {
      answer: 'Sorry, something went wrong. Please try again.',
      cards: [],
      browseCards: [],
      browseCardsTail: [],
      trace: { iterations: 0, tool_calls: [], finished_reason: 'error' as const, total_ms: 0 },
    };
  }

  const duration = Date.now() - t0;

  // ---------------------------------------------------------------------
  // Persist bot summary so next-turn follow-ups have context.
  // ---------------------------------------------------------------------
  try {
    const titles = loopResult.cards.slice(0, 10).map(c => c.title);
    const ids = loopResult.cards.slice(0, 10).map(c => c.note_id);
    const actionType =
      loopResult.trace.tool_calls.some(tc => tc.name === 'summarize') ? 'synthesis'
      : loopResult.trace.tool_calls.some(tc => tc.name === 'count_notes') ? 'chat'
      : 'search';
    await addBotSummary(
      body.user_id,
      titles,
      'agent_v2',
      loopResult.cards.length,
      chatEnv,
      clientSource,
      { noteIds: ids, actionType: actionType as any },
    );
  } catch (e) {
    console.error(`[${requestId}] v2: addBotSummary failed:`, e);
  }

  // ---------------------------------------------------------------------
  // Trace logging — reuse the existing agent_traces table.
  // ---------------------------------------------------------------------
  const scratchpad: Scratchpad = {
    trace_id: traceId,
    user_id: body.user_id,
    query: body.query,
    structured: {
      // Synthetic — keeps the existing column non-null.
      operation: 'unknown',
      topic: null,
      filter: selectedTags.length > 0 ? { tag_filter: selectedTags } : {},
      ambiguity: 0,
      notes: 'agent_v2 (function-calling planner)',
    } as any,
    candidates: [],
    evidence: loopResult.cards.map(c => ({ note_id: c.note_id, title: c.title })),
    partials: [loopResult.answer.slice(0, 500)],
    confidence: loopResult.trace.finished_reason === 'final_answer' ? 1.0 : 0.5,
    steps: loopResult.trace.tool_calls.map(tc => ({
      tool: tc.name,
      ms: tc.duration_ms,
      ok: tc.ok,
      note: tc.result_preview ?? tc.error,
    })),
  };

  await writeAgentTrace(env, {
    trace_id: traceId,
    parent_request_id: requestId,
    user_id: body.user_id,
    query: body.query,
    client_source: body.client_source,
    route: 'agent_v2',
    scratchpad,
    recipe: loopResult.trace.tool_calls.map(tc => tc.name),
    duration_ms: duration,
    status,
    error: errorMessage,
  });

  // ---------------------------------------------------------------------
  // Build response (mirrors classic /rag-search-auth shape).
  // Surface a `search_deeper` block when vector_search was used so the
  // dashboard's "Search Deeper" button can re-POST with exclude_note_ids
  // and hit the fast-path short-circuit above.
  // ---------------------------------------------------------------------
  const usedVectorSearch = loopResult.trace.tool_calls.some(tc => tc.name === 'vector_search');
  // Show More is pagination over the same completed tool output; it is not
  // Search Deeper. Keep the first page small enough for the chat UI, while
  // sending the already verified remainder for local client-side paging.
  const BROWSE_PAGE_SIZE = 10;

  // For semantic queries (vector_search was called), the response's `results`
  // must ONLY contain vector-search verified cards. Otherwise the planner's
  // scratchpad `list_notes` / `fetch_note` calls — which it may make without
  // a proper tag filter — dump random recent notes into the user's view
  // (e.g. a finance reel surfacing on a "movies to watch" query).
  //
  // For non-semantic queries (only list_notes / count_notes / fetch_note),
  // fall back to the planner card pool so structured requests
  // ("show me my instagram notes from june") still work.
  //
  // "See more" (result_pagination.remaining_results) receives ONLY verified
  // overflow beyond the first-page window (rare — the verifier usually
  // returns <=10 approved cards, so this is normally empty and the button
  // disappears).
  //
  // We intentionally do NOT splice in the verifier-rejected tail here. The
  // original design surfaced rejected candidates as a "browse anyway" pool
  // in case the verifier was too strict, but in practice it just dumps
  // clearly-irrelevant cards on the user (e.g. "relationship" -> first page
  // is fine, "See more" is noise). Rejected candidates are still recorded
  // in verifier_traces for offline eval; they're just not shown.
  // Sort verified cards by stable global citation_index so the client-side
  // numbered carousel matches the [N] markers the planner emitted. Cards
  // without an index (list_notes / fetch_note fallback paths) drop to the
  // end. Only applies when vector_search was used; the non-semantic branch
  // uses `loopResult.cards` in tool-call order.
  const sortedBrowseCards = usedVectorSearch
    ? [...loopResult.browseCards].sort((a, b) => {
        const ai = a.citation_index ?? Number.POSITIVE_INFINITY;
        const bi = b.citation_index ?? Number.POSITIVE_INFINITY;
        return ai - bi;
      })
    : loopResult.browseCards;
  const verifiedFirstPage = sortedBrowseCards.slice(0, BROWSE_PAGE_SIZE);
  const verifiedOverflow = sortedBrowseCards.slice(BROWSE_PAGE_SIZE);
  const firstPageCardsRaw = usedVectorSearch
    ? verifiedFirstPage
    : loopResult.cards.slice(0, BROWSE_PAGE_SIZE);
  const remainingResultCardsRaw = usedVectorSearch
    ? verifiedOverflow
    : loopResult.cards.slice(BROWSE_PAGE_SIZE);
  // Hydrate cards with source_url / social_source / file_type from notes.
  // Without this the regular planner path returned only chunk fields, so
  // Flutter's `_iconForResult` / `_sourceLabel` fell through the fallback
  // chain and rendered Instagram posts as generic "Snap" with a document
  // icon. Mirrors what the Search Deeper fast path already does.
  const [firstPageCards, remainingResultCards] = await Promise.all([
    firstPageCardsRaw.length > 0
      ? hydrateSourceUrls(firstPageCardsRaw as any[], body.user_id, env)
      : Promise.resolve(firstPageCardsRaw),
    remainingResultCardsRaw.length > 0
      ? hydrateSourceUrls(remainingResultCardsRaw as any[], body.user_id, env)
      : Promise.resolve(remainingResultCardsRaw),
  ]);
  // Search Deeper exclude list: use the FULL pre-rerank candidate pool from
  // every vector_search call, not just the cards the verifier kept. That
  // ensures round 2 hybrid search excludes everything we already considered
  // (including reranker-rejected docs), so it draws from genuinely fresh
  // notes. Falls back to the union of visible + browse-cached ids if the
  // loop didn't accumulate any (older code paths or non-vector_search
  // routes).
  const seenIds = Array.from(new Set(
    [...loopResult.cards, ...loopResult.browseCards, ...(loopResult.browseCardsTail ?? [])]
      .map(c => c.note_id)
      .filter((id): id is string => !!id),
  ));
  const sdExcludeIds = loopResult.candidateNoteIds && loopResult.candidateNoteIds.length > 0
    ? loopResult.candidateNoteIds
    : seenIds;
  const totalPagedResults = firstPageCards.length + remainingResultCards.length;

  // If the LLM relevance verifier failed on any vector_search call this
  // request, override the planner's answer. The planner might otherwise say
  // "no notes found" (which the tool result would technically support since
  // we fail-closed on verifier errors) — but that's misleading. Tell the
  // user the check itself failed so they retry instead of assuming the
  // corpus doesn't contain what they asked for.
  const verifierErrored = Boolean(loopResult.verifierError);
  const answerText = verifierErrored
    ? "Sorry, something went wrong while checking which notes are relevant to your search. Please try again in a moment."
    : loopResult.answer;

  const responseBody: any = {
    answer: answerText,
    results: verifierErrored ? [] : firstPageCards,
    query_type: 'agent_v2',
    ...(verifierErrored ? { verifier_error: loopResult.verifierError } : {}),
    agent: {
      trace_id: traceId,
      route: 'agent_v2',
      duration_ms: duration,
      iterations: loopResult.trace.iterations,
      tool_calls: loopResult.trace.tool_calls.map(tc => ({
        name: tc.name,
        ok: tc.ok,
        ms: tc.duration_ms,
      })),
      finished_reason: loopResult.trace.finished_reason,
    },
    ...(loopResult.clarification ? { clarification: loopResult.clarification } : {}),
    ...(!verifierErrored && remainingResultCards.length > 0 ? {
      result_pagination: {
        total_results: totalPagedResults,
        page_size: BROWSE_PAGE_SIZE,
        remaining_results: remainingResultCards,
      },
    } : {}),
  };

  if (!verifierErrored && usedVectorSearch && seenIds.length > 0) {
    // Only surface Search Deeper for semantic (vector_search) turns.
    // list_notes / count_notes are deterministic tag/type filters — the
    // returned set IS exhaustive for the intent, so "deeper" is
    // semantically meaningless (the fast-path handler would silently
    // pivot to vector_search off-tag and replace the browse results).
    responseBody.search_deeper = {
      available: true,
      exclude_note_ids: sdExcludeIds,
      total_so_far: sdExcludeIds.length,
      message: "Didn\u2019t find what you were looking for? I can search deeper for more results.",
    };
  }

  return new Response(JSON.stringify(responseBody), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

function normalizeTagFilters(value: unknown): string[] {
  const raw = Array.isArray(value) ? value : value ? [value] : [];
  return [...new Set(raw
    .filter((tag): tag is string => typeof tag === 'string')
    .map(tag => tag.trim())
    .filter(Boolean))];
}

// ---------------------------------------------------------------------------
// Hydrate Search Deeper result cards with source_url pulled from notes.metadata.
//
// Without this the fast path emitted only chunk fields and Flutter's
// _openSourceDocument fell through to the in-app /notes/{id} route, which
// rendered as "can't open this file" for non-doc notes (Instagram reels,
// tweets, webpages, etc. that the user expects to open externally).
//
// One bulk SELECT per Search Deeper round; matches the columns tool_fetch_note
// already pulls so the response shape stays consistent across both paths.
// ---------------------------------------------------------------------------
async function hydrateSourceUrls(
  results: any[],
  userId: string,
  env: RagSearchEnv,
): Promise<any[]> {
  if (!results || results.length === 0) return results;
  const ids = results.map(r => String(r.note_id || '')).filter(Boolean);
  if (ids.length === 0) return results;

  try {
    const idList = ids.map(id => `"${id}"`).join(',');
    const params = new URLSearchParams();
    params.set('id', `in.(${idList})`);
    params.set('user_id', `eq.${userId}`);
    params.set('select', 'id,metadata,description,file_type,tag,created_at');
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/notes?${params.toString()}`, {
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      },
    });
    if (!r.ok) {
      console.warn(`[hydrateSourceUrls] notes fetch failed: ${r.status}`);
      return results;
    }
    const rows: any[] = await r.json();
    const byId = new Map<string, any>();
    for (const row of rows) byId.set(String(row.id), row);

    return results.map((card) => {
      const row = byId.get(String(card.note_id));
      if (!row) return card;
      const meta = (row.metadata && typeof row.metadata === 'object') ? row.metadata : {};
      const social = (meta.social && typeof meta.social === 'object') ? meta.social : {};
      const sourceUrl = social.source_url || meta.source_url || undefined;
      const socialSource = social.source || social.source_app || undefined;
      return {
        ...card,
        // Surface fields Flutter's SearchResult.fromJson reads. Existing
        // chunk fields (chunk_content, blob_url, score, etc.) pass through.
        source_url: sourceUrl,
        social_source: socialSource,
        description: card.description ?? row.description,
        file_type: card.file_type ?? row.file_type,
        tag: card.tag ?? row.tag,
        created_at: card.created_at ?? row.created_at,
      };
    });
  } catch (e) {
    console.warn('[hydrateSourceUrls] failed:', e);
    return results;
  }
}
