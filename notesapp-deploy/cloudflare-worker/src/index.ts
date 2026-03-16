/**
 * NotesApp Vector Search Worker - Enhanced with Voyage AI Reranking
 * 
 * Runs at Cloudflare edge for low-latency vector operations.
 * - /search: Query vectors with optional filters
 * - /search-rerank: Query + Voyage AI reranking in one call
 * - /embed: Generate embedding for text
 * - /embed-batch: Generate embeddings for multiple texts
 * - /upsert: Insert or update vectors
 * - /delete: Remove vectors by ID
 * - /health: Health check
 */

export interface Env {
  VECTORIZE: Vectorize;
  AI: Ai;
  WORKER_API_KEY: string;
  VOYAGE_API_KEY: string;
  EMBEDDING_MODEL: string;
}

interface SearchRequest {
  query?: string;           // Text query (will generate embedding)
  embedding?: number[];     // Pre-computed embedding (768-dim)
  user_id?: string;
  tag?: string;
  limit?: number;
}

interface SearchRerankRequest {
  query: string;            // Text query (required)
  user_id: string;          // User filter (required)
  tag?: string;             // Optional tag filter
  limit?: number;           // Initial search limit (default 50)
  top_k?: number;           // Final results after reranking (default 10)
  rerank_model?: string;    // Voyage model (default: rerank-2.5)
}

interface EmbedRequest {
  text: string;
}

interface EmbedBatchRequest {
  texts: string[];
}

interface UpsertRequest {
  vectors: Array<{
    id: string;
    values?: number[];      // Pre-computed embedding
    text?: string;          // Text to embed (if values not provided)
    metadata: Record<string, unknown>;
  }>;
  namespace?: string;       // Optional namespace for organization
}

interface DeleteRequest {
  ids: string[];
}

interface VoyageRerankResponse {
  object: string;
  model: string;
  usage: { total_tokens: number };
  data: Array<{
    index: number;
    relevance_score: number;
    document?: string;
  }>;
}

// CORS headers for cross-origin requests
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key",
};

// Validate API key
function validateApiKey(request: Request, env: Env): boolean {
  const apiKey = request.headers.get("X-API-Key") || 
                 request.headers.get("Authorization")?.replace("Bearer ", "");
  return apiKey === env.WORKER_API_KEY;
}

// Generate embedding using Workers AI
async function generateEmbedding(text: string, env: Env): Promise<{ embedding: number[], time_ms: number }> {
  const start = Date.now();
  
  // Add query prefix for BGE model
  const queryText = `Represent this sentence for searching relevant passages: ${text}`;
  
  const response = await env.AI.run(env.EMBEDDING_MODEL as any, {
    text: [queryText],
  });
  
  const embedding = (response as any).data[0];
  const time_ms = Date.now() - start;
  
  console.log(`Embedding generated in ${time_ms}ms, dim=${embedding.length}`);
  
  return { embedding, time_ms };
}

// Generate embeddings for batch of texts
async function generateEmbeddings(texts: string[], env: Env): Promise<{ embeddings: number[][], time_ms: number }> {
  const start = Date.now();
  
  // Add query prefix for BGE model
  const queryTexts = texts.map(t => `Represent this sentence for searching relevant passages: ${t}`);
  
  const response = await env.AI.run(env.EMBEDDING_MODEL as any, {
    text: queryTexts,
  });
  
  const embeddings = (response as any).data;
  const time_ms = Date.now() - start;
  
  console.log(`Batch embeddings generated in ${time_ms}ms, count=${embeddings.length}`);
  
  return { embeddings, time_ms };
}

