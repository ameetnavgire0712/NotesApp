# NotesApp Search Flow - Complete Technical Documentation

> Last Updated: January 27, 2026

This document provides a comprehensive breakdown of what happens when a user searches for a query, from the moment the request hits the server until the response is returned.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Server Startup & Warmup](#2-server-startup--warmup)
3. [Authentication & Caching](#3-authentication--caching)
4. [Query Processing Pipeline & Search Scenarios](#4-query-processing-pipeline--search-scenarios)
5. [Retrieval Methods](#5-retrieval-methods)
6. [Reranking](#6-reranking)
7. [Models & Configuration](#7-models--configuration)
8. [Complete Flow Diagrams](#8-complete-flow-diagrams)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT REQUEST                                  │
│                    POST /api/v1/search {"query": "..."}                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FASTAPI SERVER                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  ┌───────────────────┐  │
│  │ Auth Layer  │→│ Query Analyzer│→│ RAG Agent  │→│ Retrieval Tools   │  │
│  │ (Cached)    │  │              │  │ (LLM Loop) │  │ (Vector/Hybrid)   │  │
│  └─────────────┘  └──────────────┘  └────────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        ▼                             ▼                             ▼
┌───────────────┐           ┌─────────────────┐           ┌─────────────────┐
│   SUPABASE    │           │  LOCAL MODELS   │           │    GROQ LLM     │
│  PostgreSQL   │           │                 │           │                 │
│  ┌─────────┐  │           │ ┌─────────────┐ │           │ ┌─────────────┐ │
│  │ notes   │  │           │ │ BGE Embed   │ │           │ │ llama-3.3   │ │
│  │ chunks  │  │           │ │ (768 dim)   │ │           │ │   -70b      │ │
│  │ api_keys│  │           │ └─────────────┘ │           │ └─────────────┘ │
│  └─────────┘  │           │ ┌─────────────┐ │           │ ┌─────────────┐ │
│  ┌─────────┐  │           │ │ Cross-Enc   │ │           │ │ llama-3.1   │ │
│  │ pgvector│  │           │ │ Reranker    │ │           │ │   -8b       │ │
│  └─────────┘  │           │ └─────────────┘ │           │ └─────────────┘ │
└───────────────┘           └─────────────────┘           └─────────────────┘
```

---

## 2. Server Startup & Warmup

When the FastAPI server starts, it eagerly loads models and warms up connections to avoid cold start penalties.

### Startup Sequence

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SERVER STARTUP SEQUENCE                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  t=0ms      ┌──────────────────────────────────────────────────────┐        │
│             │ 1. Initialize Logging Service                        │        │
│             │    • Start background flush task                     │        │
│             │    • Configure structured logging                    │        │
│             └──────────────────────────────────────────────────────┘        │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=50ms     ┌──────────────────────────────────────────────────────┐        │
│             │ 2. Load BGE Embedding Model                          │        │
│             │    • Model: BAAI/bge-base-en-v1.5                    │        │
│             │    • Dimensions: 768                                  │        │
│             │    • Generate test embedding ("warmup")              │        │
│             └──────────────────────────────────────────────────────┘        │
│                                    │ ~2-3 seconds                            │
│                                    ▼                                         │
│  t=3s       ┌──────────────────────────────────────────────────────┐        │
│             │ 3. Initialize Retrieval Tools                        │        │
│             │    • Create Supabase client                          │        │
│             │    • Initialize embeddings singleton                 │        │
│             └──────────────────────────────────────────────────────┘        │
│                                    │ ~100ms                                  │
│                                    ▼                                         │
│  t=3.1s     ┌──────────────────────────────────────────────────────┐        │
│             │ 4. Warm Supabase Connection                          │        │
│             │    • Execute: SELECT 1                               │        │
│             │    • Establishes connection pool                     │        │
│             └──────────────────────────────────────────────────────┘        │
│                                    │ ~200ms                                  │
│                                    ▼                                         │
│  t=3.3s     ┌──────────────────────────────────────────────────────┐        │
│             │ 5. Initialize RAG Agent                              │        │
│             │    • Create Groq client                              │        │
│             │    • Configure tool definitions                      │        │
│             └──────────────────────────────────────────────────────┘        │
│                                    │ ~100ms                                  │
│                                    ▼                                         │
│  t=3.4s     ┌──────────────────────────────────────────────────────┐        │
│             │ 6. Load Cross-Encoder Reranker                       │        │
│             │    • Model: cross-encoder/ms-marco-MiniLM-L-6-v2    │        │
│             │    • Max length: 512 tokens                          │        │
│             └──────────────────────────────────────────────────────┘        │
│                                    │ ~4-5 seconds                            │
│                                    ▼                                         │
│  t=8s       ┌──────────────────────────────────────────────────────┐        │
│             │ 7. Initialize Semantic Chunker (Docling)             │        │
│             │    • HybridChunker with BGE tokenizer alignment      │        │
│             │    • Max tokens per chunk: 256                       │        │
│             │    • merge_peers=True for context preservation       │        │
│             └──────────────────────────────────────────────────────┘        │
│                                    │ ~1-2 seconds                            │
│                                    ▼                                         │
│  t=10s      ┌──────────────────────────────────────────────────────┐        │
│             │ ✓ SERVER READY                                       │        │
│             │   Listening on http://0.0.0.0:8000                   │        │
│             └──────────────────────────────────────────────────────┘        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

TOTAL STARTUP TIME: ~8-12 seconds (dominated by model loading)
```

### Models Loaded at Startup

| Model | Purpose | Size | Load Time |
|-------|---------|------|-----------|
| `BAAI/bge-base-en-v1.5` | Query embeddings | 438MB | 2-3s |
| `cross-encoder/ms-marco-MiniLM-L-6-v2` | Reranking | 90MB | 4-5s |
| Docling HybridChunker | Semantic chunking | ~50MB | 1-2s |

---

## 3. Authentication & Caching

### Cache Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CACHE LAYERS                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                    TOKEN CACHE (JWT Sessions)                    │        │
│  │  ─────────────────────────────────────────────────────────────  │        │
│  │  TTL: 300 seconds (5 minutes)                                   │        │
│  │  Max Entries: 100                                               │        │
│  │  Key: hash(access_token)                                        │        │
│  │  Value: {user_id, email, expires_at}                            │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                    API KEY CACHE (MCP/External)                  │        │
│  │  ─────────────────────────────────────────────────────────────  │        │
│  │  TTL: 1800 seconds (30 minutes)                                 │        │
│  │  Max Entries: 50                                                │        │
│  │  Key: hash(api_key)                                             │        │
│  │  Value: {user_id, is_active, expires_at}                        │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                    TAGS CACHE (Per User)                         │        │
│  │  ─────────────────────────────────────────────────────────────  │        │
│  │  TTL: 600 seconds (10 minutes)                                  │        │
│  │  Key: user_id                                                   │        │
│  │  Value: [{tag, count}, ...]                                     │        │
│  └─────────────────────────────────────────────────────────────────┘        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Authentication Flow

```
Request with API Key Header
           │
           ▼
    ┌──────────────┐
    │ Extract Key  │
    │ from Header  │
    └──────────────┘
           │
           ▼
    ┌──────────────┐     ┌─────────────────────┐
    │ Hash API Key │────▶│ Check Cache         │
    └──────────────┘     │ _api_key_cache[hash]│
                         └─────────────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
           ┌───────────────┐             ┌───────────────┐
           │  CACHE HIT    │             │  CACHE MISS   │
           │  (< 2ms)      │             │  (~1.5s)      │
           └───────────────┘             └───────────────┘
                    │                             │
                    │                             ▼
                    │                    ┌───────────────┐
                    │                    │ Query Supabase│
                    │                    │ user_api_keys │
                    │                    └───────────────┘
                    │                             │
                    │                             ▼
                    │                    ┌───────────────┐
                    │                    │ Validate:     │
                    │                    │ • is_active   │
                    │                    │ • expires_at  │
                    │                    └───────────────┘
                    │                             │
                    │                             ▼
                    │                    ┌───────────────┐
                    │                    │ Cache Result  │
                    │                    │ TTL: 30 min   │
                    │                    └───────────────┘
                    │                             │
                    └──────────────┬──────────────┘
                                   │
                                   ▼
                          ┌───────────────┐
                          │ Return user_id│
                          └───────────────┘
```

---

## 4. Query Processing Pipeline & Search Scenarios

This section provides a complete unified flow covering all search scenarios from query arrival to response.

---

### 4.1 Master Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    COMPLETE QUERY PROCESSING FLOW                            │
│            (From Request Arrival to Response Delivery)                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                              User Query Arrives
                    "find my pan card from personal docs"
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  PHASE 1: AUTHENTICATION (~50ms)                                             │
│  ─────────────────────────────────                                           │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ Check API Key Cache                                                  │    │
│  │   → CACHE HIT: Extract user_id immediately (~2ms)                   │    │
│  │   → CACHE MISS: Query Supabase user_api_keys (~1.5s)               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  PHASE 2: PARALLEL PREPROCESSING (~100ms)                                    │
│  ─────────────────────────────────────────                                   │
│                                                                              │
│  ┌────────────────────────────┐     ┌────────────────────────────────────┐  │
│  │      Spell Check           │     │        Fetch All Tags              │  │
│  │   (llama-3.1-8b-instant)   │     │      (from cache or DB)            │  │
│  │        ~100ms              │     │          ~50ms                     │  │
│  └────────────────────────────┘     └────────────────────────────────────┘  │
│                                                                              │
│  Both run in parallel, wait for slower one                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  PHASE 3: QUERY ANALYSIS (~50ms)                                             │
│  ───────────────────────────────                                             │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ Detect:                                                              │    │
│  │   • Intent: RETRIEVE, LIST, ANSWER, COMPARE, SUMMARIZE, COUNT       │    │
│  │   • Complexity: SIMPLE (2 iter), MODERATE (3), COMPLEX (5)          │    │
│  │   • Tags: via exact match + fuzzy matching                          │    │
│  │   • Keywords: top 10 after stopword removal                         │    │
│  │   • Temporal: NEWEST, OLDEST, NONE                                  │    │
│  │   • Limit to one: "the latest", "my newest"                         │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Output for "find my pan card from personal docs":                          │
│    intent=RETRIEVE, tag="personal docs", keywords=["pan","card"]            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  PHASE 4: PATH SELECTION                                                     │
│  ────────────────────────                                                    │
│                                                                              │
│           ┌───────────────────────────────────────────────────────┐         │
│           │              FAST PATH CHECK                          │         │
│           │   Pattern: "show me", "list my", "get all"            │         │
│           │   + No temporal keywords                              │         │
│           │   + No specific search terms                          │         │
│           └───────────────────────────────────────────────────────┘         │
│                                      │                                       │
│               ┌──────────────────────┼──────────────────────┐               │
│               │ FAST PATH            │ TAG DETECTED         │ NO TAG       │
│               ▼                      ▼                      ▼               │
│      ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐     │
│      │   SCENARIO A    │    │ TAG PATH        │    │   AGENT PATH    │     │
│      │ Simple Discovery│    │ (Scenarios B,C) │    │ (Scenarios D,E) │     │
│      │ ~700ms          │    │ ~480-980ms      │    │ ~1300-2600ms    │     │
│      └─────────────────┘    └─────────────────┘    └─────────────────┘     │
│                                      │                                       │
│                            ┌─────────┴─────────┐                            │
│                            ▼                   ▼                            │
│                   ┌─────────────────┐ ┌─────────────────┐                   │
│                   │   SCENARIO B    │ │   SCENARIO C    │                   │
│                   │   LIST_ALL      │ │   SPECIFIC      │                   │
│                   │   ~480ms        │ │   ~980ms        │                   │
│                   └─────────────────┘ └─────────────────┘                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │
          ════════════════════════════╪════════════════════════════════
                    DETAILED SCENARIO FLOWS BELOW
          ════════════════════════════╪════════════════════════════════
                                      │
                                      ▼
```

---

### 4.2 Scenario A: Simple Discovery Query (FAST PATH)

**Example Queries:**
- `"show me my documents"`
- `"list my files"`
- `"get all my notes"`

**Characteristics:** No temporal keywords, no specific search terms, discovery intent

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ SCENARIO A: SIMPLE DISCOVERY (FAST PATH)                                     │
│ Query: "show me my documents"                                               │
│ Total Time: ~700ms                                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  t=0ms    ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 1: Auth Validation                                 │       │
│           │ • Check API key cache → HIT (typical)                   │       │
│           │ • Extract user_id                                       │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=50ms   ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 4: Fast Path Detection                             │       │
│           │ • Pattern: "show me" ✓                                  │       │
│           │ • No temporal keywords ✓                                │       │
│           │ • No specific search terms ✓                            │       │
│           │ → FAST PATH MATCH (skip LLM agent loop)                 │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~0ms (pattern match)                    │
│                                    ▼                                         │
│  t=50ms   ┌─────────────────────────────────────────────────────────┐       │
│           │ EXECUTION: Direct vector_search                         │       │
│           │                                                          │       │
│           │  ┌─────────────────────────────────────────────────────┐│       │
│           │  │ 1. Generate BGE embedding for query       (~200ms) ││       │
│           │  │ 2. Supabase match_notes RPC (cosine sim)  (~200ms) ││       │
│           │  │ 3. Rerank with cross-encoder              (~200ms) ││       │
│           │  └─────────────────────────────────────────────────────┘│       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~600ms                                  │
│                                    ▼                                         │
│  t=650ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ FINALIZE: Generate download URLs                        │       │
│           │ • Async batch URL generation                            │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=700ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ ✓ RESPONSE SENT                                         │       │
│           │                                                          │       │
│           │   {                                                      │       │
│           │     "answer": null,                                      │       │
│           │     "documents": [...top 5 matching docs...],           │       │
│           │     "intent": "RETRIEVE"                                │       │
│           │   }                                                      │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                                                              │
│  ✅ TOTAL: ~700ms (No LLM agent overhead)                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4.3 Scenario B: Tag-Based List (LIST_ALL)

**Example Queries:**
- `"personal documents"`
- `"show me educational content"`
- `"my work files"`

**Characteristics:** Tag detected, no specific search terms beyond tag

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ SCENARIO B: TAG-BASED LIST (LIST_ALL)                                       │
│ Query: "personal documents"                                                  │
│ Total Time: ~480ms (FASTEST PATH - no vector search!)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  t=0ms    ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 1: Auth Validation (cache hit)                     │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=50ms   ┌──────────────────────┬────────────────────────────┐             │
│           │ PHASE 2: Parallel Preprocessing                    │             │
│           │                                                     │             │
│           │ Spell Check (async)  │ Fetch Tags (async)          │             │
│           │ LLM: 8B instant      │ Cache or DB                 │             │
│           └──────────────────────┴────────────────────────────┘             │
│                                    │ ~100ms (parallel)                       │
│                                    ▼                                         │
│  t=150ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 3: Query Analysis                                  │       │
│           │                                                          │       │
│           │ • Intent: LIST                                          │       │
│           │ • Tag detection: "personal documents" → "personal docs" │       │
│           │   (fuzzy match: "documents" → "docs")                   │       │
│           │ • Keywords beyond tag: none                             │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=200ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 4: TAG PATH - Tag Intent Classification           │       │
│           │                                                          │       │
│           │ ┌─────────────────────────────────────────────────────┐ │       │
│           │ │ LLM: llama-3.1-8b-instant                           │ │       │
│           │ │                                                      │ │       │
│           │ │ Prompt: Does user want ALL docs in "personal docs"  │ │       │
│           │ │ or searching for something SPECIFIC?                │ │       │
│           │ │                                                      │ │       │
│           │ │ Keywords beyond tag: none meaningful                │ │       │
│           │ │ → Decision: LIST_ALL                                │ │       │
│           │ └─────────────────────────────────────────────────────┘ │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~130ms                                  │
│                                    ▼                                         │
│  t=330ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ EXECUTION: search_by_tag("personal docs")               │       │
│           │                                                          │       │
│           │ • Query: SELECT * FROM notes WHERE tag = 'personal docs'│       │
│           │ • Order by created_at DESC                              │       │
│           │ • NO VECTOR SEARCH NEEDED!                              │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~100ms                                  │
│                                    ▼                                         │
│  t=430ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ FINALIZE: Generate download URLs                        │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=480ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ ✓ RESPONSE SENT                                         │       │
│           │                                                          │       │
│           │   {                                                      │       │
│           │     "answer": null,                                      │       │
│           │     "documents": [...all docs with tag...],             │       │
│           │     "intent": "LIST"                                    │       │
│           │   }                                                      │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                                                              │
│  ✅ TOTAL: ~480ms (Fastest possible - direct DB query)                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4.4 Scenario C: Tag-Based Specific Search (SPECIFIC)

**Example Queries:**
- `"find my pan card from personal docs"`
- `"get resume from work files"`
- `"search for tax documents in financial"`

**Characteristics:** Tag detected + specific search terms beyond the tag

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ SCENARIO C: TAG-BASED SPECIFIC SEARCH                                       │
│ Query: "find my pan card from personal docs"                                │
│ Total Time: ~980ms                                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  t=0ms    ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 1-2: Auth + Preprocessing                         │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~150ms                                  │
│                                    ▼                                         │
│  t=150ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 3: Query Analysis                                  │       │
│           │                                                          │       │
│           │ • Intent: RETRIEVE                                      │       │
│           │ • Tag detected: "personal docs"                         │       │
│           │ • Keywords: ["pan", "card"] ← meaningful search terms   │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=200ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 4: TAG PATH - Tag Intent Classification           │       │
│           │                                                          │       │
│           │ ┌─────────────────────────────────────────────────────┐ │       │
│           │ │ LLM: llama-3.1-8b-instant                           │ │       │
│           │ │                                                      │ │       │
│           │ │ Keywords beyond tag: "pan card"                     │ │       │
│           │ │ → Meaningful, specific item being searched          │ │       │
│           │ │ → Decision: SPECIFIC                                │ │       │
│           │ └─────────────────────────────────────────────────────┘ │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~130ms                                  │
│                                    ▼                                         │
│  t=330ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ EXECUTION: hybrid_search("pan card", tag="personal docs")│       │
│           │                                                          │       │
│           │  ┌─────────────────────────────────────────────────────┐│       │
│           │  │ 1. CHUNK SEARCH (Vector)                   ~300ms  ││       │
│           │  │    • Generate BGE embedding                        ││       │
│           │  │    • Query chunks WHERE tag='personal docs'        ││       │
│           │  │    • Threshold: 0.45 similarity                    ││       │
│           │  │    • Group by note_id, keep best chunk per doc     ││       │
│           │  ├─────────────────────────────────────────────────────┤│       │
│           │  │ 2. FULLTEXT SEARCH (Parallel)              ~100ms  ││       │
│           │  │    • PostgreSQL FTS for "pan card"                 ││       │
│           │  │    • Filter by tag='personal docs'                 ││       │
│           │  ├─────────────────────────────────────────────────────┤│       │
│           │  │ 3. MERGE & SCORE                           ~10ms   ││       │
│           │  │    • combined = 0.7 × vector + 0.3 × text_rank     ││       │
│           │  ├─────────────────────────────────────────────────────┤│       │
│           │  │ 4. RERANK (Cross-encoder)                  ~200ms  ││       │
│           │  │    • Score query-document pairs                    ││       │
│           │  │    • Re-sort by rerank score                       ││       │
│           │  └─────────────────────────────────────────────────────┘│       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~600ms                                  │
│                                    ▼                                         │
│  t=930ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ FINALIZE: Generate download URLs                        │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=980ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ ✓ RESPONSE SENT                                         │       │
│           │                                                          │       │
│           │   {                                                      │       │
│           │     "answer": null,                                      │       │
│           │     "documents": [PAN card doc ranked first],           │       │
│           │     "intent": "RETRIEVE"                                │       │
│           │   }                                                      │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                                                              │
│  ✅ TOTAL: ~980ms (Tag-scoped hybrid search)                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4.5 Scenario D: Complex Query with Synthesis (AGENT PATH)

**Example Queries:**
- `"What experience did I have at Centric Consulting?"`
- `"Summarize my machine learning projects"`
- `"Compare my two resumes"`

**Characteristics:** No tag, needs synthesis/answer, requires LLM reasoning

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ SCENARIO D: COMPLEX QUERY WITH SYNTHESIS (AGENT PATH)                       │
│ Query: "What experience did I have at Centric Consulting?"                  │
│ Total Time: ~2600ms                                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  t=0ms    ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 1-2: Auth + Preprocessing                         │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~150ms                                  │
│                                    ▼                                         │
│  t=150ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 3: Query Analysis                                  │       │
│           │                                                          │       │
│           │ • Intent: ANSWER (ends with ?)                          │       │
│           │ • Needs synthesis: TRUE                                 │       │
│           │ • Complexity: MODERATE (max 3 iterations)               │       │
│           │ • Keywords: ["experience", "Centric", "Consulting"]     │       │
│           │ • No tag detected                                       │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=200ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 4: AGENT PATH (No tag detected + synthesis needed)│       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │                                         │
│                                    ▼                                         │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                         LLM AGENT LOOP                                │   │
│  │                    (llama-3.3-70b-versatile)                          │   │
│  ├──────────────────────────────────────────────────────────────────────┤   │
│  │                                                                       │   │
│  │  ╔═══════════════════════════════════════════════════════════════╗   │   │
│  │  ║ ITERATION 1: Tool Selection                                    ║   │   │
│  │  ╚═══════════════════════════════════════════════════════════════╝   │   │
│  │                                                                       │   │
│  │  t=200ms  ┌───────────────────────────────────────────────────────┐  │   │
│  │           │ LLM Reasoning (70B model)                             │  │   │
│  │           │                                                        │  │   │
│  │           │ "User asks about Centric Consulting experience.       │  │   │
│  │           │  'Centric Consulting' is a proper noun (company).     │  │   │
│  │           │  Proper nouns need keyword matching, not just         │  │   │
│  │           │  semantic search.                                      │  │   │
│  │           │                                                        │  │   │
│  │           │  → Tool: hybrid_search                                │  │   │
│  │           │  → Query: 'Centric Consulting experience'"            │  │   │
│  │           └───────────────────────────────────────────────────────┘  │   │
│  │                                    │ ~400ms                           │   │
│  │                                    ▼                                  │   │
│  │  t=600ms  ┌───────────────────────────────────────────────────────┐  │   │
│  │           │ Execute: hybrid_search("Centric Consulting experience")│  │   │
│  │           │                                                        │  │   │
│  │           │ • Chunk search: embedding + vector similarity         │  │   │
│  │           │ • Fulltext search: "Centric" AND "Consulting"         │  │   │
│  │           │ • Merge scores: 0.7×vector + 0.3×text                 │  │   │
│  │           │ • Rerank with cross-encoder                           │  │   │
│  │           │                                                        │  │   │
│  │           │ Returns 3 candidates:                                 │  │   │
│  │           │   1. Job Openings at Centric (score: 0.68)           │  │   │
│  │           │   2. Resume - Amit (score: 0.62)                     │  │   │
│  │           │   3. Resume - Updated (score: 0.58)                  │  │   │
│  │           └───────────────────────────────────────────────────────┘  │   │
│  │                                    │ ~700ms                           │   │
│  │                                    ▼                                  │   │
│  │  ╔═══════════════════════════════════════════════════════════════╗   │   │
│  │  ║ ITERATION 2: Review Results + Finalize                        ║   │   │
│  │  ╚═══════════════════════════════════════════════════════════════╝   │   │
│  │                                                                       │   │
│  │  t=1300ms ┌───────────────────────────────────────────────────────┐  │   │
│  │           │ LLM Reviews Results                                   │  │   │
│  │           │                                                        │  │   │
│  │           │ "User asks for 'experience' at Centric.               │  │   │
│  │           │  The Job Openings doc is ABOUT Centric but not       │  │   │
│  │           │  about user's experience there.                       │  │   │
│  │           │  The Resume docs contain actual experience.           │  │   │
│  │           │                                                        │  │   │
│  │           │  CRITICAL RULES APPLIED:                              │  │   │
│  │           │  - 'experience' implies resumes/CV content            │  │   │
│  │           │  - Job posting ≠ user's experience                    │  │   │
│  │           │                                                        │  │   │
│  │           │  → Filter out: Job Openings                           │  │   │
│  │           │  → Keep: Both resume documents                        │  │   │
│  │           │  → Action: finalize_results with synthesis=true"      │  │   │
│  │           └───────────────────────────────────────────────────────┘  │   │
│  │                                    │ ~400ms                           │   │
│  │                                    ▼                                  │   │
│  │  t=1700ms ┌───────────────────────────────────────────────────────┐  │   │
│  │           │ finalize_results                                      │  │   │
│  │           │                                                        │  │   │
│  │           │ {                                                      │  │   │
│  │           │   "selected_note_ids": [resume1_id, resume2_id],     │  │   │
│  │           │   "needs_synthesis": true,                            │  │   │
│  │           │   "reasoning": "These docs contain Centric experience"│  │   │
│  │           │ }                                                      │  │   │
│  │           └───────────────────────────────────────────────────────┘  │   │
│  │                                    │ ~50ms                            │   │
│  │                                                                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼                                         │
│  t=1750ms ┌─────────────────────────────────────────────────────────┐       │
│           │ SYNTHESIS PHASE                                          │       │
│           │                                                          │       │
│           │ ┌─────────────────────────────────────────────────────┐ │       │
│           │ │ 1. Fetch full content of selected documents         │ │       │
│           │ │ 2. Truncate to 8000 chars each (token limits)       │ │       │
│           │ │ 3. LLM generates synthesized answer:                │ │       │
│           │ │                                                      │ │       │
│           │ │ "Based on your resumes, at Centric Consulting you   │ │       │
│           │ │  worked as a Senior Consultant from 2019-2022.      │ │       │
│           │ │  Key responsibilities included..."                  │ │       │
│           │ └─────────────────────────────────────────────────────┘ │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~800ms                                  │
│                                    ▼                                         │
│  t=2550ms ┌─────────────────────────────────────────────────────────┐       │
│           │ FINALIZE: Generate download URLs                        │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=2600ms ┌─────────────────────────────────────────────────────────┐       │
│           │ ✓ RESPONSE SENT                                         │       │
│           │                                                          │       │
│           │   {                                                      │       │
│           │     "answer": "Based on your resumes, at Centric...",   │       │
│           │     "documents": [resume1, resume2],                    │       │
│           │     "intent": "ANSWER"                                  │       │
│           │   }                                                      │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                                                              │
│  ✅ TOTAL: ~2600ms (2-3 seconds for complex synthesis)                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4.6 Scenario E: Temporal Query (AGENT PATH with Post-Processing)

**Example Queries:**
- `"get my latest resume"`
- `"show me the oldest document"`
- `"find my most recent tax filing"`

**Characteristics:** Temporal keyword detected, requires sorting + limiting

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ SCENARIO E: TEMPORAL QUERY                                                   │
│ Query: "get my latest resume"                                               │
│ Total Time: ~1370ms                                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  t=0ms    ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 1-2: Auth + Preprocessing                         │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~150ms                                  │
│                                    ▼                                         │
│  t=150ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 3: Query Analysis                                  │       │
│           │                                                          │       │
│           │ • Intent: RETRIEVE                                      │       │
│           │ • Temporal: NEWEST ("latest" detected)                  │       │
│           │ • Limit to one: TRUE ("my latest" = singular)          │       │
│           │ • Keywords: ["resume"]                                  │       │
│           │ • No tag detected                                       │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=200ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 4: AGENT PATH                                      │       │
│           │ (Temporal keywords require agent for proper handling)   │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │                                         │
│                                    ▼                                         │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                         LLM AGENT LOOP                                │   │
│  ├──────────────────────────────────────────────────────────────────────┤   │
│  │                                                                       │   │
│  │  t=200ms  ┌───────────────────────────────────────────────────────┐  │   │
│  │           │ ITERATION 1: Tool Selection                           │  │   │
│  │           │                                                        │  │   │
│  │           │ LLM: "User wants resume. Use hybrid_search to find   │  │   │
│  │           │ all matching resumes, then system will handle        │  │   │
│  │           │ temporal sorting."                                    │  │   │
│  │           │                                                        │  │   │
│  │           │ → Tool: hybrid_search("resume")                       │  │   │
│  │           └───────────────────────────────────────────────────────┘  │   │
│  │                                    │ ~400ms                           │   │
│  │                                    ▼                                  │   │
│  │  t=600ms  ┌───────────────────────────────────────────────────────┐  │   │
│  │           │ Execute hybrid_search("resume")                       │  │   │
│  │           │                                                        │  │   │
│  │           │ Returns ALL matching resumes:                         │  │   │
│  │           │   1. Resume_v3.pdf (created: 2025-12-15)             │  │   │
│  │           │   2. Resume_v2.pdf (created: 2024-06-01)             │  │   │
│  │           │   3. Old_Resume.pdf (created: 2023-01-15)            │  │   │
│  │           └───────────────────────────────────────────────────────┘  │   │
│  │                                    │ ~700ms                           │   │
│  │                                    ▼                                  │   │
│  │  t=900ms  ┌───────────────────────────────────────────────────────┐  │   │
│  │           │ ITERATION 2: finalize_results                         │  │   │
│  │           │                                                        │  │   │
│  │           │ LLM includes ALL resume candidates                   │  │   │
│  │           │ (System handles temporal sorting, not LLM)            │  │   │
│  │           └───────────────────────────────────────────────────────┘  │   │
│  │                                    │ ~400ms                           │   │
│  │                                                                       │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼                                         │
│  t=1300ms ┌─────────────────────────────────────────────────────────┐       │
│           │ POST-PROCESSING (System-level, not LLM)                  │       │
│           │                                                          │       │
│           │ ┌─────────────────────────────────────────────────────┐ │       │
│           │ │ 1. Check query_analysis.temporal == NEWEST          │ │       │
│           │ │ 2. Sort documents by created_at DESC                │ │       │
│           │ │ 3. Check query_analysis.limit_to_one == TRUE        │ │       │
│           │ │ 4. Return ONLY first document                       │ │       │
│           │ │                                                      │ │       │
│           │ │ Result: [Resume_v3.pdf] (single newest document)    │ │       │
│           │ └─────────────────────────────────────────────────────┘ │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~20ms                                   │
│                                    ▼                                         │
│  t=1320ms ┌─────────────────────────────────────────────────────────┐       │
│           │ FINALIZE: Generate download URL (single doc)            │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=1370ms ┌─────────────────────────────────────────────────────────┐       │
│           │ ✓ RESPONSE SENT                                         │       │
│           │                                                          │       │
│           │   {                                                      │       │
│           │     "answer": null,                                      │       │
│           │     "documents": [Resume_v3.pdf],  // single newest     │       │
│           │     "intent": "RETRIEVE"                                │       │
│           │   }                                                      │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                                                              │
│  ✅ TOTAL: ~1370ms                                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4.7 Decision Tree Quick Reference

```
                                    Query Arrives
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                    │
              Chrome Extension?     Fast Path?          No Fast Path
              (/instant endpoint)   (discovery only)         │
                    │                    │                    │
                    ▼                    ▼                    ▼
             ┌─────────────┐      ┌─────────────┐     ┌─────────────┐
             │ SCENARIO F  │      │ SCENARIO A  │     │ Tag Detected?│
             │   ~500-800ms│      │   ~700ms    │     └─────────────┘
             └─────────────┘      └─────────────┘           │
                                              ┌─────────────┴─────────────┐
                                              │                           │
                                             YES                          NO
                                              │                           │
                                              ▼                           ▼
                                      ┌─────────────┐            ┌─────────────┐
                                      │Tag Intent   │            │ AGENT PATH  │
                                      │Classification│            │ (LLM Loop)  │
                                      └─────────────┘            └─────────────┘
                                              │                           │
                                    ┌─────────┴─────────┐                │
                                    │                   │                │
                                LIST_ALL            SPECIFIC             │
                                    │                   │                │
                                    ▼                   ▼                ▼
                             ┌─────────────┐    ┌─────────────┐   ┌─────────────┐
                             │ SCENARIO B  │    │ SCENARIO C  │   │SCENARIO D/E │
                             │   ~480ms    │    │   ~980ms    │   │ ~1300-2600ms│
                             └─────────────┘    └─────────────┘   └─────────────┘
```

---

### 4.8 Scenario F: Instant Search (Chrome Extension)

**Endpoint:** `GET /api/v1/search/instant?q=<query>&max_results=3`

**Purpose:** Fast, low-latency search for Chrome Extension integration. Triggers when user performs Google searches to suggest relevant existing notes.

**Example Queries:**
- User Googles "pan card application" → Extension suggests matching notes
- User Googles "machine learning tutorial" → Extension shows relevant docs

**Characteristics:** Optimized for speed (~500-800ms), returns direct Azure SAS URLs, uses reranking + LLM filtering

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ SCENARIO F: INSTANT SEARCH (Chrome Extension)                               │
│ Query: "pan card application"                                               │
│ Total Time: ~500-800ms                                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  t=0ms    ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 1: Auth Validation                                 │       │
│           │ • API key from Chrome Extension                         │       │
│           │ • Scope: 'read' required                                │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=50ms   ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 2: Hybrid Search with Reranking                    │       │
│           │                                                          │       │
│           │ ┌─────────────────────────────────────────────────────┐ │       │
│           │ │ retrieval_tools.hybrid_search(                      │ │       │
│           │ │   query=q,                                          │ │       │
│           │ │   user_id=user_id,                                  │ │       │
│           │ │   limit=max_results * 2,  # 6 candidates for 3      │ │       │
│           │ │   rerank=True  # Cross-encoder reranking            │ │       │
│           │ │ )                                                   │ │       │
│           │ └─────────────────────────────────────────────────────┘ │       │
│           │                                                          │       │
│           │ Steps inside hybrid_search:                             │       │
│           │   1. chunk_search (vector) ─┬─→ Merge ─→ Rerank         │       │
│           │   2. fulltext_search (FTS) ─┘   (0.7v + 0.3t)           │       │
│           │                                                          │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~400ms                                  │
│                                    ▼                                         │
│  t=450ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 3: LLM Filtering (Optional)                        │       │
│           │                                                          │       │
│           │ If candidates > max_results:                            │       │
│           │ ┌─────────────────────────────────────────────────────┐ │       │
│           │ │ filter_results_with_llm(                            │ │       │
│           │ │   query="pan card application",                     │ │       │
│           │ │   candidates=[6 reranked docs],                     │ │       │
│           │ │   max_results=3                                     │ │       │
│           │ │ )                                                   │ │       │
│           │ │                                                      │ │       │
│           │ │ LLM: llama-3.1-8b-instant                           │ │       │
│           │ │ Prompt: "Identify top 3 most relevant documents"    │ │       │
│           │ │ Returns: "1, 3" (indices of best matches)           │ │       │
│           │ └─────────────────────────────────────────────────────┘ │       │
│           │                                                          │       │
│           │ If candidates <= max_results:                           │       │
│           │   → Skip LLM, use reranked results directly            │       │
│           │                                                          │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~150ms (if LLM needed)                  │
│                                    ▼                                         │
│  t=600ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ PHASE 4: Generate Direct Azure SAS URLs                  │       │
│           │                                                          │       │
│           │ For each result:                                        │       │
│           │   1. Extract blob_name from blob_url                    │       │
│           │   2. Generate SAS URL with 10-year expiry               │       │
│           │   3. Extension can open document directly               │       │
│           │                                                          │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                    │ ~50ms                                   │
│                                    ▼                                         │
│  t=650ms  ┌─────────────────────────────────────────────────────────┐       │
│           │ ✓ RESPONSE                                               │       │
│           │                                                          │       │
│           │   {                                                      │       │
│           │     "query": "pan card application",                    │       │
│           │     "results": [                                        │       │
│           │       {                                                 │       │
│           │         "id": "uuid",                                   │       │
│           │         "title": "PAN Card",                            │       │
│           │         "snippet": "First 200 chars...",                │       │
│           │         "relevance": 0.82,                              │       │
│           │         "url": "https://blob.../pan.pdf?sp=r&sv=...",  │       │
│           │         "source": "hybrid_reranked"                     │       │
│           │       },                                                │       │
│           │       ...                                               │       │
│           │     ],                                                  │       │
│           │     "search_url": "https://api.../docs#/Notes",        │       │
│           │     "duration_ms": 650                                  │       │
│           │   }                                                      │       │
│           └─────────────────────────────────────────────────────────┘       │
│                                                                              │
│  ✅ TOTAL: ~500-800ms (optimized for extension popup)                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4.9 Keywords Sync Endpoint (Chrome Extension Cache)

**Endpoint:** `GET /api/v1/search/keywords`

**Purpose:** Returns keyword index for Chrome Extension to cache locally. Enables instant client-side matching without network calls for common queries.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ KEYWORDS SYNC (Chrome Extension Local Cache)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ Response Format:                                                     │    │
│  │                                                                      │    │
│  │   {                                                                 │    │
│  │     "keywords": {                                                   │    │
│  │       "resume": [                                                   │    │
│  │         {"id": "uuid1", "title": "Resume - Amit", "url": "sas..."},│    │
│  │         {"id": "uuid2", "title": "Resume - 2024", "url": "sas..."} │    │
│  │       ],                                                            │    │
│  │       "pan": [                                                      │    │
│  │         {"id": "uuid3", "title": "PAN Card", "url": "sas..."}      │    │
│  │       ],                                                            │    │
│  │       "personal docs": [                                            │    │
│  │         {"id": "uuid3", "title": "PAN Card", "url": "sas..."},     │    │
│  │         {"id": "uuid4", "title": "Passport", "url": "sas..."}      │    │
│  │       ],                                                            │    │
│  │       ...                                                           │    │
│  │     },                                                              │    │
│  │     "total_notes": 42,                                              │    │
│  │     "last_updated": "2026-01-27T10:30:00Z"                         │    │
│  │   }                                                                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ Keyword Extraction Logic:                                           │    │
│  │                                                                      │    │
│  │   1. From titles: Split into words, filter stopwords, min 3 chars  │    │
│  │   2. From tags: Add each tag as a keyword                          │    │
│  │   3. Dedup: Each note appears once per keyword                     │    │
│  │                                                                      │    │
│  │ Stop words filtered:                                                │    │
│  │   "the", "a", "an", "is", "are", "was", "were", "of", "for",       │    │
│  │   "to", "in", "on", "at", "by", "with", "and", "or", "-", "–", "|" │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ Chrome Extension Usage:                                             │    │
│  │                                                                      │    │
│  │   1. On startup/periodic: Fetch /keywords and cache locally        │    │
│  │   2. When user types in Google: Match against local cache          │    │
│  │   3. Show instant suggestions (0ms latency)                        │    │
│  │   4. If no local match: Fall back to /instant endpoint             │    │
│  │   5. Click opens document directly via SAS URL                     │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4.10 Scenario Summary Table

| Scenario | Example Query | Path | Key Steps | Latency |
|----------|---------------|------|-----------|---------|
| **A: Simple Discovery** | "show me my documents" | Fast Path | Skip LLM → vector_search → rerank | ~700ms |
| **B: Tag List (LIST_ALL)** | "personal documents" | Tag Path | LLM intent → search_by_tag (no vectors) | ~480ms |
| **C: Tag Specific** | "pan card from personal docs" | Tag Path | LLM intent → hybrid_search with tag filter | ~980ms |
| **D: Complex/Synthesis** | "What experience at Centric?" | Agent Path | LLM loop → hybrid_search → synthesis | ~2600ms |
| **E: Temporal** | "get my latest resume" | Agent Path | LLM loop → hybrid_search → temporal sort | ~1370ms |
| **F: Instant Search** | Chrome Extension trigger | Instant Path | hybrid_search → rerank → LLM filter → SAS URLs | ~500-800ms |

---

## 5. Retrieval Methods

### Method Comparison

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          RETRIEVAL METHODS                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         vector_search                                │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │ USE WHEN: Conceptual/semantic queries, broad topics                 │    │
│  │ EXAMPLE: "documents about machine learning"                         │    │
│  │                                                                      │    │
│  │ FLOW:                                                               │    │
│  │   Query → BGE Embedding → match_notes RPC → Rerank → Results       │    │
│  │           (768 dim)       (cosine sim)       (optional)             │    │
│  │                                                                      │    │
│  │ THRESHOLD: 0.25 similarity                                          │    │
│  │ TIMING: ~400-600ms                                                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         hybrid_search                                │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │ USE WHEN: Specific names, company names, proper nouns               │    │
│  │ EXAMPLE: "Centric Consulting job openings"                          │    │
│  │                                                                      │    │
│  │ FLOW:                                                               │    │
│  │   Query ─┬─→ chunk_search (vector) ──┬─→ Merge ─→ Rerank ─→ Results│    │
│  │          └─→ fulltext_search (FTS) ──┘   (0.7v + 0.3t)             │    │
│  │                                                                      │    │
│  │ THRESHOLD: 0.15 combined                                            │    │
│  │ TIMING: ~600-900ms                                                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         chunk_search                                 │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │ USE WHEN: Specific facts, dates, numbers buried in documents        │    │
│  │ EXAMPLE: "when did I join Centric?", "what was my role at MSC?"    │    │
│  │                                                                      │    │
│  │ FLOW:                                                               │    │
│  │   Query → BGE Embedding → search_chunks RPC → Group by doc → Rerank│    │
│  │                           (search passages)    (keep best)          │    │
│  │                                                                      │    │
│  │ THRESHOLD: 0.45 similarity                                          │    │
│  │ TIMING: ~500-800ms                                                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         search_by_tag                                │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │ USE WHEN: Category-based retrieval, user specifies tag             │    │
│  │ EXAMPLE: "personal documents", "show me educational content"        │    │
│  │                                                                      │    │
│  │ FLOW:                                                               │    │
│  │   Tag → Supabase WHERE tag = X → Order by created_at DESC          │    │
│  │                                                                      │    │
│  │ THRESHOLD: Exact match (similarity = 1.0)                          │    │
│  │ TIMING: ~100-200ms (FASTEST)                                       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Hybrid Search Deep Dive

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      HYBRID SEARCH INTERNALS                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Query: "Centric Consulting job openings"                                   │
│                            │                                                 │
│                            ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 1: Parallel Search Execution                                   │    │
│  │                                                                      │    │
│  │  ┌─────────────────────────┐    ┌─────────────────────────────────┐ │    │
│  │  │    CHUNK SEARCH         │    │     FULLTEXT SEARCH             │ │    │
│  │  │    (Vector-based)       │    │     (Keyword-based)             │ │    │
│  │  ├─────────────────────────┤    ├─────────────────────────────────┤ │    │
│  │  │ 1. Generate embedding   │    │ 1. Call search_notes_fulltext   │ │    │
│  │  │ 2. Query chunks with    │    │ 2. PostgreSQL FTS matching      │ │    │
│  │  │    vector similarity    │    │ 3. Returns text_rank scores     │ │    │
│  │  │ 3. Threshold: 0.45      │    │                                 │ │    │
│  │  │ 4. Group by note_id     │    │                                 │ │    │
│  │  │ 5. Keep best chunk/doc  │    │                                 │ │    │
│  │  └─────────────────────────┘    └─────────────────────────────────┘ │    │
│  │           │                                │                         │    │
│  │           │ vector_similarity: 0.54        │ text_rank: 1.0         │    │
│  │           │                                │                         │    │
│  │           └────────────────┬───────────────┘                         │    │
│  │                            ▼                                         │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 2: Score Combination                                           │    │
│  │                                                                      │    │
│  │  combined_score = 0.7 × vector_similarity + 0.3 × text_rank        │    │
│  │                                                                      │    │
│  │  Example:                                                           │    │
│  │    Doc A: 0.7 × 0.54 + 0.3 × 1.0 = 0.378 + 0.30 = 0.678            │    │
│  │    Doc B: 0.7 × 0.51 + 0.3 × 0.0 = 0.357 + 0.00 = 0.357            │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 3: Add Keyword-Only Matches                                    │    │
│  │                                                                      │    │
│  │  Documents with text_rank > 0.3 but NOT in vector results          │    │
│  │  → Added with combined_score = text_rank                           │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 4: Reranking (if enabled)                                      │    │
│  │                                                                      │    │
│  │  Cross-encoder scores query-document pairs                         │    │
│  │  Model: ms-marco-MiniLM-L-6-v2                                     │    │
│  │                                                                      │    │
│  │  Input: "Centric Consulting job openings" + "Job Openings for..."  │    │
│  │  Output: rerank_score = 1.04 (relevant)                            │    │
│  │                                                                      │    │
│  │  Input: "Centric Consulting job openings" + "Resume of Amit..."    │    │
│  │  Output: rerank_score = -0.41 (less relevant)                      │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Reranking

### Cross-Encoder Reranking Pipeline

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        RERANKING PIPELINE                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  INPUT: 6 candidate documents from hybrid_search                            │
│  MODEL: cross-encoder/ms-marco-MiniLM-L-6-v2                               │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 1: Text Preparation                                            │    │
│  │                                                                      │    │
│  │  For each document:                                                 │    │
│  │    title_text = title × 2 (repeated for weight)                    │    │
│  │    content = first_200_words + " ... " + last_100_words            │    │
│  │    doc_text = title_text + content                                 │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                            │                                                 │
│                            ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 2: Cross-Encoder Scoring                                       │    │
│  │                                                                      │    │
│  │  pairs = [(query, doc1_text), (query, doc2_text), ...]             │    │
│  │  scores = model.predict(pairs)                                      │    │
│  │                                                                      │    │
│  │  Results:                                                           │    │
│  │    Doc 1 (Job Openings): +1.04                                     │    │
│  │    Doc 2 (Resume PDF):   -0.41                                     │    │
│  │    Doc 3 (Resume DOCX):  -2.10                                     │    │
│  │    Doc 4 (Other):        -5.50                                     │    │
│  │    Doc 5 (Other):        -7.20                                     │    │
│  │    Doc 6 (Other):        -9.30                                     │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                            │                                                 │
│                            ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 3: Filtering                                                   │    │
│  │                                                                      │    │
│  │  THRESHOLD: -8.0 (absolute minimum)                                 │    │
│  │  MAX_GAP: 5.0 (from top score)                                     │    │
│  │                                                                      │    │
│  │  Top score = 1.04                                                   │    │
│  │  Max allowed = 1.04 - 5.0 = -3.96                                  │    │
│  │                                                                      │    │
│  │  Filter results:                                                    │    │
│  │    ✓ Doc 1: +1.04 (passes both)                                    │    │
│  │    ✓ Doc 2: -0.41 (> -3.96, > -8.0)                               │    │
│  │    ✓ Doc 3: -2.10 (> -3.96, > -8.0)                               │    │
│  │    ✗ Doc 4: -5.50 (< -3.96, gap too large)                        │    │
│  │    ✗ Doc 5: -7.20 (< -3.96, gap too large)                        │    │
│  │    ✗ Doc 6: -9.30 (< -8.0, below threshold)                       │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                            │                                                 │
│                            ▼                                                 │
│  OUTPUT: 3 documents passed reranking                                       │
│  (Further filtering by LLM based on document type & intent)                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6.5 Document Upload & Chunking Pipeline

When a document is uploaded, it goes through a pipeline that prepares it for search.

### Upload Pipeline Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DOCUMENT UPLOAD PIPELINE                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  USER UPLOAD                                                                 │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 1 & 2: PARALLEL OPERATIONS                                     │    │
│  │                                                                      │    │
│  │  ┌────────────────────┐    ┌────────────────────┐                   │    │
│  │  │ Azure Blob Upload  │    │ TensorLake/Direct  │                   │    │
│  │  │ (Store original)   │    │ (Convert to MD)    │                   │    │
│  │  └────────────────────┘    └────────────────────┘                   │    │
│  │              │                        │                              │    │
│  │              └────────────┬───────────┘                              │    │
│  │                           ▼                                          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 3: HTML CLEANUP                                                 │    │
│  │ • Remove scripts, styles, tracking pixels                           │    │
│  │ • Clean HTML entities                                               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 4: SEMANTIC CHUNKING (Docling HybridChunker)                   │    │
│  │                                                                      │    │
│  │  Input: Markdown content                                            │    │
│  │                     │                                                │    │
│  │                     ▼                                                │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │ Docling Document Converter                                  │    │    │
│  │  │ • Parses document structure (headers, sections, lists)      │    │    │
│  │  │ • Builds DoclingDocument with hierarchy                     │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  │                     │                                                │    │
│  │                     ▼                                                │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │ HybridChunker (tokenization-aware semantic chunking)        │    │    │
│  │  │                                                              │    │    │
│  │  │ Configuration:                                               │    │    │
│  │  │ • Tokenizer: BAAI/bge-base-en-v1.5 (aligned with embeddings)│    │    │
│  │  │ • Max Tokens: 256 per chunk                                 │    │    │
│  │  │ • merge_peers: True (combine small adjacent chunks)         │    │    │
│  │  │                                                              │    │    │
│  │  │ Process:                                                     │    │    │
│  │  │ 1. Start from hierarchical structure (one chunk per element)│    │    │
│  │  │ 2. Split oversized chunks at token boundaries               │    │    │
│  │  │ 3. Merge undersized peer chunks with same context           │    │    │
│  │  │ 4. Contextualize: add section headers to each chunk         │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  │                     │                                                │    │
│  │                     ▼                                                │    │
│  │  Output: List of chunks with:                                        │    │
│  │  • content: raw chunk text                                          │    │
│  │  • contextualized_content: text + section headers (for embedding)   │    │
│  │  • token_count: tokens in contextualized version                    │    │
│  │  • metadata: headings, captions, position info                      │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 5: EMBEDDING GENERATION                                         │    │
│  │                                                                      │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │ Document Embedding                                          │    │    │
│  │  │ • Full text (title + content)                               │    │    │
│  │  │ • BGE 768-dim vector                                        │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  │                                                                      │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │ Chunk Embeddings (batch)                                    │    │    │
│  │  │ • Each contextualized_content → 768-dim vector              │    │    │
│  │  │ • Batch processing for speed                                │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ STEP 6: DATABASE INSERT                                              │    │
│  │                                                                      │    │
│  │  notes table:                                                        │    │
│  │  • id, user_id, title, content, embedding, tag, blob_url            │    │
│  │                                                                      │    │
│  │  note_chunks table:                                                  │    │
│  │  • id, note_id, chunk_index, content, embedding                     │    │
│  │  • (contextualized content stored in embedding)                     │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Semantic Chunking vs Simple Chunking

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    CHUNKING METHOD COMPARISON                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  SIMPLE WORD-BASED CHUNKING (Fallback)                                       │
│  ──────────────────────────────────────                                      │
│  • Chunk size: 500 words                                                     │
│  • Overlap: 50 words                                                         │
│  • No structure awareness                                                    │
│  • May split mid-sentence or mid-section                                     │
│                                                                              │
│  Example: "...machine learning. Types of Machine Learning Supervised..."     │
│           (Header may be split from its content)                             │
│                                                                              │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                              │
│  SEMANTIC CHUNKING (Docling HybridChunker)                                   │
│  ─────────────────────────────────────────                                   │
│  • Token-aware: aligned with BGE tokenizer (256 max tokens)                 │
│  • Structure-aware: respects document hierarchy                             │
│  • Context-enriched: each chunk knows its section                           │
│  • Merge peers: combines small adjacent chunks with same context            │
│                                                                              │
│  Example:                                                                    │
│  Chunk 1: "Introduction to Machine Learning..."                             │
│           Context: "Document Title > Introduction"                          │
│                                                                              │
│  Chunk 2: "Supervised learning is where you have input..."                  │
│           Context: "Document Title > Types > Supervised Learning"           │
│                                                                              │
│  BENEFITS OF SEMANTIC CHUNKING:                                              │
│  ✓ Better retrieval accuracy (chunks are self-contained)                    │
│  ✓ Context preservation (section headers in embedding)                      │
│  ✓ Token-efficient (no mid-word splits)                                     │
│  ✓ Better for hierarchical documents (PDFs, web pages)                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Fallback Behavior

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CHUNKING FALLBACK LOGIC                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  if settings.use_semantic_chunking == True:                                 │
│      │                                                                       │
│      ├─► Try Docling HybridChunker                                          │
│      │       │                                                               │
│      │       ├─► Success → Use semantic chunks                              │
│      │       │                                                               │
│      │       └─► Failure (import error, parse error, etc.)                  │
│      │               │                                                       │
│      │               └─► Fall back to simple word chunking                  │
│      │                                                                       │
│  else:                                                                       │
│      └─► Use simple word-based chunking directly                            │
│                                                                              │
│  Configuration (.env):                                                       │
│  USE_SEMANTIC_CHUNKING=true   # Enable Docling (default)                    │
│  USE_SEMANTIC_CHUNKING=false  # Use simple chunking only                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Models & Configuration

### All Models Used

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              MODELS SUMMARY                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ EMBEDDINGS                                                           │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │                                                                      │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │ Document Upload (OpenAI)                                      │  │    │
│  │  │ Model: text-embedding-3-small                                 │  │    │
│  │  │ Dimensions: 1536                                              │  │    │
│  │  │ Usage: When notes are created/uploaded                        │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  │                                                                      │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │ Search Queries (Local BGE)                                    │  │    │
│  │  │ Model: BAAI/bge-base-en-v1.5                                  │  │    │
│  │  │ Dimensions: 768                                               │  │    │
│  │  │ Query Prefix: "Represent this sentence for searching..."      │  │    │
│  │  │ Usage: Every search query                                     │  │    │
│  │  │ Speed: ~200ms per embedding                                   │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ RERANKER                                                             │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │ Model: cross-encoder/ms-marco-MiniLM-L-6-v2                        │    │
│  │ Max Length: 512 tokens                                              │    │
│  │ Score Range: typically -10 to +10                                  │    │
│  │ Threshold: -8.0                                                    │    │
│  │ Max Gap: 5.0                                                       │    │
│  │ Speed: ~200-500ms for 6-14 candidates                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ LLMs (via Groq)                                                     │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │                                                                      │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │ Tool Selection & Synthesis (Main)                             │  │    │
│  │  │ Model: llama-3.3-70b-versatile                                │  │    │
│  │  │ Temperature: 0.1                                              │  │    │
│  │  │ Max Tokens: 2000                                              │  │    │
│  │  │ Usage: Agent loop, finalize_results, synthesis                │  │    │
│  │  │ Speed: ~400ms per call                                        │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  │                                                                      │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │ Fast Classification (Intent, Spell Check)                     │  │    │
│  │  │ Model: llama-3.1-8b-instant                                   │  │    │
│  │  │ Temperature: 0.1                                              │  │    │
│  │  │ Usage: Tag intent (LIST_ALL/SPECIFIC), spell correction       │  │    │
│  │  │ Speed: ~130ms per call                                        │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  │                                                                      │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### All Thresholds & Configuration

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        THRESHOLDS & CONFIGURATION                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  SIMILARITY THRESHOLDS                                                       │
│  ─────────────────────                                                       │
│  │ Context          │ Threshold │ Notes                                │    │
│  ├───────────────────┼───────────┼──────────────────────────────────────┤    │
│  │ hybrid_search     │ 0.15      │ Combined vector + text score        │    │
│  │ vector_search     │ 0.25      │ Document-level similarity           │    │
│  │ chunk_search      │ 0.45      │ Passage-level (higher for precision)│    │
│  │ fuzzy_tag_match   │ 0.80      │ Tag name fuzzy matching             │    │
│  └───────────────────┴───────────┴──────────────────────────────────────┘    │
│                                                                              │
│  RERANKER THRESHOLDS                                                         │
│  ───────────────────                                                         │
│  │ Parameter         │ Value     │ Notes                                │    │
│  ├───────────────────┼───────────┼──────────────────────────────────────┤    │
│  │ score_threshold   │ -8.0      │ Absolute minimum score              │    │
│  │ max_gap_from_top  │ 5.0       │ Max distance from highest score     │    │
│  └───────────────────┴───────────┴──────────────────────────────────────┘    │
│                                                                              │
│  CACHE TTLs                                                                  │
│  ─────────                                                                   │
│  │ Cache             │ TTL       │ Max Entries                          │    │
│  ├───────────────────┼───────────┼──────────────────────────────────────┤    │
│  │ Token cache       │ 5 min     │ 100                                  │    │
│  │ API key cache     │ 30 min    │ 50                                   │    │
│  │ Tags cache        │ 10 min    │ Per user                             │    │
│  └───────────────────┴───────────┴──────────────────────────────────────┘    │
│                                                                              │
│  CHUNKING PARAMETERS                                                         │
│  ───────────────────                                                         │
│  │ Parameter         │ Value     │ Notes                                │    │
│  ├───────────────────┼───────────┼──────────────────────────────────────┤    │
│  │ chunk_size        │ 500 words │ ~650 tokens                          │    │
│  │ chunk_overlap     │ 50 words  │ Sliding window overlap               │    │
│  │ max_content_synth │ 8000 char │ Max per doc for synthesis            │    │
│  └───────────────────┴───────────┴──────────────────────────────────────┘    │
│                                                                              │
│  AGENT ITERATIONS BY COMPLEXITY                                              │
│  ──────────────────────────────                                              │
│  │ Complexity        │ Max Iter  │ Trigger                              │    │
│  ├───────────────────┼───────────┼──────────────────────────────────────┤    │
│  │ SIMPLE            │ 2         │ ≤5 words, "quick", "just", "only"   │    │
│  │ MODERATE          │ 3         │ Default                              │    │
│  │ COMPLEX           │ 5         │ ≥15 words, multi-hop, "comprehensive"│    │
│  └───────────────────┴───────────┴──────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. Complete Flow Diagrams

### Master Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    COMPLETE SEARCH FLOW                                              │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                      │
│  CLIENT                          SERVER                              EXTERNAL SERVICES              │
│  ──────                          ──────                              ─────────────────              │
│                                                                                                      │
│  ┌─────────┐                                                                                        │
│  │ Search  │───────────────────▶ POST /api/v1/search                                               │
│  │ Request │                            │                                                           │
│  └─────────┘                            ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ Auth Middleware  │◀───────────────▶ Supabase (if cache miss)       │
│                               │ (API Key Check)  │                                                  │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│                                         ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ Spell Check      │◀───────────────▶ Groq (llama-3.1-8b)           │
│                               │ + Fetch Tags     │◀───────────────▶ Supabase (if cache miss)       │
│                               │ (Parallel)       │                                                  │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│                                         ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ Query Analysis   │                                                  │
│                               │ (Local, ~50ms)   │                                                  │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│                         ┌───────────────┼───────────────┐                                           │
│                         │               │               │                                           │
│                         ▼               ▼               ▼                                           │
│                   ┌──────────┐   ┌──────────┐   ┌──────────┐                                       │
│                   │FAST PATH │   │ TAG PATH │   │AGENT PATH│                                       │
│                   │(~700ms)  │   │(~500ms)  │   │(~2-3s)   │                                       │
│                   └──────────┘   └──────────┘   └──────────┘                                       │
│                         │               │               │                                           │
│                         │               │               ▼                                           │
│                         │               │     ┌──────────────────┐                                  │
│                         │               │     │ LLM Agent Loop   │◀──▶ Groq (llama-3.3-70b)        │
│                         │               │     │ (Tool Calling)   │                                  │
│                         │               │     └──────────────────┘                                  │
│                         │               │               │                                           │
│                         │               ▼               ▼                                           │
│                         │         ┌──────────────────────────┐                                      │
│                         │         │ Tag Intent Classification│◀──▶ Groq (llama-3.1-8b)             │
│                         │         │ (LIST_ALL vs SPECIFIC)   │                                      │
│                         │         └──────────────────────────┘                                      │
│                         │               │                                                           │
│                         ▼               ▼                                                           │
│                   ┌─────────────────────────────────────────────────────┐                          │
│                   │              RETRIEVAL EXECUTION                     │                          │
│                   │  ┌─────────┐ ┌──────────┐ ┌────────────┐ ┌────────┐ │                          │
│                   │  │ vector_ │ │ hybrid_  │ │ chunk_     │ │search_ │ │                          │
│                   │  │ search  │ │ search   │ │ search     │ │by_tag  │ │                          │
│                   │  └─────────┘ └──────────┘ └────────────┘ └────────┘ │                          │
│                   └─────────────────────────────────────────────────────┘                          │
│                                         │                                                           │
│                                         ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ BGE Embedding    │ (Local model)                                   │
│                               │ Generation       │                                                  │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│                                         ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ Supabase RPC     │◀───────────────▶ Supabase (vector search)       │
│                               │ (Vector Search)  │                                                  │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│                                         ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ Cross-Encoder    │ (Local model)                                   │
│                               │ Reranking        │                                                  │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│                                         ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ finalize_results │                                                  │
│                               │ + Temporal Sort  │                                                  │
│                               │ + Limit Apply    │                                                  │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│                                         ▼                                                           │
│                               ┌──────────────────┐                                                  │
│                               │ Generate SAS URLs│◀───────────────▶ Azure Blob Storage             │
│                               └──────────────────┘                                                  │
│                                         │                                                           │
│  ┌─────────┐                            │                                                           │
│  │Response │◀───────────────────────────┘                                                           │
│  │ (JSON)  │                                                                                        │
│  └─────────┘                                                                                        │
│                                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Timing Summary by Scenario

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TIMING SUMMARY                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Scenario                          │ Typical Time │ Path                    │
│  ──────────────────────────────────┼──────────────┼────────────────────────│
│  Simple discovery                  │ ~700ms       │ FAST PATH               │
│  Tag list (LIST_ALL)               │ ~480ms       │ TAG PATH                │
│  Tag search (SPECIFIC)             │ ~980ms       │ TAG PATH + hybrid       │
│  Complex question with synthesis   │ ~2600ms      │ AGENT PATH (2 iter)     │
│  Temporal query (latest/oldest)    │ ~1370ms      │ AGENT PATH              │
│  Multi-step research               │ ~4000ms      │ AGENT PATH (3-5 iter)   │
│                                                                              │
│  First request after startup       │ +1500ms      │ API key cache miss      │
│  Subsequent requests               │ Normal       │ Caches warmed           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Appendix: Database Schema

```sql
-- notes table
CREATE TABLE notes (
    id UUID PRIMARY KEY,
    user_id UUID REFERENCES users(id),
    title TEXT,
    content TEXT,
    tag TEXT,
    file_type TEXT,
    blob_url TEXT,
    embedding VECTOR(1536),  -- OpenAI text-embedding-3-small
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- note_chunks table (for passage-level search)
CREATE TABLE note_chunks (
    id UUID PRIMARY KEY,
    note_id UUID REFERENCES notes(id) ON DELETE CASCADE,
    chunk_index INTEGER,
    content TEXT,
    embedding VECTOR(768),  -- BGE embeddings
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- user_api_keys table
CREATE TABLE user_api_keys (
    id UUID PRIMARY KEY,
    user_id UUID REFERENCES users(id),
    api_key_hash TEXT UNIQUE,
    is_active BOOLEAN DEFAULT TRUE,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_notes_user_id ON notes(user_id);
CREATE INDEX idx_notes_tag ON notes(tag);
CREATE INDEX idx_notes_embedding ON notes USING ivfflat (embedding vector_cosine_ops);
CREATE INDEX idx_chunks_note_id ON note_chunks(note_id);
CREATE INDEX idx_chunks_embedding ON note_chunks USING ivfflat (embedding vector_cosine_ops);
```

---

*Document generated: January 27, 2026*
