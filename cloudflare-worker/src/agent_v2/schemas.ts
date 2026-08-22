// agent_v2/schemas.ts
// ===========================================================================
// Zod schemas for the v2 agent's tool catalog.
//
// One source of truth — the same Zod object is:
//   1) converted to JSON Schema and shipped to Groq as `tools[].parameters`
//   2) used to validate `tool_calls[].arguments` locally (`safeParse`)
//   3) used to derive TypeScript argument types via `z.infer<>`
//
// If the planner returns invalid args, the tool runner returns a structured
// error message back to the planner so it can self-correct.
// ===========================================================================

import { z } from 'zod';
import { zodToJsonSchema } from 'zod-to-json-schema';

// ---------------------------------------------------------------------------
// Shared enums
// ---------------------------------------------------------------------------

export const TimeWindowEnum = z.enum([
  'today',
  'yesterday',
  'this_week',
  'last_week',
  'this_month',
  'last_month',
  'last_7d',
  'last_30d',
  'last_90d',
  'last_180d',
  'all_time',
]);

export const FileTypeEnum = z.enum([
  'linkedin',
  'twitter',
  'instagram',
  'youtube',
  'reddit',
  'facebook',
  'webpage',
  'uploaded_file',
  'quick_note',
  'image',
  'pdf',
  'article',
]);

// ---------------------------------------------------------------------------
// 1. list_notes — hard SQL filter, returns rows
// ---------------------------------------------------------------------------
export const ListNotesArgs = z.object({
  file_types: z.array(FileTypeEnum).optional()
    .describe('Filter by note file_type. e.g. ["linkedin","twitter"]. Omit to include all types.'),
  time_window: TimeWindowEnum.optional()
    .describe('Filter by created_at window. Omit for all-time.'),
  tags: z.array(z.string()).optional()
    .describe('Filter by user-applied tag values.'),
  topic: z.string().min(2).optional()
    .describe('Free-text keyword (>=2 chars) that must appear in title/content/description. Use this for "about X" filters.'),
  limit: z.number().int().min(1).max(100).default(25),
});
export type ListNotesArgs = z.infer<typeof ListNotesArgs>;

// ---------------------------------------------------------------------------
// 2. count_notes — returns counts, optionally grouped
// ---------------------------------------------------------------------------
export const CountNotesArgs = z.object({
  file_types: z.array(FileTypeEnum).optional(),
  time_window: TimeWindowEnum.optional(),
  tags: z.array(z.string()).optional(),
  group_by: z.enum(['file_type', 'tag', 'date_day']).optional()
    .describe('If set, return per-group counts instead of just a total.'),
});
export type CountNotesArgs = z.infer<typeof CountNotesArgs>;

// ---------------------------------------------------------------------------
// 3. vector_search — semantic / hybrid search via classic rag pipeline
// ---------------------------------------------------------------------------
export const VectorSearchArgs = z.object({
  query: z.string().min(1).max(500)
    .describe('Natural-language search query for semantic + keyword retrieval.'),
  // Discovery searches need enough completed results for the client to show
  // the first 10 and a local Browse More page. The previous implicit default
  // of 8 made that impossible whenever the planner omitted `k`.
  k: z.number().int().min(1).max(20).default(20)
    .describe('Maximum number of ranked discovery results to retrieve. Default 20 supports a first page of 10 plus Browse More.'),
  exclude_note_ids: z.array(z.string()).optional()
    .describe('Note ids to exclude (e.g. for "search deeper" follow-ups).'),
});
export type VectorSearchArgs = z.infer<typeof VectorSearchArgs>;

// ---------------------------------------------------------------------------
// 4. fetch_note — full note by id
// ---------------------------------------------------------------------------
export const FetchNoteArgs = z.object({
  note_id: z.string().uuid()
    .describe('UUID of the note. MUST come from a prior tool result or prior assistant turn — never invent or guess.'),
});
export type FetchNoteArgs = z.infer<typeof FetchNoteArgs>;

