/**
 * Chat Session Management — KV-backed conversational memory for SnapBot
 * 
 * Stores recent conversation turns (user queries + lightweight bot summaries)
 * in a KV namespace with session boundary detection (30-min inactivity timeout).
 * 
 * Used by the RAG pipeline to rewrite follow-up queries into standalone queries.
 */

// ============================================================================
// TYPES
// ============================================================================

export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;        // User: original query. Assistant: lightweight summary
  timestamp: number;      // epoch ms
  titles?: string[];      // Assistant only: document titles returned
  noteIds?: string[];     // Assistant only: corresponding UUIDs (parallel to titles)
  path_taken?: string;    // Assistant only: RAG path (hybrid, tag, etc.)
}

export interface ChatSession {
  user_id: string;
  messages: ChatMessage[];
  created_at: number;
  last_active: number;
  // Working context for conversational follow-up operations
  active_result_note_ids?: string[];   // top-5 note UUIDs from last search
  active_result_titles?: string[];     // corresponding titles (for selection UI)
  last_action_type?: 'search' | 'synthesis' | 'transform' | 'chat';
  // Pending task set when user must choose a specific document before we can act
  pending_context_task?: string;       // e.g. "summarize that" — applied after user picks a doc
}

export interface ChatSessionEnv {
  CHAT_SESSIONS: KVNamespace;
  GROQ_API_KEY: string;
}

// ============================================================================
// CONSTANTS
// ============================================================================

const SESSION_TIMEOUT_MS = 30 * 60 * 1000;  // 30 minutes inactivity = new session
const SESSION_TTL_SECONDS = 24 * 60 * 60;   // KV TTL: 24 hours
const MAX_MESSAGES = 20;                      // Cap conversation history
// Production-tier model; gpt-oss-20b is too weak for our Mode A/B prompt — use 120b for reliability
const GROQ_REWRITE_MODEL = "openai/gpt-oss-120b";

// ============================================================================
// SESSION MANAGEMENT
// ============================================================================

function getSessionKey(userId: string, clientSource?: string): string {
  const source = clientSource || 'unknown';
  return `chat_session:${userId}:${source}`;
}

/**
 * Load the current chat session for a user.
 * Returns null if no session exists or if the session has timed out.
 */
export async function loadChatSession(
  userId: string,
  env: ChatSessionEnv,
  clientSource?: string
): Promise<ChatSession | null> {
  const key = getSessionKey(userId, clientSource);
  const raw = await env.CHAT_SESSIONS.get(key);
  if (!raw) return null;

  try {
    const session: ChatSession = JSON.parse(raw);
    
    // Check if session has timed out (30 min inactivity)
    const now = Date.now();
    if (now - session.last_active > SESSION_TIMEOUT_MS) {
      // Session expired — delete it and return null
      await env.CHAT_SESSIONS.delete(key);
      return null;
    }

    // Backward compatibility: older KV records won't have all fields.
    session.active_result_note_ids = (session.active_result_note_ids || []).slice(0, 5);
    session.active_result_titles = session.active_result_titles || [];
    session.last_action_type = session.last_action_type || 'search';
    session.pending_context_task = session.pending_context_task || undefined;
    
    return session;
  } catch {
    // Corrupt data — delete and start fresh
    await env.CHAT_SESSIONS.delete(key);
    return null;
  }
}

/**
 * Delete (expire) a chat session immediately.
 */
export async function deleteChatSession(
  userId: string,
  env: ChatSessionEnv,
  clientSource?: string
): Promise<void> {
  const key = getSessionKey(userId, clientSource);
  await env.CHAT_SESSIONS.delete(key);
}

/**
 * Save the chat session to KV with TTL.
 */
export async function saveChatSession(
  session: ChatSession,
  env: ChatSessionEnv,
  clientSource?: string
): Promise<void> {
  const key = getSessionKey(session.user_id, clientSource);
  await env.CHAT_SESSIONS.put(key, JSON.stringify(session), {
    expirationTtl: SESSION_TTL_SECONDS,
  });
}

