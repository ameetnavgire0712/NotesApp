// agent/tools/compare_two_sets.ts
// ===========================================================================
// Phase 4 synthesis: take two BucketFilterOutputs and produce a side-by-side
// comparison via Groq 70B. Single LLM call.
// ===========================================================================

import type { ToolContext } from '../types';
import type { BucketFilterOutput, BucketNote } from './bucket_filter';

const GROQ_70B = 'llama-3.3-70b-versatile';
const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';

export interface CompareInput {
  topic: string;
  bucket_a: BucketFilterOutput;
  bucket_b: BucketFilterOutput;
  /** Human-readable labels for the two windows, e.g. "last month" / "this month". */
  label_a: string;
  label_b: string;
}

export interface CompareOutput {
  answer: string;
  used_a: number;
  used_b: number;
  duration_ms: number;
}

const MAX_NOTES_PER_SIDE = 10;
const MAX_PREVIEW_CHARS = 400;

export async function runCompareTwoSets(
  input: CompareInput,
  ctx: ToolContext,
): Promise<CompareOutput> {
  const t0 = Date.now();
  const { env } = ctx;

  const aNotes = input.bucket_a.notes.slice(0, MAX_NOTES_PER_SIDE);
  const bNotes = input.bucket_b.notes.slice(0, MAX_NOTES_PER_SIDE);
  const topicLabel = input.topic && input.topic.length >= 2 ? input.topic : 'your saved notes';

  // If both buckets empty, short-circuit — no point calling the LLM.
  if (aNotes.length === 0 && bNotes.length === 0) {
    return {
      answer: `I couldn't find any notes about **${topicLabel}** in either ${input.label_a} or ${input.label_b}. Try a different topic or time range.`,
      used_a: 0,
      used_b: 0,
      duration_ms: Date.now() - t0,
    };
  }

  if (aNotes.length === 0) {
    return {
      answer: `I have no notes about **${topicLabel}** from ${input.label_a}, but I found ${bNotes.length} from ${input.label_b}. Save more from ${input.label_a} to make a meaningful comparison.`,
      used_a: 0,
      used_b: bNotes.length,
      duration_ms: Date.now() - t0,
    };
  }
  if (bNotes.length === 0) {
    return {
      answer: `I have no notes about **${topicLabel}** from ${input.label_b}, but I found ${aNotes.length} from ${input.label_a}. Save more from ${input.label_b} to make a meaningful comparison.`,
      used_a: aNotes.length,
      used_b: 0,
      duration_ms: Date.now() - t0,
    };
  }

  const prompt = buildPrompt(topicLabel, input.label_a, aNotes, input.label_b, bNotes);

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
            "You are a careful analyst comparing two sets of a user's personal notes. " +
            'Stay grounded in the provided notes. If a side has no relevant content for a theme, say so explicitly. ' +
            'Never invent facts that are not in the notes.',
        },
        { role: 'user', content: prompt },
      ],
      temperature: 0.2,
      max_tokens: 700,
    }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    throw new Error(`Groq compare call failed: ${resp.status} ${errText.slice(0, 200)}`);
  }

  const data: any = await resp.json();
  const answer = data.choices?.[0]?.message?.content?.trim() || '';

  return {
    answer: answer || `(No comparison output produced for **${input.topic}**.)`,
    used_a: aNotes.length,
    used_b: bNotes.length,
    duration_ms: Date.now() - t0,
  };
}

function buildPrompt(
  topic: string,
  labelA: string,
  notesA: BucketNote[],
  labelB: string,
  notesB: BucketNote[],
): string {
  const renderNotes = (notes: BucketNote[]) =>
    notes
      .map((n, i) => {
        const date = (n.created_at || '').slice(0, 10);
        const title = (n.title || '(untitled)').slice(0, 120);
        const body = (n.content_preview || '').replace(/\s+/g, ' ').trim().slice(0, MAX_PREVIEW_CHARS);
        return `[${i + 1}] (${date}) ${title}\n    ${body}`;
      })
      .join('\n');

  return `Topic: ${topic}

Compare these two sets of the user's notes side-by-side. Surface what changed, what stayed the same, and any new directions in the more recent set.

=== SET A — ${labelA} (${notesA.length} notes) ===
${renderNotes(notesA)}

=== SET B — ${labelB} (${notesB.length} notes) ===
${renderNotes(notesB)}

Write the comparison using this exact structure:

**Themes in ${labelA}:** 2-4 bullets, grounded in SET A.

**Themes in ${labelB}:** 2-4 bullets, grounded in SET B.

**What changed:** 2-4 bullets describing concrete differences (new topics, abandoned ones, shifts in framing, deeper dives, etc.). Cite note titles in *italics* when relevant.

**Bottom line:** one short sentence summarizing the most interesting shift.

Keep it tight. No filler, no apologies.`;
}