// ---------------------------------------------------------------------------
// 5. summarize — map-reduce summary over a set of notes
// ---------------------------------------------------------------------------
export const SummarizeArgs = z.object({
  note_ids: z.array(z.string().uuid()).min(1).optional()
    .describe('Specific note ids to summarize. Use for "summarize those / these / the previous ones". Ids must come from a prior tool result.'),
  topic: z.string().min(2).optional()
    .describe('Topic keyword (>=2 chars). Used when note_ids is not provided to fetch matching notes first.'),
  time_window: TimeWindowEnum.optional()
    .describe('Time window for fetching notes (used with topic).'),
  file_types: z.array(FileTypeEnum).optional(),
  limit: z.number().int().min(1).max(100).default(50),
}).refine(
  v => (v.note_ids && v.note_ids.length > 0) || (v.topic && v.topic.length >= 2),
  { message: 'summarize requires either note_ids (non-empty) OR topic (>=2 chars). Run list_notes/vector_search first if you have neither.' },
);
export type SummarizeArgs = z.infer<typeof SummarizeArgs>;

// ---------------------------------------------------------------------------
// 6. ask_user — request clarification, ends the loop
// ---------------------------------------------------------------------------
export const AskUserArgs = z.object({
  question: z.string().min(1).max(500)
    .describe('A short clarifying question to ask the user.'),
  options: z.array(z.string()).optional()
    .describe('Optional suggested choices for the user.'),
});
export type AskUserArgs = z.infer<typeof AskUserArgs>;

// ---------------------------------------------------------------------------
// Tool descriptors — what we ship to Groq as `tools[]`
// ---------------------------------------------------------------------------
export interface ToolDescriptor {
  name: string;
  description: string;
  parameters: z.ZodTypeAny;
}

export const TOOL_DESCRIPTORS: ToolDescriptor[] = [
  {
    name: 'list_notes',
    description:
      'List the user\'s saved notes that match HARD filters (file_type, tag, time_window, topic keyword). ' +
      'Use for "show / find / list my X" queries when filters are clear. ' +
      'Returns array of {note_id, title, file_type, tag, created_at}.',
    parameters: ListNotesArgs,
  },
  {
    name: 'count_notes',
    description:
      'Count notes matching filters. Set group_by for breakdowns ("which platform do I save most from" → group_by:"file_type"). ' +
      'Returns {total} or {total, groups:[{key,count}]}. No content; for content use list_notes.',
    parameters: CountNotesArgs,
  },
  {
    name: 'vector_search',
    description:
      'Semantic + keyword hybrid search over the user\'s notes. Use ONLY for open-ended fuzzy questions where ' +
      'list_notes filters are not enough (e.g. "what did I save about productivity"). ' +
      'Slower than list_notes — prefer list_notes when the user gives concrete filters. Requires a non-empty `query` string.',
    parameters: VectorSearchArgs,
  },
  {
    name: 'fetch_note',
    description:
      'Fetch the full content of a single note by UUID. Use for "the 2nd one", "open that note", "show me details of <title>". ' +
      'CRITICAL: note_id MUST be a real UUID seen in a previous tool result or prior assistant turn. NEVER invent ids.',
    parameters: FetchNoteArgs,
  },
  {
    name: 'summarize',
    description:
      'Map-reduce summary across many notes. Two ways to call:\n' +
      ' (a) {note_ids: [...]}    — for "summarize those / these results". Ids MUST come from a prior tool result.\n' +
      ' (b) {topic, time_window} — for "summarize my notes about X this month". Fetches matching notes then summarizes.\n' +
      'NEVER call with both empty — you will get an error. If unsure, run list_notes or vector_search first to get ids.',
    parameters: SummarizeArgs,
  },
  {
    name: 'ask_user',
    description:
      'Ask a clarifying question. Use ONLY when the request is truly ambiguous and a sensible default cannot be chosen. ' +
      'Prefer making an assumption and proceeding. This ends the loop.',
    parameters: AskUserArgs,
  },
];

/** Build the OpenAI/Groq-format tools[] array from descriptors. */
export function buildGroqTools() {
  return TOOL_DESCRIPTORS.map(t => ({
    type: 'function' as const,
    function: {
      name: t.name,
      description: t.description,
      parameters: zodToJsonSchema(t.parameters, { target: 'openApi3' }) as Record<string, unknown>,
    },
  }));
}

/** Validate a tool call's arguments. Returns parsed value or an error string. */
export function validateToolArgs(
  name: string,
  rawArgs: unknown,
): { ok: true; value: any } | { ok: false; error: string } {
  const desc = TOOL_DESCRIPTORS.find(t => t.name === name);
  if (!desc) return { ok: false, error: `unknown tool "${name}"` };
  const parsed = desc.parameters.safeParse(rawArgs);
  if (!parsed.success) {
    return {
      ok: false,
      error: `invalid arguments for ${name}: ${JSON.stringify(parsed.error.issues)}`,
    };
  }
  return { ok: true, value: parsed.data };
}
