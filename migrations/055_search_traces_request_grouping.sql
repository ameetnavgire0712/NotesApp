-- 055_search_traces_request_grouping.sql
-- ============================================================================
-- Adds fields needed to group multi-round searches into a single "request"
-- and to expose the metrics the app actually renders (verified + browse tail).
--
-- Historical problem: a single user query (e.g. "find horror movies") can
-- generate 3+ search_traces rows — base agent-v2 round, planner sub-rounds,
-- and Search Deeper rounds. Each has its own correlation_id and the admin
-- dashboard shows them as 3 unrelated entries. Users see "same query 3x,
-- one with results, one with 0" and think we're logging garbage.
--
-- Fix: mint one `request_id` at the top-level worker request boundary,
-- write it on every child trace row (including agent_traces), and let the
-- dashboard collapse them into a request tree.
--
-- The `browse_pool_count` / `app_visible_count` columns close the gap
-- between what the admin dashboard reports (`final_count` = LLM-verified
-- only) and what the Flutter/extension UI actually shows to the user
-- (verified + rejected browse tail + hydrated fetch_note results).
-- ============================================================================

-- Column A.1: parent_request_id
--
-- The worker-scoped requestId (e.g. `wr_1786035217559_9i9f22t`) minted at
-- the very top of the fetch handler in cloudflare-worker/src/index.ts. All
-- retrieval rounds triggered by the same user request share this value.
--
-- correlation_id remains per-round unique (needed for the detail-view URL);
-- parent_request_id is nullable so existing rows keep working.
alter table public.search_traces
  add column if not exists parent_request_id text;

comment on column public.search_traces.parent_request_id is
  'Top-level worker request id. Multiple search_traces rows sharing this value belong to the same user request (base + planner rounds + Search Deeper).';

create index if not exists idx_search_traces_parent_request_id
  on public.search_traces (parent_request_id)
  where parent_request_id is not null;

-- Column A.2: mirror onto agent_traces so cross-linking works both ways.
alter table public.agent_traces
  add column if not exists parent_request_id text;

comment on column public.agent_traces.parent_request_id is
  'Top-level worker request id. Same value in search_traces.parent_request_id for the same request.';

create index if not exists idx_agent_traces_parent_request_id
  on public.agent_traces (parent_request_id)
  where parent_request_id is not null;

-- Column B.1: browse_pool_count
--
-- Number of cards the response actually shipped to the client for the
-- browse tail (rejected-by-verifier candidates the client can reveal via
-- "See more"). This is what the app UI already displays alongside the
-- verified cards.
alter table public.search_traces
  add column if not exists browse_pool_count integer;

comment on column public.search_traces.browse_pool_count is
  'Rejected candidates shipped as browse tail (client-side "See more" pool).';

-- Column B.2: app_visible_count
--
-- The single number a UX-oriented metric should show: total cards the
-- Flutter/extension user could see on their screen for this round (verified
-- + browse tail + hydrated notes). Derived at write time so dashboard
-- queries stay cheap.
alter table public.search_traces
  add column if not exists app_visible_count integer;

comment on column public.search_traces.app_visible_count is
  'Total cards visible to the user (verified + browse tail + hydrated).';
