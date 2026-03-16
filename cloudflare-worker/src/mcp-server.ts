/**
 * MCP (Model Context Protocol) Server for NotesApp
 * 
 * Implements the MCP Streamable HTTP Transport specification for Claude Desktop.
 * Uses the same RAG search pipeline as the Chrome extension and dashboard.
 * 
 * Claude Desktop Config (claude_desktop_config.json):
 * {
 *   "mcpServers": {
 *     "notesapp": {
 *       "url": "https://notesapp-vector-search.monocle0712.workers.dev/mcp",
 *       "headers": {
 *         "X-API-Key": "na_your_api_key_here"
 *       }
 *     }
 *   }
 * }
 */

import { validateAuth, AuthEnv } from './auth';
import { RagSearchEnv } from './rag-search';

// =============================================================================
// MCP Types
// =============================================================================

interface MCPRequest {
  jsonrpc: "2.0";
  id?: string | number;
  method: string;
  params?: Record<string, any>;
}

interface MCPResponse {
  jsonrpc: "2.0";
  id?: string | number;
  result?: any;
  error?: {
    code: number;
    message: string;
    data?: any;
  };
}

interface MCPTool {
  name: string;
  description: string;
  inputSchema: {
    type: "object";
    properties: Record<string, any>;
    required: string[];
  };
}

// =============================================================================
// MCP Tools Definition
// =============================================================================

const MCP_TOOLS: MCPTool[] = [
  {
    name: "search_notes",
    description: "Search the user's personal notes and documents. Use this tool when the user asks about their personal information, documents, or files. Returns relevant documents with view links.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Natural language search query"
        },
        max_results: {
          type: "integer",
          description: "Maximum number of documents to return (default: 5)"
        }
      },
      required: ["query"]
    }
  },
  {
    name: "get_note",
    description: "Get the full content of a specific note by its ID. Returns complete text and a secure view link.",
    inputSchema: {
      type: "object",
      properties: {
        note_id: {
          type: "string",
          description: "The UUID of the note to retrieve"
        }
      },
      required: ["note_id"]
    }
  },
  {
    name: "create_note",
    description: "Create a new quick note with text content.",
    inputSchema: {
      type: "object",
      properties: {
        content: {
          type: "string",
          description: "The content/body of the note"
        },
        title: {
          type: "string",
          description: "Optional title for the note"
        },
        tag: {
          type: "string",
          description: "Optional tag/category for the note"
        }
      },
      required: ["content"]
    }
  },
  {
    name: "list_tags",
    description: "List all available tags/categories in your notes.",
    inputSchema: {
      type: "object",
      properties: {},
      required: []
    }
  },
  {
    name: "delete_note",
    description: "Delete a note by its ID. This action is irreversible.",
    inputSchema: {
      type: "object",
      properties: {
        note_id: {
          type: "string",
          description: "The UUID of the note to delete"
        }
      },
      required: ["note_id"]
    }
  }
];

// =============================================================================
// MCP Server Implementation
// =============================================================================

export interface MCPEnv extends RagSearchEnv, AuthEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key, Mcp-Session-Id",
};

/**
 * Generate a signed view token for a note (same as rag-search.ts)
 */
async function generateViewToken(noteId: string, userId: string, env: MCPEnv): Promise<string> {
  const payload = {
    note_id: noteId,
    user_id: userId,
    exp: Math.floor(Date.now() / 1000) + (24 * 60 * 60), // 24 hours
    iat: Math.floor(Date.now() / 1000)
  };
  
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(env.SUPABASE_SERVICE_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replace(/=/g, '');
  const payloadB64 = btoa(JSON.stringify(payload)).replace(/=/g, '');
  const signatureInput = `${header}.${payloadB64}`;
  
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(signatureInput)
  );
  
  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  return `${header}.${payloadB64}.${signatureB64}`;
}

/**
 * Handle search_notes tool - calls the same RAG search as dashboard/extension
 */
