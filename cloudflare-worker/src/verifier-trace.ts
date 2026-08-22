// verifier-trace.ts
// ============================================================================
// Task D: writes one row per LLM relevance-verifier call to
// public.verifier_traces (migration 056). Fire-and-forget — failures never
// affect the search response.
//
// The pipeline builds a VerifierTraceInput before or after the LLM call and
// hands it here; this module owns the HTTP write and the prompt-version tag.
// Keeping the payload construction in the caller lets us reuse the same
// helper for the agent v2 lean verifier and the classic rag-search verifier
// without leaking their internal prompt shapes.
// ============================================================================

// Bump whenever the verifier prompt changes so eval runs are pinned to a
// specific version. Match the git tag / PR description if you want traceability
// beyond the string.
//   v2-2025-01-qualifier-strict — added rule 5 (qualifier STRICT). Kept
//     "return numbers" output; llama-3.3-70b still passed heist / drama
//     movies on "horror movies" because bare number output hides reasoning.
//   v3-2026-08-json-evidence — restructured to per-candidate JSON with
//     mandatory qualifier_evidence quote. Rejects any candidate whose
//     evidence is NONE/empty even if the LLM sets relevant:true. FLAW:
//     the prompt banned Content-based evidence, so notes whose primary
//     description lives inline in the content chunk (e.g. an Instagram
//     reel with Description="" and Content containing 'Description: "horror movies"')
//     were rejected. LLM also took the lazy shortcut and wrote "NONE" for
//     every candidate under structured output.
//   v4-2026-08-content-evidence — allow evidence quotes from any of
//     Title/Tag/Description/Content. Adds "must inspect all four fields
//     before writing NONE" instruction. Keeps the primary-subject
//     guardrail so incidental keyword hits still fail.
//   v5-2026-08-per-candidate-reason — switched output shape from bare
//     "relevant" index list to per-candidate {index, relevant, reason}.
//     Forces chain-of-thought reasoning: measurably more accurate
//     verdicts (11 vs 7 relevant on "interior designing home decor" for
//     the same 13 candidates) at ~5x higher verifier latency. Filtering
//     is respected — irrelevant candidates are split into the rejected
//     pool as before, but every verdict now has a stored justification
//     for offline review.
//   v5.1-2026-08-tail-and-trim — two changes on top of v5:
//     (a) prompt reason field trimmed from "one short sentence" to
//     "≤10 words" to cut output tokens ~2-3x for latency;
//     (b) candidates ranked beyond VERIFY_CAP still drop from THIS round,
//     but their note_ids are no longer added to the Search Deeper exclude
//     list — so they can naturally resurface (and get verified) on the
//     next deeper round instead of vanishing permanently.
export const VERIFIER_PROMPT_VERSION = 'v5.1-2026-08-tail-and-trim';

export interface VerifierCandidateInput {
  index: number; // 1-based, matches what the LLM sees
  note_id: string;
  title: string | null;
  tag: string | null;
  description: string | null;
  content_preview: string | null; // truncated
  rerank_score: number | null;
  keyword_score: number | null;
}

export interface VerifierTraceInput {
  correlation_id: string;
  parent_request_id?: string;
  user_id?: string;
  query: string;
  candidates_input: VerifierCandidateInput[];
  prompt_hash?: string;
  llm_response: string | null;
  verified_indices: number[]; // 1-based
  rejected_indices: number[]; // 1-based
  verdict: 'some' | 'none' | 'error';
  model: string;
  latency_ms: number;
  error_message?: string;
  source: 'agent_v2_lean' | 'rag_search_classic';
}

export async function writeVerifierTrace(
  env: any,
  trace: VerifierTraceInput,
): Promise<void> {
  try {
    const body = {
      correlation_id: trace.correlation_id,
      parent_request_id: trace.parent_request_id ?? null,
      user_id: trace.user_id ?? null,
      query: trace.query.slice(0, 2000),
      candidates_input: trace.candidates_input,
      candidate_count: trace.candidates_input.length,
      prompt_version: VERIFIER_PROMPT_VERSION,
      prompt_hash: trace.prompt_hash ?? null,
      llm_response: trace.llm_response,
      verified_indices: trace.verified_indices,
      rejected_indices: trace.rejected_indices,
      verdict: trace.verdict,
      model: trace.model,
      latency_ms: trace.latency_ms,
      error_message: trace.error_message ?? null,
      source: trace.source,
    };

    await fetch(`${env.SUPABASE_URL}/rest/v1/verifier_traces`, {
      method: 'POST',
      headers: {
        apikey: env.SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Content-Type': 'application/json',
        Prefer: 'return=minimal',
      },
      body: JSON.stringify(body),
    });
  } catch (err) {
    console.error('[verifier-trace] write failed:', err);
  }
}
