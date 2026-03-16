# NotesApp - Deployment & Scaling Architecture

> Last Updated: January 27, 2026

This document outlines the deployment options, scaling strategies, and infrastructure decisions for NotesApp as it grows from a personal tool to a production system supporting thousands of users.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Evolution](#2-architecture-evolution)
3. [Latency Budget Analysis](#3-latency-budget-analysis)
4. [Component Deep Dive](#4-component-deep-dive)
5. [Cost Analysis](#5-cost-analysis)
6. [Implementation Roadmap](#6-implementation-roadmap)
7. [Key Recommendations](#7-key-recommendations)

---

## 1. Executive Summary

**Goal**: Sub-3 second response time with high accuracy for 1000s of concurrent users querying millions of vectors.

**Current State**: Single-server architecture, ~2-3s response time for complex queries, 289 chunks, Supabase-hosted pgvector.

**Target State**: Distributed architecture supporting 10K+ concurrent users, millions of vectors, <3s P95 latency.

---

## 2. Architecture Evolution

### Phase 1: Current State (You Are Here)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CURRENT ARCHITECTURE                                 │
│                         (Single Server, ~100 users)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Users (1-100)                                                               │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     SINGLE FASTAPI SERVER                            │    │
│  │                     (Your Laptop / Single VM)                        │    │
│  │                                                                      │    │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐    │    │
│  │  │ BGE Embed   │ │ Reranker    │ │ Semantic    │ │ RAG Agent   │    │    │
│  │  │ (CPU)       │ │ (CPU)       │ │ Chunker     │ │ (Groq API)  │    │    │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     SUPABASE (Cloud)                                 │    │
│  │  PostgreSQL + pgvector + Auth                                       │    │
│  │  ~300ms network latency per call                                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  LIMITATIONS:                                                                │
│  ❌ Single point of failure                                                 │
│  ❌ CPU-bound embedding/reranking (400ms + 500ms)                          │
│  ❌ Network latency to Supabase (~300ms per call)                          │
│  ❌ No horizontal scaling                                                   │
│  ❌ Memory limit (16GB) caps vector count                                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Phase 2: Production-Ready (100-1000 users)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PHASE 2: PRODUCTION ARCHITECTURE                          │
│                    (1000 users, 100K vectors, <3s P95)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Users (100-1000)                                                            │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     CLOUDFLARE / AWS CLOUDFRONT                      │    │
│  │                     (CDN + DDoS Protection)                          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     LOAD BALANCER (NGINX/Traefik)                    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│              ┌───────────────┼───────────────┐                              │
│              ▼               ▼               ▼                              │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐               │
│  │ API Server 1    │ │ API Server 2    │ │ API Server 3    │               │
│  │ (Stateless)     │ │ (Stateless)     │ │ (Stateless)     │               │
│  │                 │ │                 │ │                 │               │
│  │ • Auth          │ │ • Auth          │ │ • Auth          │               │
│  │ • Query Analysis│ │ • Query Analysis│ │ • Query Analysis│               │
│  │ • Orchestration │ │ • Orchestration │ │ • Orchestration │               │
│  └─────────────────┘ └─────────────────┘ └─────────────────┘               │
│              │               │               │                              │
│              └───────────────┼───────────────┘                              │
│                              │                                               │
│         ┌────────────────────┼────────────────────┐                         │
│         ▼                    ▼                    ▼                         │
│  ┌─────────────┐    ┌─────────────────┐    ┌─────────────┐                 │
│  │ REDIS       │    │ GPU INFERENCE   │    │ POSTGRESQL  │                 │
│  │ (Cache +    │    │ SERVICE         │    │ + pgvector  │                 │
│  │  Sessions)  │    │ (Modal/RunPod)  │    │ (Self-hosted│                 │
│  │             │    │                 │    │  or Supabase│                 │
│  │ • Auth cache│    │ • Embedding     │    │  Pro)       │                 │
│  │ • Tag cache │    │ • Reranking     │    │             │                 │
│  │ • Query     │    │ • Batched       │    │ • HNSW index│                 │
│  │   cache     │    │                 │    │ • FTS index │                 │
│  └─────────────┘    └─────────────────┘    └─────────────┘                 │
│                              │                                               │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     GROQ API (LLM)                                   │    │
│  │                     llama-3.3-70b for agent                          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  BENEFITS:                                                                   │
│  ✅ Horizontal scaling (add more API servers)                               │
│  ✅ GPU acceleration for embedding/reranking                                │
│  ✅ Redis caching reduces DB load                                           │
│  ✅ No single point of failure                                              │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Phase 3: Enterprise Scale (10K+ users, Millions of vectors)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PHASE 3: ENTERPRISE ARCHITECTURE                          │
│                    (10K+ users, 10M+ vectors, <2s P95)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Users (10K+)                                                                │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │            GLOBAL CDN + EDGE FUNCTIONS (Cloudflare Workers)          │    │
│  │            • Auth at edge                                            │    │
│  │            • Query caching                                           │    │
│  │            • Rate limiting                                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                              │                                               │
│              ┌───────────────┴───────────────┐                              │
│              ▼                               ▼                              │
│  ┌─────────────────────────┐    ┌─────────────────────────┐                │
│  │    REGION: US-EAST      │    │    REGION: EU-WEST      │                │
│  │                         │    │                         │                │
│  │  ┌─────────────────┐   │    │  ┌─────────────────┐   │                │
│  │  │ K8s Cluster     │   │    │  │ K8s Cluster     │   │                │
│  │  │ ┌─────────────┐ │   │    │  │ ┌─────────────┐ │   │                │
│  │  │ │API Pods (5) │ │   │    │  │ │API Pods (5) │ │   │                │
│  │  │ └─────────────┘ │   │    │  │ └─────────────┘ │   │                │
│  │  │ ┌─────────────┐ │   │    │  │ ┌─────────────┐ │   │                │
│  │  │ │GPU Pods (2) │ │   │    │  │ │GPU Pods (2) │ │   │                │
│  │  │ └─────────────┘ │   │    │  │ └─────────────┘ │   │                │
│  │  └─────────────────┘   │    │  └─────────────────┘   │                │
│  │                         │    │                         │                │
│  │  ┌─────────────────┐   │    │  ┌─────────────────┐   │                │
│  │  │ Redis Cluster   │   │    │  │ Redis Cluster   │   │                │
│  │  └─────────────────┘   │    │  └─────────────────┘   │                │
│  │                         │    │                         │                │
│  │  ┌─────────────────┐   │    │  ┌─────────────────┐   │                │
│  │  │ Qdrant/Milvus   │   │    │  │ Qdrant/Milvus   │   │                │
│  │  │ (Vector DB)     │   │    │  │ (Vector DB)     │   │                │
│  │  │ GPU-accelerated │   │    │  │ GPU-accelerated │   │                │
│  │  └─────────────────┘   │    │  └─────────────────┘   │                │
│  │                         │    │                         │                │
│  └─────────────────────────┘    └─────────────────────────┘                │
│              │                               │                              │
│              └───────────────┬───────────────┘                              │
│                              ▼                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │              GLOBAL POSTGRESQL (CockroachDB / Citus)                 │    │
│  │              (Metadata, Auth, Cross-region sync)                     │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  BENEFITS:                                                                   │
│  ✅ Multi-region (low latency globally)                                     │
│  ✅ Auto-scaling based on load                                              │
│  ✅ GPU-native vector DB (sub-10ms search)                                  │
│  ✅ Edge caching for repeat queries                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Latency Budget Analysis

### Target: <3 seconds end-to-end (P95)

| Component | Current | Target | How to Achieve |
|-----------|---------|--------|----------------|
| Network (client→server) | 100ms | 50ms | CDN edge |
| Auth validation | 50ms | 5ms | Redis cache |
| Query analysis | 50ms | 30ms | Optimize code |
| Embedding generation | 400ms | 50ms | GPU (Modal) |
| Vector search (DB) | 300ms* | 20ms | Local PG + FAISS |
| Reranking | 500ms | 80ms | GPU (Modal) |
| LLM agent (Groq) | 800ms | 400ms | Faster model |
| URL generation | 50ms | 20ms | Async batch |
| Network (server→client) | 100ms | 50ms | CDN edge |
| **TOTAL** | **~2350ms** | **~705ms** | |

*300ms includes ~250ms network latency to Supabase

### Optimized Latency by Query Type (Phase 2)

| Query Type | Expected Latency |
|------------|------------------|
| Simple Query (Fast Path) | ~300ms ✅ |
| Tag-based List | ~200ms ✅ |
| Hybrid Search | ~500ms ✅ |
| Complex with Synthesis | ~1200ms ✅ |
| Multi-hop Research | ~2000ms ✅ |

**All under 3 seconds!**

---

## 4. Component Deep Dive

### 4.1 API Layer (Stateless)

**Design Principles:**
- No in-memory state between requests
- All state in Redis or PostgreSQL
- Any server can handle any request
- Easy horizontal scaling

**Scaling Strategy:**
- Start with 3 servers behind load balancer
- Auto-scale based on CPU/memory (60% threshold)
- Max 10 servers for Phase 2

### 4.2 Redis Caching Strategy

| Cache Type | Key Pattern | TTL | Hit Rate Target | Latency Savings |
|------------|-------------|-----|-----------------|-----------------|
| Auth Cache | `auth:{api_key_hash}` | 30 min | 99% | 49ms |
| Query Cache | `query:{user_id}:{query_hash}` | 5 min | 30% | ~2000ms |
| Embedding Cache | `embed:{query_hash}` | 1 hour | 40% | 399ms |
| Tag Cache | `tags:{user_id}` | 10 min | 95% | 99ms |

**Cache Invalidation:**
- On document upload → invalidate user's query cache
- On document delete → invalidate user's query cache

### 4.3 GPU Inference Service (Modal)

**Performance Comparison:**

| Operation | CPU (current) | GPU (Modal T4) | Speedup |
|-----------|---------------|----------------|---------|
| Single embedding | 400ms | 50ms | 8x |
| Batch 10 embeddings | 4000ms | 80ms | 50x |
| Rerank 6 docs | 500ms | 80ms | 6x |
| Rerank 20 docs | 1500ms | 120ms | 12x |

**Cost:**
- T4 GPU: $0.000016/second = $0.058/hour
- Per query (embed + rerank): ~130ms = $0.000002
- 1M queries/month: ~$2

### 4.4 Vector Search Options

**Option A: PostgreSQL + pgvector (Recommended for Phase 2)**

| Scale | Search Time | Notes |
|-------|-------------|-------|
| 100K vectors | ~10ms | Local, no network |
| 1M vectors | ~30ms | HNSW m=32, ef=128 |

Configuration:
- shared_buffers: 8GB
- effective_cache_size: 24GB
- work_mem: 256MB
- HNSW index: m=32, ef_construction=128

**Option B: Qdrant/Milvus (For Phase 3, 10M+ vectors)**

| Provider | Cost | Performance |
|----------|------|-------------|
| Qdrant Cloud | $30+/month | Sub-10ms for 10M vectors |
| Self-hosted (RunPod) | $75/month | Sub-5ms with GPU |

---

## 5. Cost Analysis

### Phase 1 (Current): ~$25/month

| Service | Cost/month | Notes |
|---------|------------|-------|
| Supabase (Free tier) | $0 | 500MB DB, 1GB storage |
| Groq API | $0 | Free tier sufficient |
| Azure Blob | ~$5 | Document storage |
| Local compute | $0 | Your laptop |
| Domain/SSL | ~$20 | Annual, amortized |
| **TOTAL** | **~$25** | |

### Phase 2 (Production): ~$120-200/month

| Service | Cost/month | Notes |
|---------|------------|-------|
| Hetzner CCX33 | $38 | 8 vCPU, 32GB RAM, PostgreSQL |
| Hetzner CCX21 x2 | $30 | API servers (redundancy) |
| Redis (Upstash) | $10 | Serverless, pay-per-request |
| Modal GPU | $10-50 | Pay per millisecond, scales |
| Cloudflare | $0-20 | Free tier or Pro |
| Groq API | $0-20 | May need paid tier |
| Azure Blob | $10 | More storage |
| Monitoring (Grafana) | $0 | Self-hosted on Hetzner |
| **TOTAL** | **~$120-180** | 1000 users, 100K vectors |

### Phase 3 (Enterprise): ~$500-2000/month

| Service | Cost/month | Notes |
|---------|------------|-------|
| K8s Cluster (2 zones) | $300-500 | Auto-scaling pods |
| Qdrant Cloud | $100-300 | Managed vector DB |
| Redis Cluster | $50-100 | High availability |
| GPU instances | $100-500 | Reserved capacity |
| CDN (Cloudflare Pro) | $20 | Global edge |
| Monitoring stack | $50-100 | Datadog/New Relic |
| **TOTAL** | **~$620-1520** | 10K users, 10M vectors |

---

## 6. Implementation Roadmap

### Phase 1.5: Quick Wins (1-2 weeks)

- [ ] Add Redis caching for auth, embeddings, queries
- [ ] Implement query result caching with TTL
- [ ] Add embedding cache (same query = same embedding)
- [ ] Optimize batch operations in reranker
- [ ] Add request-level telemetry/logging

**Expected improvement: 2350ms → ~1500ms**

### Phase 2A: Infrastructure (2-4 weeks)

- [ ] Set up Hetzner VM with PostgreSQL + pgvector
- [ ] Migrate data from Supabase (keep Supabase for auth)
- [ ] Set up Modal for GPU inference
- [ ] Implement API server as Docker container
- [ ] Set up load balancer (Nginx/Traefik)
- [ ] Add health checks and monitoring

**Expected improvement: 1500ms → ~700ms**

### Phase 2B: Reliability (2-4 weeks)

- [ ] Add second API server for redundancy
- [ ] Set up PostgreSQL replication
- [ ] Implement circuit breakers for external services
- [ ] Add rate limiting and DDoS protection
- [ ] Set up automated backups
- [ ] Create runbooks for common issues

### Phase 3: Scale (When needed, 4-8 weeks)

- [ ] Migrate to Kubernetes
- [ ] Implement multi-region deployment
- [ ] Migrate to dedicated vector DB (Qdrant)
- [ ] Add edge caching (Cloudflare Workers)
- [ ] Implement request queuing for load spikes

---

## 7. Key Recommendations

### Immediate (This Week)

1. ✅ Keep semantic chunking with 512 tokens (already done)
2. ✅ Keep chunk threshold at 0.45 (already done)
3. Add Redis for auth + query caching → 30-50% latency reduction
4. Add embedding caching → save 400ms on repeat queries

### Short Term (1-2 months)

1. Self-host PostgreSQL on Hetzner → eliminate 300ms network latency
2. Use Modal for GPU inference → reduce embed+rerank from 900ms to 150ms
3. Add second API server → redundancy and load distribution

### Medium Term (3-6 months)

1. Kubernetes deployment for auto-scaling
2. Dedicated vector DB if >1M vectors
3. Multi-region if user base is global

### Architecture Decision Summary

| Component | Current | Phase 2 | Phase 3 |
|-----------|---------|---------|---------|
| API Servers | 1 (laptop) | 2-3 (Hetzner) | K8s (auto) |
| Database | Supabase | Self-hosted PG | PG + Qdrant |
| Vector Index | pgvector HNSW | pgvector HNSW | Qdrant GPU |
| Embedding | CPU (local) | GPU (Modal) | GPU (dedicated) |
| Reranking | CPU (local) | GPU (Modal) | GPU (dedicated) |
| Caching | In-memory | Redis | Redis Cluster |
| CDN | None | Cloudflare | Cloudflare Pro |
| Users | 1-100 | 100-1000 | 10K+ |
| Vectors | 300 | 100K | 10M+ |
| Latency (P95) | ~2500ms | ~700ms | ~500ms |
| Cost/month | ~$25 | ~$150 | ~$1000 |

---

## Appendix A: Development Machine Requirements

### Current Development Machine

| Component | Specification | Assessment |
|-----------|---------------|------------|
| **CPU** | AMD Ryzen 7 5800H (8 cores, 16 threads) | ✅ Excellent for FAISS CPU |
| **RAM** | 16 GB DDR4 | ⚠️ Tight for PostgreSQL + FAISS + Models |
| **GPU** | NVIDIA GeForce RTX 3050 Ti (4GB VRAM) | ⚠️ Limited VRAM for FAISS GPU |
| **Storage** | 476 GB SSD (~161 GB free) | ✅ Sufficient |
| **OS** | Windows 11 | ✅ OK (Linux better for production) |

### Scaling Projections

| Scale | Chunks | FAISS RAM | PostgreSQL | Total RAM Needed |
|-------|--------|-----------|------------|------------------|
| Current | 289 | 1 MB | 0.5 GB | ~10 GB ✅ |
| 1,000 docs | ~5,000 | 15 MB | 1 GB | ~12 GB ✅ |
| 10,000 docs | ~50,000 | 150 MB | 2 GB | ~14 GB ⚠️ |
| 100,000 docs | ~500,000 | 1.5 GB | 4 GB | ~18 GB ❌ |
| 1M docs | ~5,000,000 | 15 GB | 10 GB | ~40 GB ❌ |

**Your laptop can handle up to ~10,000 documents comfortably.**

---

## Appendix B: Cloud Provider Comparison

### Production VM Options

| Provider | Instance | Specs | Monthly Cost | Best For |
|----------|----------|-------|--------------|----------|
| **Hetzner** | CPX41 | 8 vCPU, 16GB RAM | **€15 (~$16)** | Budget, EU |
| **Hetzner** | CCX33 | 8 vCPU, 32GB RAM | **€35 (~$38)** | Growth |
| DigitalOcean | Basic 8GB | 4 vCPU, 8GB RAM | $48 | Simple |
| DigitalOcean | Basic 16GB | 8 vCPU, 16GB RAM | $96 | Mid-tier |
| Vultr | 8GB | 4 vCPU, 8GB RAM | $48 | Global |
| AWS EC2 | t3.xlarge | 4 vCPU, 16GB RAM | ~$120 | Enterprise |
| **RunPod** | CPU Pod | 8 vCPU, 32GB RAM | **$30** | ML workloads |
| **RunPod** | GPU Pod (T4) | 8 vCPU, 16GB + T4 GPU | **$75** | GPU FAISS |

### GPU Cloud Options (for Embedding/Reranking)

| Provider | GPU | $/hour | $/1000 queries | Best For |
|----------|-----|--------|----------------|----------|
| **Modal** | T4 | $0.06 | **$0.50** | Low volume, sporadic |
| **Modal** | A10G | $0.21 | $1.80 | Faster inference |
| RunPod | RTX 4090 | $0.68 | $1.50 | Budget + speed |
| Replicate | T4 | $0.81 | $2.50 | Simple API |
| HF Endpoints | T4 | $0.60 | $5+ | Always-on workloads |

---

*Document generated: January 27, 2026*
