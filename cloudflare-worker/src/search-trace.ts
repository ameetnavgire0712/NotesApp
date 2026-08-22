// search-trace.ts
// =============================================================================
// Shared helper for writing to `public.search_traces`.
//
// Previously this lived inside rag-search.ts and could only be called from the
// classic /rag-search-auth pipeline. The agent v2 pipeline (Flutter chat)
// runs the same performHybridSearch() under the hood but wrote nothing to
// search_traces, so its runs were invisible in the admin activity-logs
// dashboard even though the retrieval work happened.
//
// Both pipelines now share this module. The interface is the union of every
// field the search_traces table stores — callers only populate what applies
// to their path (classic populates everything, agent v2 populates the subset
// it has: query, timing, candidates, verification, tool name).
//
// Failure to persist a trace NEVER breaks the search request — the fetch is
// scheduled via ctx.waitUntil() and errors are logged only.
// =============================================================================

import type { ExecutionContext } from '@cloudflare/workers-types';

export interface SearchTraceEnv {
  SUPABASE_URL?: string;
  SUPABASE_SERVICE_KEY?: string;
  LOG_ENABLED?: string;
}

export interface SearchTraceEntry {
  correlation_id: string;
  user_id: string;
  query: string;
  query_corrected?: string;
  query_rewritten?: string;
  /**
   * Top-level worker request id. Every retrieval round belonging to the
   * same user request (base + planner sub-rounds + Search Deeper) shares
   * this value so the admin dashboard can collapse them into one tile.
   * Nullable so older rows keep working.
   */
  parent_request_id?: string;

  // Timestamps for each phase (ISO strings)
  request_received_at?: string;
  auth_started_at?: string;
  auth_completed_at?: string;
  spell_check_started_at?: string;
  tags_fetch_started_at?: string;
  embedding_started_at?: string;
  search_started_at?: string;
  rerank_started_at?: string;
  relevance_check_started_at?: string;
  synthesis_started_at?: string;
  response_sent_at?: string;

  // Complete timing breakdown
  timing_total_ms?: number;
  timing_auth_ms?: number;
  timing_spell_check_ms?: number;
  timing_tags_fetch_ms?: number;
  timing_embedding_ms?: number;
  timing_vector_search_ms?: number;
  timing_keyword_search_ms?: number;
  timing_rerank_ms?: number;
  timing_relevance_check_ms?: number;
  timing_synthesis_ms?: number;
  timing_worker_ms?: number;

  // Auth details
  auth_method?: string;
  auth_user_email?: string;

  // Cache status
  embedding_cached: boolean;
  search_cached: boolean;
  tags_cached?: boolean;
  synthesis_cached?: boolean;

  // Chunk grouping info (top-N per doc)
  chunks_before_grouping?: number;
  chunks_after_grouping?: number;
  unique_documents?: number;
  chunks_per_doc_limit?: number;
  // Dedup after LLM verification
  dedup_before_count?: number;
  dedup_after_count?: number;
  dedup_removed?: number;

  // Candidate arrays at each stage
  vector_candidates?: Array<Record<string, any>>;
  keyword_candidates?: Array<Record<string, any>>;
  combined_candidates?: Array<Record<string, any>>;
  reranked_candidates?: Array<Record<string, any>>;
  reranker_input_preview?: Array<Record<string, any>>;
  relevance_verified_candidates?: Array<Record<string, any>>;
  final_results?: Array<Record<string, any>>;

  // Counts
  vector_count?: number;
  excluded_note_ids_count?: number;
  keyword_count?: number;
  keyword_query?: string;
  keyword_query_normalized?: string;
  keyword_only_injected?: number;
  title_match_count?: number;
  description_match_count?: number;
  title_only_injected?: number;
  desc_only_injected?: number;
  title_with_content_injected?: number;
  desc_with_content_injected?: number;
  combined_count?: number;
  reranked_count?: number;
  relevance_verified_count?: number;
  final_count?: number;
  /**
   * Rejected candidates the client ships as a "See more" browse tail. The
   * app UI shows verified cards + this pool, so tracking it here lets the
   * dashboard report a count that matches what the user actually sees.
   */
  browse_pool_count?: number;
  /**
   * Total cards visible to the user for this retrieval round (verified +
   * browse tail + hydrated fetch_note results). Derived at write time so
   * dashboard queries stay cheap.
   */
  app_visible_count?: number;

