-- Migration 056: verifier_traces
-- ============================================================================
-- Task D: capture the exact prompt/inputs/output of the LLM relevance verifier
-- (verifyLeanRelevance in agent_v2/lean_search.ts, and the classic verifier in
-- rag-search.ts) so we can:
--   1. Ground verifier-prompt tweaks in real data instead of anecdote — every
--      change to the verifier prompt gets re-run against a fixed eval set.
--   2. Debug false negatives ("horror movies search returned nothing") and
--      false positives ("furniture ad slipped through") without having to
--      re-run the pipeline in prod.
--   3. Build a labelled dataset by joining verifier_traces with user
--      thumbs-up/down feedback (future work).
--
-- Design notes:
--   - One row per verifier LLM call, keyed by (correlation_id, model). The
--     agent v2 planner may issue MULTIPLE vector_search + verify pairs per
--     user request, so we lean on correlation_id (per-round) rather than
--     parent_request_id (per-request). parent_request_id is also stored so
--     the dashboard can join across rounds.
--   - candidates_input is a JSONB blob (not a normalised table) because it's
--     read whole for eval replay and never queried piecewise.
--   - We intentionally do NOT store the full verifier prompt string — the
--     prompt is versioned in git, and re-hashing it here would balloon the
--     row size. prompt_version + prompt_hash let the eval harness assert
--     "these traces were generated with the prompt we're evaluating".
-- ============================================================================

create table if not exists public.verifier_traces (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),

    -- Grouping keys (see migration 055 for parent_request_id rationale).
    correlation_id text not null,
    parent_request_id text,
    user_id uuid,

    -- Inputs.
    query text not null,
    -- Array of { index, note_id, title, tag, description, content_preview,
    -- rerank_score, keyword_score }. index is 1-based, matches the number the
    -- LLM sees in the prompt and returns.
    candidates_input jsonb not null,
    candidate_count integer not null,

    -- Prompt versioning (see rationale above).
    prompt_version text,
    prompt_hash text,

    -- Outputs.
    -- Raw LLM response after <think> stripping — same string the pipeline
    -- parsed to decide which cards passed.
    llm_response text,
    -- 1-based indices the LLM approved.
    verified_indices integer[] not null default '{}',
    -- 1-based indices retrieved but not approved (the "See more" browse tail).
    rejected_indices integer[] not null default '{}',
    verdict text not null check (verdict in ('some', 'none', 'error')),

    -- Meta.
    model text not null,
    latency_ms integer,
    error_message text,

    -- Where this row came from — 'agent_v2_lean' | 'rag_search_classic'.
    source text not null
);

comment on table public.verifier_traces is
  'One row per LLM relevance-verifier call. Enables prompt-eval replay and pass/fail rate analysis.';

create index if not exists idx_verifier_traces_correlation on public.verifier_traces (correlation_id);
create index if not exists idx_verifier_traces_parent on public.verifier_traces (parent_request_id) where parent_request_id is not null;
create index if not exists idx_verifier_traces_created on public.verifier_traces (created_at desc);
create index if not exists idx_verifier_traces_prompt_version on public.verifier_traces (prompt_version) where prompt_version is not null;
