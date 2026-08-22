// agent/tools/summarize_many.ts
// ===========================================================================
// Phase 5 — map-reduce summarize.
//
// Fetch up to MAX_NOTES notes that match a topic+window, batch them in groups
// of BATCH_SIZE, summarize each batch with the 8B model (parallel "map"),
// then merge the batch summaries with the 70B model ("reduce").
//
// Output shape mirrors compare_two_sets so the handler can surface a few
// representative notes as result cards in the UI.
// ===========================================================================

import type { ToolContext, TimeWindow } from '../types';
import { resolveTimeWindow } from '../time_window';

const GROQ_8B = 'llama-3.1-8b-instant';
const GROQ_70B = 'llama-3.3-70b-versatile';
const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';

const MAX_NOTES = 100;
const BATCH_SIZE = 8;
const PREVIEW_CHARS = 800;

export interface SummarizeManyInput {
  topic: string;
  window: TimeWindow;
  /** Hard cap on rows fetched. Default 100. */
  limit?: number;
}

export interface SummarizeNote {
  note_id: string;
  title: string;
  content_preview: string;
  created_at: string;
  tag?: string;
  file_type?: string;
}

export interface SummarizeManyOutput {
  answer: string;
  notes_count: number;
  batches: number;
  duration_ms: number;
  notes: SummarizeNote[];
  /** Per-batch micro-summaries (for trace inspection). */
  batch_summaries: string[];
}

/**
 * Fetch matching notes, then run a map-reduce summarize.
 */
export async function runSummarizeMany(
  input: SummarizeManyInput,
  ctx: ToolContext,
): Promise<SummarizeManyOutput> {
  const t0 = Date.now();
  const { env } = ctx;
  const userId = ctx.scratchpad.user_id;
  const limit = Math.min(Math.max(input.limit ?? MAX_NOTES, 1), MAX_NOTES);

  // ---- 1) Fetch notes -----------------------------------------------------
  const notes = await fetchNotes(env, userId, input.topic, input.window, limit);
  const tr = resolveTimeWindow(input.window);
  const windowLabel = tr?.label ?? 'all time';
  const topicLabel = input.topic && input.topic.length >= 2 ? input.topic : null;

  if (notes.length === 0) {
    const scopePhrase = topicLabel
      ? `notes about **${topicLabel}** in ${windowLabel}`
      : `notes in ${windowLabel}`;
    return {
      answer: `I couldn't find any ${scopePhrase}. Try a different topic or time range.`,
      notes_count: 0,
      batches: 0,
      duration_ms: Date.now() - t0,
      notes: [],
      batch_summaries: [],
    };
  }

  // ---- 2) Single-shot path for small N -----------------------------------
  if (notes.length <= BATCH_SIZE) {
    const single = await summarizeBatch(env, notes, topicLabel, windowLabel, GROQ_70B, true);
    return {
      answer: single,
      notes_count: notes.length,
      batches: 1,
      duration_ms: Date.now() - t0,
      notes,
      batch_summaries: [single],
    };
  }

  // ---- 3) MAP: chunk + summarize each batch with 8B in parallel ----------
  const batches: SummarizeNote[][] = [];
  for (let i = 0; i < notes.length; i += BATCH_SIZE) {
    batches.push(notes.slice(i, i + BATCH_SIZE));
  }

  const batchSummaries = await Promise.all(
    batches.map((batch, i) =>
      summarizeBatch(env, batch, topicLabel, windowLabel, GROQ_8B, false, i + 1, batches.length),
    ),
  );

  // ---- 4) REDUCE: merge with 70B -----------------------------------------
  const merged = await reduceSummaries(env, batchSummaries, topicLabel, windowLabel, notes.length);

  return {
    answer: merged,
    notes_count: notes.length,
    batches: batches.length,
    duration_ms: Date.now() - t0,
    notes,
    batch_summaries: batchSummaries,
  };
}

// ---------------------------------------------------------------------------
// Note fetcher (PostgREST).
// ---------------------------------------------------------------------------
async function fetchNotes(
  env: ToolContext['env'],
  userId: string,
  topic: string,
  window: TimeWindow,
  limit: number,
): Promise<SummarizeNote[]> {
  const tr = resolveTimeWindow(window);
  const params = new URLSearchParams();
  params.set('user_id', `eq.${userId}`);
  params.append('status', 'neq.deleted');
  if (tr) {
    params.append('created_at', `gte.${tr.gte}`);
    if (tr.lt) params.append('created_at', `lt.${tr.lt}`);
  }
  params.set('select', 'id,title,content_markdown,description,tag,file_type,created_at');
  params.set('order', 'created_at.desc');
  params.set('limit', String(limit));

  let url = `${env.SUPABASE_URL}/rest/v1/notes?${params.toString()}`;
  const trimmedTopic = (topic || '').trim();
  if (trimmedTopic.length >= 2) {
    const safeTopic = trimmedTopic.replace(/[%_]/g, '\\$&');
    const pattern = `*${safeTopic}*`;
    url += `&or=(title.ilike.${pattern},content_markdown.ilike.${pattern},description.ilike.${pattern})`;
  }

  const resp = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    },
  });
  if (!resp.ok) {
    throw new Error(`summarize_many fetch failed: ${resp.status} ${await resp.text()}`);
  }
  const rows: any[] = await resp.json();
  return rows.map(r => {
    const body =
      (r.content_markdown && r.content_markdown.toString()) ||
      (r.description && r.description.toString()) ||
      '';
    return {
      note_id: r.id,
      title: (r.title || '').toString(),
      content_preview: body.slice(0, PREVIEW_CHARS),
      created_at: r.created_at,
      tag: r.tag,
      file_type: r.file_type,
    };
  });
}

