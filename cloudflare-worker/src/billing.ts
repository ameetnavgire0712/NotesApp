import { AuthResult } from './auth';
import { logAudit } from './audit';

export type BillingMetric = 'upload' | 'snapbot_search' | 'google_search';

export interface BillingEnv {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_KEY: string;
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-API-Key',
};

interface QuotaDecision {
  allowed: boolean;
  code?: string;
  metric: BillingMetric;
  used?: number;
  limit?: number;
  remaining?: number;
  plan_code?: string;
  effective_plan_code?: string;
  reset_at?: string;
  quota_unavailable?: boolean;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });
}

async function supabaseRpc<T>(
  env: BillingEnv,
  functionName: string,
  body: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${functionName}`, {
    method: 'POST',
    headers: {
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Supabase RPC ${functionName} failed: ${response.status} ${text.slice(0, 500)}`);
  }

  return await response.json() as T;
}

export async function consumeQuota(
  env: BillingEnv,
  userId: string,
  metric: BillingMetric,
  idempotencyKey: string,
  metadata: Record<string, unknown> = {},
): Promise<QuotaDecision> {
  try {
    return await supabaseRpc<QuotaDecision>(env, 'consume_monthly_quota', {
      p_user_id: userId,
      p_metric: metric,
      p_amount: 1,
      p_idempotency_key: idempotencyKey,
      p_metadata: metadata,
    });
  } catch (err) {
    // Do not block core app behavior if the billing migration has not been
    // applied yet or Supabase has a transient issue. The error is still logged
    // so we can fix billing without causing an upload/search outage.
    console.error(`[Billing] Quota check failed open for ${metric}:`, err);
    return {
      allowed: true,
      metric,
      code: 'QUOTA_UNAVAILABLE',
      quota_unavailable: true,
    };
  }
}

/**
 * Refund a previously-consumed monthly quota credit. Called when an upload
 * pipeline fails or a stuck upload is swept up by the cleanup cron, so the
 * user's monthly limit doesn't tick down for work they never received.
 *
 * Backed by the `refund_monthly_quota` RPC (migration 050). Idempotent:
 * refunding the same trace_id twice is a no-op because the underlying
 * usage_events row is deleted on the first call.
 *
 * Failures are swallowed and logged — refund failures must never break a
 * pipeline-failure cleanup path.
 */
export async function refundQuota(
  env: BillingEnv,
  userId: string,
  metric: BillingMetric,
  idempotencyKey: string,
): Promise<void> {
  if (!idempotencyKey) return;
  try {
    const result = await supabaseRpc<{ refunded?: boolean; reason?: string }>(
      env,
      'refund_monthly_quota',
      {
        p_user_id: userId,
        p_metric: metric,
        p_idempotency_key: idempotencyKey,
      },
    );
    if (result?.refunded) {
      console.log(`[Billing] Refunded ${metric} quota for ${userId} (key=${idempotencyKey})`);
    } else {
      console.log(`[Billing] No-op quota refund for ${userId} key=${idempotencyKey} reason=${result?.reason || 'unknown'}`);
    }
  } catch (err) {
    console.error(`[Billing] refundQuota threw for ${metric} ${userId}:`, err);
  }
}

export function quotaExceededResponse(decision: QuotaDecision): Response {
  const isUpload = decision.metric === 'upload';
  const isGoogleSearch = decision.metric === 'google_search';
  const limitLabel = isUpload
    ? 'uploads'
    : isGoogleSearch
      ? 'Google searches'
      : 'SnapBot searches';
  const resetText = decision.reset_at
    ? ` It will reset on ${formatResetDate(decision.reset_at)}.`
    : ' It will reset next month.';
  return jsonResponse({
    error: `You have reached your monthly ${limitLabel} limit (${decision.used ?? 0}/${decision.limit ?? 0}).${resetText}`,
    code: isUpload
      ? 'MONTHLY_UPLOAD_LIMIT_REACHED'
      : isGoogleSearch
        ? 'MONTHLY_GOOGLE_SEARCH_LIMIT_REACHED'
        : 'MONTHLY_SNAPBOT_LIMIT_REACHED',
    metric: decision.metric,
    used: decision.used,
    limit: decision.limit,
    remaining: decision.remaining,
    plan_code: decision.plan_code,
    effective_plan_code: decision.effective_plan_code,
    reset_at: decision.reset_at,
    upgrade_available: decision.effective_plan_code !== 'premium',
  }, 429);
}

function formatResetDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString('en-IN', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'Asia/Kolkata',
    timeZoneName: 'short',
  });
}

export async function handleBillingStatus(
  authResult: AuthResult,
  env: BillingEnv,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }

  try {
    const status = await supabaseRpc(env, 'get_billing_status', {
      p_user_id: authResult.user_id,
    });
    return jsonResponse(status);
  } catch (err) {
    console.error('[Billing] Status failed:', err);
    return jsonResponse({
      error: 'Billing status unavailable',
      code: 'BILLING_UNAVAILABLE',
    }, 503);
  }
}

