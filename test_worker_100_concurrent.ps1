# 100 Concurrent Query Test for Worker /rag-search-auth endpoint
# Tests parallelism and timing

$workerUrl = "https://notesapp-vector-search.monocle0712.workers.dev/rag-search-auth"
$apiKey = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"

# Sample queries to test
$queries = @(
    "resume", "pan card", "azure deployment", "kubernetes", "docker",
    "machine learning", "python tutorial", "javascript", "react hooks", "nodejs",
    "database design", "sql query", "mongodb", "redis cache", "api design",
    "microservices", "cloud computing", "aws lambda", "serverless", "terraform",
    "git workflow", "ci cd pipeline", "testing strategy", "code review", "agile",
    "project management", "team collaboration", "communication skills", "leadership", "mentoring",
    "data analysis", "visualization", "tableau", "power bi", "excel formulas",
    "financial modeling", "budgeting", "forecasting", "risk management", "compliance",
    "marketing strategy", "seo optimization", "content marketing", "social media", "analytics",
    "product design", "user experience", "wireframes", "prototyping", "usability testing",
    "security best practices", "authentication", "authorization", "encryption", "firewall",
    "networking basics", "tcp ip", "dns configuration", "load balancing", "cdn",
    "mobile development", "ios app", "android app", "flutter", "react native",
    "web scraping", "data extraction", "etl process", "data pipeline", "streaming",
    "artificial intelligence", "neural networks", "deep learning", "nlp", "computer vision",
    "blockchain", "smart contracts", "cryptocurrency", "defi", "nft",
    "devops practices", "monitoring", "logging", "alerting", "incident response",
    "performance optimization", "caching strategies", "database indexing", "query optimization", "profiling",
    "system architecture", "scalability", "high availability", "disaster recovery", "backup strategy",
    "interview preparation", "resume tips", "salary negotiation", "career growth", "networking"
)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  100 Concurrent Query Test - Worker RAG   " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Endpoint: $workerUrl"
Write-Host "Queries: 100"
Write-Host ""

$testStart = Get-Date
Write-Host "Test started at: $testStart" -ForegroundColor Yellow
Write-Host ""

# Create 100 jobs
$jobs = @()
$results = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

# Use runspaces for true parallelism
$runspacePool = [runspacefactory]::CreateRunspacePool(1, 100)
$runspacePool.Open()

$scriptBlock = {
    param($url, $apiKey, $query, $index)
    
    $startTime = Get-Date
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $body = @{ query = $query } | ConvertTo-Json
        $response = Invoke-RestMethod -Uri $url -Method POST -Headers @{
            "Content-Type" = "application/json"
            "X-API-Key" = $apiKey
        } -Body $body -TimeoutSec 60
        
        $stopwatch.Stop()
        $endTime = Get-Date
        
        return [PSCustomObject]@{
            Index = $index
            Query = $query
            Success = $true
            ClientMs = $stopwatch.ElapsedMilliseconds
            WorkerMs = $response.metadata.timing.total_ms
            ResultCount = $response.results.Count
            RequestId = $response.request_id
            StartTime = $startTime
            EndTime = $endTime
            Error = $null
        }
    }
    catch {
        $stopwatch.Stop()
        return [PSCustomObject]@{
            Index = $index
            Query = $query
            Success = $false
            ClientMs = $stopwatch.ElapsedMilliseconds
            WorkerMs = 0
            ResultCount = 0
            RequestId = $null
            StartTime = $startTime
            EndTime = Get-Date
            Error = $_.Exception.Message
        }
    }
}

$runspaces = @()

Write-Host "Launching 100 concurrent requests..." -ForegroundColor Green

for ($i = 0; $i -lt 100; $i++) {
    $query = $queries[$i % $queries.Count]
    
    $powershell = [powershell]::Create()
    $powershell.RunspacePool = $runspacePool
    [void]$powershell.AddScript($scriptBlock)
    [void]$powershell.AddArgument($workerUrl)
    [void]$powershell.AddArgument($apiKey)
    [void]$powershell.AddArgument($query)
    [void]$powershell.AddArgument($i + 1)
    
    $runspaces += [PSCustomObject]@{
        PowerShell = $powershell
        Handle = $powershell.BeginInvoke()
    }
}

Write-Host "All 100 requests launched. Waiting for completion..." -ForegroundColor Yellow

# Collect results
$allResults = @()
foreach ($rs in $runspaces) {
    $result = $rs.PowerShell.EndInvoke($rs.Handle)
    $allResults += $result
    $rs.PowerShell.Dispose()
}

$runspacePool.Close()
$runspacePool.Dispose()

$testEnd = Get-Date
$totalTestTime = ($testEnd - $testStart).TotalMilliseconds

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "              TEST RESULTS                  " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Sort by start time to analyze parallelism
$sortedResults = $allResults | Sort-Object StartTime

# Calculate statistics
$successResults = $sortedResults | Where-Object { $_.Success }
$failedResults = $sortedResults | Where-Object { -not $_.Success }

$clientTimes = $successResults | ForEach-Object { $_.ClientMs }
$workerTimes = $successResults | Where-Object { $_.WorkerMs -gt 0 } | ForEach-Object { $_.WorkerMs }

Write-Host "SUMMARY:" -ForegroundColor Green
Write-Host "  Total Requests:    100"
Write-Host "  Successful:        $($successResults.Count)" -ForegroundColor Green
Write-Host "  Failed:            $($failedResults.Count)" -ForegroundColor $(if ($failedResults.Count -gt 0) { "Red" } else { "Green" })
Write-Host "  Total Test Time:   $([math]::Round($totalTestTime, 0)) ms"
Write-Host ""

