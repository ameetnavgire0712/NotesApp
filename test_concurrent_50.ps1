# 50 Query Concurrent Load Test Script
param(
    [int]$QueryCount = 50
)

$queries = @(
    "centric consulting", "msc software", "resume", "nitor infotech", "bitwise",
    "modality specific chunking", "rag", "cognee ai memory", "cognee", "what is redis pricing?",
    "give me my latest resume", "different data ingestion techniques", "centric job openings",
    "show me the relieving letter", "what are different rag chunking methods?",
    "show me the rag search flow", "what is redis?", "how to sign in to microsoft?",
    "AI marketing strategy", "AI logo builder", "what is elsa?", "advanced rag",
    "ai marketing assistant", "what is dataverse", "elsa marketing", "marketing assistant",
    "machine learning basics", "python programming", "azure functions", "docker containers",
    "kubernetes deployment", "react framework", "nodejs backend", "sql database",
    "mongodb tutorial", "api design patterns", "microservices architecture", "cloud computing",
    "devops practices", "git version control", "agile methodology", "project management",
    "data science workflow", "natural language processing", "computer vision", "deep learning",
    "neural networks", "recommendation systems", "search algorithms", "vector databases"
)

Write-Host ""
Write-Host "========== 50 QUERY CONCURRENT LOAD TEST ==========" -ForegroundColor Cyan
Write-Host "Queries: $($queries.Count)" -ForegroundColor Yellow
Write-Host "Endpoint: https://notesapp-gateway.monocle0712.workers.dev/api/v1/search/smart"
Write-Host "Starting at: $(Get-Date -Format 'HH:mm:ss.fff')"
Write-Host ""

$url = "https://notesapp-gateway.monocle0712.workers.dev/api/v1/search/smart"
$apiKey = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Create runspace pool for true concurrency
$runspacePool = [runspacefactory]::CreateRunspacePool(1, 50)
$runspacePool.Open()

$scriptBlock = {
    param($query, $url, $apiKey)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $body = @{query = $query; max_results = 5; spell_check = $true; synthesize = $false} | ConvertTo-Json
        $headers = @{"Content-Type"="application/json"; "X-API-Key"=$apiKey}
        $response = Invoke-RestMethod -Uri $url -Method POST -Headers $headers -Body $body -TimeoutSec 60
        $sw.Stop()
        @{
            query = $query
            client_ms = $sw.ElapsedMilliseconds
            backend_ms = $response.duration_ms
            results = $response.results.Count
            worker_id = $response.metadata.worker_request_id
            path = $response.metadata.path_taken
            corrected = $response.query_corrected
            titles = ($response.results | Select-Object -First 3 | ForEach-Object { $_.title }) -join " | "
            error = $null
        }
    } catch {
        $sw.Stop()
        @{query = $query; client_ms = $sw.ElapsedMilliseconds; error = $_.Exception.Message}
    }
}

$runspaces = @()
$globalStart = [System.Diagnostics.Stopwatch]::StartNew()

# Launch ALL queries at once
foreach ($q in $queries) {
    $ps = [powershell]::Create().AddScript($scriptBlock).AddArgument($q).AddArgument($url).AddArgument($apiKey)
    $ps.RunspacePool = $runspacePool
    $runspaces += @{PowerShell = $ps; Handle = $ps.BeginInvoke()}
}

Write-Host "All $($runspaces.Count) requests launched simultaneously!" -ForegroundColor Green
Write-Host "Waiting for responses..."
Write-Host ""

# Collect results
$results = @()
foreach ($rs in $runspaces) {
    $results += $rs.PowerShell.EndInvoke($rs.Handle)
    $rs.PowerShell.Dispose()
}

$globalStart.Stop()
$runspacePool.Close()

# Output results sorted by time
Write-Host ""
Write-Host "========== RESULTS (sorted by response time) ==========" -ForegroundColor Cyan
$sorted = $results | Sort-Object client_ms
$i = 1
foreach ($r in $sorted) {
    if ($r.error) {
        Write-Host "$i. [$($r.client_ms)ms] '$($r.query)' - ERROR: $($r.error)" -ForegroundColor Red
    } else {
        $color = "Green"
        if ($r.client_ms -ge 5000) { $color = "Red" }
        elseif ($r.client_ms -ge 3000) { $color = "Yellow" }
        
        $corrMsg = ""
        if ($r.corrected -and $r.corrected -ne $r.query) { $corrMsg = " -> '$($r.corrected)'" }
        
        Write-Host "$i. [$($r.client_ms)ms] '$($r.query)'$corrMsg" -ForegroundColor $color
        Write-Host "   Results: $($r.results) | Path: $($r.path) | Backend: $($r.backend_ms)ms | ID: $($r.worker_id)"
        if ($r.titles) { Write-Host "   Titles: $($r.titles)" -ForegroundColor DarkGray }
    }
    $i++
}

# Statistics
Write-Host ""
Write-Host "========== STATISTICS ==========" -ForegroundColor Cyan
$successful = $results | Where-Object { -not $_.error }
$failed = $results | Where-Object { $_.error }
$times = $successful | Select-Object -ExpandProperty client_ms

Write-Host "Total Wall Clock Time: $($globalStart.ElapsedMilliseconds)ms" -ForegroundColor Yellow
Write-Host "Successful: $($successful.Count) / $($results.Count)"
Write-Host "Failed: $($failed.Count)"

if ($times.Count -gt 0) {
    $sortedTimes = $times | Sort-Object
    Write-Host "Min: $($sortedTimes[0])ms"
    Write-Host "Max: $($sortedTimes[-1])ms"
    Write-Host "Avg: $([math]::Round(($times | Measure-Object -Average).Average))ms"
    Write-Host "P50: $($sortedTimes[[math]::Floor($times.Count * 0.5)])ms"
    Write-Host "P95: $($sortedTimes[[math]::Floor($times.Count * 0.95)])ms"
}

# Return results for further analysis
$results
