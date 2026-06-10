# Phase 2 — Manual steps you must complete

Everything in this doc is **a click in a web UI, not a code change**. The
code-level Phase 2 work (Dependabot, RLS CI guard, audit_log migration,
PII redaction, Worker rate-limiting bindings) has already been committed
and deployed. These manual steps finish the picture.

> Time required: about 10 minutes total.

---

## 1. Apply the new SQL migrations in Supabase

We can't apply migrations from local because the project uses Supabase
SQL Editor as the source of truth (no `psql` access, no migration runner
in CI). Apply these in order:

1. Open <https://supabase.com/dashboard/project/_/sql/new>
2. Paste the contents of [migrations/052_phase1_owner_policies.sql](../migrations/052_phase1_owner_policies.sql)
3. Run. Confirm the verification block at the bottom shows
   `policy_count >= 1` for every table.
4. New tab, paste [migrations/053_phase2_audit_log.sql](../migrations/053_phase2_audit_log.sql),
   run. Confirm the verification query returns one row with
   `rls = true` and `policy_count = 2`.

After this, the Worker code is free to start writing to `audit_log`
(adding write-call sites is deferred to a follow-up — the table exists
and is ready).

---

## 2. GitHub: turn on secret scanning + push protection

Settings → **Code security** (left sidebar in the repo settings).

Toggle ON, in this order:

| Setting | Where | Why |
|---|---|---|
| **Secret scanning** | Code security → "Secret scanning" | GitHub flags leaked tokens already in history. Free for public repos; for private repos it requires GitHub Advanced Security (which we have via the personal plan). |
| **Push protection** | Code security → "Push protection" | Refuses pushes that contain a recognised secret. Stops accidental commits of Supabase service keys, Voyage API keys, Groq keys, etc. before they ever reach `main`. |
| **Validity checks** | Code security → "Secret scanning" subsection | Calls the issuing service to check whether the leaked secret is still live. Helpful prioritisation. |

> If a toggle is greyed out with "available on GitHub Advanced Security
> only", that's fine — public repos get most of this for free; for the
> private parts of the org you'll see the upgrade prompt. Skip those
> toggles for now and revisit when ready.

After enabling: visit Security → "Secret scanning alerts". GitHub will
backfill-scan history, which takes a few minutes. Triage anything that
appears.

---

## 3. GitHub: confirm Dependabot is active

We just committed [.github/dependabot.yml](../.github/dependabot.yml).
Verify it's parsing:

1. Repo → **Insights** → **Dependency graph** → **Dependabot**.
2. You should see four ecosystems listed (npm, pip, pub, github-actions)
   with "next update" timestamps in the future.
3. PRs will appear weekly (Monday 07:00 Asia/Kolkata) when there are
   updates. They're grouped by minor+patch so you don't drown.

If you see a YAML parse error here, fix the config and re-push — the
file is small and human-editable.

---

## 4. Cloudflare: enable WAF managed rules

The Worker now has built-in Workers Rate Limiting (deployed in this
phase), but for L7 attack patterns (SQLi, XSS, log4j, common scanners)
the right layer is Cloudflare WAF. It runs in front of the Worker and
costs nothing on the current plan.

1. Open <https://dash.cloudflare.com/> → select the `infosnap.ai` zone
   (NOT the Worker — WAF lives at the zone level).
2. **Security** → **WAF** → **Managed rules** tab.
3. Enable:
   - **Cloudflare Managed Ruleset** — leave on "Default" action
     (`Managed Challenge` for the high-severity tier).
   - **Cloudflare OWASP Core Ruleset** — paranoia level **PL1**
     (PL2+ false-positives heavily on rich text inputs like ours).
     Score threshold: 60. Action: `Managed Challenge`.
4. Click **Deploy**.

Verification: hit `https://infosnap.ai/?id=<script>alert(1)</script>` in
an incognito window — you should get the Cloudflare interstitial.