export async function handleBillingUpgradeDev(
  authResult: AuthResult,
  env: BillingEnv,
  ctx: ExecutionContext,
  request: Request,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }

  const now = new Date();
  const periodEnd = new Date(now);
  periodEnd.setMonth(periodEnd.getMonth() + 1);

  try {
    const planResp = await fetch(`${env.SUPABASE_URL}/rest/v1/user_plans?on_conflict=user_id`, {
      method: 'POST',
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'resolution=merge-duplicates,return=minimal',
      },
      body: JSON.stringify({
        user_id: authResult.user_id,
        plan_code: 'premium',
        status: 'active',
        current_period_start: now.toISOString(),
        current_period_end: periodEnd.toISOString(),
        cancel_at_period_end: false,
        provider: 'manual',
        metadata: { source: 'dev_placeholder_upgrade' },
        updated_at: now.toISOString(),
      }),
    });

    if (!planResp.ok) {
      throw new Error(`plan upsert failed: ${planResp.status} ${await planResp.text()}`);
    }

    await insertBillingEvent(env, authResult.user_id, 'manual_premium_started', {
      current_period_start: now.toISOString(),
      current_period_end: periodEnd.toISOString(),
    });

    // Audit: plan changed. Treat manual dev upgrades and real Stripe
    // webhooks the same so the timeline is consistent.
    logAudit(env, ctx, request, {
      event_type: 'billing.upgrade',
      user_id: authResult.user_id,
      actor_email: authResult.email ?? null,
      resource_type: 'plan',
      resource_id: 'premium',
      details: {
        provider: 'manual',
        source: 'dev_placeholder_upgrade',
        period_start: now.toISOString(),
        period_end: periodEnd.toISOString(),
      },
    });

    const status = await supabaseRpc(env, 'get_billing_status', {
      p_user_id: authResult.user_id,
    });
    return jsonResponse(status);
  } catch (err) {
    console.error('[Billing] Manual upgrade failed:', err);
    return jsonResponse({ error: 'Could not upgrade to premium', code: 'UPGRADE_FAILED' }, 500);
  }
}

export async function handleBillingCancel(
  authResult: AuthResult,
  env: BillingEnv,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }

  try {
    const patchResp = await fetch(`${env.SUPABASE_URL}/rest/v1/user_plans?user_id=eq.${encodeURIComponent(authResult.user_id)}`, {
      method: 'PATCH',
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
      },
      body: JSON.stringify({
        status: 'cancelled',
        cancel_at_period_end: true,
        updated_at: new Date().toISOString(),
      }),
    });

    if (!patchResp.ok) {
      throw new Error(`plan cancel failed: ${patchResp.status} ${await patchResp.text()}`);
    }

    await insertBillingEvent(env, authResult.user_id, 'manual_premium_cancelled', {});
    const status = await supabaseRpc(env, 'get_billing_status', {
      p_user_id: authResult.user_id,
    });
    return jsonResponse(status);
  } catch (err) {
    console.error('[Billing] Cancel failed:', err);
    return jsonResponse({ error: 'Could not cancel premium', code: 'CANCEL_FAILED' }, 500);
  }
}

export async function handleBillingReactivate(
  authResult: AuthResult,
  env: BillingEnv,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }

  try {
    const patchResp = await fetch(`${env.SUPABASE_URL}/rest/v1/user_plans?user_id=eq.${encodeURIComponent(authResult.user_id)}`, {
      method: 'PATCH',
      headers: {
        'apikey': env.SUPABASE_SERVICE_KEY,
        'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
      },
      body: JSON.stringify({
        plan_code: 'premium',
        status: 'active',
        cancel_at_period_end: false,
        updated_at: new Date().toISOString(),
      }),
    });

    if (!patchResp.ok) {
      throw new Error(`plan reactivate failed: ${patchResp.status} ${await patchResp.text()}`);
    }

    await insertBillingEvent(env, authResult.user_id, 'manual_premium_reactivated', {});
    const status = await supabaseRpc(env, 'get_billing_status', {
      p_user_id: authResult.user_id,
    });
    return jsonResponse(status);
  } catch (err) {
    console.error('[Billing] Reactivate failed:', err);
    return jsonResponse({ error: 'Could not reactivate premium', code: 'REACTIVATE_FAILED' }, 500);
  }
}

export async function handleBillingHistory(
  authResult: AuthResult,
  env: BillingEnv,
): Promise<Response> {
  if (!authResult.authenticated || !authResult.user_id) {
    return jsonResponse({ error: 'Unauthorized' }, 401);
  }

  try {
    const response = await fetch(
      `${env.SUPABASE_URL}/rest/v1/billing_events?user_id=eq.${encodeURIComponent(authResult.user_id)}&select=event_type,provider,amount_cents,currency,metadata,created_at&order=created_at.desc&limit=50`,
      {
        headers: {
          'apikey': env.SUPABASE_SERVICE_KEY,
          'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
        },
      },
    );
    if (!response.ok) {
      throw new Error(`history failed: ${response.status} ${await response.text()}`);
    }
    return jsonResponse({ events: await response.json() });
  } catch (err) {
    console.error('[Billing] History failed:', err);
    return jsonResponse({ error: 'Could not load billing history', code: 'HISTORY_FAILED' }, 500);
  }
}

async function insertBillingEvent(
  env: BillingEnv,
  userId: string,
  eventType: string,
  metadata: Record<string, unknown>,
): Promise<void> {
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/billing_events`, {
    method: 'POST',
    headers: {
      'apikey': env.SUPABASE_SERVICE_KEY,
      'Authorization': `Bearer ${env.SUPABASE_SERVICE_KEY}`,
      'Content-Type': 'application/json',
      'Prefer': 'return=minimal',
    },
    body: JSON.stringify({
      user_id: userId,
      event_type: eventType,
      provider: 'manual',
      metadata,
    }),
  });

  if (!response.ok) {
    console.warn(`[Billing] Could not insert event ${eventType}: ${response.status} ${await response.text()}`);
  }
}
