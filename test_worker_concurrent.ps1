# Test 50 concurrent queries against Worker /rag-search-auth endpoint

$queries = @(
    "what is my resume about",
    "find documents about python",
    "search for machine learning notes",
    "what did I save about kubernetes",
    "find my travel documents",
    "notes about cooking recipes",
    "what is cognee",
    "search for interview preparation",
    "find documents about AWS",
    "what are my project notes",
    "search for budget planning",
    "find notes about meditation",
    "what did I save about fitness",
    "documents about home renovation",
    "find my reading list",
    "notes about productivity",
    "what is in my work documents",
    "search for meeting notes",
    "find documents about investments",
    "notes about learning goals",
    "what did I save about health",
    "search for vacation planning",
    "find my tech notes",
    "documents about personal growth",
    "notes about side projects",
    "what is my password manager",
    "search for shopping lists",
    "find documents about cars",
    "notes about gardening",
    "what did I save about music",
    "search for book summaries",
    "find my financial notes",
    "documents about family",
    "notes about hobbies",
    "what is in my research notes",
    "search for gift ideas",
    "find documents about insurance",
    "notes about career goals",
    "what did I save about movies",
    "search for workout routines",
    "find my study notes",
    "documents about pets",
    "notes about relationships",
    "what is my daily routine",
    "search for meal prep",
    "find documents about taxes",
    "notes about mental health",
    "what did I save about sports",
    "search for home automation",
    "find my journal entries"
)

$apiKey = "na_Af5k1WlJmFUNgdkqvOtMeIgtm8U609TYS-Pg4t4YKUU"
$workerUrl = "https://notesapp-vector-search.monocle0712.workers.dev/rag-search-auth"

Write-Host "Testing 50 concurrent queries against Worker /rag-search-auth..."
Write-Host "URL: $workerUrl"
Write-Host ""

$startTime = Get-Date

# Start all jobs
$jobs = @()
foreach ($query in $queries) {
    $job = Start-Job -ScriptBlock {
        param($url, $key, $query)
        $queryStart = Get-Date
        try {
            $body = @{ query = $query; max_results = 5 } | ConvertTo-Json
            $response = Invoke-RestMethod -Uri $url -Method POST -Headers @{
                "Content-Type" = "application/json"
                "X-API-Key" = $key
            } -Body $body -TimeoutSec 60
            
            $clientTime = ((Get-Date) - $queryStart).TotalMilliseconds
            @{
                Query = $query.Substring(0, [Math]::Min(25, $query.Length))
                Success = $true
                ClientMs = [math]::Round($clientTime)
                BackendMs = $response.metadata.timing.total_ms
                Results = $response.results.Count
            }
        } catch {
            $clientTime = ((Get-Date) - $queryStart).TotalMilliseconds
            @{
                Query = $query.Substring(0, [Math]::Min(25, $query.Length))
                Success = $false
                ClientMs = [math]::Round($clientTime)
                BackendMs = 0
                Results = 0
                Error = $_.Exception.Message
            }
        }
    } -ArgumentList $workerUrl, $apiKey, $query
    $jobs += $job
}

# Wait for all jobs
$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

$endTime = Get-Date
$totalTime = ($endTime - $startTime).TotalSeconds

# Display results
Write-Host ""
Write-Host "Query                      OK     ClientMs  BackendMs  Results"
Write-Host "------------------------------------------------------------"
foreach ($r in $results) {
    $ok = if ($r.Success) { "Yes" } else { "No" }
    Write-Host ("{0,-25} {1,-5} {2,8}  {3,9}  {4,7}" -f $r.Query, $ok, $r.ClientMs, $r.BackendMs, $r.Results)
}

# Calculate statistics
$successful = $results | Where-Object { $_.Success }
$failed = $results | Where-Object { -not $_.Success }

$avgClient = [math]::Round(($successful | Measure-Object -Property ClientMs -Average).Average)
$avgBackend = [math]::Round(($successful | Measure-Object -Property BackendMs -Average).Average)
$maxClient = ($successful | Measure-Object -Property ClientMs -Maximum).Maximum
$minClient = ($successful | Measure-Object -Property ClientMs -Minimum).Minimum

Write-Host ""
Write-Host "========== RESULTS =========="
Write-Host "Total wall clock time: $([math]::Round($totalTime, 1))s"
Write-Host "Successful: $($successful.Count) / 50"
Write-Host "Failed: $($failed.Count)"
Write-Host ""
Write-Host "Client-side timing (includes network):"
Write-Host "  Average: ${avgClient}ms"
Write-Host "  Min: ${minClient}ms"
Write-Host "  Max: ${maxClient}ms"
Write-Host ""
Write-Host "Backend timing (Worker reported):"
Write-Host "  Average: ${avgBackend}ms"