async function handleSearchNotes(
  query: string,
  maxResults: number,
  userId: string,
  apiKey: string,
  env: MCPEnv
): Promise<string> {
  // Call the RAG search endpoint (same as Chrome extension)
  const workerUrl = 'https://notesapp-vector-search.monocle0712.workers.dev';
  
  const response = await fetch(`${workerUrl}/rag-search-auth`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': apiKey
    },
    body: JSON.stringify({
      query,
      max_results: maxResults,
      client_source: 'mcp_claude'
    })
  });
  
  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Search failed: ${response.status} - ${errorText}`);
  }
  
  const result = await response.json() as {
    answer?: string;
    documents?: Array<{
      note_id?: string;
      id?: string;
      title?: string;
      tag?: string;
      content_preview?: string;
    }>;
  };
  
  // Format output for Claude
  let output = `## Search Results for: "${query}"\n\n`;
  
  if (result.answer) {
    output += `**Answer:**\n${result.answer}\n\n`;
  }
  
  const docs = result.documents || [];
  
  if (docs.length > 0) {
    output += "### 📎 Documents Found\n\n";
    
    for (let i = 0; i < docs.length; i++) {
      const doc = docs[i];
      const docTitle = doc.title || 'Untitled';
      const docTag = doc.tag ? ` [${doc.tag}]` : '';
      const docId = doc.note_id || doc.id;
      
      output += `${i + 1}. **${docTitle}**${docTag}\n`;
      
      if (docId) {
        try {
          const viewToken = await generateViewToken(docId, userId, env);
          output += `   View: https://notesapp-vector-search.monocle0712.workers.dev/api/v1/notes/${docId}/view?token=${viewToken}\n`;
        } catch (e) {
          // Skip view link if token generation fails
        }
      }
    }
    
    // Add previews if no answer was synthesized
    if (!result.answer && docs.length > 0) {
      output += "\n### Previews\n\n";
      for (const doc of docs) {
        const preview = (doc.content_preview || '').slice(0, 500);
        if (preview) {
          output += `**${doc.title || 'Untitled'}:**\n${preview}...\n\n`;
        }
      }
    }
  } else {
    output += "No documents found matching your query.\n";
  }
  
  return output;
}

/**
 * Handle get_note tool - fetch a specific note by ID
 */
async function handleGetNote(
  noteId: string,
  userId: string,
  env: MCPEnv
): Promise<string> {
  // Fetch note from Supabase
  const response = await fetch(
    `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}&select=*`,
    {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`
      }
    }
  );
  
  if (!response.ok) {
    throw new Error(`Failed to fetch note: ${response.status}`);
  }
  
  const notes = await response.json() as Array<{
    id: string;
    title?: string;
    tag?: string;
    file_type?: string;
    created_at?: string;
    content_markdown?: string;
  }>;
  
  if (notes.length === 0) {
    return `❌ Note not found or you don't have access to it.`;
  }
  
  const note = notes[0];
  
  // Generate view token
  let viewUrl = '';
  try {
    const viewToken = await generateViewToken(noteId, userId, env);
    viewUrl = `https://notesapp-vector-search.monocle0712.workers.dev/api/v1/notes/${noteId}/view?token=${viewToken}`;
  } catch (e) {
    // Skip view link if token generation fails
  }
  
  let output = `## ${note.title || 'Untitled'}\n\n`;
  if (note.tag) output += `**Tag:** ${note.tag}\n`;
  if (note.file_type) output += `**Type:** ${note.file_type}\n`;
  if (note.created_at) output += `**Created:** ${note.created_at}\n`;
  if (viewUrl) output += `**View:** ${viewUrl}\n`;
  output += "\n---\n\n";
  output += note.content_markdown || "No content available.";
  
  return output;
}

/**
 * Handle create_note tool - create a quick text note
 */
async function handleCreateNote(
  content: string,
  title: string | undefined,
  tag: string | undefined,
  userId: string,
  env: MCPEnv
): Promise<string> {
  // Call the upload quick-note endpoint
  const response = await fetch(
    'https://notesapp-vector-search.monocle0712.workers.dev/api/v1/upload/quick-note',
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`
      },
      body: JSON.stringify({
        content,
        title,
        tag,
        user_id: userId
      })
    }
  );
  
  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to create note: ${error}`);
  }
  
  const result = await response.json() as { note_id?: string; chunks_created?: number };
  
  return `✅ Note created successfully!\n\n**Note ID:** \`${result.note_id}\`\n**Chunks created:** ${result.chunks_created || 0}`;
}

/**
 * Handle list_tags tool - list all user's tags
 */
