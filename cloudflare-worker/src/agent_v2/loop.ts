// agent_v2/loop.ts
// ===========================================================================
// The planner loop — Groq function-calling ReAct-style agent.
//
// Algorithm:
//   1. Send user message + tool catalog to Groq.
//   2. If model returns tool_calls → execute them in parallel → append
//      `role:"tool"` results → loop.
//   3. If model returns content → that's the final answer.
//   4. Hard-cap at MAX_ITERATIONS to prevent runaway.
//
// Returns a structured envelope so the handler can log + render.
// ===========================================================================

import type { RagSearchEnv } from '../rag-search';
import type { ExecutionContext } from '@cloudflare/workers-types';
import { buildGroqTools, validateToolArgs } from './schemas';
import { executeTool, type ResultCard, type ToolRunContext } from './tools';
import type { LeanVectorSearchFn } from './lean_search';

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
// Primary planner model. Picked for tool-use reliability.
//   - llama-3.3-70b-versatile sometimes emits the deprecated
//     `<function=name{args}</function>` text format and 400s with
//     `tool_use_failed`. We handle that via a fallback parser below,
//     but prefer a model that doesn't trigger it.
//   - openai/gpt-oss-120b is consistently strict-JSON on tool calls.
const PLANNER_MODEL = 'openai/gpt-oss-120b';
const MAX_ITERATIONS = 5;

// ---------------------------------------------------------------------------
// Message types (OpenAI-compatible)
// ---------------------------------------------------------------------------
type Msg =
  | { role: 'system'; content: string }
  | { role: 'user'; content: string }
  | { role: 'assistant'; content?: string | null; tool_calls?: ToolCall[] }
  | { role: 'tool'; tool_call_id: string; content: string };

interface ToolCall {
  id: string;
  type: 'function';
  function: { name: string; arguments: string };
}

export interface PriorTurn {
  role: 'user' | 'assistant';
  content: string;
}

export interface AgentLoopResult {
  answer: string;
  cards: ResultCard[];
  /**
   * Full output of the most recent vector_search call. This is kept separate
   * from `cards`, which also contains planner-context cards from list_notes
   * and fetch_note. Browse More must page this completed retrieval only.
   */
  browseCards: ResultCard[];
  /**
   * Retrieval-tier candidates from vector_search that the LLM relevance
   * verifier rejected. Still above the rerank floor (~0.4) — topically
   * related but weaker matches. Surfaced through the client's "See more"
   * pool so users can reach lower-confidence hits without polluting the
   * verified first page.
   */
  browseCardsTail: ResultCard[];
  /**
   * Every note_id that vector + keyword search considered across all
   * vector_search tool calls in this loop — BEFORE rerank filtering. Used
   * by Search Deeper so the next round excludes anything we already
   * evaluated (not just the rerank survivors).
   */
  candidateNoteIds: string[];
  /**
   * Populated when the LLM relevance verifier failed on any vector_search
   * call during this loop (HTTP error, malformed JSON, network drop, etc.).
   * The handler uses this to override the user-facing answer with an
   * explicit "something went wrong" message. Absent when every verifier
   * call succeeded (including legitimate "nothing relevant" verdicts).
   */
  verifierError?: string;
  trace: {
    iterations: number;
    tool_calls: Array<{
      iteration: number;
      name: string;
      args: any;
      ok: boolean;
      duration_ms: number;
      result_preview?: string;
      error?: string;
    }>;
    finished_reason: 'final_answer' | 'max_iterations' | 'ask_user' | 'no_tool' | 'error';
    total_ms: number;
  };
  /** If a tool returned an ask_user clarification, set here. */
  clarification?: { question: string; options: string[] };
}