// ---------------------------------------------------------------------------
// Per-batch summarize (MAP step) — also reused for the small-N single shot.
// ---------------------------------------------------------------------------
async function summarizeBatch(
  env: ToolContext['env'],
  notes: SummarizeNote[],
  topicLabel: string | null,
  windowLabel: string,
  model: string,
  finalShape: boolean,
  batchIndex?: number,
  batchTotal?: number,
): Promise<string> {
  const lines = notes.map((n, i) => {
    const date = (n.created_at || '').slice(0, 10);
    const title = (n.title || '(untitled)').slice(0, 120);
    const body = (n.content_preview || '').replace(/\s+/g, ' ').trim().slice(0, PREVIEW_CHARS);
    return `[${i + 1}] (${date}) ${title}\n    ${body}`;
  });

  const scope = topicLabel
    ? `notes about **${topicLabel}** from ${windowLabel}`
    : `notes from ${windowLabel}`;

  const userPrompt = finalShape
    ? `Summarize these ${notes.length} of the user's ${scope}.

${lines.join('\n')}

Write the summary using this exact structure:

**Key themes:** 3-5 bullets covering the main topics or recurring ideas, grounded in the notes.

**Notable items:** 2-4 specific things worth calling out (a particularly interesting note, a surprising find, a strong opinion, etc.). Cite note titles in *italics* when relevant.

**Bottom line:** one short sentence capturing the overall shape of what the user has been saving.

Stay grounded in the provided notes. No filler, no apologies. Never invent facts not in the notes.`
    : `You are summarizing batch ${batchIndex} of ${batchTotal} of the user's ${scope}.

${lines.join('\n')}

Output a tight summary in 4-7 sentences (or 4-7 bullets) covering:
- the main topics in this batch,
- any notable specifics (titles, names, claims) worth preserving,
- the overall flavor of what was saved.

Stay grounded in the notes. Don't invent. Don't apologize. Don't preface with "this batch contains" — get straight to content.`;

  const resp = await fetch(GROQ_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${env.GROQ_API_KEY}`,
    },
    body: JSON.stringify({
      model,
      messages: [
        {
          role: 'system',
          content:
            "You are a careful analyst summarizing a user's personal notes. " +
            'Stay grounded in the provided notes. Never invent facts. ' +
            'Be concrete: prefer specific topics and titles over vague generalities.',
        },
        { role: 'user', content: userPrompt },
      ],
      temperature: 0.2,
      max_tokens: finalShape ? 800 : 350,
    }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`Groq summarize batch failed (${model}): ${resp.status} ${errText.slice(0, 200)}`);
  }
  const data: any = await resp.json();
  return (data.choices?.[0]?.message?.content || '').trim();
}

// ---------------------------------------------------------------------------
// Merge step (REDUCE) — collapse N batch summaries into one final answer.
// ---------------------------------------------------------------------------
async function reduceSummaries(
  env: ToolContext['env'],
  batchSummaries: string[],
  topicLabel: string | null,
  windowLabel: string,
  totalNotes: number,
): Promise<string> {
  const scope = topicLabel
    ? `notes about **${topicLabel}** from ${windowLabel}`
    : `notes from ${windowLabel}`;

  const numbered = batchSummaries
    .map((s, i) => `=== Batch ${i + 1} summary ===\n${s.trim()}`)
    .join('\n\n');

  const userPrompt = `You're synthesizing per-batch summaries of ${totalNotes} of the user's ${scope}.

${numbered}

Merge these into ONE coherent summary. Don't list them by batch — group ideas across batches by theme. Use this exact structure:

**Key themes:** 3-6 bullets covering the dominant topics across all batches.

**Notable items:** 3-5 specific things worth calling out (interesting notes, recurring names, strong takes). Cite note titles in *italics* when relevant.

**Bottom line:** one short sentence capturing the overall shape of what the user has been saving across the whole set.

Rules:
- Stay grounded in the per-batch summaries — don't invent new facts.
- If different batches contradict each other, surface that explicitly.
- No filler, no apologies, no meta-commentary about the batches.`;

  const resp = await fetch(GROQ_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${env.GROQ_API_KEY}`,
    },
    body: JSON.stringify({
      model: GROQ_70B,
      messages: [
        {
          role: 'system',
          content:
            "You are a careful analyst merging multiple partial summaries into one. " +
            'Stay grounded. Never invent facts not present in the partial summaries.',
        },
        { role: 'user', content: userPrompt },
      ],
      temperature: 0.2,
      max_tokens: 900,
    }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`Groq summarize reduce failed: ${resp.status} ${errText.slice(0, 200)}`);
  }
  const data: any = await resp.json();
  return (data.choices?.[0]?.message?.content || '').trim();
}