async function handleListTags(userId: string, env: MCPEnv): Promise<string> {
  // Fetch distinct tags from Supabase
  const response = await fetch(
    `${env.SUPABASE_URL}/rest/v1/notes?user_id=eq.${userId}&select=tag`,
    {
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`
      }
    }
  );
  
  if (!response.ok) {
    throw new Error(`Failed to fetch tags: ${response.status}`);
  }
  
  const notes = await response.json() as Array<{ tag?: string }>;
  const tags = [...new Set(notes.map(n => n.tag).filter(Boolean))].sort();
  
  let output = "## Available Tags\n\n";
  if (tags.length > 0) {
    for (const tag of tags) {
      output += `- ${tag}\n`;
    }
  } else {
    output += "No tags found.";
  }
  
  return output;
}

/**
 * Handle delete_note tool - delete a note by ID
 */
async function handleDeleteNote(
  noteId: string,
  userId: string,
  env: MCPEnv
): Promise<string> {
  // Delete from Supabase
  const response = await fetch(
    `${env.SUPABASE_URL}/rest/v1/notes?id=eq.${noteId}&user_id=eq.${userId}`,
    {
      method: 'DELETE',
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Prefer': 'return=minimal'
      }
    }
  );
  
  if (!response.ok) {
    throw new Error(`Failed to delete note: ${response.status}`);
  }
  
  // Also delete vectors
  // (Note: This is a simplified version - in production you'd also clean up blob storage)
  
  return `✅ Note \`${noteId}\` deleted successfully.`;
}

/**
 * Handle MCP tool call
 */
async function handleToolCall(
  toolName: string,
  args: Record<string, any>,
  userId: string,
  apiKey: string,
  env: MCPEnv
): Promise<{ content: Array<{ type: "text"; text: string }> }> {
  let text: string;
  
  try {
    switch (toolName) {
      case "search_notes":
        text = await handleSearchNotes(
          args.query,
          args.max_results || 5,
          userId,
          apiKey,
          env
        );
        break;
        
      case "get_note":
        text = await handleGetNote(args.note_id, userId, env);
        break;
        
      case "create_note":
        text = await handleCreateNote(
          args.content,
          args.title,
          args.tag,
          userId,
          env
        );
        break;
        
      case "list_tags":
        text = await handleListTags(userId, env);
        break;
        
      case "delete_note":
        text = await handleDeleteNote(args.note_id, userId, env);
        break;
        
      default:
        text = `❌ Unknown tool: ${toolName}`;
    }
  } catch (error) {
    text = `❌ Error: ${error instanceof Error ? error.message : String(error)}`;
  }
  
  return {
    content: [{ type: "text", text }]
  };
}

/**
 * Process an MCP JSON-RPC request
 */
async function processMCPRequest(
  mcpRequest: MCPRequest,
  userId: string,
  apiKey: string,
  env: MCPEnv
): Promise<MCPResponse> {
  const { method, params, id } = mcpRequest;
  
  try {
    switch (method) {
      case "initialize":
        return {
          jsonrpc: "2.0",
          id,
          result: {
            protocolVersion: "2024-11-05",
            capabilities: {
              tools: {}
            },
            serverInfo: {
              name: "notesapp",
              version: "1.0.0"
            }
          }
        };
        
      case "initialized":
        // Client acknowledgment - no response needed
        return { jsonrpc: "2.0", id, result: {} };
        
      case "tools/list":
        return {
          jsonrpc: "2.0",
          id,
          result: {
            tools: MCP_TOOLS
          }
        };
        
      case "tools/call":
        const toolName = params?.name;
        const toolArgs = params?.arguments || {};
        
        if (!toolName) {
          return {
            jsonrpc: "2.0",
            id,
            error: {
              code: -32602,
              message: "Invalid params: tool name required"
            }
          };
        }
        
        const toolResult = await handleToolCall(toolName, toolArgs, userId, apiKey, env);
        
        return {
          jsonrpc: "2.0",
          id,
          result: toolResult
        };
        
      case "ping":
        return { jsonrpc: "2.0", id, result: {} };
        
      default:
        return {
          jsonrpc: "2.0",
          id,
          error: {
            code: -32601,
            message: `Method not found: ${method}`
          }
        };
    }
  } catch (error) {
    return {
      jsonrpc: "2.0",
      id,
      error: {
        code: -32603,
        message: error instanceof Error ? error.message : "Internal error"
      }
    };
  }
}

/**
 * Main MCP endpoint handler
 */
export async function handleMCP(
  request: Request,
  env: MCPEnv,
  ctx: ExecutionContext
): Promise<Response> {
  // Handle CORS preflight
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  
  // Only accept POST for MCP requests
  if (request.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  // Get API key from request header (we'll need it for sub-requests)
  const apiKey = request.headers.get('X-API-Key') || '';
  
  // Authenticate the request
  const authResult = await validateAuth(request, env as AuthEnv);
  
  if (!authResult.authenticated) {
    return new Response(
      JSON.stringify({ 
        jsonrpc: "2.0",
        error: {
          code: -32000,
          message: authResult.error || "Authentication required"
        }
      }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  const userId = authResult.user_id;
  if (!userId) {
    return new Response(
      JSON.stringify({
        jsonrpc: "2.0",
        error: {
          code: -32000,
          message: "User ID not found in authentication"
        }
      }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  // Parse the request body
  let body: MCPRequest | MCPRequest[];
  try {
    body = await request.json();
  } catch (e) {
    return new Response(
      JSON.stringify({
        jsonrpc: "2.0",
        error: {
          code: -32700,
          message: "Parse error: invalid JSON"
        }
      }),
      { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  // Handle batch requests
  if (Array.isArray(body)) {
    const responses = await Promise.all(
      body.map(req => processMCPRequest(req, userId, apiKey, env))
    );
    return new Response(
      JSON.stringify(responses),
      { headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  
  // Handle single request
  const response = await processMCPRequest(body, userId, apiKey, env);
  
  return new Response(
    JSON.stringify(response),
    { headers: { "Content-Type": "application/json", ...corsHeaders } }
  );
}