/**
 * Add a user message to the session (creates session if none exists).
 * Returns the updated session.
 */
export async function addUserMessage(
  userId: string,
  query: string,
  env: ChatSessionEnv,
  clientSource?: string
): Promise<ChatSession> {
  let session = await loadChatSession(userId, env, clientSource);
  
  const now = Date.now();
  
  if (!session) {
    // New session
    session = {
      user_id: userId,
      messages: [],
      created_at: now,
      last_active: now,
      active_result_note_ids: [],
      active_result_titles: [],
      last_action_type: 'search',
    };
  }
  
  // Add user message
  session.messages.push({
    role: 'user',
    content: query,
    timestamp: now,
  });
  
  // Cap message history
  if (session.messages.length > MAX_MESSAGES) {
    session.messages = session.messages.slice(-MAX_MESSAGES);
  }
  
  session.last_active = now;
  await saveChatSession(session, env, clientSource);
  
  return session;
}

/**
 * Add a bot response summary to the session.
 * Stores lightweight summary (titles + path), not the full answer.
 */
export async function addBotSummary(
  userId: string,
  titles: string[],
  pathTaken: string,
  resultCount: number,
  env: ChatSessionEnv,
  clientSource?: string,
  options?: {
    noteIds?: string[];
    actionType?: 'search' | 'synthesis' | 'transform' | 'chat';
    pendingContextTask?: string;   // set when bot asked user to pick a specific doc
    clearPendingTask?: boolean;    // clear pending task after successful context op
    preserveActiveSet?: boolean;   // when true, do NOT overwrite active_result_note_ids/titles
                                   // (used when a single doc was selected out of a larger
                                   //  working set — we want subsequent ordinals like "second one"
                                   //  to still resolve against the original list)
    lastFocusedNoteId?: string;    // optional: track the doc the user most recently focused on
  }
): Promise<void> {
  const session = await loadChatSession(userId, env, clientSource);
  if (!session) return;

  const summary = resultCount > 0
    ? `Found ${resultCount} result(s): ${titles.slice(0, 5).join(', ')}`
    : 'No results found';

  session.messages.push({
    role: 'assistant',
    content: summary,
    timestamp: Date.now(),
    titles,
    noteIds: (options?.noteIds || []).slice(0, 5),
    path_taken: pathTaken,
  });

  if (session.messages.length > MAX_MESSAGES) {
    session.messages = session.messages.slice(-MAX_MESSAGES);
  }

  // Cap note IDs to 5. When the caller has narrowed to a single doc out of a
  // larger working set (e.g. user said "first one"), pass preserveActiveSet=true
  // so we keep the original 4-doc list intact for follow-up ordinals.
  if (!options?.preserveActiveSet) {
    session.active_result_note_ids = (options?.noteIds || []).slice(0, 5);
    session.active_result_titles = titles.slice(0, 5);
  }
  session.last_action_type = options?.actionType || 'search';

  if (options?.clearPendingTask) {
    session.pending_context_task = undefined;
  } else if (options?.pendingContextTask) {
    session.pending_context_task = options.pendingContextTask;
  }

  session.last_active = Date.now();
  await saveChatSession(session, env, clientSource);
}

// ============================================================================
// QUERY REWRITING
// ============================================================================

/**
 * Build conversation context string from session history for the rewrite prompt.
 * Only includes the last few turns to keep the prompt small.
 */
function buildConversationContext(session: ChatSession): string {
  // Use last 6 messages (3 turns) for context
  const recent = session.messages.slice(-6);
  return recent.map(m => {
    if (m.role === 'user') return `User: ${m.content}`;
    return `Assistant: ${m.content}`;
  }).join('\n');
}

/**
 * Rewrite a follow-up query into a standalone query using conversation context.
 * Only called when there's prior conversation history.
 * 
 * Returns the rewritten query, or the original if rewriting fails/isn't needed.
 */