if ($successResults.Count -gt 0) {
    Write-Host "CLIENT-SIDE TIMING (includes network):" -ForegroundColor Yellow
    Write-Host "  Min:     $([math]::Round(($clientTimes | Measure-Object -Minimum).Minimum, 0)) ms"
    Write-Host "  Max:     $([math]::Round(($clientTimes | Measure-Object -Maximum).Maximum, 0)) ms"
    Write-Host "  Avg:     $([math]::Round(($clientTimes | Measure-Object -Average).Average, 0)) ms"
    Write-Host "  Median:  $([math]::Round(($clientTimes | Sort-Object)[49], 0)) ms"
    Write-Host ""
    
    if ($workerTimes.Count -gt 0) {
        Write-Host "WORKER-SIDE TIMING (from response):" -ForegroundColor Yellow
        Write-Host "  Min:     $([math]::Round(($workerTimes | Measure-Object -Minimum).Minimum, 0)) ms"
        Write-Host "  Max:     $([math]::Round(($workerTimes | Measure-Object -Maximum).Maximum, 0)) ms"
        Write-Host "  Avg:     $([math]::Round(($workerTimes | Measure-Object -Average).Average, 0)) ms"
        Write-Host ""
    }
}

# Analyze parallelism
Write-Host "PARALLELISM ANALYSIS:" -ForegroundColor Yellow

$firstStart = ($sortedResults | Select-Object -First 1).StartTime
$lastStart = ($sortedResults | Select-Object -Last 1).StartTime
$firstEnd = ($sortedResults | Sort-Object EndTime | Select-Object -First 1).EndTime
$lastEnd = ($sortedResults | Sort-Object EndTime | Select-Object -Last 1).EndTime

$launchSpread = ($lastStart - $firstStart).TotalMilliseconds
$completionSpread = ($lastEnd - $firstEnd).TotalMilliseconds

Write-Host "  First request started:  $($firstStart.ToString('HH:mm:ss.fff'))"
Write-Host "  Last request started:   $($lastStart.ToString('HH:mm:ss.fff'))"
Write-Host "  Launch spread:          $([math]::Round($launchSpread, 0)) ms"
Write-Host ""
Write-Host "  First request completed: $($firstEnd.ToString('HH:mm:ss.fff'))"
Write-Host "  Last request completed:  $($lastEnd.ToString('HH:mm:ss.fff'))"
Write-Host "  Completion spread:       $([math]::Round($completionSpread, 0)) ms"
Write-Host ""

# Calculate theoretical sequential time
$theoreticalSequential = ($clientTimes | Measure-Object -Sum).Sum
$parallelismFactor = $theoreticalSequential / $totalTestTime

Write-Host "  Theoretical sequential time: $([math]::Round($theoreticalSequential, 0)) ms"
Write-Host "  Actual total time:           $([math]::Round($totalTestTime, 0)) ms"
Write-Host "  Parallelism factor:          $([math]::Round($parallelismFactor, 1))x" -ForegroundColor $(if ($parallelismFactor -gt 10) { "Green" } else { "Yellow" })
Write-Host ""

if ($parallelismFactor -gt 50) {
    Write-Host "  ✅ HIGHLY PARALLEL - Requests executed concurrently!" -ForegroundColor Green
} elseif ($parallelismFactor -gt 10) {
    Write-Host "  ✅ PARALLEL - Good concurrent execution" -ForegroundColor Green
} elseif ($parallelismFactor -gt 2) {
    Write-Host "  ⚠️  PARTIALLY PARALLEL - Some queuing detected" -ForegroundColor Yellow
} else {
    Write-Host "  ❌ SEQUENTIAL - Requests appear to be queued" -ForegroundColor Red
}

Write-Host ""
Write-Host "TIMING DISTRIBUTION:" -ForegroundColor Yellow

# Bucket the times
$under1s = ($clientTimes | Where-Object { $_ -lt 1000 }).Count
$under2s = ($clientTimes | Where-Object { $_ -ge 1000 -and $_ -lt 2000 }).Count
$under3s = ($clientTimes | Where-Object { $_ -ge 2000 -and $_ -lt 3000 }).Count
$under5s = ($clientTimes | Where-Object { $_ -ge 3000 -and $_ -lt 5000 }).Count
$over5s = ($clientTimes | Where-Object { $_ -ge 5000 }).Count

Write-Host "  < 1s:    $under1s requests"
Write-Host "  1-2s:    $under2s requests"
Write-Host "  2-3s:    $under3s requests"
Write-Host "  3-5s:    $under5s requests"
Write-Host "  > 5s:    $over5s requests"
Write-Host ""

# Show failed requests if any
if ($failedResults.Count -gt 0) {
    Write-Host "FAILED REQUESTS:" -ForegroundColor Red
    $failedResults | ForEach-Object {
        Write-Host "  #$($_.Index) '$($_.Query)': $($_.Error)"
    }
    Write-Host ""
}

# Show slowest requests
Write-Host "TOP 10 SLOWEST REQUESTS:" -ForegroundColor Yellow
$sortedResults | Sort-Object ClientMs -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Host "  #$($_.Index.ToString().PadLeft(3)) | $($_.ClientMs.ToString().PadLeft(5))ms | $($_.Query)"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Test completed at: $(Get-Date)" -ForegroundColor Yellow