// Call Voyage AI Reranker API
async function rerank(
  query: string, 
  documents: string[], 
  env: Env,
  model: string = "rerank-2.5",
  top_k?: number
): Promise<{ results: Array<{ index: number; score: number; text: string }>, time_ms: number }> {
  const start = Date.now();
  
  // Validate model - only accept Voyage AI models, default to rerank-2.5
  const validModels = ["rerank-2.5", "rerank-2.5-lite", "rerank-2", "rerank-2-lite", "rerank-lite-1"];
  const actualModel = validModels.includes(model) ? model : "rerank-2.5";
  
  const response = await fetch("https://api.voyageai.com/v1/rerank", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${env.VOYAGE_API_KEY}`,
    },
    body: JSON.stringify({
      model: actualModel,
      query,
      documents,
      top_k: top_k || documents.length,
      return_documents: true,
    }),
  });
  
  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Voyage API error: ${response.status} - ${error}`);
  }
  
  const data: VoyageRerankResponse = await response.json();
  const time_ms = Date.now() - start;
  
  const results = data.data.map((r, idx) => ({
    index: r.index,
    score: r.relevance_score,
    text: r.document || documents[r.index],
  }));
  
  console.log(`Reranking completed in ${time_ms}ms, input=${documents.length}, output=${results.length}`);
  
  return { results, time_ms };
}

