$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dataPath = Join-Path $root 'data'
$random = [System.Random]::new(41726)

function Get-Choice {
    param([object[]]$items)
    return $items[$script:random.Next(0, $items.Count)]
}

function Get-Number([int]$minimum, [int]$maximum) {
    return $script:random.Next($minimum, $maximum + 1)
}

function Write-CsvFile($path, $rows) {
    $lines = @($rows | ConvertTo-Csv -NoTypeInformation)
    [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

$departmentRates = @(
    [pscustomobject]@{ department = 'Engineering'; loaded_labor_usd_per_hour = 78.00 },
    [pscustomobject]@{ department = 'Customer Support'; loaded_labor_usd_per_hour = 42.00 },
    [pscustomobject]@{ department = 'Marketing'; loaded_labor_usd_per_hour = 58.00 },
    [pscustomobject]@{ department = 'Finance'; loaded_labor_usd_per_hour = 67.00 },
    [pscustomobject]@{ department = 'Sales'; loaded_labor_usd_per_hour = 63.00 },
    [pscustomobject]@{ department = 'People Ops'; loaded_labor_usd_per_hour = 54.00 }
)

$modelRates = @(
    [pscustomobject]@{ model = 'Nova-Small'; input_usd_per_million = 30.00; output_usd_per_million = 120.00 },
    [pscustomobject]@{ model = 'Nova-Large'; input_usd_per_million = 200.00; output_usd_per_million = 800.00 },
    [pscustomobject]@{ model = 'Open-Compact'; input_usd_per_million = 8.00; output_usd_per_million = 30.00 }
)

$workflows = @{
    'Engineering' = @('code_review', 'data_query', 'document_summary')
    'Customer Support' = @('customer_reply', 'policy_lookup', 'document_summary')
    'Marketing' = @('content_draft', 'document_summary', 'data_query')
    'Finance' = @('data_query', 'document_summary', 'policy_lookup')
    'Sales' = @('customer_reply', 'content_draft', 'document_summary')
    'People Ops' = @('policy_lookup', 'document_summary', 'content_draft')
}
$baselineMinutes = @{
    code_review = 28
    customer_reply = 14
    document_summary = 18
    data_query = 24
    content_draft = 22
    policy_lookup = 12
}
$baseSuccess = @{
    code_review = 0.79
    customer_reply = 0.89
    document_summary = 0.85
    data_query = 0.74
    content_draft = 0.83
    policy_lookup = 0.78
}
$monthlyTaskCounts = @(1250, 1420, 1600, 1780, 1980, 2200)
$inputTokenRanges = @{
    code_review = @(1800, 12000)
    customer_reply = @(500, 3000)
    document_summary = @(2500, 14000)
    data_query = @(1200, 7000)
    content_draft = @(800, 4500)
    policy_lookup = @(900, 6000)
}
$outputTokenRanges = @{
    code_review = @(300, 2400)
    customer_reply = @(150, 1000)
    document_summary = @(250, 1800)
    data_query = @(200, 1400)
    content_draft = @(250, 1600)
    policy_lookup = @(120, 800)
}

$events = [System.Collections.Generic.List[object]]::new()
$eventNumber = 1
for ($month = 1; $month -le $monthlyTaskCounts.Count; $month++) {
    $daysInMonth = [DateTime]::DaysInMonth(2026, $month)
    for ($i = 0; $i -lt $monthlyTaskCounts[$month - 1]; $i++) {
        $department = Get-Choice -items @('Engineering', 'Customer Support', 'Marketing', 'Finance', 'Sales', 'People Ops')
        $workflow = Get-Choice -items $workflows[$department]
        $modelRoll = $random.NextDouble()
        if ($department -eq 'Engineering') {
            if ($modelRoll -lt 0.45) { $model = 'Nova-Large' }
            elseif ($modelRoll -lt 0.73) { $model = 'Nova-Small' }
            else { $model = 'Open-Compact' }
        }
        else {
            if ($modelRoll -lt 0.22) { $model = 'Nova-Large' }
            elseif ($modelRoll -lt 0.62) { $model = 'Nova-Small' }
            else { $model = 'Open-Compact' }
        }

        $outcomeRoll = $random.NextDouble()
        $successRate = $baseSuccess[$workflow]
        if ($department -eq 'Engineering' -and $workflow -eq 'code_review') { $successRate -= 0.04 }
        if ($department -eq 'Finance' -and $workflow -eq 'data_query') { $successRate -= 0.07 }
        if ($outcomeRoll -lt $successRate) { $outcome = 'success' }
        elseif ($outcomeRoll -lt ($successRate + 0.13)) { $outcome = 'partial' }
        else { $outcome = 'failed' }

        $tokensInRange = $inputTokenRanges[$workflow]
        $tokensOutRange = $outputTokenRanges[$workflow]
        $inputTokens = Get-Number $tokensInRange[0] $tokensInRange[1]
        $outputTokens = Get-Number $tokensOutRange[0] $tokensOutRange[1]
        $baseline = $baselineMinutes[$workflow]
        if ($outcome -eq 'success') {
            $savedShare = 0.28 + ($random.NextDouble() * 0.42)
            $reviewShare = 0.10 + ($random.NextDouble() * 0.20)
        }
        elseif ($outcome -eq 'partial') {
            $savedShare = 0.10 + ($random.NextDouble() * 0.24)
            $reviewShare = 0.22 + ($random.NextDouble() * 0.28)
        }
        else {
            $savedShare = 0.01 + ($random.NextDouble() * 0.08)
            $reviewShare = 0.18 + ($random.NextDouble() * 0.30)
        }

        $date = [DateTime]::new(2026, $month, (Get-Number 1 $daysInMonth), (Get-Number 8 17), (Get-Number 0 59), 0)
        $userNumber = Get-Number 1 40
        $events.Add([pscustomobject]@{
            event_id = ('EVT-{0:D6}' -f $eventNumber)
            occurred_at = $date.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            department = $department
            workflow = $workflow
            user_id = ('USR-{0}-{1:D3}' -f ($department -replace '[^A-Za-z]', '').ToUpperInvariant().Substring(0, 3), $userNumber)
            model = $model
            input_tokens = $inputTokens
            output_tokens = $outputTokens
            outcome = $outcome
            minutes_saved = [Math]::Round($baseline * $savedShare, 2)
            review_minutes = [Math]::Round($baseline * $reviewShare, 2)
        })
        $eventNumber++
    }
}

Write-CsvFile (Join-Path $dataPath 'department_rates.csv') $departmentRates
Write-CsvFile (Join-Path $dataPath 'model_rates.csv') $modelRates
Write-CsvFile (Join-Path $dataPath 'usage_events.csv') $events

Write-Output ("Generated {0:N0} synthetic task events in {1}" -f $events.Count, $dataPath)
