// agent/handler.ts
// ===========================================================================
// !!! DEPRECATED — replaced by ../agent_v2/handler.ts on 2025-01 !!!
//
// This file implements the legacy regex-router + 5-lane dispatch agent.
// /agent-search-auth in index.ts now routes to agent_v2/handler.ts (Groq
// function-calling planner loop with 6 tools). This handler is kept in
// the tree for rollback only — once we've validated agent_v2 in production
// for ~1 week with no regressions, this file (and ./understand.ts and the
// bespoke compare/list/summarize specs in ./types.ts) can be deleted.
//
// `handleAgentSearch` is no longer wired up by the router — it is kept
// exported for the reference and rollback. The agent_v2 wrappers still
// depend on:
//   ./tools/list_notes.ts        (used by tool_list_notes)
//   ./tools/count_and_group.ts   (used by tool_count_notes)
//   ./tools/summarize_many.ts    (used by tool_summarize topic-path)
//   ./time_window.ts             (used by tool_count_notes)
//   ./trace.ts                   (used by handler)
// — DO NOT DELETE those.
//
// Original behaviour (before deprecation):
//   - Run `understand` on the query.
//   - If operation is 'count' or 'group_count' → run count_and_group tool.
//   - Otherwise → forward to classic /rag-search-auth via the supplied
//     `forwardToClassic` closure, then post-process the response through
//     the controller (Phase 3) before returning.
// ===========================================================================

import type { ExecutionContext } from '@cloudflare/workers-types';
import type { AgentEnv, AgentResponse, Scratchpad, TimeWindow } from './types';
import { understand } from './understand';
import { countAndGroupTool, renderCountAnswer } from './tools/count_and_group';
import { writeAgentTrace } from './trace';
import { decideController, applyControllerDecision } from './controller';
import { executeRecipe } from './execute';
import { runBucketFilter, type BucketFilterOutput } from './tools/bucket_filter';
import { runCompareTwoSets } from './tools/compare_two_sets';
import { runSummarizeMany, type SummarizeNote } from './tools/summarize_many';
import { runListNotes, renderListAnswer, type ListNotesNote } from './tools/list_notes';
import {
  loadChatSession,
  addUserMessage,
  addBotSummary,
  deleteChatSession,
  rewriteQueryWithContext,
  type ChatSessionEnv,
  type ChatSession,
} from '../chat-session';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
};

export interface AgentRequestBody {
  query: string;
  user_id: string;
  client_source?: string;
  [key: string]: unknown;
}

/**
 * Closure provided by index.ts that forwards the original (already-authed,
 * already-quota-charged) request to handleRagSearch and returns its Response.
 */
export type ForwardToClassic = () => Promise<Response>;