// Handle single embedding request
async function handleEmbed(request: Request, env: Env): Promise<Response> {
  try {
    const body: EmbedRequest = await request.json();
    
    if (!body.text) {
      return new Response(
        JSON.stringify({ error: "Must provide 'text'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    const { embedding, time_ms } = await generateEmbedding(body.text, env);
    
    return new Response(
      JSON.stringify({
        success: true,
        embedding,
        dimensions: embedding.length,
        timing: { embedding_ms: time_ms },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Embed error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle batch embedding request
async function handleEmbedBatch(request: Request, env: Env): Promise<Response> {
  try {
    const body: EmbedBatchRequest = await request.json();
    
    if (!body.texts || body.texts.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'texts' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Workers AI has batch limits - process in chunks of 100
    const batchSize = 100;
    const allEmbeddings: number[][] = [];
    let totalTime = 0;
    
    for (let i = 0; i < body.texts.length; i += batchSize) {
      const batch = body.texts.slice(i, i + batchSize);
      const { embeddings, time_ms } = await generateEmbeddings(batch, env);
      allEmbeddings.push(...embeddings);
      totalTime += time_ms;
    }
    
    return new Response(
      JSON.stringify({
        success: true,
        embeddings: allEmbeddings,
        count: allEmbeddings.length,
        dimensions: allEmbeddings[0]?.length || 768,
        timing: { embedding_ms: totalTime },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Embed batch error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle search requests (original, without reranking)
async function handleSearch(request: Request, env: Env): Promise<Response> {
  const start = Date.now();
  
  try {
    const body: SearchRequest = await request.json();
    
    // Get or generate embedding
    let queryVector: number[];
    let embeddingTime = 0;
    
    if (body.embedding && body.embedding.length === 768) {
      queryVector = body.embedding;
    } else if (body.query) {
      const result = await generateEmbedding(body.query, env);
      queryVector = result.embedding;
      embeddingTime = result.time_ms;
    } else {
      return new Response(
        JSON.stringify({ error: "Must provide 'query' or 'embedding'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Build filter if provided
    const filter: VectorizeVectorMetadataFilter = {};
    if (body.user_id) {
      filter["user_id"] = { $eq: body.user_id };
    }
    if (body.tag) {
      filter["tag"] = { $eq: body.tag };
    }
    
    // Query Vectorize
    const limit = Math.min(body.limit || 50, 50);
    const vectorizeStart = Date.now();
    
    const results = await env.VECTORIZE.query(queryVector, {
      topK: limit,
      returnMetadata: "all",
      filter: Object.keys(filter).length > 0 ? filter : undefined,
    });
    
    const vectorizeTime = Date.now() - vectorizeStart;
    
    // Transform results
    const matches = results.matches.map((match) => ({
      chunk_id: match.id,
      similarity: match.score,
      ...match.metadata,
    }));
    
    const totalTime = Date.now() - start;
    
    return new Response(
      JSON.stringify({
        success: true,
        matches,
        timing: {
          embedding_ms: embeddingTime,
          vectorize_ms: vectorizeTime,
          total_ms: totalTime,
        },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Search error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle search + rerank in one call
async function handleSearchRerank(request: Request, env: Env): Promise<Response> {
  const start = Date.now();
  
  try {
    const body: SearchRerankRequest = await request.json();
    
    if (!body.query) {
      return new Response(
        JSON.stringify({ error: "Must provide 'query'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    if (!body.user_id) {
      return new Response(
        JSON.stringify({ error: "Must provide 'user_id'" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Step 1: Generate embedding
    const { embedding, time_ms: embeddingTime } = await generateEmbedding(body.query, env);
    
    // Step 2: Query Vectorize
    const searchLimit = Math.min(body.limit || 50, 100); // Get more for reranking
    const filter: VectorizeVectorMetadataFilter = {
      user_id: { $eq: body.user_id },
    };
    if (body.tag) {
      filter.tag = { $eq: body.tag };
    }
    
    const vectorizeStart = Date.now();
    const results = await env.VECTORIZE.query(embedding, {
      topK: searchLimit,
      returnMetadata: "all",
      filter,
    });
    const vectorizeTime = Date.now() - vectorizeStart;
    
    if (results.matches.length === 0) {
      return new Response(
        JSON.stringify({
          success: true,
          matches: [],
          timing: {
            embedding_ms: embeddingTime,
            vectorize_ms: vectorizeTime,
            rerank_ms: 0,
            total_ms: Date.now() - start,
          },
        }),
        { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Step 3: Prepare documents for reranking
    // Use content_preview from metadata, or fallback to chunk_text
    const documentsForRerank = results.matches.map(match => {
      const metadata = match.metadata as Record<string, unknown>;
      return (metadata.content_preview as string) || 
             (metadata.chunk_text as string) || 
             (metadata.content as string) || 
             "";
    });
    
    // Step 4: Rerank with Voyage AI
    const topK = body.top_k || 10;
    const { results: reranked, time_ms: rerankTime } = await rerank(
      body.query,
      documentsForRerank,
      env,
      body.rerank_model || "rerank-2.5",
      topK
    );
    
    // Step 5: Combine results with original metadata
    const matches = reranked.map(r => {
      const originalMatch = results.matches[r.index];
      return {
        chunk_id: originalMatch.id,
        similarity: originalMatch.score,      // Original vector similarity
        rerank_score: r.score,                // Voyage rerank score
        ...originalMatch.metadata,
      };
    });
    
    const totalTime = Date.now() - start;
    
    console.log(`Search+Rerank: embedding=${embeddingTime}ms, vectorize=${vectorizeTime}ms, rerank=${rerankTime}ms, total=${totalTime}ms`);
    
    return new Response(
      JSON.stringify({
        success: true,
        matches,
        raw_results_count: results.matches.length,
        timing: {
          embedding_ms: embeddingTime,
          vectorize_ms: vectorizeTime,
          rerank_ms: rerankTime,
          total_ms: totalTime,
        },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Search+Rerank error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle standalone rerank requests (no search, just rerank provided documents)
interface RerankRequest {
  query: string;
  documents: string[];
  model?: string;
  top_k?: number;
}

async function handleRerank(request: Request, env: Env): Promise<Response> {
  try {
    const body: RerankRequest = await request.json();
    
    if (!body.query || !body.documents || body.documents.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'query' and 'documents' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    const { results, time_ms } = await rerank(
      body.query,
      body.documents,
      env,
      body.model || "rerank-2.5",
      body.top_k || body.documents.length
    );
    
    // Return in Voyage-compatible format
    return new Response(
      JSON.stringify({
        success: true,
        results: results.map(r => ({
          index: r.index,
          relevance_score: r.score,
          document: { text: r.text },
        })),
        timing: { rerank_ms: time_ms },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Rerank error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle upsert requests
async function handleUpsert(request: Request, env: Env): Promise<Response> {
  const start = Date.now();
  
  try {
    const body: UpsertRequest = await request.json();
    
    if (!body.vectors || body.vectors.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'vectors' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Process vectors - generate embeddings if needed
    const vectorsToUpsert: VectorizeVector[] = [];
    let embeddingTime = 0;
    
    for (const v of body.vectors) {
      let values: number[];
      
      if (v.values && v.values.length === 768) {
        values = v.values;
      } else if (v.text) {
        const result = await generateEmbedding(v.text, env);
        values = result.embedding;
        embeddingTime += result.time_ms;
      } else {
        return new Response(
          JSON.stringify({ error: `Vector ${v.id} must have 'values' or 'text'` }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      
      // Add namespace to metadata if provided
      const metadata = { ...v.metadata };
      if (body.namespace) {
        metadata.namespace = body.namespace;
      }
      
      vectorsToUpsert.push({
        id: v.id,
        values,
        metadata,
      });
    }
    
    // Batch upsert (max 1000 per batch)
    const batchSize = 1000;
    let totalUpserted = 0;
    const upsertStart = Date.now();
    
    for (let i = 0; i < vectorsToUpsert.length; i += batchSize) {
      const batch = vectorsToUpsert.slice(i, i + batchSize);
      await env.VECTORIZE.upsert(batch);
      totalUpserted += batch.length;
    }
    
    const upsertTime = Date.now() - upsertStart;
    const totalTime = Date.now() - start;
    
    console.log(`Upsert completed: ${totalUpserted} vectors, embedding=${embeddingTime}ms, upsert=${upsertTime}ms, total=${totalTime}ms`);
    
    return new Response(
      JSON.stringify({
        success: true,
        count: totalUpserted,
        timing: { 
          embedding_ms: embeddingTime,
          upsert_ms: upsertTime,
          total_ms: totalTime 
        },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Upsert error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Handle delete requests
async function handleDelete(request: Request, env: Env): Promise<Response> {
  const start = Date.now();
  
  try {
    const body: DeleteRequest = await request.json();
    
    if (!body.ids || body.ids.length === 0) {
      return new Response(
        JSON.stringify({ error: "Must provide 'ids' array" }),
        { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    await env.VECTORIZE.deleteByIds(body.ids);
    
    const totalTime = Date.now() - start;
    console.log(`Delete completed: ${body.ids.length} vectors in ${totalTime}ms`);
    
    return new Response(
      JSON.stringify({
        success: true,
        count: body.ids.length,
        timing: { total_ms: totalTime },
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
    
  } catch (error) {
    console.error("Delete error:", error);
    return new Response(
      JSON.stringify({ error: String(error) }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Health check
async function handleHealth(env: Env): Promise<Response> {
  try {
    // Test Vectorize
    const testVector = new Array(768).fill(0.1);
    await env.VECTORIZE.query(testVector, { topK: 1 });
    
    // Check if Jina key is configured
    const jinaConfigured = !!env.JINA_API_KEY;
    
    return new Response(
      JSON.stringify({ 
        status: "healthy",
        vectorize: "connected",
        ai: "available",
        jina_reranker: jinaConfigured ? "configured" : "not_configured",
        endpoints: [
          "/health",
          "/search",
          "/search-rerank",
          "/embed",
          "/embed-batch",
          "/upsert",
          "/delete"
        ],
      }),
      { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  } catch (error) {
    return new Response(
      JSON.stringify({ 
        status: "unhealthy",
        error: String(error),
      }),
      { status: 503, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
}

// Main request handler
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    
    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }
    
    // Health check (no auth required)
    if (path === "/health" || path === "/") {
      return handleHealth(env);
    }
    
    // Validate API key for all other endpoints
    if (!validateApiKey(request, env)) {
      return new Response(
        JSON.stringify({ error: "Unauthorized - Invalid or missing API key" }),
        { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
      );
    }
    
    // Route requests
    switch (path) {
      case "/search":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleSearch(request, env);
        
      case "/search-rerank":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleSearchRerank(request, env);
        
      case "/rerank":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleRerank(request, env);
        
      case "/embed":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleEmbed(request, env);
        
      case "/embed-batch":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleEmbedBatch(request, env);
        
      case "/upsert":
        if (request.method !== "POST") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleUpsert(request, env);
        
      case "/delete":
        if (request.method !== "POST" && request.method !== "DELETE") {
          return new Response("Method not allowed", { status: 405, headers: corsHeaders });
        }
        return handleDelete(request, env);
        
      default:
        return new Response(
          JSON.stringify({ 
            error: "Not found",
            endpoints: ["/health", "/search", "/search-rerank", "/rerank", "/embed", "/embed-batch", "/upsert", "/delete"],
          }),
          { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
    }
  },
};