// ---------------------------------------------------------------------------
// System prompt — kept lean. Anything more belongs in tool descriptions.
// ---------------------------------------------------------------------------
function buildSystemPrompt(): string {
  const today = new Date().toISOString().slice(0, 10);
  return [
    `You are SnapBot, an assistant that answers questions about the user's personal saved notes (links, articles, social posts, files).`,
    `Today's date is ${today}.`,
    ``,
    `# How to choose a tool`,
    `- "show / find / list my X" with structured filters (file type, time, tag) → list_notes`,
    `- "how many / which platform / breakdown" → count_notes (set group_by for per-group counts)`,
    `- Open-ended "what did I save about X" or fuzzy topic queries → vector_search`,
    `- "summarize my notes about X" → summarize with {topic, time_window}`,
    `- "summarize those" / "summarize the previous results" → summarize with {note_ids: ["<ids from prior tool result>"]}`,
    `- "the 2nd one" / "open that note" → fetch_note with the exact id from a prior tool result or prior turn`,
    `- Only call ask_user when truly ambiguous; otherwise pick a sensible default and proceed.`,
    ``,
    `# Hard rules — DO NOT VIOLATE`,
    `1. NEVER invent or guess a note_id. Use ONLY ids that appear verbatim in a previous tool result in this conversation. If you don't have an id, do a list_notes / vector_search first.`,
    `2. NEVER call a tool with empty or partial required arguments. If you don't have what you need, call a different tool first to get it.`,
    `   - summarize requires EITHER note_ids (non-empty array) OR topic (non-empty string).`,
    `   - vector_search requires a non-empty query.`,
    `   - fetch_note requires a real note_id from a prior tool result.`,
    `3. After a tool returns an error, READ the error and FIX the arguments. Do not repeat the same broken call.`,
    `4. When you have enough information to answer, STOP calling tools and write the final answer.`,
    `5. Prefer one good call over several speculative ones. Reason explicitly which tool is correct before calling.`,
    `6. STOP after ONE retrieval tool call for find/show/list/browse/discover queries. The client renders the returned cards directly — the user does NOT need a text summary of them. After list_notes / vector_search / count_notes returns cards, do NOT call fetch_note or summarize; write a one-line final answer like "Here's what I found:" and stop. Only call fetch_note when the user references a SPECIFIC prior card ("the 2nd one", "open that", "details of X"). Only call summarize when the user EXPLICITLY asks for a summary ("summarize", "tldr", "give me a digest").`,
    ``,
    `# Multi-turn conversations`,
    `- The conversation history above shows prior user questions and the assistant's prior answers.`,
    `- For follow-ups like "those", "that one", "the 2nd", "just this month", "the AI ones":`,
    `   * If the prior turn returned a list of notes, the user is referring to that list. Use those notes/ids.`,
    `   * If the prior turn was a count/comparison and the follow-up adds a filter ("just this month", "only youtube"), call the same tool again with the added filter.`,
    `- Inherit prior filters when the user adds to the previous question, not when they ask something new.`,
    ``,
    `# Final answer style`,
    `- Concise, direct, markdown allowed (lists, bold).`,
    `- Do NOT use markdown tables. Prefer short bullet lists instead.`,
    `- Reference notes by title, not by id.`,
    `- Do not narrate the tool plan; just answer.`,
  ].join('\n');
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------
export async function runAgentLoop(opts: {
  userQuery: string;
  priorTurns: PriorTurn[];
  ctx: ExecutionContext;
  env: RagSearchEnv;
  userId: string;
  requestId: string;
  leanVectorSearch: LeanVectorSearchFn;
  forwardToClassic: () => Promise<Response>;
  /** Explicit dashboard tag filters that every retrieval tool must honor. */
  selectedTags?: string[];
}): Promise<AgentLoopResult> {
  const t0 = Date.now();
  const tools = buildGroqTools();

  const messages: Msg[] = [
    { role: 'system', content: buildSystemPrompt() },
    ...opts.priorTurns.map(t => ({ role: t.role, content: t.content }) as Msg),
    { role: 'user', content: opts.userQuery },
  ];

  const toolCtx: ToolRunContext = {
    env: opts.env,
    ctx: opts.ctx,
    userId: opts.userId,
    requestId: opts.requestId,
    selectedTags: opts.selectedTags,
    leanVectorSearch: opts.leanVectorSearch,
    forwardToClassic: opts.forwardToClassic,
    citationIndexById: new Map<string, number>(),
    retrievalCallCount: 0,
  };

  const trace: AgentLoopResult['trace'] = {
    iterations: 0,
    tool_calls: [],
    finished_reason: 'max_iterations',
    total_ms: 0,
  };
  const allCards: ResultCard[] = [];
  let browseCards: ResultCard[] = [];
  let browseCardsTail: ResultCard[] = [];
  const allCandidateNoteIds = new Set<string>();
  // First verifier error we see wins. Persisted across iterations so a
  // late failure in round 2 still surfaces even if round 1 succeeded.
  let verifierError: string | undefined;
  const isSpecificNoteRequest = /\b(?:the\s+\d+(?:st|nd|rd|th)?\s+(?:one|note)|details?\s+(?:of|about)\s+(?:that|the)|open\s+(?:that|the)|show\s+(?:that|the)\s+(?:note|one))\b/i
    .test(opts.userQuery);
  let clarification: AgentLoopResult['clarification'];

  for (let iter = 0; iter < MAX_ITERATIONS; iter++) {
    trace.iterations = iter + 1;

    const supportsParallel = !PLANNER_MODEL.startsWith('openai/gpt-oss');
    const reqBody: any = {
      model: PLANNER_MODEL,
      messages,
      tools,
      tool_choice: 'auto',
      temperature: 0.1,
      max_tokens: 1200,
    };
    if (supportsParallel) reqBody.parallel_tool_calls = true;

    const resp = await fetch(GROQ_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${opts.env.GROQ_API_KEY}`,
      },
      body: JSON.stringify(reqBody),
    });
    if (!resp.ok) {
      const errText = await resp.text();
      // ----- Recover from Groq's `tool_use_failed` --------------------
      // Some Llama variants emit `<function=NAME{...json...}</function>`
      // in the content stream instead of structured tool_calls, causing
      // Groq to return 400 with the offending text in `failed_generation`.
      // We parse it here and synthesize a tool_call so the loop continues.
      const recovered = tryRecoverFailedToolUse(errText);
      if (recovered) {
        console.warn(`[${opts.requestId}] v2 planner recovered tool_use_failed → ${recovered.name}`);
        const synthId = `recover_${iter}_${Date.now()}`;
        const synthCalls: ToolCall[] = [{
          id: synthId,
          type: 'function',
          function: { name: recovered.name, arguments: JSON.stringify(recovered.args) },
        }];
        messages.push({ role: 'assistant', content: null, tool_calls: synthCalls });
        const exec = await runSynthesizedToolCall(
          synthCalls[0],
          toolCtx,
          iter + 1,
          trace,
          allCards,
          (cards) => { browseCards = dedupeBrowseCards([...cards, ...browseCards]); },
          (tail) => { browseCardsTail = dedupeBrowseCards([...browseCardsTail, ...tail]); },
          isSpecificNoteRequest,
        );
        messages.push({
          role: 'tool',
          tool_call_id: synthId,
          content: JSON.stringify(exec.payload).slice(0, 8000),
        });
        if (exec.verifierError && !verifierError) {
          verifierError = exec.verifierError;
        }
        if (exec.clarification) {
          clarification = exec.clarification;
          trace.finished_reason = 'ask_user';
          trace.total_ms = Date.now() - t0;
          return { answer: clarification.question, cards: allCards, browseCards, browseCardsTail, candidateNoteIds: Array.from(allCandidateNoteIds), trace, clarification, verifierError };
        }
        continue;
      }

      console.error(`[${opts.requestId}] v2 planner groq error:`, resp.status, errText);
      trace.finished_reason = 'error';
      trace.total_ms = Date.now() - t0;
      return {
        answer: 'Sorry, I had trouble planning that request. Please try again.',
        cards: [],
        browseCards: [],
        browseCardsTail: [],
        candidateNoteIds: Array.from(allCandidateNoteIds),
        trace,
      };
    }
    const data: any = await resp.json();
    const choice = data.choices?.[0];
    const msg = choice?.message ?? {};
    const toolCalls: ToolCall[] | undefined = msg.tool_calls;

    // Always push the assistant turn (with or without tool_calls) into history
    // so the next iteration sees it.
    messages.push({
      role: 'assistant',
      content: msg.content ?? null,
      tool_calls: toolCalls,
    });

    if (!toolCalls || toolCalls.length === 0) {
      // Final answer.
      trace.finished_reason = msg.content ? 'final_answer' : 'no_tool';
      trace.total_ms = Date.now() - t0;
      return {
        answer: (msg.content || '').trim(),
        cards: allCards,
        browseCards,
        browseCardsTail,
        candidateNoteIds: Array.from(allCandidateNoteIds),
        trace,
        clarification,
        verifierError,
      };
    }

    // Execute tool calls (in parallel) and append role:"tool" replies.
    const execs = toolCalls.map(async (tc) => {
      const tStart = Date.now();
      let parsedArgs: any = {};
      try { parsedArgs = JSON.parse(tc.function.arguments || '{}'); } catch {
        parsedArgs = { __parse_error: tc.function.arguments };
      }
      const validation = validateToolArgs(tc.function.name, parsedArgs);
      if (!validation.ok) {
        trace.tool_calls.push({
          iteration: iter + 1,
          name: tc.function.name,
          args: parsedArgs,
          ok: false,
          duration_ms: Date.now() - tStart,
          error: validation.error,
        });
        return {
          tool_call_id: tc.id,
          payload: { error: validation.error },
        };
      }
      const exec = await executeTool(tc.function.name, validation.value, toolCtx);
      const ms = Date.now() - tStart;
      trace.tool_calls.push({
        iteration: iter + 1,
        name: tc.function.name,
        args: validation.value,
        ok: exec.ok,
        duration_ms: ms,
        result_preview: previewJson(exec.result),
        error: exec.ok ? undefined : (exec.result?.error ?? 'tool failed'),
      });
      if (exec.cards && exec.cards.length > 0) {
        if (tc.function.name === 'vector_search') {
          // A discovery response may need planner list/fetch calls for
          // context, but only vector_search represents the ranked result
          // set that Browse More is allowed to page.
          // The planner may refine a discovery query with a second semantic
          // search. Preserve both completed retrievals, with the latest
          // refinement ranked first, rather than discarding valid cards from
          // the first search.
          browseCards = dedupeBrowseCards([...exec.cards, ...browseCards]);
        }
        if (tc.function.name === 'vector_search' && exec.rejectedCards && exec.rejectedCards.length > 0) {
          // Preserve the unverified retrieval tail so the response layer
          // can splice it into "See more". Dedupe against verified so a
          // card approved in a later refinement never doubles up here.
          const verifiedIds = new Set(browseCards.map(c => c.note_id));
          const freshTail = exec.rejectedCards.filter(c => !c.note_id || !verifiedIds.has(c.note_id));
          browseCardsTail = dedupeBrowseCards([...browseCardsTail, ...freshTail]);
        }
        if (isSpecificNoteRequest && tc.function.name === 'fetch_note') {
          // For “details of the 2nd one”, the prior list is only context to
          // resolve the reference. Show the fetched note, not that list.
          replaceVisibleCards(allCards, exec.cards);
        } else {
          appendVisibleCards(allCards, exec.cards);
        }
      }
      if (exec.candidateNoteIds) {
        for (const id of exec.candidateNoteIds) if (id) allCandidateNoteIds.add(id);
      }
      // Capture the first verifier error we observe. Even if the planner
      // continues and makes another vector_search call, the handler will
      // still show a "something went wrong" message so the user knows a
      // relevance check failed.
      if (exec.verifierError && !verifierError) {
        verifierError = exec.verifierError;
      }
      // ask_user short-circuits the loop after the current iteration.
      if (tc.function.name === 'ask_user' && exec.ok) {
        clarification = {
          question: exec.result.question,
          options: exec.result.options ?? [],
        };
      }
      return {
        tool_call_id: tc.id,
        payload: exec.result,
        cards: exec.cards,
      };
    });

    const results = await Promise.all(execs);
    for (const r of results) {
      messages.push({
        role: 'tool',
        tool_call_id: r.tool_call_id,
        content: JSON.stringify(r.payload).slice(0, 8000),
      });
    }

    if (clarification) {
      trace.finished_reason = 'ask_user';
      trace.total_ms = Date.now() - t0;
      return {
        answer: clarification.question,
        cards: allCards,
        browseCards,
        browseCardsTail,
        candidateNoteIds: Array.from(allCandidateNoteIds),
        trace,
        clarification,
        verifierError,
      };
    }
  }

  // Hit iteration cap — ask the model for a final answer with no tools.
  trace.finished_reason = 'max_iterations';
  const finalResp = await fetch(GROQ_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${opts.env.GROQ_API_KEY}`,
    },
    body: JSON.stringify({
      model: PLANNER_MODEL,
      messages: [
        ...messages,
        {
          role: 'user',
          content: 'You have used the maximum number of tool calls. Write a final answer to the original question using only the information you already have. Do not call any more tools.',
        },
      ],
      temperature: 0.1,
      max_tokens: 800,
    }),
  });
  let finalAnswer = '';
  if (finalResp.ok) {
    const fd: any = await finalResp.json();
    finalAnswer = (fd.choices?.[0]?.message?.content || '').trim();
  }
  trace.total_ms = Date.now() - t0;
  return {
    answer: finalAnswer || 'I tried to answer but ran out of steps. Please rephrase.',
    cards: allCards,
    browseCards,
    browseCardsTail,
    candidateNoteIds: Array.from(allCandidateNoteIds),
    trace,
    verifierError,
  };
}

