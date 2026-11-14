$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dataPath = Join-Path $root 'data'
$events = @(Import-Csv (Join-Path $dataPath 'usage_events.csv'))
$models = @(Import-Csv (Join-Path $dataPath 'model_rates.csv'))
$departments = @(Import-Csv (Join-Path $dataPath 'department_rates.csv'))

if ($events.Count -eq 0) { throw 'usage_events.csv is empty.' }
if (@($events | Group-Object event_id | Where-Object Count -gt 1).Count -gt 0) {
    throw 'usage_events.csv contains duplicate event_id values.'
}
if (@($models | Group-Object model | Where-Object Count -gt 1).Count -gt 0) {
    throw 'model_rates.csv contains duplicate model values.'
}
if (@($departments | Group-Object department | Where-Object Count -gt 1).Count -gt 0) {
    throw 'department_rates.csv contains duplicate department values.'
}

$modelNames = @{}
foreach ($model in $models) { $modelNames[$model.model] = $true }
$departmentNames = @{}
foreach ($department in $departments) { $departmentNames[$department.department] = $true }
$badRows = 0
foreach ($event in $events) {
    $parsedDate = [DateTime]::MinValue
    $validDate = [DateTime]::TryParseExact(
        $event.occurred_at,
        'yyyy-MM-dd HH:mm:ss',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )
    if (!$validDate -or !$modelNames.ContainsKey($event.model) -or !$departmentNames.ContainsKey($event.department)) {
        $badRows++
        continue
    }
    $invalidValues = $event.outcome -notin @('success', 'partial', 'failed')
    $invalidValues = $invalidValues -or ([int]$event.input_tokens -lt 0)
    $invalidValues = $invalidValues -or ([int]$event.output_tokens -lt 0)
    $invalidValues = $invalidValues -or ([double]$event.minutes_saved -lt 0)
    $invalidValues = $invalidValues -or ([double]$event.review_minutes -lt 0)
    if ($invalidValues) {
        $badRows++
    }
}
if ($badRows -gt 0) { throw ("Found {0} rows with invalid values or missing rate-card keys." -f $badRows) }

Write-Output ("PASS: {0:N0} events; unique IDs; valid dates, outcomes, tokens, and rate-card keys." -f $events.Count)
