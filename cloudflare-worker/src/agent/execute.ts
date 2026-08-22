// agent/execute.ts
// ===========================================================================
// Minimal sequential recipe executor (Phase 4).
//
// A Recipe is just an ordered list of steps. The executor runs them one
// after another, threads outputs by name through a shared bag, and records
// timing in the scratchpad. No DAG, no retries, no parallelism — those come
// in later phases when we actually need them.
// ===========================================================================

import type { Scratchpad, ToolContext } from './types';

export interface RecipeStep<TIn = any, TOut = any> {
  /** Step label for traces. */
  name: string;
  /** Build the step input from the bag of named outputs from prior steps. */
  input: (bag: Record<string, any>) => TIn;
  /** The work. Receives the step input and the shared ToolContext. */
  run: (input: TIn, ctx: ToolContext) => Promise<TOut>;
  /** Key under which to store this step's output in the bag. Defaults to `name`. */
  output_key?: string;
}

export interface ExecuteResult {
  bag: Record<string, any>;
  steps: Array<{ name: string; ms: number; ok: boolean; note?: string }>;
  total_ms: number;
}

export async function executeRecipe(
  recipe: RecipeStep[],
  ctx: ToolContext,
): Promise<ExecuteResult> {
  const bag: Record<string, any> = {};
  const steps: ExecuteResult['steps'] = [];
  const t0 = Date.now();

  for (const step of recipe) {
    const stepStart = Date.now();
    const key = step.output_key || step.name;
    try {
      const inp = step.input(bag);
      const out = await step.run(inp, ctx);
      bag[key] = out;
      const entry = { name: step.name, ms: Date.now() - stepStart, ok: true };
      steps.push(entry);
      pushScratchpadStep(ctx.scratchpad, entry);
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : String(err);
      const entry = { name: step.name, ms: Date.now() - stepStart, ok: false, note: errorMessage };
      steps.push(entry);
      pushScratchpadStep(ctx.scratchpad, entry);
      // Re-throw so the handler can record the trace and surface the error.
      throw err;
    }
  }

  return { bag, steps, total_ms: Date.now() - t0 };
}

function pushScratchpadStep(
  sp: Scratchpad,
  entry: { name: string; ms: number; ok: boolean; note?: string },
): void {
  sp.steps.push({ tool: entry.name, ms: entry.ms, ok: entry.ok, note: entry.note });
}
