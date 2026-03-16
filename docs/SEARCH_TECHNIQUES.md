# Search Techniques in RAG Agent

The RAG Agent uses a combination of **LLM tool-calling** and **pattern-based routing** to select the optimal search strategy.

---

## Search Flow Overview

```
User Query
    │
    ▼
┌───────────────────────────────┐
│  1. Query Analysis (LLM)      │
│  - Intent detection           │
│  - Keyword extraction         │
│  - Tag detection              │
└───────────────────────────────┘
    │
    ▼
┌───────────────────────────────┐
│  2. Discovery Pattern Check   │  ◄── NEW: Pre-processing bypass
│  (Regex-based, no LLM)        │
└───────────────────────────────┘
    │
    ├── Match? ──► Direct vector_search (bypass agent)
    │
    └── No match ──► LLM Agent Tool Selection
                         │
                         ▼
                    [8 Tools Available]
```

---

## Discovery Query Bypass (Pattern-Based)

For **discovery/listing queries**, the system bypasses the LLM agent and directly uses `vector_search` for reliability.

**Matched Patterns:**
| Pattern | Example Query |
|---------|---------------|
| `^do\s+i\s+have` | "do i have any documents for my resume" |
| `^show\s+me` | "show me my CVs" |
| `^find\s+(my\|all\|the)` | "find my resume documents" |
| `^list\s+(my\|all\|the)` | "list all invoices" |
| `^are\s+there\s+any` | "are there any reports?" |
| `^get\s+(my\|all\|the)` | "get my files" |
| `any\s+documents?\s+(for\|about)` | "any documents for my resume" |

**Why bypass?** LLMs sometimes incorrectly choose `chunk_search` for discovery queries. Pattern matching ensures consistent behavior.

---

## LLM Agent Tools (8 Total)

---

## 1. `hybrid_search` - Combined Vector + Full-Text
**Best for:** Queries with specific keywords AND conceptual meaning

**Example Query:** `"MSC Software experience"`

**How it works:**
- Vector similarity (70%) for semantic meaning
- Full-text search (30%) for exact keyword matching
- Returns `combined_score` and `text_rank` (keyword match score)
- Documents with `text_rank = 0` are filtered out when keywords are expected

---

## 2. `vector_search` - Pure Semantic Search
**Best for:** 
- Conceptual/meaning-based queries
- **Discovery queries** (handled automatically via pattern bypass)

**Example Queries:** 
- `"documents about machine learning projects"`
- `"do i have any documents for my resume"` (auto-routed)
- `"show me my CV files"` (auto-routed)

**How it works:**
- Converts query to embedding vector (OpenAI text-embedding-3-small, 1536 dimensions)
- Finds documents with similar meaning (cosine similarity)
- Good for abstract concepts, synonyms work well

---

## 3. `chunk_search` - Deep Passage-Level Search
**Best for:** Questions asking for specific facts, roles, experiences, dates, or details buried inside documents

**Example Queries:** 
- `"what was my role in Centric consulting"`
- `"what experience do I have in data engineering"`
- `"when did I work at MSC Software"`
- `"what was the revenue in Q3 2025?"`

**How it works:**
- Searches at chunk level (paragraphs/sections)
- More precise for pinpointing specific facts in long documents
- Returns chunk content with parent document context

**Trigger words:** Queries starting with "what", "who", "when", "where", "how", "which" (when asking for FACTS, not existence)

**DO NOT USE FOR:** Discovery queries like "do I have", "show me", "find my" (these are auto-routed to vector_search)

---

## 4. `search_by_tag` - Exact Tag Match
**Best for:** Category-based retrieval

**Example Query:** `"show all resumes"` or `"get documents tagged as invoices"`

**How it works:**
- Exact match on tag field
- No semantic search, just category filtering
- Fast and precise for organized collections

---

## 5. `get_all_tags` - List Available Categories
**Best for:** Discovery queries

