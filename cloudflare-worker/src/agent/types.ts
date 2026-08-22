// agent/types.ts
// ===========================================================================
// Core types for the SnapBot agent search pipeline.
//
// The agent endpoint is *additive* — it lives at /agent-search-auth alongside
// the existing /rag-search-auth. If a query is not supported by the agent,
// the request is forwarded to the classic pipeline unchanged.
// ===========================================================================

import type { RagSearchEnv } from '../rag-search';

/** Subset of envs the agent layer needs. Extends classic search's env. */
export interface AgentEnv extends RagSearchEnv {}

/**
 * Structured representation of a user query, produced by `understand`.
 * Phase 1 only populates a small subset; later phases fill more fields.
 */
export interface StructuredQuery {
  /** What the user wants to do. */
  operation: 'find' | 'count' | 'group_count' | 'compare' | 'summarize' | 'list' | 'general' | 'unknown';

  /** Topic/entities mentioned, if any. */
  topic: string | null;

  /** Optional filters extracted deterministically from the query. */
  filter: {
    time?: TimeWindow;
    file_types?: string[];
    platforms?: string[];
    tags?: string[];
  };

  /** Field to group by, when operation is 'group_count'. */
  group_by?: 'file_type' | 'tag' | 'platform' | 'date_day';

  /** Two-window comparison spec, when operation is 'compare'. */
  compare?: {
    window_a: TimeWindow;
    window_b: TimeWindow;
    topic: string;
  };

  /** Map-reduce summarize spec, when operation is 'summarize'. */
  summarize?: {
    topic: string;
    window: TimeWindow;
  };

  /** Deterministic list spec, when operation is 'list'. */
  list?: {
    topic: string;
    window?: TimeWindow;
    file_types?: string[];
    tags?: string[];
  };

  /** 0..1 — how unsure the extractor is. */
  ambiguity: number;

  /** Free-form description for trace inspection. */
  notes?: string;
}

export type TimeWindow =
  | 'today'
  | 'yesterday'
  | 'this_week'
  | 'last_week'
  | 'this_month'
  | 'last_month'
  | 'last_7d'
  | 'last_30d'
  | 'last_90d'
  | 'last_180d'
  | 'all_time';

/** Working memory passed through tools. */
export interface Scratchpad {
  trace_id: string;
  user_id: string;
  query: string;
  structured: StructuredQuery;
  candidates: any[];
  evidence: any[];
  partials: string[];
  confidence: number;
  steps: Array<{ tool: string; ms: number; ok: boolean; note?: string }>;
}

/** A tool is a single step in a recipe. */
export interface Tool<TIn = any, TOut = any> {
  name: string;
  run(input: TIn, ctx: ToolContext): Promise<TOut>;
}

export interface ToolContext {
  env: AgentEnv;
  scratchpad: Scratchpad;
  requestId: string;
}

/** Final response shape returned to the client.
 *  Mirrors the classic /rag-search-auth response so the Flutter app code path
 *  is unchanged, plus a small `agent` envelope for inspection.
 */
export interface AgentResponse {
  answer: string;
  results: any[];
  query_type?: string;
  agent: {
    trace_id: string;
    route: string;
    duration_ms: number;
  };
}