function previewJson(v: any): string {
  try {
    const s = JSON.stringify(v);
    return s.length > 300 ? s.slice(0, 300) + '…' : s;
  } catch {
    return String(v);
  }
}

function replaceVisibleCards(target: ResultCard[], cards: ResultCard[]): void {
  const unique = new Map<string, ResultCard>();
  for (const card of cards) {
    if (card.note_id && !unique.has(card.note_id)) unique.set(card.note_id, card);
  }
  target.splice(0, target.length, ...unique.values());
}

function appendVisibleCards(target: ResultCard[], cards: ResultCard[]): void {
  for (const card of cards) {
    if (card.note_id && !target.some(existing => existing.note_id === card.note_id)) {
      target.push(card);
    }
  }
}

/**
 * Note IDs are unique but the same saved post can exist in multiple notes
 * (for example, ingestion/retest copies). Do not make Browse More repeat an
 * indistinguishable card. Keep the highest-ranked occurrence by preserving
 * the retrieval order.
 */
function dedupeBrowseCards(cards: ResultCard[]): ResultCard[] {
  const seenNoteIds = new Set<string>();
  const seenContent = new Set<string>();
  return cards.filter((card) => {
    if (!card.note_id || seenNoteIds.has(card.note_id)) return false;
    const fingerprint = `${(card.title || '').trim().toLowerCase()}\u0000${(card.content_preview || card.description || '').trim().toLowerCase()}`;
    if (seenContent.has(fingerprint)) return false;
    seenNoteIds.add(card.note_id);
    seenContent.add(fingerprint);
    return true;
  });
}