> Why not "Block"? `Managed Challenge` lets a real human through after a
> JS challenge but stops headless scrapers. Switch to `Block` only after
> a week of monitoring shows zero false-positives in the WAF events tab.

---

## 5. Cloudflare: rate-limit rules at the edge (optional, recommended)

We already do per-IP rate limiting inside the Worker (UPLOAD_RATELIMIT,
SEARCH_RATELIMIT — see `cloudflare-worker/wrangler.toml`). But the
Worker rate-limit costs a sub-request to even reject; if you want to
spare that cost during a real DDoS, add an edge rule:

1. CF dashboard → `infosnap.ai` zone → **Security** → **WAF** →
   **Rate limiting rules** tab → **Create rule**.
2. Two rules:

   **Rule A — Upload flood**
   - Field: URI Path → contains → `/api/v1/upload/`
   - Period: `1 minute`
   - Requests: `60`  (2x the Worker limit, so this only fires under
     extreme abuse and the Worker handles normal bursts)
   - Action: `Block`, duration `10 minutes`
   - Characteristics: `IP source address`

   **Rule B — Search flood**
   - Field: URI Path → contains → `/rag-search`
   - Period: `1 minute`
   - Requests: `240`  (2x the Worker limit)
   - Action: `Block`, duration `10 minutes`
   - Characteristics: `IP source address`

3. Save. They take effect immediately.

These edge rules are belt-and-braces with the Worker bindings — both
layers protect, and the edge layer is cheaper under attack.

---

## 6. (Already done by the code) Phase 2 deliverables

For completeness, the things that **don't** need a manual step:

- ✅ Dependabot weekly grouped updates — `.github/dependabot.yml`
- ✅ RLS guard CI check — `.github/workflows/rls-guard.yml` +
  `scripts/rls_guard.py`. Will run on the next PR that touches a `.sql`
  migration.
- ✅ `audit_log` table — `migrations/053_phase2_audit_log.sql`
  (apply via step 1 above).
- ✅ PII / secret redaction helper — `cloudflare-worker/src/log-redact.ts`.
  Already wired into `auth.ts` (no more `SERVICE_KEY` prefix in logs)
  and into the `worker_logs` + `search_traces` shippers (queries
  scrubbed before persistence; emails masked).
- ✅ Cloudflare Workers Rate Limiting bindings — `UPLOAD_RATELIMIT`
  (30/min/IP) and `SEARCH_RATELIMIT` (120/min/IP), applied in
  `cloudflare-worker/src/index.ts` before any heavy work.

---

## 7. Explicitly deferred to a follow-up session

These three items from the original 7-item plan are real refactors that
deserve their own focused session. They're tracked here so they don't
get lost:

- **Move read-only endpoints (Recap / Bootstrap / Billing status) off
  the service key.** Currently every Supabase call in the Worker uses
  `SUPABASE_SERVICE_KEY`. To convert read-only endpoints to JWT
  pass-through, we need a small `supabaseClientForUser(jwt)` factory
  and per-endpoint migration. Migration 052 already provides the owner
  SELECT policies the new client will rely on, so the SQL groundwork
  is done.

- **"Download all my snaps as ZIP" endpoint.** Cloudflare Workers don't
  ship with a zip library; the cleanest approach is a new endpoint that
  streams a manifest JSON + signed Azure blob URLs (the user's browser
  fetches the blobs directly). Design + ship in a follow-up.

- **"Delete my account" endpoint.** Cascade across `notes`,
  `note_chunks`, `embeddings` (Vectorize batch delete by ID list),
  Azure blobs (delete by user prefix), KV (delete by user prefix),
  `groups` / `group_members` / `group_invites`, `recap_cache`,
  `user_api_keys`, `audit_log` (only if user requests full erasure —
  otherwise keep for legal hold), then `auth.users` (soft-delete then
  hard-delete after 30-day window). Non-trivial; needs its own design
  review against DPDP / GDPR right-to-erasure timing.

When you're ready for any of these, ask and we'll scope a dedicated
session.
