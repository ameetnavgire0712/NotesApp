"""
100 Query Test Results Analysis
================================

Test Run: 17:52:57 - 17:55:37 IST (2 minutes)

=== TEST RESULTS ===
Total queries: 100
Successful:    7 (7%)
Failed:        93 (93%)
Total time:    120.26s

=== SUCCESS TIMING ===
Min:    61.73s
Max:    101.24s
Avg:    79.63s
P50:    78.34s
P90:    101.24s

=== FAILURE ANALYSIS ===
- 3 requests: 500 error - "Search failed: '<' not supported between instances of 'str' and 'float'"
- 90 requests: Timeout after 120s (connection closed without response)

=== FLY.IO LOG ANALYSIS (from fly logs) ===

1. RERANK TIMES (Voyage AI via Cloudflare Worker):
   - Observed range: 14.9s - 36.4s per rerank call
   - Examples from logs:
     * "Reranked 15 candidates via Voyage AI in 33.727s"
     * "Reranked 15 candidates via Voyage AI in 36.426s"
     * "Reranked 1 candidates via Voyage AI in 14.921s"
     * "Reranked 12 candidates via Voyage AI in 18.213s"
     * "Reranked 2 candidates via Voyage AI in 26.551s"
     * "Reranked 10 candidates via Voyage AI in 27.006s"

2. WORKER SEARCH TIMES (Cloudflare Vectorize):
   - Observed range: 13-19 seconds total worker time
   - Vectorize-only: ~320ms
   - Examples from logs:
     * "Worker search: 50 results in 13043.8ms (vectorize=316ms)"
     * "Worker search: 50 results in 19402.6ms (vectorize=320ms)"
     * "Worker search: 50 results in 14895.1ms (vectorize=329ms)"
     * "Worker search: 50 results in 14970.7ms (vectorize=321ms)"

3. BREAKDOWN OF WORKER TIME:
   - Vectorize query: ~320ms (fast!)
   - Workers AI embedding: 13-19 SECONDS (VERY SLOW!)
   
   The Worker is taking 13-19 seconds to generate embeddings via Workers AI!
   This is the PRIMARY bottleneck, not Vectorize.

=== ROOT CAUSE ANALYSIS ===

BOTTLENECK #1: Workers AI Embedding Generation (13-19 seconds)
- The Cloudflare Worker uses Workers AI (@cf/baai/bge-base-en-v1.5) to generate embeddings
- Under concurrent load, this is extremely slow (13-19s per request)
- This is causing most of the latency

BOTTLENECK #2: Voyage AI Reranking (15-36 seconds)
- Reranking via Voyage AI is also slow
- Even small candidate sets (1-2 docs) take 15-26 seconds
- This suggests API latency issues or rate limiting

COMBINED EFFECT:
- Each search requires: embedding (13-19s) + vectorize (0.3s) + rerank (15-36s)
- Total per-request: 28-55 seconds minimum
- Under 100 concurrent requests, queuing makes this much worse
- Most requests timeout at 120s

=== ERRORS IDENTIFIED ===

1. Type comparison error: "'<' not supported between instances of 'str' and 'float'"
   - This is a bug in the code comparing scores
   - Likely in the ranking/sorting logic when scores are missing

=== RECOMMENDATIONS ===

1. **Workers AI is the main bottleneck**
   - Consider using a different embedding provider
   - Or batch embedding requests
   - Or cache embeddings locally

2. **Voyage AI Reranking is slow**
   - Consider Cohere (faster, same pricing)
   - Or implement local reranking
   - Or skip reranking for high-concurrency scenarios

3. **Add request queuing/rate limiting**
   - Limit concurrent requests to Fly.io
   - Queue excess requests

4. **Fix the type comparison bug**
   - Check where scores are compared
   - Handle None/string values properly
"""

print(__doc__)