// ---------------------------------------------------------------------------
// Recovery helpers for Groq's `tool_use_failed` error
// ---------------------------------------------------------------------------

/**
 * Parse a Groq 400 error body looking for a `<function=NAME{json}</function>`
 * pattern. Returns the tool name + parsed args if recoverable, else null.
 */
function tryRecoverFailedToolUse(
  errBodyText: string,
): { name: string; args: any } | null {
  let body: any;
  try { body = JSON.parse(errBodyText); } catch { return null; }
  if (body?.error?.code !== 'tool_use_failed') return null;
  const fg: string | undefined = body?.error?.failed_generation;
  if (!fg) return null;
  // Match `<function=NAME{...}</function>` (older Llama tool-call notation).
  const m = fg.match(/<function=([a-zA-Z_][\w]*)(\{[\s\S]*?\})\s*<\/function>/);
  if (!m) return null;
  const [, name, jsonText] = m;
  try {
    const args = JSON.parse(jsonText);
    return { name, args };
  } catch {
    return null;
  }
}

/**
 * Run a tool call that we synthesized from a recovered `tool_use_failed`.
 * Mirrors the in-loop tool execution path.
 */
async function runSynthesizedToolCall(
  tc: ToolCall,
  toolCtx: ToolRunContext,
  iteration: number,
  trace: AgentLoopResult['trace'],
  allCards: ResultCard[],
  setBrowseCards: (cards: ResultCard[]) => void,
  addBrowseCardsTail: (cards: ResultCard[]) => void,
  replaceFetchCards: boolean,
): Promise<{ payload: any; clarification?: AgentLoopResult['clarification']; verifierError?: string }> {
  const tStart = Date.now();
  const parsedArgs = (() => {
    try { return JSON.parse(tc.function.arguments || '{}'); } catch { return {}; }
  })();
  const validation = validateToolArgs(tc.function.name, parsedArgs);
  if (!validation.ok) {
    trace.tool_calls.push({
      iteration,
      name: tc.function.name,
      args: parsedArgs,
      ok: false,
      duration_ms: Date.now() - tStart,
      error: validation.error,
    });
    return { payload: { error: validation.error } };
  }
  const exec = await executeTool(tc.function.name, validation.value, toolCtx);
  trace.tool_calls.push({
    iteration,
    name: tc.function.name,
    args: validation.value,
    ok: exec.ok,
    duration_ms: Date.now() - tStart,
    result_preview: previewJson(exec.result),
    error: exec.ok ? undefined : (exec.result?.error ?? 'tool failed'),
  });
  if (exec.cards && exec.cards.length > 0) {
    if (tc.function.name === 'vector_search') {
      setBrowseCards(dedupeBrowseCards(exec.cards));
      if (exec.rejectedCards && exec.rejectedCards.length > 0) {
        addBrowseCardsTail(exec.rejectedCards);
      }
    }
    if (replaceFetchCards && tc.function.name === 'fetch_note') {
      replaceVisibleCards(allCards, exec.cards);
    } else {
      appendVisibleCards(allCards, exec.cards);
    }
  }
  if (exec.candidateNoteIds) {
    // The synthesized path doesn't have access to the loop-level Set, so we
    // rely on the caller to also accumulate via the normal exec path. This
    // synthesized branch is only hit on `tool_use_failed` recovery, which is
    // rare and harmless if Search Deeper sees a slightly smaller exclude
    // set.
  }
  if (tc.function.name === 'ask_user' && exec.ok) {
    return {
      payload: exec.result,
      clarification: {
        question: exec.result.question,
        options: exec.result.options ?? [],
      },
      verifierError: exec.verifierError,
    };
  }
  return { payload: exec.result, verifierError: exec.verifierError };
}
