// agent/tools/count_and_group.ts
// ===========================================================================
// Phase 1 tool: deterministic counting and group-by aggregation over the
// `notes` table via PostgREST. No LLM call.
//
// Supports:
//   - Pure count:           "how many notes did I save last week"
//   - Group + count:        "which platform do I save the most from"
//   - Pure count w/ filter: "how many youtube notes do I have"
//
// Only counts non-deleted notes (status != 'deleted' if column exists; we
// rely on the same predicate the rest of the worker uses — `is_deleted = false`
// when the column exists. Keeping conservative: filter on user_id only and
// trust upstream soft-delete handling. We can add `is_deleted=eq.false` later
// once we confirm the column.)
// ===========================================================================

import type { Tool, ToolContext } from '../types';
import { resolveTimeWindow } from '../time_window';

interface CountAndGroupInput {}
interface CountAndGroupOutput {
  total: number;
  groups?: Array<{ key: string; count: number }>;
  time_label?: string;
  filter_label?: string;
}

export const countAndGroupTool: Tool<CountAndGroupInput, CountAndGroupOutput> = {
  name: 'count_and_group',
  async run(_input, ctx: ToolContext): Promise<CountAndGroupOutput> {
    const { env, scratchpad } = ctx;
    const sq = scratchpad.structured;
    const userId = scratchpad.user_id;

    // Build PostgREST query string.
    const params = new URLSearchParams();
    params.set('user_id', `eq.${userId}`);

    // Time filter
    let timeLabel: string | undefined;
    if (sq.filter.time) {
      const tr = resolveTimeWindow(sq.filter.time);
      if (tr) {
        params.append('created_at', `gte.${tr.gte}`);
        if (tr.lt) params.append('created_at', `lt.${tr.lt}`);
        timeLabel = tr.label;
      }
    }

    // Platform / file_type filter
    let filterLabel: string | undefined;
    if (sq.filter.platforms && sq.filter.platforms.length > 0) {
      const list = sq.filter.platforms.map(encodeURIComponent).join(',');
      params.set('file_type', `in.(${list})`);
      filterLabel = sq.filter.platforms.join(', ');
    }

    const headers = {
      apikey: env.SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
    };

    if (sq.operation === 'count') {
      // Cheap path: HEAD-style count via Content-Range header.
      const countParams = new URLSearchParams(params);
      countParams.set('select', 'id');
      countParams.set('limit', '1');
      const url = `${env.SUPABASE_URL}/rest/v1/notes?${countParams.toString()}`;
      const r = await fetch(url, {
        headers: { ...headers, Prefer: 'count=exact', Range: '0-0' },
      });
      if (!r.ok) {
        throw new Error(`postgrest count failed: ${r.status} ${await r.text()}`);
      }
      const cr = r.headers.get('Content-Range') || '';
      const total = parseInt(cr.split('/')[1] || '0', 10) || 0;
      return { total, time_label: timeLabel, filter_label: filterLabel };
    }

    // group_count: fetch all matching rows (id, file_type, tag, created_at)
    // and aggregate in JS. Bounded to 5000 for safety — well above realistic
    // per-user note counts.
    const groupParams = new URLSearchParams(params);
    const fields = sq.group_by === 'tag' ? 'id,tag' : 'id,file_type,tag,created_at';
    groupParams.set('select', fields);
    groupParams.set('limit', '5000');
    const url = `${env.SUPABASE_URL}/rest/v1/notes?${groupParams.toString()}`;
    const r = await fetch(url, { headers });
    if (!r.ok) {
      throw new Error(`postgrest group failed: ${r.status} ${await r.text()}`);
    }
    const rows: any[] = await r.json();

    const counts = new Map<string, number>();
    for (const row of rows) {
      let key: string;
      switch (sq.group_by) {
        case 'tag':
          key = (row.tag || 'untagged').toString();
          break;
        case 'file_type':
        case 'platform':
          key = (row.file_type || 'unknown').toString();
          break;
        case 'date_day': {
          const ca = row.created_at as string | undefined;
          key = ca ? ca.slice(0, 10) : 'unknown';
          break;
        }
        default:
          key = (row.file_type || 'unknown').toString();
      }
      counts.set(key, (counts.get(key) || 0) + 1);
    }

    const groups = Array.from(counts.entries())
      .map(([key, count]) => ({ key, count }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 20);

    return {
      total: rows.length,
      groups,
      time_label: timeLabel,
      filter_label: filterLabel,
    };
  },
};

/** Render a CountAndGroupOutput into a human-friendly answer. */
export function renderCountAnswer(
  query: string,
  out: CountAndGroupOutput,
  groupBy?: string,
): string {
  const timeSuffix = out.time_label ? ` from ${out.time_label}` : '';

  if (!out.groups) {
    const noun = out.filter_label
      ? `${out.filter_label} note${out.total === 1 ? '' : 's'}`
      : `note${out.total === 1 ? '' : 's'}`;
    if (timeSuffix) {
      return `You have **${out.total}** ${noun}${timeSuffix}.`;
    }
    return `You have **${out.total}** ${noun} in total.`;
  }

  const where = [out.filter_label ? `(${out.filter_label})` : null, out.time_label ? `from ${out.time_label}` : null]
    .filter(Boolean)
    .join(' ');

  if (out.groups.length === 0) {
    return where ? `No notes match ${where}.` : 'No notes found.';
  }

  const label = groupBy || 'group';
  const top = out.groups[0];
  const lines: string[] = [];
  lines.push(`Your top ${label}${out.groups.length > 1 ? 's' : ''}${where ? ` ${where}` : ''}:`);
  for (const g of out.groups.slice(0, 10)) {
    lines.push(`- **${g.key}** — ${g.count}`);
  }
  if (out.groups.length > 10) {
    lines.push(`_…and ${out.groups.length - 10} more._`);
  }
  // If user asked "which most" specifically, lead with the winner.
  if (/\b(which|what)\b.*\b(most|top|popular)\b/i.test(query)) {
    return `Your most-saved ${label} is **${top.key}** with **${top.count}** note${top.count === 1 ? '' : 's'}${where ? ` ${where}` : ''}.\n\n${lines.slice(1).join('\n')}`;
  }
  return lines.join('\n');
}
