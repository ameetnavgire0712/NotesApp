// agent/controller.ts
// ===========================================================================
// Phase 3: post-retrieval controller. Reads the classic /rag-search-auth
// response and decides whether to:
//   - continue          → return the response as-is
//   - refuse_grounded   → replace the answer with an honest "no evidence" note
//                         (Phase 2's general-knowledge escalation is not yet
//                          wired, so we don't offer it here)
//   - ask_user          → replace the answer with a clarifying question
//                         offering the top candidates
//
// Thresholds are intentionally conservative. They can be tuned from the
// agent_traces table once we have data.
// ===========================================================================

import type { StructuredQuery } from './types';

export interface ControllerDecision {
  action: 'continue' | 'refuse_grounded' | 'ask_user';
  reason: string;
  /** Replacement answer text, if action is not 'continue'. */
  answer?: string;
  /** Candidate titles considered, for trace logging. */
  candidates?: string[];
  /** Confidence summary recorded in the scratchpad. */
  confidence: {
    top_rerank: number | null;
    result_count: number;
    ambiguity: number;
  };
}

interface RagResultLite {
  note_id?: string;
  title?: string;
  rerank_score?: number;
  similarity_score?: number;
  [key: string]: any;
}

interface RagResponseLite {
  success?: boolean;
  results?: RagResultLite[];
  answer?: string;
  query_type?: string;
  path_taken?: string;
  [key: string]: any;
}

// ---- Tunable thresholds ---------------------------------------------------
const MIN_TOP_RERANK = 0.3; // below this → no real grounding in notes
const AMBIGUITY_THRESHOLD = 0.7; // above this → ask user

/**
 * Score-based controller. Pure function — no I/O.
 */
export function decideController(
  structured: StructuredQuery,
  rag: RagResponseLite,
): ControllerDecision {
  const results = Array.isArray(rag.results) ? rag.results : [];
  const topRerank = pickTopRerank(results);
  const ambiguity = structured.ambiguity ?? 0;

  const confidence = {
    top_rerank: topRerank,
    result_count: results.length,
    ambiguity,
  };

  // 1) Genuine ambiguity → ask back. Only fires if `understand` has set a
  //    non-trivial ambiguity score; today's regex extractor sets ~0.1, so
  //    this is essentially dormant until a future LLM-based extractor lifts it.
  if (ambiguity >= AMBIGUITY_THRESHOLD && results.length > 0) {
    const candidates = results
      .slice(0, 3)
      .map(r => (r.title || '').trim())
      .filter(Boolean);
    if (candidates.length > 0) {
      return {
        action: 'ask_user',
        reason: `ambiguity_${ambiguity.toFixed(2)}`,
        answer: buildAskUserAnswer(candidates),
        candidates,
        confidence,
      };
    }
  }

  // 2) Empty result set → no grounding at all.
  if (results.length === 0) {
    // If classic produced an answer anyway (e.g. action=chat, tags suggestion,
    // empty-collection greeting), don't override it. Empty results + no answer
    // is the genuine "we have nothing" case.
    if (rag.answer && rag.answer.trim().length > 20) {
      return { action: 'continue', reason: 'empty_results_with_chat_answer', confidence };
    }
    return {
      action: 'refuse_grounded',
      reason: 'no_results',
      answer: buildRefuseAnswer(/*hasResults=*/ false),
      confidence,
    };
  }

  // 3) Weak grounding → refuse.
  if (topRerank !== null && topRerank < MIN_TOP_RERANK) {
    // Some paths (e.g. tag browse, anchored note, conversational) don't run
    // the reranker, so all rerank_scores will be undefined → topRerank=null.
    // We only refuse when we *did* see scores and they were too low.
    return {
      action: 'refuse_grounded',
      reason: `low_rerank_${topRerank.toFixed(3)}`,
      answer: buildRefuseAnswer(/*hasResults=*/ true),
      confidence,
    };
  }

  return { action: 'continue', reason: 'ok', confidence };
}

/**
 * Apply the controller decision to the rag response and return a new
 * response object. Does not mutate the input.
 */
export function applyControllerDecision(
  rag: RagResponseLite,
  decision: ControllerDecision,
): RagResponseLite {
  if (decision.action === 'continue') return rag;

  return {
    ...rag,
    answer: decision.answer ?? rag.answer,
    // Preserve results so the UI can still show note cards; the message
    // text now signals lack of confidence or asks back. UI doesn't need
    // any new fields.
    controller: {
      action: decision.action,
      reason: decision.reason,
    },
  } as RagResponseLite;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function pickTopRerank(results: RagResultLite[]): number | null {
  let top: number | null = null;
  for (const r of results) {
    const s = typeof r.rerank_score === 'number' ? r.rerank_score : null;
    if (s === null) continue;
    if (top === null || s > top) top = s;
  }
  return top;
}

function buildRefuseAnswer(hasResults: boolean): string {
  if (hasResults) {
    return (
      "I couldn't find a strong match for this in your notes. " +
      "The closest items are below — they may not contain the answer, but you can browse them. " +
      "Try rephrasing, or save a note on this topic and ask again."
    );
  }
  return (
    "I don't see anything in your notes about this yet. " +
    "Try rephrasing the question, or save a note on this topic and ask again."
  );
}

function buildAskUserAnswer(candidates: string[]): string {
  const lines = candidates.map(c => `- ${c}`).join('\n');
  return (
    "I want to make sure I get this right. Did you mean any of these?\n\n" +
    lines +
    '\n\nReply with the one you meant, or rephrase your question.'
  );
}
