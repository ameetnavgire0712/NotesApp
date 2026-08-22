// agent/trace.ts
// ===========================================================================
// Best-effort logging of agent runs to public.agent_traces.
// Failure to log never breaks the request.
// ===========================================================================

import type { AgentEnv, Scratchpad } from './types';

export async function writeAgentTrace(
  env: AgentEnv,
  payload: {
    trace_id: string;
    user_id: string;
    query: string;
    client_source?: string;
    route: string;
    scratchpad: Scratchpad;
    recipe: string[];
    duration_ms: number;
    status: 'completed' | 'error';
    error?: string;
    /**
     * Top-level worker request id. Same value written to
     * search_traces.parent_request_id for every retrieval round from the
     * same user request, so the dashboard can join agent_traces with the
     * matching search_traces rows and render them as a single tree.
     */
    parent_request_id?: string;
  },
): Promise<void> {
  try {
    const body = {
      trace_id: payload.trace_id,
      parent_request_id: payload.parent_request_id ?? null,
      user_id: payload.user_id,
      query: payload.query.slice(0, 2000),
      client_source: payload.client_source ?? null,
      route: payload.route,
      structured_query: payload.scratchpad.structured,
      recipe: payload.recipe,
      scratchpad: {
        confidence: payload.scratchpad.confidence,
        steps: payload.scratchpad.steps,
        partials: payload.scratchpad.partials.slice(0, 10),
        candidate_count: payload.scratchpad.candidates.length,
        evidence_count: payload.scratchpad.evidence.length,
      },
      duration_ms: payload.duration_ms,
      status: payload.status,
      error: payload.error ?? null,
    };

    await fetch(`${env.SUPABASE_URL}/rest/v1/agent_traces`, {
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
    console.error('[agent/trace] failed to write trace:', err);
  }
}