**Example Query:** `"what categories do I have?"` or `"list all tags"`

**How it works:**
- Returns all unique tags with document counts
- Helps user understand available categories

---

## 6. `fuzzy_match_tag` - Approximate Tag Matching
**Best for:** When user mentions a tag that might not be exact

**Example Query:** `"find my CVs"` (when tag is "Amit CV")

**How it works:**
- Uses fuzzy string matching (SequenceMatcher)
- Threshold: 80% similarity
- Handles typos and partial matches

---

## 7. `get_document_content` - Retrieve Full Document
**Best for:** When LLM needs more context from a search result

**Example Query:** (internal use) After finding a document, get full content

**How it works:**
- Fetches complete `content_markdown` by note ID
- Used for deeper analysis or answer synthesis

---

## 8. `finalize_results` - Return Final Selection
**Best for:** Completing the search

**Example:** (internal use) After gathering results, select and return

**How it works:**
- LLM provides `selected_note_ids`, `reasoning`, optional `answer`
- Triggers filtering and response generation

---

## Decision Flow Examples

| User Query | Routing | Tool Used | Why |
|------------|---------|-----------|-----|
| `"do i have any documents for my resume"` | **Pattern bypass** | `vector_search` | Discovery pattern matched |
| `"show me my CVs"` | **Pattern bypass** | `vector_search` | Discovery pattern matched |
| `"MSC Software"` | LLM Agent | `hybrid_search` | Specific company name = keyword matching needed |
| `"AI and data engineering topics"` | LLM Agent | `vector_search` | Conceptual query, no specific keywords |
| `"what was my role at Centric?"` | LLM Agent | `chunk_search` | Fact extraction from documents |
| `"what skills does Amit have?"` | LLM Agent | `chunk_search` | Looking for specific info in documents |
| `"show all Amit CV documents"` | LLM Agent | `fuzzy_match_tag` → `search_by_tag` | Tag-based request |
| `"what types of documents do I have?"` | LLM Agent | `get_all_tags` | Category listing request |

---

## Similarity Thresholds

| Source | Threshold | Notes |
|--------|-----------|-------|
| `hybrid` | 0.15 | Combined score is weighted (0.7×vector + 0.3×text) |
| `vector` | 0.25 | Pure cosine similarity |
| `chunk` | 0.25 | Pure cosine similarity |
| `tag` | 0.0 | Exact match, no similarity filter |

---

## Hybrid Search Formula

```
combined_score = (vector_weight × vector_similarity) + (text_weight × text_rank)
```

Default weights:
- `vector_weight = 0.7`
- `text_weight = 0.3`

Documents with `text_rank = 0` (no keyword match) are filtered out when the query contains significant keywords.

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                     RAG Agent Search                        │
├─────────────────────────────────────────────────────────────┤
│  Pre-Processing Layer (Pattern-Based)                       │
│  ├── Discovery patterns → Direct vector_search              │
│  └── Other queries → LLM Agent                              │
├─────────────────────────────────────────────────────────────┤
│  LLM Agent Layer (Groq llama-3.3-70b-versatile)            │
│  ├── Tool selection based on query analysis                 │
│  ├── Multi-iteration support (up to 3 iterations)          │
│  └── Self-reflection and answer synthesis                   │
├─────────────────────────────────────────────────────────────┤
│  Backend (Supabase + pgvector)                              │
│  ├── hybrid_search_notes (RPC)                              │
│  ├── search_chunks_with_context (RPC)                       │
│  └── get_tags_with_counts (RPC)                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Files

| File | Purpose |
|------|---------|
| `app/services/rag_agent.py` | Main agent with discovery bypass and tool execution |
| `app/services/retrieval_tools.py` | Tool implementations (vector, hybrid, chunk search) |
| `app/services/query_analyzer.py` | Query intent analysis |
| `migrations/002_add_search_indexes.sql` | SQL functions for hybrid/chunk search |
