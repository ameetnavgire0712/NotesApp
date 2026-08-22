-- 051_agent_traces.sql
-- ============================================================================
-- Agent search traces (Phase 0 of agent search architecture).
--
-- Logs every request that hits POST /agent-search-auth. Separate from
-- search_traces so existing analytics and the eval harness are untouched.
--
-- Apply via the Supabase SQL Editor.
-- ============================================================================

create table if not exists public.agent_traces (
  trace_id          text primary key,
  user_id           uuid not null,
  created_at        timestamptz not null default now(),
  query             text not null,
  client_source     text,
  route             text not null,            -- 'forward_classic' | 'count_and_group' | ...
  structured_query  jsonb,
  recipe            text[],
  scratchpad        jsonb,
  llm_calls         jsonb,
  duration_ms       integer,
  status            text not null default 'completed',  -- 'completed' | 'error'
  error             text
);

create index if not exists idx_agent_traces_user_created
  on public.agent_traces (user_id, created_at desc);

create index if not exists idx_agent_traces_route
  on public.agent_traces (route, created_at desc);

grant select, insert, update on public.agent_traces to service_role;