  // Thresholds
  min_vector_threshold?: number;
  min_rerank_threshold?: number;

  // Source info
  source_worker?: string;
  request_path?: string;
  client_source?: string;

  // Agentic RAG fields
  intent_classification?: string;
  intent_confidence?: string;
  intent_reasoning?: string;
  timing_intent_router_ms?: number;
  tool_invoked?: string;
  timing_collection_fetch_ms?: number;
  collection_doc_count?: number;
  path_taken?: string;

  // Errors
  error_occurred?: boolean;
  error_message?: string;
  error_type?: string;

  // LLM call log
  llm_calls?: Array<{ model: string; purpose: string; duration_ms: number }>;
  backend_metadata?: Record<string, any>;

  // Answer info
  answer_generated?: boolean;
  answer_preview?: string;

  // Transform gate / conversation planner
  planner_action?: string;
  planner_operation?: string;
  planner_needs_retrieval?: boolean;
  planner_reason?: string;
  timing_planner_ms?: number;
}

export function sendSearchTrace(
  trace: SearchTraceEntry,
  env: SearchTraceEnv,
  ctx: ExecutionContext,
): void {
  // Skip if logging disabled or Supabase not configured.
  if (env.LOG_ENABLED !== 'true' || !env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    return;
  }

  ctx.waitUntil(
    (async () => {
      try {
        const resp = await fetch(`${env.SUPABASE_URL}/rest/v1/search_traces`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            apikey: env.SUPABASE_SERVICE_KEY!,
            Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            Prefer: 'return=minimal',
          },
          body: JSON.stringify({
            correlation_id: trace.correlation_id,
            parent_request_id: trace.parent_request_id,
            user_id: trace.user_id,
            query: trace.query,
            query_corrected: trace.query_corrected,
            query_rewritten: trace.query_rewritten,
            // Timestamps
            request_received_at: trace.request_received_at,
            auth_started_at: trace.auth_started_at,
            auth_completed_at: trace.auth_completed_at,
            spell_check_started_at: trace.spell_check_started_at,
            tags_fetch_started_at: trace.tags_fetch_started_at,
            embedding_started_at: trace.embedding_started_at,
            search_started_at: trace.search_started_at,
            rerank_started_at: trace.rerank_started_at,
            relevance_check_started_at: trace.relevance_check_started_at,
            synthesis_started_at: trace.synthesis_started_at,
            response_sent_at: trace.response_sent_at,
            // Timings
            timing_total_ms: trace.timing_total_ms,
            timing_auth_ms: trace.timing_auth_ms,
            timing_spell_check_ms: trace.timing_spell_check_ms,
            timing_tags_fetch_ms: trace.timing_tags_fetch_ms,
            timing_embedding_ms: trace.timing_embedding_ms,
            timing_vector_search_ms: trace.timing_vector_search_ms,
            timing_keyword_search_ms: trace.timing_keyword_search_ms,
            timing_rerank_ms: trace.timing_rerank_ms,
            timing_relevance_check_ms: trace.timing_relevance_check_ms,
            timing_synthesis_ms: trace.timing_synthesis_ms,
            timing_worker_ms: trace.timing_worker_ms,
            // Auth
            auth_method: trace.auth_method,
            auth_user_email: trace.auth_user_email,
            // Cache
            embedding_cached: trace.embedding_cached,
            tags_cached: trace.tags_cached,
            synthesis_cached: trace.synthesis_cached,
            // Counts
            vector_count: trace.vector_count,
            excluded_note_ids_count: trace.excluded_note_ids_count,
            keyword_count: trace.keyword_count,
            keyword_query: trace.keyword_query,
            keyword_query_normalized: trace.keyword_query_normalized,
            keyword_only_injected: trace.keyword_only_injected,
            title_match_count: trace.title_match_count,
            description_match_count: trace.description_match_count,
            title_only_injected: trace.title_only_injected,
            desc_only_injected: trace.desc_only_injected,
            title_with_content_injected: trace.title_with_content_injected,
            desc_with_content_injected: trace.desc_with_content_injected,
            combined_count: trace.combined_count,
            reranked_count: trace.reranked_count,
            relevance_verified_count: trace.relevance_verified_count,
            final_count: trace.final_count,
            browse_pool_count: trace.browse_pool_count,
            app_visible_count: trace.app_visible_count,
            // Grouping / dedup
            chunks_before_grouping: trace.chunks_before_grouping,
            chunks_after_grouping: trace.chunks_after_grouping,
            unique_documents: trace.unique_documents,
            chunks_per_doc_limit: trace.chunks_per_doc_limit,
            dedup_before_count: trace.dedup_before_count,
            dedup_after_count: trace.dedup_after_count,
            dedup_removed: trace.dedup_removed,
            // Candidate arrays
            vector_candidates: trace.vector_candidates || [],
            keyword_candidates: trace.keyword_candidates || [],
            combined_candidates: trace.combined_candidates || [],
            reranked_candidates: trace.reranked_candidates || [],
            reranker_input_preview: trace.reranker_input_preview || [],
            relevance_verified_candidates: trace.relevance_verified_candidates || [],
            final_results: trace.final_results || [],
            // Thresholds
            min_vector_threshold: trace.min_vector_threshold,
            min_rerank_threshold: trace.min_rerank_threshold,
            // Routing
            source_worker: trace.source_worker || 'cloudflare-worker',
            request_path: trace.request_path,
            client_source: trace.client_source || 'unknown',
            // Agentic
            intent_classification: trace.intent_classification,
            intent_confidence: trace.intent_confidence,
            intent_reasoning: trace.intent_reasoning,
            timing_intent_router_ms: trace.timing_intent_router_ms,
            tool_invoked: trace.tool_invoked,
            timing_collection_fetch_ms: trace.timing_collection_fetch_ms,
            collection_doc_count: trace.collection_doc_count,
            path_taken: trace.path_taken,
            // Errors
            error_occurred: trace.error_occurred || false,
            error_message: trace.error_message,
            error_type: trace.error_type,
            // LLM
            llm_calls: trace.llm_calls || [],
            backend_metadata: trace.backend_metadata,
            answer_generated: trace.answer_generated || false,
            answer_preview: trace.answer_preview,
            // Planner
            planner_action: trace.planner_action,
            planner_reason: trace.planner_reason,
            timing_planner_ms: trace.timing_planner_ms,
          }),
        });
        if (!resp.ok) {
          console.error(
            '[search-trace] failed to POST search_traces:',
            resp.status,
            (await resp.text()).slice(0, 300),
          );
        }

        // Also insert into user_activities so the Python-backed analytics /
        // metrics endpoints (app/api/v1/logs.py, metrics_service.py) can see
        // the search. Dashboard doesn't read this table but downstream
        // reporting does. user_activities.correlation_id is a UUID so we
        // mint a fresh one and stash the worker correlation_id in metadata
        // for cross-referencing back to search_traces.
        const activityResp = await fetch(`${env.SUPABASE_URL}/rest/v1/user_activities`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            apikey: env.SUPABASE_SERVICE_KEY!,
            Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            Prefer: 'return=minimal',
          },
          body: JSON.stringify({
            correlation_id: crypto.randomUUID(),
            user_id: trace.user_id,
            action: 'chat_search',
            resource_type: 'search',
            status: trace.error_occurred ? 'error' : 'success',
            duration_ms: trace.timing_total_ms || 0,
            metadata: {
              query: trace.query,
              query_corrected: trace.query_corrected,
              keyword_query: trace.keyword_query,
              keyword_query_normalized: trace.keyword_query_normalized,
              results_count: trace.final_count || 0,
              vector_count: trace.vector_count,
              keyword_count: trace.keyword_count,
              embedding_cached: trace.embedding_cached,
              synthesis_cached: trace.synthesis_cached,
              client_source: trace.client_source || 'unknown',
              worker_request_id: trace.correlation_id,
              intent: trace.intent_classification,
              intent_confidence: trace.intent_confidence,
              tool_invoked: trace.tool_invoked,
              path_taken: trace.path_taken,
              answer_generated: trace.answer_generated,
              error_occurred: trace.error_occurred,
              error_message: trace.error_message,
              error_type: trace.error_type,
              llm_calls_count: trace.llm_calls?.length || 0,
              planner_action: trace.planner_action,
              planner_reason: trace.planner_reason,
            },
          }),
        });
        if (!activityResp.ok) {
          console.error(
            '[search-trace] failed to POST user_activities:',
            activityResp.status,
            (await activityResp.text()).slice(0, 300),
          );
        }
      } catch (err) {
        console.error('[search-trace] unexpected error posting search_traces:', err);
      }
    })(),
  );
}
