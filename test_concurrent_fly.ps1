# 50 Query Concurrent Load Test - DIRECT to Fly.io (correct endpoint)
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
Write-Host "========== 50 QUERY CONCURRENT - DIRECT TO FLY.IO ==========" -ForegroundColor Cyan
Write-Host "URL: https://notesapp-search.fly.dev/api/v1/search/smart"
Write-Host "Queries: $($queries.Count)"
Write-Host "Starting at: $(Get-Date -Format 'HH:mm:ss.fff')"
Write-Host ""

$url = "https://notesapp-search.fly.dev/api/v1/search/smart"  # DIRECT to Fly.io
$apiKey = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

$runspacePool = [runspacefactory]::CreateRunspacePool(1, 50)
$runspacePool.Open()

$scriptBlock = {
    param($query, $url, $apiKey)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $body = @{query = $query; max_results = 5; spell_check = $true; synthesize = $false} | ConvertTo-Json
        $headers = @{"Content-Type"="application/json"; "X-API-Key"=$apiKey}
        $response = Invoke-RestMethod -Uri $url -Method POST -Headers $headers -Body $body -TimeoutSec 120
        $sw.Stop()
        @{
            query = $query
            client_ms = $sw.ElapsedMilliseconds
            backend_ms = $response.duration_ms
            results = $response.results.Count
            worker_id = $response.metadata.worker_request_id
            error = $null
        }
    } catch {
        $sw.Stop()
        @{
            query = $query
            client_ms = $sw.ElapsedMilliseconds
            error = $_.Exception.Message
        }
    }
}

$startAll = Get-Date
$runspaces = @()

foreach ($q in $queries) {
    $ps = [powershell]::Create().AddScript($scriptBlock).AddArgument($q).AddArgument($url).AddArgument($apiKey)
    $ps.RunspacePool = $runspacePool
    $runspaces += @{PowerShell = $ps; Handle = $ps.BeginInvoke(); Query = $q}
}

$results = @()
$i = 0
foreach ($rs in $runspaces) {
    $i++
    $result = $rs.PowerShell.EndInvoke($rs.Handle)
    $results += $result
    if ($result.error) {
        Write-Host "$i. [$($result.client_ms)ms] '$($result.query)' - ERROR: $($result.error)" -ForegroundColor Red
    } else {
        Write-Host "$i. [$($result.client_ms)ms] '$($result.query)' - Results: $($result.results) | Backend: $($result.backend_ms)ms"
    }
    $rs.PowerShell.Dispose()
}

$totalTime = ((Get-Date) - $startAll).TotalMilliseconds
$runspacePool.Close()

Write-Host ""
Write-Host "========== STATISTICS ==========" -ForegroundColor Yellow
$successful = $results | Where-Object { -not $_.error }
if ($successful.Count -gt 0) {
    $times = $successful.client_ms
    Write-Host "Total Wall Clock: $([int]$totalTime)ms"
    Write-Host "Successful: $($successful.Count) / $($queries.Count)"
    Write-Host "Failed: $($results.Count - $successful.Count)"
    Write-Host ""
    Write-Host "Client Response Times:"
    Write-Host "  Min: $($times | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum)ms"
    Write-Host "  Max: $($times | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum)ms"
    Write-Host "  Avg: $([int]($times | Measure-Object -Average | Select-Object -ExpandProperty Average))ms"
    
    $backendTimes = $successful.backend_ms | Where-Object { $_ }
    if ($backendTimes) {
        Write-Host ""
        Write-Host "Backend (Fly.io) Times:"
        Write-Host "  Min: $($backendTimes | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum)ms"
        Write-Host "  Max: $($backendTimes | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum)ms"
        Write-Host "  Avg: $([int]($backendTimes | Measure-Object -Average | Select-Object -ExpandProperty Average))ms"
    }
}
