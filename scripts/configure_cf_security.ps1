<#
.SYNOPSIS
    Phase 2 — Cloudflare zone configuration (WAF managed rules + edge rate
    limits) for infosnap.ai.

.DESCRIPTION
    Run ONCE. Idempotent — safe to re-run if you tweak limits later. Uses
    the Cloudflare REST API directly so you don't have to click through the
    dashboard.

    What it configures:
      1. Cloudflare Managed Ruleset      — high-confidence threat blocks
         (CVE-2021-44228 log4j, etc.). Action: Managed Challenge.
      2. Cloudflare OWASP Core Ruleset   — anomaly-scored attack patterns
         (SQLi / XSS / RFI). Paranoia PL1, score 60, Managed Challenge.
      3. Rate-limit rule (upload)        — 60 req/min/IP on /api/v1/upload/*
         Block 10 minutes when exceeded. (2x the Worker's own 30/min
         limit, so this catches only true floods.)
      4. Rate-limit rule (search)        — 240 req/min/IP on /rag-search*
         Block 10 minutes when exceeded.

.PARAMETER ApiToken
    Cloudflare API token. Create at:
        https://dash.cloudflare.com/profile/api-tokens → Create Token
    Permissions required:
        Zone   | Zone WAF       | Edit
        Zone   | Zone           | Read
    Zone resources: Include → Specific zone → infosnap.ai

    You can also set the CLOUDFLARE_API_TOKEN env var instead of passing
    -ApiToken.

.PARAMETER ZoneName
    Default 'infosnap.ai'. Override only if you know what you're doing.

.EXAMPLE
    $env:CLOUDFLARE_API_TOKEN = 'cf_...'
    .\scripts\configure_cf_security.ps1

.EXAMPLE
    .\scripts\configure_cf_security.ps1 -ApiToken cf_xxx
#>
[CmdletBinding()]
param(
    [string] $ApiToken = $env:CLOUDFLARE_API_TOKEN,
    [string] $ZoneName = 'infosnap.ai'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ApiToken)) {
    Write-Error "Cloudflare API token required. Pass -ApiToken or set `$env:CLOUDFLARE_API_TOKEN."
    exit 1
}

$base = 'https://api.cloudflare.com/client/v4'
$headers = @{
    'Authorization' = "Bearer $ApiToken"
    'Content-Type'  = 'application/json'
}

function Invoke-CfApi {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [object] $Body
    )
    $uri = "$base$Path"
    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = $headers
    }
    if ($null -ne $Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    try {
        $resp = Invoke-RestMethod @params
    } catch {
        $body = $_.ErrorDetails.Message
        throw "CF API $Method $Path failed: $($_.Exception.Message)`n$body"
    }
    if (-not $resp.success) {
        $err = ($resp.errors | ConvertTo-Json -Depth 5 -Compress)
        throw "CF API $Method $Path returned success=false: $err"
    }
    return $resp.result
}

# ----------------------------------------------------------------------------
# 1. Resolve zone ID
# ----------------------------------------------------------------------------
Write-Host "→ Looking up zone '$ZoneName'..." -ForegroundColor Cyan
$zones = Invoke-CfApi -Method GET -Path "/zones?name=$ZoneName"
if (-not $zones -or $zones.Count -eq 0) {
    throw "Zone '$ZoneName' not found. Is the API token scoped to it?"
}
$zoneId = $zones[0].id
Write-Host "  zone id = $zoneId" -ForegroundColor DarkGray

# ----------------------------------------------------------------------------
# 2. Deploy managed WAF rulesets (Cloudflare Managed + OWASP Core)
#    The zone-level entrypoint for the http_request_firewall_managed phase
#    contains rules that "execute" each ruleset. We list available managed
#    rulesets at the account level, then upsert two rules into the zone
#    entrypoint that reference them.
# ----------------------------------------------------------------------------
Write-Host "→ Resolving managed rulesets..." -ForegroundColor Cyan
$account = (Invoke-CfApi -Method GET -Path "/zones/$zoneId").account
$accountId = $account.id
Write-Host "  account id = $accountId" -ForegroundColor DarkGray

# Account-level catalogue of all rulesets CF offers.
$allRulesets = Invoke-CfApi -Method GET -Path "/accounts/$accountId/rulesets"

$managed = $allRulesets | Where-Object {
    $_.kind -eq 'managed' -and $_.name -eq 'Cloudflare Managed Ruleset'
} | Select-Object -First 1
$owasp = $allRulesets | Where-Object {
    $_.kind -eq 'managed' -and $_.name -eq 'Cloudflare OWASP Core Ruleset'
} | Select-Object -First 1

if (-not $managed) { throw "Could not find 'Cloudflare Managed Ruleset' in account catalogue." }
if (-not $owasp)   { throw "Could not find 'Cloudflare OWASP Core Ruleset' in account catalogue." }

Write-Host "  managed ruleset id = $($managed.id)" -ForegroundColor DarkGray
Write-Host "  owasp   ruleset id = $($owasp.id)"   -ForegroundColor DarkGray

# Get (or create) the zone-level entrypoint for the managed phase.
try {
    $entrypoint = Invoke-CfApi -Method GET `
        -Path "/zones/$zoneId/rulesets/phases/http_request_firewall_managed/entrypoint"
} catch {
    # If no entrypoint exists yet, create an empty one.
    Write-Host "  no existing entrypoint — creating..." -ForegroundColor DarkYellow
    $entrypoint = Invoke-CfApi -Method POST -Path "/zones/$zoneId/rulesets" -Body @{
        name  = 'default'
        kind  = 'zone'
        phase = 'http_request_firewall_managed'
        rules = @()
    }
}

# Build desired rules.
$desiredRules = @(
    @{
        action            = 'execute'
        action_parameters = @{
            id       = $managed.id
            version  = 'latest'
            overrides = @{
                action = 'managed_challenge'
            }
        }
        expression  = '(true)'
        description = 'Phase2: Cloudflare Managed Ruleset (managed challenge)'
        enabled     = $true
    },
    @{
        action            = 'execute'
        action_parameters = @{
            id       = $owasp.id
            version  = 'latest'
            overrides = @{
                action = 'managed_challenge'
                rules  = @(
                    # PL1 paranoia + score threshold 60 are the conventional
                    # "let normal traffic through" settings.
                    @{ id = '6179ae15870a4bb7b2d480d4843b323c'; enabled = $true; action_parameters = @{ paranoia_level = 'PL1' } },
                    @{ id = '4814384a9e5d4011a7b924bc83b7d59a'; enabled = $true; action_parameters = @{ score_threshold = 60 } }
                )
            }
        }
        expression  = '(true)'
        description = 'Phase2: Cloudflare OWASP Core Ruleset (PL1, score 60, managed challenge)'
        enabled     = $true
    }
)

# Filter out any old Phase2-managed rules and append ours (idempotent).
$keepRules = @($entrypoint.rules | Where-Object { -not $_.description -or $_.description -notlike 'Phase2:*' })
$newRules  = $keepRules + $desiredRules

Write-Host "→ Updating WAF entrypoint with $($newRules.Count) rule(s)..." -ForegroundColor Cyan
Invoke-CfApi -Method PUT -Path "/zones/$zoneId/rulesets/$($entrypoint.id)" -Body @{
    rules = $newRules
} | Out-Null
Write-Host "  WAF managed rules: OK" -ForegroundColor Green

# ----------------------------------------------------------------------------
# 3. Edge rate-limit rules (separate phase: http_ratelimit)
#    Each rule blocks an IP for 10 minutes after it exceeds the threshold.
# ----------------------------------------------------------------------------
Write-Host "→ Configuring edge rate-limit rules..." -ForegroundColor Cyan
try {
    $rlEntry = Invoke-CfApi -Method GET `
        -Path "/zones/$zoneId/rulesets/phases/http_ratelimit/entrypoint"
} catch {
    Write-Host "  no existing rate-limit entrypoint — creating..." -ForegroundColor DarkYellow
    $rlEntry = Invoke-CfApi -Method POST -Path "/zones/$zoneId/rulesets" -Body @{
        name  = 'default'
        kind  = 'zone'
        phase = 'http_ratelimit'
        rules = @()
    }
}

$desiredRateLimits = @(
    @{
        action      = 'block'
        ratelimit   = @{
            characteristics       = @('ip.src', 'cf.colo.id')
            period                = 60
            requests_per_period   = 60
            mitigation_timeout    = 600
        }
        expression  = '(http.request.uri.path matches "^/api/v1/upload/")'
        description = 'Phase2: Edge rate-limit /api/v1/upload (60/min/IP)'
        enabled     = $true
    },
    @{
        action      = 'block'
        ratelimit   = @{
            characteristics       = @('ip.src', 'cf.colo.id')
            period                = 60
            requests_per_period   = 240
            mitigation_timeout    = 600
        }
        expression  = '(http.request.uri.path matches "^/rag-search")'
        description = 'Phase2: Edge rate-limit /rag-search* (240/min/IP)'
        enabled     = $true
    }
)

$keepRl = @($rlEntry.rules | Where-Object { -not $_.description -or $_.description -notlike 'Phase2:*' })
$newRl  = $keepRl + $desiredRateLimits

Invoke-CfApi -Method PUT -Path "/zones/$zoneId/rulesets/$($rlEntry.id)" -Body @{
    rules = $newRl
} | Out-Null
Write-Host "  Edge rate-limit rules: OK" -ForegroundColor Green

# ----------------------------------------------------------------------------
# 4. Summary
# ----------------------------------------------------------------------------
Write-Host ""
Write-Host "Phase 2 Cloudflare configuration complete." -ForegroundColor Green
Write-Host "Verify in the dashboard:" -ForegroundColor DarkGray
Write-Host "  https://dash.cloudflare.com/$accountId/$ZoneName/security/waf"
Write-Host "  https://dash.cloudflare.com/$accountId/$ZoneName/security/waf/rate-limiting-rules"