export async function rewriteQueryWithContext(
  currentQuery: string,
  session: ChatSession,
  env: ChatSessionEnv
): Promise<{ rewrittenQuery: string; wasRewritten: boolean; durationMs: number }> {
  const start = Date.now();
  
  // Only rewrite if there's at least 1 prior user message (current is already added)
  const priorMessages = session.messages.filter(m => m.role === 'user');
  if (priorMessages.length <= 1) {
    return { rewrittenQuery: currentQuery, wasRewritten: false, durationMs: 0 };
  }
  
  // Fast path: "list all" queries are standalone and should NOT be rewritten
  // These are complete queries meaning "show all documents" - not follow-ups
  const queryLower = currentQuery.toLowerCase().trim();
  const listAllPatterns = [
    /^show\s*(me\s*)?(all|everything|docs|documents|notes|files)?$/,
    /^list\s*(all|everything|my)?\s*(docs|documents|notes|files)?$/,
    /^(all|everything)$/,
    /^get\s*(all|everything|my)?\s*(docs|documents|notes|files)?$/,
    /^(my\s*)?(docs|documents|notes|files)$/,
  ];
  if (listAllPatterns.some(p => p.test(queryLower))) {
    console.log(`Query rewrite: skipping for list-all query "${currentQuery}"`);
    return { rewrittenQuery: currentQuery, wasRewritten: false, durationMs: Date.now() - start };
  }

  const conversationContext = buildConversationContext(session);

  const systemPrompt = `You are a query rewriter for a personal documents search assistant.

═══════════════════════════════════════════════════════════════════════
YOUR JOB — ONE DECISION
═══════════════════════════════════════════════════════════════════════
For the CURRENT QUERY, answer this question:

  "Would this query make sense ON ITS OWN to a stranger who has not seen
   any of the prior conversation?"

If YES → echo the query back, EXACTLY AS WRITTEN. Do not paraphrase.
If NO  → rewrite it so a stranger would understand it, by pulling the
         missing referent(s) from the most recent ASSISTANT turn.

That is the whole job. There is no checklist of trigger words. Reason
semantically about what the user is pointing at.

═══════════════════════════════════════════════════════════════════════
HOW TO RESOLVE A VAGUE REFERENCE
═══════════════════════════════════════════════════════════════════════
The user may refer back to earlier results in many ways — by position
("the first", "the second"), by property ("the long one", "the weird
manufacturing one", "the optimistic essay", "the earlier contract",
"the one about pricing"), by pronoun ("it", "them", "that"), or by a
bare verb that implies an operation on the prior list ("explain",
"summarize", "compare them", "each one").

To rewrite:
  1. Read the ASSISTANT's most recent turn and identify the document
     titles / topics it presented.
  2. Pick the title(s) that best fit what the user is pointing at.
     - "the first" / "the second" → position in the list
     - descriptive phrases → the single title that best matches the
       description (by topic, length, tone, date, etc.)
     - plural references ("each one", "all of them", "compare them")
       → list ALL the titles, joined by commas
  3. Substitute the chosen title(s) into the user's query.

If nothing in the prior turn plausibly fits, return the query unchanged
rather than inventing a topic. Never fabricate titles that were not in
the assistant's last turn.

═══════════════════════════════════════════════════════════════════════
SPECIAL CASE — RETRY
═══════════════════════════════════════════════════════════════════════
If the user is expressing dissatisfaction with the previous results and
asking for a re-run ("try again", "retry", "again", "search again",
"not what I wanted", "wrong results", "that's not it", "something else",
or any phrase semantically equivalent), OUTPUT the user's most recent
PRIOR query verbatim. This is how they ask to re-run the last search.

═══════════════════════════════════════════════════════════════════════
OUTPUT RULES (STRICT)
═══════════════════════════════════════════════════════════════════════
- One line of plain text. No quotes, no prefix, no explanation, no markdown.
- Under 30 words.
- Never invent titles or topics not present in the conversation above.
- When in doubt between rewriting and echoing → echo.

═══════════════════════════════════════════════════════════════════════
CONVERSATION (most recent at the bottom)
═══════════════════════════════════════════════════════════════════════
${conversationContext}

═══════════════════════════════════════════════════════════════════════
EXAMPLES (illustrative — apply the principle, not the literal pattern)
═══════════════════════════════════════════════════════════════════════

Conversation:
  User: aadhaar documents
  Assistant: Found 3 results: Aadhaar Card, KYC Form, Address Proof
  User: tell me more about the first one
Output: tell me more about Aadhaar Card

Conversation:
  User: fabrication
  Assistant: Found 4 results: Steel Fab Quote, Welding Guide, Sheet Metal Notes, Vendor List
  User: explain each one
Output: explain Steel Fab Quote, Welding Guide, Sheet Metal Notes, Vendor List

Conversation:
  User: invoices
  Assistant: Found 3 results: ACME-12k, Globex-2k, Initech-87k
  User: the weird one
Output: Initech-87k

Conversation:
  User: contracts
  Assistant: Found 2 results: NDA-2024, MSA-2023
  User: the earlier contract
Output: MSA-2023

Conversation:
  User: ai pricing
  Assistant: Found 2 results: Optimizing Groq Pricing for OpenAI GPT-OSS, Anthropic Rate Limits Overview
  User: the one about pricing
Output: Optimizing Groq Pricing for OpenAI GPT-OSS

Conversation:
  User: essays
  Assistant: Found 3 results: Why I'm Worried About AI, The Case for Optimism, Notes on Stoicism
  User: the optimistic one
Output: The Case for Optimism

Conversation:
  User: machine learning notes
  Assistant: Found 5 results.
  User: try again
Output: machine learning notes

Conversation:
  User: tax receipts
  Assistant: Found 0 results.
  User: not what I wanted
Output: tax receipts

Conversation:
  User: show webpages from march
  Assistant: Found 2 results.
  User: show images from march
Output: show images from march

Conversation:
  User: machine learning notes
  Assistant: Found 4 results.
  User: 🔥🎉💻🚀🤖
Output: 🔥🎉💻🚀🤖

Conversation:
  (no prior turns)
  User: explain
Output: explain

═══════════════════════════════════════════════════════════════════════
CURRENT QUERY
═══════════════════════════════════════════════════════════════════════
${currentQuery}`;

  try {
    const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${env.GROQ_API_KEY}`,
      },
      body: JSON.stringify({
        model: GROQ_REWRITE_MODEL,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: currentQuery },
        ],
        temperature: 0.1,
        max_tokens: 256,
      }),
    });

    if (!response.ok) {
      console.error(`Query rewrite Groq error: ${response.status}`);
      return { rewrittenQuery: currentQuery, wasRewritten: false, durationMs: Date.now() - start };
    }

    const data = await response.json() as { choices: Array<{ message: { content: string } }> };
    let rewritten = data.choices[0]?.message?.content?.trim();
    
    if (!rewritten || rewritten.length === 0) {
      return { rewrittenQuery: currentQuery, wasRewritten: false, durationMs: Date.now() - start };
    }
    
    // Strip <think> tags (safety net for qwen3), quotes, and any echoed control tokens
    rewritten = rewritten.replace(/<think>[\s\S]*?<\/think>/g, '').trim();
    rewritten = rewritten.replace(/\/no_think/gi, '').trim();
    rewritten = rewritten.replace(/^["']|["']$/g, '').trim();
    // Collapse multiple blank lines / take first line only (rewrite should be a single short query)
    rewritten = rewritten.split(/\r?\n/).map(s => s.trim()).filter(Boolean)[0] || '';
    
    const durationMs = Date.now() - start;
    const wasRewritten = rewritten.toLowerCase() !== currentQuery.toLowerCase();
    
    console.log(`Query rewrite: "${currentQuery}" → "${rewritten}" (${wasRewritten ? 'rewritten' : 'unchanged'}, ${durationMs}ms)`);
    
    return { rewrittenQuery: rewritten, wasRewritten, durationMs };
  } catch (error) {
    console.error('Query rewrite failed:', error);
    return { rewrittenQuery: currentQuery, wasRewritten: false, durationMs: Date.now() - start };
  }
}
