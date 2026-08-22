// agent/time_window.ts
// ===========================================================================
// Maps a TimeWindow keyword to an absolute [start, end] ISO range.
// Pure functions — no I/O, no side effects.
// ===========================================================================

import type { TimeWindow } from './types';

export interface TimeRange {
  /** Inclusive lower bound, ISO 8601. */
  gte: string;
  /** Exclusive upper bound, ISO 8601, or undefined for "no upper bound". */
  lt?: string;
  label: string;
}

export function resolveTimeWindow(window: TimeWindow, now: Date = new Date()): TimeRange | null {
  // Use UTC throughout — notes.created_at is timestamptz.
  const startOfDay = (d: Date) => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const today = startOfDay(now);

  switch (window) {
    case 'today':
      return {
        gte: today.toISOString(),
        label: 'today',
      };
    case 'yesterday': {
      const y = new Date(today.getTime() - 24 * 3600 * 1000);
      return {
        gte: y.toISOString(),
        lt: today.toISOString(),
        label: 'yesterday',
      };
    }
    case 'this_week': {
      // Week starts Monday in UTC.
      const dow = (today.getUTCDay() + 6) % 7; // 0=Mon..6=Sun
      const monday = new Date(today.getTime() - dow * 24 * 3600 * 1000);
      return { gte: monday.toISOString(), label: 'this week' };
    }
    case 'last_week': {
      const dow = (today.getUTCDay() + 6) % 7;
      const thisMonday = new Date(today.getTime() - dow * 24 * 3600 * 1000);
      const lastMonday = new Date(thisMonday.getTime() - 7 * 24 * 3600 * 1000);
      return {
        gte: lastMonday.toISOString(),
        lt: thisMonday.toISOString(),
        label: 'last week',
      };
    }
    case 'this_month': {
      const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
      return { gte: start.toISOString(), label: 'this month' };
    }
    case 'last_month': {
      const startThis = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
      const startLast = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
      return {
        gte: startLast.toISOString(),
        lt: startThis.toISOString(),
        label: 'last month',
      };
    }
    case 'last_7d':
      return { gte: new Date(now.getTime() - 7 * 24 * 3600 * 1000).toISOString(), label: 'the last 7 days' };
    case 'last_30d':
      return { gte: new Date(now.getTime() - 30 * 24 * 3600 * 1000).toISOString(), label: 'the last 30 days' };
    case 'last_90d':
      return { gte: new Date(now.getTime() - 90 * 24 * 3600 * 1000).toISOString(), label: 'the last 90 days' };
    case 'last_180d':
      return { gte: new Date(now.getTime() - 180 * 24 * 3600 * 1000).toISOString(), label: 'the last 6 months' };
    case 'all_time':
      return null;
  }
}