export async function handleAgentSearch(
  body: AgentRequestBody,
  env: AgentEnv,
  _ctx: ExecutionContext,
  requestId: string,
  forwardToClassic: ForwardToClassic,
): Promise<Response> {
  const t0 = Date.now();
  const traceId = `at_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
  const clientSource = (body.client_source as string | undefined) || 'unknown';
  const newSession = body.new_session === true;

  // ---------------------------------------------------------------------
  // Phase 6: conversational follow-up rewriting for agent lanes.
  //
  // We peek the existing chat session (read-only) and, if there's prior
  // history, ask the same Groq rewriter the classic /rag-search-auth path
  // uses. This lets follow-ups like "summarize those" or "the 2nd one"
  // resolve before `understand()` sees the query.
  //
  // Important: we do NOT call addUserMessage()/addBotSummary() yet — if
  // the query falls through to runForwardPath, classic search will run
  // its own session bookkeeping (addUserMessage + rewrite + addBotSummary)
  // exactly as before. Only agent-claimed lanes write to KV from here.
  // ---------------------------------------------------------------------
  const chatEnv: ChatSessionEnv = {
    CHAT_SESSIONS: env.CHAT_SESSIONS,
    GROQ_API_KEY: env.GROQ_API_KEY,
  };

  let effectiveQuery = body.query;
  let rewriteApplied = false;
  let rewriteMs = 0;

  let session: ChatSession | null = null;
  if (!newSession) {
    try {
      session = await loadChatSession(body.user_id, chatEnv, clientSource);
    } catch (e) {
      console.error(`[${requestId}] agent: loadChatSession failed:`, e);
      session = null;
    }
  }
  const priorUserTurns = session?.messages.filter(m => m.role === 'user').length ?? 0;
  if (session && priorUserTurns >= 1) {
    // Build an in-memory session view with the current user message appended
    // so rewriter's "priorMessages > 1" guard doesn't short-circuit.
    const tempSession: ChatSession = {
      ...session,
      messages: [
        ...session.messages,
        { role: 'user' as const, content: body.query, timestamp: Date.now() },
      ],
    };
    try {
      const rew = await rewriteQueryWithContext(body.query, tempSession, chatEnv);
      rewriteMs = rew.durationMs;
      if (rew.wasRewritten && rew.rewrittenQuery && rew.rewrittenQuery !== body.query) {
        effectiveQuery = rew.rewrittenQuery;
        rewriteApplied = true;
        console.log(
          `[${requestId}] agent rewrite: "${body.query}" → "${effectiveQuery}" (${rewriteMs}ms)`,
        );
      } else {
        console.log(`[${requestId}] agent rewrite: not needed (${rewriteMs}ms)`);
      }
    } catch (e) {
      console.error(`[${requestId}] agent rewrite failed:`, e);
    }
  }

  const structured = understand(effectiveQuery);
  console.log(
    `[${requestId}] agent: op=${structured.operation} group_by=${structured.group_by ?? '-'} ` +
      `time=${structured.filter.time ?? '-'} platforms=${(structured.filter.platforms ?? []).join('|') || '-'}`,
  );

  const scratchpad: Scratchpad = {
    trace_id: traceId,
    user_id: body.user_id,
    query: effectiveQuery,
    structured,
    candidates: [],
    evidence: [],
    partials: [],
    confidence: 0,
    steps: [],
  };
  if (rewriteApplied) {
    scratchpad.steps.push({
      tool: 'rewrite_query',
      ms: rewriteMs,
      ok: true,
      note: `original="${body.query}"`,
    });
  }

  const isAgentClaimed =
    structured.operation === 'count' ||
    structured.operation === 'group_count' ||
    (structured.operation === 'compare' && !!structured.compare) ||
    (structured.operation === 'summarize' && !!structured.summarize) ||
    (structured.operation === 'list' && !!structured.list);

  if (!isAgentClaimed) {
    // Forward original (un-rewritten) query so classic /rag-search-auth runs
    // its own session work + rewrite + bot summary unchanged.
    return runForwardPath(body, env, scratchpad, traceId, t0, forwardToClassic);
  }

  // Agent-claimed lane: take over session bookkeeping ourselves so the
  // forward path's classic addUserMessage/addBotSummary doesn't run.
  if (newSession) {
    try {
      await deleteChatSession(body.user_id, chatEnv, clientSource);
    } catch (e) {
      console.error(`[${requestId}] agent: deleteChatSession failed:`, e);
    }
  }
  try {
    await addUserMessage(body.user_id, body.query, chatEnv, clientSource);
  } catch (e) {
    console.error(`[${requestId}] agent: addUserMessage failed:`, e);
  }

  // Stash chat env on body for lane paths so they can write addBotSummary.
  // This avoids changing every lane's signature.
  (body as any)._chatEnv = chatEnv;
  (body as any)._clientSource = clientSource;

  if (structured.operation === 'count' || structured.operation === 'group_count') {
    return runCountPath(body, env, scratchpad, traceId, t0, requestId);
  }
  if (structured.operation === 'compare' && structured.compare) {
    return runComparePath(body, env, scratchpad, traceId, t0, requestId);
  }
  if (structured.operation === 'summarize' && structured.summarize) {
    return runSummarizePath(body, env, scratchpad, traceId, t0, requestId);
  }
  if (structured.operation === 'list' && structured.list) {
    return runListPath(body, env, scratchpad, traceId, t0, requestId);
  }

  // Unreachable — isAgentClaimed already gated this — but keep TS happy.
  return runForwardPath(body, env, scratchpad, traceId, t0, forwardToClassic);
}

// ---------------------------------------------------------------------------
// Helper: persist a bot summary turn for agent-claimed lanes so follow-ups
// like "the 2nd one" / "try again" resolve correctly on the next query.
// ---------------------------------------------------------------------------
async function persistBotSummary(
  body: AgentRequestBody,
  pathTaken: string,
  titles: string[],
  noteIds: string[],
  resultCount: number,
  actionType: 'search' | 'synthesis' | 'transform' | 'chat',
  requestId: string,
): Promise<void> {
  const chatEnv = (body as any)._chatEnv as ChatSessionEnv | undefined;
  const clientSource = (body as any)._clientSource as string | undefined;
  if (!chatEnv) return;
  try {
    await addBotSummary(
      body.user_id,
      titles,
      pathTaken,
      resultCount,
      chatEnv,
      clientSource,
      { noteIds, actionType },
    );
  } catch (e) {
    console.error(`[${requestId}] agent: addBotSummary failed:`, e);
  }
}

// ---------------------------------------------------------------------------
// Phase 1 path: deterministic count / group_count
// ---------------------------------------------------------------------------
async function runCountPath(
  body: AgentRequestBody,
  env: AgentEnv,
  scratchpad: Scratchpad,
  traceId: string,
  t0: number,
  requestId: string,
): Promise<Response> {
  let answer = '';
  let status: 'completed' | 'error' = 'completed';
  let errorMessage: string | undefined;

  try {
    const stepStart = Date.now();
    const out = await countAndGroupTool.run({}, { env, scratchpad, requestId });
    scratchpad.steps.push({
      tool: 'count_and_group',
      ms: Date.now() - stepStart,
      ok: true,
      note: `total=${out.total} groups=${out.groups?.length ?? 0}`,
    });
    answer = renderCountAnswer(body.query, out, scratchpad.structured.group_by);
    scratchpad.confidence = 1.0;
    scratchpad.partials.push(answer);
  } catch (err) {
    status = 'error';
    errorMessage = err instanceof Error ? err.message : String(err);
    answer = `I couldn't run that count. (${errorMessage})`;
    scratchpad.steps.push({
      tool: 'count_and_group',
      ms: Date.now() - t0,
      ok: false,
      note: errorMessage,
    });
  }

  const duration = Date.now() - t0;

  await writeAgentTrace(env, {
    trace_id: traceId,
    user_id: body.user_id,
    query: body.query,
    client_source: body.client_source,
    route: 'count_and_group',
    scratchpad,
    recipe: ['count_and_group'],
    duration_ms: duration,
    status,
    error: errorMessage,
  });

  const responseBody: AgentResponse = {
    answer,
    results: [],
    query_type: 'analytics',
    agent: { trace_id: traceId, route: 'count_and_group', duration_ms: duration },
  };

  await persistBotSummary(
    body,
    'count_and_group',
    [],
    [],
    0,
    'synthesis',
    requestId,
  );

  return new Response(JSON.stringify(responseBody), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

// ---------------------------------------------------------------------------
// Phase 4 path: compare two time-windowed buckets.
// ---------------------------------------------------------------------------
async function runComparePath(
  body: AgentRequestBody,
  env: AgentEnv,
  scratchpad: Scratchpad,
  traceId: string,
  t0: number,
  requestId: string,
): Promise<Response> {
  const cmp = scratchpad.structured.compare!;
  const ctx = { env, scratchpad, requestId };

  let answer = '';
  let status: 'completed' | 'error' = 'completed';
  let errorMessage: string | undefined;
  let usedA = 0;
  let usedB = 0;
  let bucketA: BucketFilterOutput | undefined;
  let bucketB: BucketFilterOutput | undefined;

  try {
    const recipe = [
      {
        name: 'bucket_filter_a',
        input: () => ({ topic: cmp.topic, window: cmp.window_a, limit: 25 }),
        run: runBucketFilter,
      },
      {
        name: 'bucket_filter_b',
        input: () => ({ topic: cmp.topic, window: cmp.window_b, limit: 25 }),
        run: runBucketFilter,
      },
      {
        name: 'compare_two_sets',
        input: (bag: Record<string, any>) => ({
          topic: cmp.topic,
          bucket_a: bag.bucket_filter_a as BucketFilterOutput,
          bucket_b: bag.bucket_filter_b as BucketFilterOutput,
          label_a: humanLabel(cmp.window_a),
          label_b: humanLabel(cmp.window_b),
        }),
        run: runCompareTwoSets,
      },
    ];

    const result = await executeRecipe(recipe, ctx);
    bucketA = result.bag.bucket_filter_a as BucketFilterOutput;
    bucketB = result.bag.bucket_filter_b as BucketFilterOutput;
    const cmpOut = result.bag.compare_two_sets as { answer: string; used_a: number; used_b: number };
    answer = cmpOut.answer;
    usedA = cmpOut.used_a;
    usedB = cmpOut.used_b;
    scratchpad.confidence = (usedA > 0 && usedB > 0) ? 0.8 : 0.4;
    scratchpad.partials.push(answer);
  } catch (err) {
    status = 'error';
    errorMessage = err instanceof Error ? err.message : String(err);
    answer = `I couldn't run that comparison. (${errorMessage})`;
  }

  const duration = Date.now() - t0;

  await writeAgentTrace(env, {
    trace_id: traceId,
    user_id: body.user_id,
    query: body.query,
    client_source: body.client_source,
    route: 'compare_two_sets',
    scratchpad,
    recipe: ['bucket_filter_a', 'bucket_filter_b', 'compare_two_sets'],
    duration_ms: duration,
    status,
    error: errorMessage,
  });

  // Surface a few representative notes from each bucket so the UI can show cards.
  const results = [
    ...(bucketA?.notes ?? []).slice(0, 5).map(toResultCard),
    ...(bucketB?.notes ?? []).slice(0, 5).map(toResultCard),
  ];

  const responseBody: AgentResponse = {
    answer,
    results,
    query_type: 'compare',
    agent: { trace_id: traceId, route: 'compare_two_sets', duration_ms: duration },
  };

  const compareNotes = [
    ...(bucketA?.notes ?? []).slice(0, 5),
    ...(bucketB?.notes ?? []).slice(0, 5),
  ];
  await persistBotSummary(
    body,
    'compare_two_sets',
    compareNotes.map(n => n.title),
    compareNotes.map(n => n.note_id),
    compareNotes.length,
    'synthesis',
    requestId,
  );

  return new Response(JSON.stringify(responseBody), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

function toResultCard(n: { note_id: string; title: string; content_preview: string; tag?: string; file_type?: string; description?: string }) {
  return {
    note_id: n.note_id,
    title: n.title,
    chunk_content: n.content_preview,
    description: n.description,
    tag: n.tag,
    file_type: n.file_type,
    similarity_score: 0,
    source: 'agent_compare',
  };
}

function humanLabel(w: TimeWindow): string {
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

// ---------------------------------------------------------------------------
// Phase 5 path: map-reduce summarize.
// ---------------------------------------------------------------------------
async function runSummarizePath(
  body: AgentRequestBody,
  env: AgentEnv,
  scratchpad: Scratchpad,
  traceId: string,
  t0: number,
  requestId: string,
): Promise<Response> {
  const sm = scratchpad.structured.summarize!;
  const ctx = { env, scratchpad, requestId };

  let answer = '';
  let status: 'completed' | 'error' = 'completed';
  let errorMessage: string | undefined;
  let notesCount = 0;
  let batches = 0;
  let surfaced: SummarizeNote[] = [];

  try {
    const stepStart = Date.now();
    const out = await runSummarizeMany({ topic: sm.topic, window: sm.window, limit: 100 }, ctx);
    scratchpad.steps.push({
      tool: 'summarize_many',
      ms: Date.now() - stepStart,
      ok: true,
      note: `notes=${out.notes_count} batches=${out.batches}`,
    });
    answer = out.answer;
    notesCount = out.notes_count;
    batches = out.batches;
    surfaced = out.notes;
    scratchpad.confidence = out.notes_count > 0 ? 0.85 : 0.3;
    scratchpad.partials.push(answer);
    // Stash batch summaries for trace inspection.
    (scratchpad as any).batch_summaries = out.batch_summaries;
  } catch (err) {
    status = 'error';
    errorMessage = err instanceof Error ? err.message : String(err);
    answer = `I couldn't run that summary. (${errorMessage})`;
    scratchpad.steps.push({
      tool: 'summarize_many',
      ms: Date.now() - t0,
      ok: false,
      note: errorMessage,
    });
  }

  const duration = Date.now() - t0;

  await writeAgentTrace(env, {
    trace_id: traceId,
    user_id: body.user_id,
    query: body.query,
    client_source: body.client_source,
    route: 'summarize_many',
    scratchpad,
    recipe: ['fetch_notes', 'map_summarize_8b', 'reduce_summarize_70b'],
    duration_ms: duration,
    status,
    error: errorMessage,
  });

  // Surface up to 8 representative notes as result cards for the UI.
  const results = surfaced.slice(0, 8).map(toResultCard);

  const responseBody: AgentResponse = {
    answer,
    results,
    query_type: 'summarize',
    agent: { trace_id: traceId, route: 'summarize_many', duration_ms: duration },
  };
  // Tack on a tiny meta block in the agent envelope so tests can introspect.
  (responseBody.agent as any).summarize = { notes_count: notesCount, batches };

  await persistBotSummary(
    body,
    'summarize_many',
    surfaced.slice(0, 5).map(n => n.title),
    surfaced.slice(0, 5).map(n => n.note_id),
    notesCount,
    'synthesis',
    requestId,
  );

  return new Response(JSON.stringify(responseBody), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

// ---------------------------------------------------------------------------
// Phase 5.5 path: deterministic list (find/show/list with structured filter).
// ---------------------------------------------------------------------------
async function runListPath(
  body: AgentRequestBody,
  env: AgentEnv,
  scratchpad: Scratchpad,
  traceId: string,
  t0: number,
  requestId: string,
): Promise<Response> {
  const ls = scratchpad.structured.list!;
  const ctx = { env, scratchpad, requestId };

  let answer = '';
  let status: 'completed' | 'error' = 'completed';
  let errorMessage: string | undefined;
  let notes: ListNotesNote[] = [];
  let total = 0;

  try {
    const stepStart = Date.now();
    const out = await runListNotes(
      {
        topic: ls.topic,
        window: ls.window,
        file_types: ls.file_types,
        tags: ls.tags,
        limit: 50,
      },
      ctx,
    );
    scratchpad.steps.push({
      tool: 'list_notes',
      ms: Date.now() - stepStart,
      ok: true,
      note: `total=${out.total_matched}`,
    });
    notes = out.notes;
    total = out.total_matched;
    answer = renderListAnswer(out, ls);
    scratchpad.confidence = total > 0 ? 1.0 : 0.5;
    scratchpad.partials.push(answer);
  } catch (err) {
    status = 'error';
    errorMessage = err instanceof Error ? err.message : String(err);
    answer = `I couldn't run that listing. (${errorMessage})`;
    scratchpad.steps.push({
      tool: 'list_notes',
      ms: Date.now() - t0,
      ok: false,
      note: errorMessage,
    });
  }

  const duration = Date.now() - t0;

  await writeAgentTrace(env, {
    trace_id: traceId,
    user_id: body.user_id,
    query: body.query,
    client_source: body.client_source,
    route: 'list_notes',
    scratchpad,
    recipe: ['list_notes'],
    duration_ms: duration,
    status,
    error: errorMessage,
  });

  // Surface up to 25 result cards (deterministic listing — show real list).
  const results = notes.slice(0, 25).map(n => ({
    ...toResultCard(n),
    source: 'agent_list',
  }));

  const responseBody: AgentResponse = {
    answer,
    results,
    query_type: 'list',
    agent: { trace_id: traceId, route: 'list_notes', duration_ms: duration },
  };
  (responseBody.agent as any).list = { total_matched: total };

  await persistBotSummary(
    body,
    'list_notes',
    notes.slice(0, 5).map(n => n.title),
    notes.slice(0, 5).map(n => n.note_id),
    total,
    'search',
    requestId,
  );

  return new Response(JSON.stringify(responseBody), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

// ---------------------------------------------------------------------------
// Forward path: call classic /rag-search-auth, then run Phase 3 controller.
// ---------------------------------------------------------------------------
async function runForwardPath(
  body: AgentRequestBody,
  env: AgentEnv,
  scratchpad: Scratchpad,
  traceId: string,
  t0: number,
  forwardToClassic: ForwardToClassic,
): Promise<Response> {
  const fwdStart = Date.now();
  let classicResp: Response;
  try {
    classicResp = await forwardToClassic();
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    scratchpad.steps.push({ tool: 'forward_classic', ms: Date.now() - fwdStart, ok: false, note: errorMessage });
    await writeAgentTrace(env, {
      trace_id: traceId,
      user_id: body.user_id,
      query: body.query,
      client_source: body.client_source,
      route: 'forward_classic',
      scratchpad,
      recipe: ['forward_classic'],
      duration_ms: Date.now() - t0,
      status: 'error',
      error: errorMessage,
    });
    throw err;
  }
  scratchpad.steps.push({
    tool: 'forward_classic',
    ms: Date.now() - fwdStart,
    ok: classicResp.ok,
  });

  // Non-JSON or non-2xx: pass through unchanged. Don't mess with errors.
  const ct = classicResp.headers.get('content-type') || '';
  if (!classicResp.ok || ct.indexOf('json') === -1) {
    await writeAgentTrace(env, {
      trace_id: traceId,
      user_id: body.user_id,
      query: body.query,
      client_source: body.client_source,
      route: 'forward_classic',
      scratchpad,
      recipe: ['forward_classic'],
      duration_ms: Date.now() - t0,
      status: classicResp.ok ? 'completed' : 'error',
    });
    return classicResp;
  }

  // Parse, run controller, possibly modify, emit a fresh Response.
  let json: any;
  try {
    json = await classicResp.json();
  } catch {
    return classicResp;
  }

  const decision = decideController(scratchpad.structured, json);
  scratchpad.confidence = decision.confidence.top_rerank ?? 0;
  scratchpad.steps.push({
    tool: 'controller',
    ms: 0,
    ok: true,
    note: `${decision.action}:${decision.reason}`,
  });

  const finalJson =
    decision.action === 'continue' ? json : applyControllerDecision(json, decision);

  // Stamp agent metadata so clients (and tests) can see what happened.
  finalJson.agent = {
    trace_id: traceId,
    route: 'forward_classic',
    duration_ms: Date.now() - t0,
    controller: {
      action: decision.action,
      reason: decision.reason,
      top_rerank: decision.confidence.top_rerank,
      result_count: decision.confidence.result_count,
    },
  };

  const routeLabel =
    decision.action === 'continue'
      ? 'forward_classic'
      : `forward_classic+${decision.action}`;

  await writeAgentTrace(env, {
    trace_id: traceId,
    user_id: body.user_id,
    query: body.query,
    client_source: body.client_source,
    route: routeLabel,
    scratchpad,
    recipe: decision.action === 'continue'
      ? ['forward_classic']
      : ['forward_classic', `controller:${decision.action}`],
    duration_ms: Date.now() - t0,
    status: 'completed',
  });

  return new Response(JSON.stringify(finalJson), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}
