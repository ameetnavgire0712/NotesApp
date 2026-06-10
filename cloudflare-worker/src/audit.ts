/**
 * Append-only audit log writer.
 *
 * Posts events to the Supabase `public.audit_log` table via the PostgREST
 * `/rest/v1/audit_log` endpoint, fire-and-forget through `ctx.waitUntil`
 * so the user-facing response is never blocked or slowed by audit I/O.
 *
 * Triggers on the table physically prevent UPDATE / DELETE — even from
 * service_role — so once a row lands, it stays. Read access is owner-only
 * via RLS (`auth.uid() = user_id`); the user can later see their own
 * history via a future "Activity" panel.
 *
 * Hygiene rules baked in:
 *  - `details` is run through `redact()` so a copy-pasted email / Bearer
 *    token inside note metadata can't accidentally end up in the log.
 *  - We extract `ip_address` and `user_agent` from the Request rather than
 *    accepting them as parameters — keeps callers honest.
 *  - Failures are LOGGED, never thrown. Audit gaps are a known-known we
 *    accept rather than crash a user's delete request.
 */

import { redact } from './log-redact';

/** Minimum env subset audit needs. Worker's full Env satisfies this. */
export interface AuditEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
}

export interface AuditEntry {
  /**
   * Required. Convention: `<resource>.<verb>` (e.g. `note.delete`,
   * `auth.api_key_created`). Loose strings on purpose — new event types
   * don't need a migration.
   */
  event_type: string;
  /** Owner of the affected resource. NULL only for true system events. */
  user_id: string | null;
  /** Email of the actor (the user performing the action), if known. */
  actor_email?: string | null;
  /** Type of resource touched, e.g. `note`, `group`, `api_key`. */
  resource_type?: string;
  /** Stringified id of the resource. */
  resource_id?: string;
  /** Worker request_id for cross-table joinability with `worker_logs`. */
  request_id?: string;
  /**
   * Free-form JSON. Keep small + PII-light. The helper runs this through
   * `redact()` so accidental secrets get masked.
   */
  details?: Record<string, unknown>;
}

/**
 * Fire-and-forget audit write. Pass `ctx` so the Worker waits for the
 * Supabase POST to finish even after the user response has been sent.
 *
 * Never throws. If the audit table is unreachable we accept the gap and
 * log a console.error — the user request is unaffected.
 */
export function logAudit(
  env: AuditEnv,
  ctx: ExecutionContext,
  request: Request | null,
  entry: AuditEntry,
): void {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_KEY) {
    // Worker mis-configured — log once and bail. No point fighting.
    console.error('[audit] missing SUPABASE_URL / SUPABASE_SERVICE_KEY — event dropped:', entry.event_type);
    return;
  }

  // Extract network-level context from the request if available.
  const ip_address = request?.headers.get('CF-Connecting-IP') ?? null;
  const user_agent = request?.headers.get('User-Agent') ?? null;

  // Defensive redaction of details payload: stringify, redact, parse back.
  // If anything goes wrong we just drop the details to keep the event row.
  let safeDetails: Record<string, unknown> = {};
  if (entry.details) {
    try {
      safeDetails = JSON.parse(redact(JSON.stringify(entry.details)));
    } catch {
      safeDetails = { _redaction_error: true };
    }
  }

  const row = {
    event_type: entry.event_type,
    user_id: entry.user_id,
    actor_email: entry.actor_email ?? null,
    resource_type: entry.resource_type ?? null,
    resource_id: entry.resource_id ?? null,
    ip_address,
    user_agent,
    request_id: entry.request_id ?? null,
    details: safeDetails,
  };

  ctx.waitUntil(
    (async () => {
      try {
        const resp = await fetch(`${env.SUPABASE_URL}/rest/v1/audit_log`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            apikey: env.SUPABASE_SERVICE_KEY,
            Authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}`,
            Prefer: 'return=minimal',
          },
          body: JSON.stringify(row),
        });
        if (!resp.ok) {
          const body = await resp.text().catch(() => '<unreadable>');
          console.error('[audit] POST failed', resp.status, redact(body), 'event=', entry.event_type);
        }
      } catch (err) {
        console.error('[audit] POST threw', redact(err), 'event=', entry.event_type);
      }
    })(),
  );
}
