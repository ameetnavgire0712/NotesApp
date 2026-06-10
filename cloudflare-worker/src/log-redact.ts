/**
 * PII + secret redaction for Worker logs.
 *
 * Goal: nothing we ship to Logpush (and from there to Azure Blob Storage)
 * should contain a snap's content, a full email, an OAuth/API token, or a
 * Supabase service key. These helpers are intentionally small, dependency-
 * free, and safe to call on any string without throwing.
 *
 * Use guidance:
 *   - For pre-formatted messages, call `redact()` before `console.log()`.
 *   - For user IDs / emails, call `maskEmail()` / `maskId()` directly so the
 *     log is still useful for support (you can correlate but not dox).
 *   - For raw error bodies returned by Supabase / fetch, call `redact()` on
 *     the body before logging — those responses often echo back the
 *     Authorization header in error messages.
 *
 * NOTE: we deliberately do NOT redact short opaque hex strings (e.g. note
 * UUIDs) because they aren't PII on their own and we need them for
 * debugging. The redaction surface is: secrets, emails, JWTs, bearer
 * tokens, Supabase keys.
 */

// Matches a 3-segment JWT (eyJ-prefixed). Tight enough to avoid false
// positives on ordinary words. Supports `Bearer ` prefix optionally.
const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/g;

// Supabase publishable + service + secret keys all start with `sb_` and the
// new key format is `sb_<type>_<base64ish>`. Also catches the legacy
// SERVICE_ROLE keys which were just very long base64 strings starting with
// `eyJ` — already covered by JWT_PATTERN.
const SUPABASE_KEY_PATTERN = /\bsb_[a-z]+_[A-Za-z0-9_-]{20,}/g;

// Match "Authorization: Bearer <anything not-a-space>" (case-insensitive).
const BEARER_HEADER_PATTERN = /(Authorization\s*:\s*Bearer\s+)([^\s"']+)/gi;

// Naked Bearer tokens after "Bearer " keyword in messages.
const BEARER_TOKEN_PATTERN = /\bBearer\s+([A-Za-z0-9._\-+/=]{8,})/g;

// `X-API-Key: na_xxx` or `X-API-Key: ina_xxx` headers in log strings.
const APIKEY_HEADER_PATTERN = /((?:X-API-Key|apikey)\s*[:=]\s*)([A-Za-z0-9_-]{6,})/gi;

// Our own API key prefixes (na_, ina_) appearing standalone — keep prefix
// for diagnostics but strip the secret tail.
const NA_KEY_PATTERN = /\b(i?na_)[A-Za-z0-9_-]{8,}/g;

// Email pattern. Intentionally simple — we'd rather over-match here than
// leak. Replaces with `<a***@domain.tld>`.
const EMAIL_PATTERN = /([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/g;

/** Redact secrets, tokens, and emails in any string. */
export function redact(value: unknown): string {
  if (value === null || value === undefined) return String(value);
  let s: string;
  if (typeof value === 'string') {
    s = value;
  } else if (value instanceof Error) {
    s = `${value.name}: ${value.message}`;
  } else {
    try {
      s = JSON.stringify(value);
    } catch {
      s = String(value);
    }
  }

  // Order matters: redact headers first so the "Bearer " keyword is gone
  // before the standalone BEARER_TOKEN_PATTERN gets to it.
  s = s.replace(BEARER_HEADER_PATTERN, '$1[REDACTED_TOKEN]');
  s = s.replace(APIKEY_HEADER_PATTERN, '$1[REDACTED_KEY]');
  s = s.replace(SUPABASE_KEY_PATTERN, '[REDACTED_SB_KEY]');
  s = s.replace(JWT_PATTERN, '[REDACTED_JWT]');
  s = s.replace(BEARER_TOKEN_PATTERN, 'Bearer [REDACTED_TOKEN]');
  s = s.replace(NA_KEY_PATTERN, '$1[REDACTED]');
  s = s.replace(EMAIL_PATTERN, '$1***@$2');

  return s;
}

/** Mask an email to first-char + domain, for diagnostics. */
export function maskEmail(email: string | null | undefined): string {
  if (!email) return '<no-email>';
  const m = /^([^@]+)@(.+)$/.exec(email);
  if (!m) return '<bad-email>';
  return `${m[1][0]}***@${m[2]}`;
}

/** Show only first 8 chars of a UUID / user ID. */
export function maskId(id: string | null | undefined): string {
  if (!id) return '<none>';
  return id.length > 8 ? `${id.slice(0, 8)}…` : id;
}

/**
 * Safe console.log replacement. Forwards to console.log but redacts each
 * argument first. Use sparingly — in hot paths, prefer calling redact()
 * inline so you don't pay the stringify cost when logs are disabled.
 */
export function safeLog(...args: unknown[]): void {
  // eslint-disable-next-line no-console
  console.log(...args.map(a => (typeof a === 'string' ? redact(a) : redact(JSON.stringify(a)))));
}

export function safeError(...args: unknown[]): void {
  // eslint-disable-next-line no-console
  console.error(...args.map(a => (typeof a === 'string' ? redact(a) : redact(JSON.stringify(a)))));
}
