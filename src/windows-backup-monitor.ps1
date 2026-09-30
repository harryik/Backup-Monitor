[CmdletBinding()]
param(
    [ValidateSet('Auto', 'VeeamAgent', 'SqlBackupMaster')][string]$Provider = 'Auto',
    [ValidateRange(1, 3650)][int]$VeeamLookbackDays = 30
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'

function Get-ObjectField {
    param($InputObject, [string[]]$Names)
    if ($null -eq $InputObject) { return $null }
    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($name) -and $null -ne $InputObject[$name]) { return $InputObject[$name] }
        } else {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
        }
    }
    return $null
}

function Convert-ToEpoch {
    param($Value)
    if ($null -eq $Value -or $Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        if ($Value -is [DateTimeOffset]) { $date = $Value }
        elseif ($Value -is [DateTime]) { $date = [DateTimeOffset]$Value }
        else { return $null }
        if ($date.Year -le 1) { return $null }
        return [long]$date.ToUnixTimeSeconds()
    } catch { return $null }
}

function Convert-ToNullableBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [int] -or $Value -is [long]) {
        if ($Value -eq 0) { return $false }
        if ($Value -eq 1) { return $true }
    }
    switch (([string]$Value).Trim().ToLowerInvariant()) {
        'true' { return $true }
        'false' { return $false }
        '1' { return $true }
        '0' { return $false }
        default { return $null }
    }
}

function Get-JobUid {
    param([string]$ProviderId, [string]$NativeId)
    $bytes = [Text.Encoding]::UTF8.GetBytes($ProviderId + [char]0 + $NativeId)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $hex = -join ($hash[0..15] | ForEach-Object { $_.ToString('x2') })
    return $ProviderId + '-' + $hex
}

function Get-StatusCode {
    param($Value)
    if ($null -eq $Value) { return 0 }
    $word = ([string]$Value).Trim().ToLowerInvariant()
    switch -Regex ($word) {
        '^(success|succeeded|completed|ok)$' { return 1 }
        '^(warning|warn|completedwithwarnings)$' { return 2 }
        '^(failed|failure|error)$' { return 3 }
        '^(running|inprogress|in progress|active)$' { return 4 }
        '^(canceled|cancelled)$' { return 5 }
        '^(neverrun|never run|notrun|not run)$' { return 6 }
        '^(disabled)$' { return 7 }
        default { return 0 }
    }
}

function New-JobRecord {
    param([string]$ProviderId, [string]$Name, $Enabled, $Running, [int]$StatusCode,
          $LastStart, $LastFinish, $LastSuccess, $Duration, $NextRun, [long]$NowEpoch)
    $labels = @('Unknown', 'Success', 'Warning', 'Failed', 'Running', 'Canceled', 'NeverRun', 'Disabled')
    $age = $null
    if ($null -ne $LastSuccess -and [long]$LastSuccess -le $NowEpoch) {
        $age = [long]($NowEpoch - [long]$LastSuccess)
    }
    return [ordered]@{
        provider = $ProviderId
        job_uid = Get-JobUid $ProviderId $Name
        job = $Name
        enabled = $Enabled
        running = $Running
        status_code = $StatusCode
        status = $labels[$StatusCode]
        last_start_epoch = $LastStart
        last_finish_epoch = $LastFinish
        last_success_epoch = $LastSuccess
        last_success_age_seconds = $age
        duration_seconds = $Duration
        next_run_epoch = $NextRun
    }
}

function New-ProviderResult {
    param([string]$ProviderId, [bool]$Detected, [bool]$Ok, $ErrorText, [object[]]$Jobs = @())
    return [pscustomobject]@{
        State = [ordered]@{ provider = $ProviderId; detected = $Detected; ok = $Ok; error = $ErrorText }
        Jobs = @($Jobs)
    }
}

function Convert-VeeamEventXml {
    param([string]$XmlText)
    [xml]$xml = $XmlText
    $eventId = [int]$xml.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="EventID"]').InnerText
    if ($eventId -notin @(110, 190, 191)) { throw 'Unexpected Veeam event ID' }
    $timeNode = $xml.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="TimeCreated"]')
    $timestamp = [DateTimeOffset]::Parse([string]$timeNode.Attributes['SystemTime'].Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal)
    $data = @($xml.SelectNodes('/*[local-name()="Event"]/*[local-name()="EventData"]/*[local-name()="Data"]'))
    $name = $null
    $result = $null
    $jobId = $null
    $sessionId = $null

    foreach ($entry in $data) {
        $field = [string]$entry.GetAttribute('Name')
        if ($field -in @('JobName', 'Job', 'BackupJobName')) { $name = [string]$entry.InnerText }
        if ($field -in @('Result', 'Status', 'JobStatus')) { $result = [string]$entry.InnerText }
        if ($field -in @('JobId', 'JobID', 'BackupJobId')) { $jobId = [string]$entry.InnerText }
        if ($field -in @('SessionId', 'SessionID')) { $sessionId = [string]$entry.InnerText }
    }

    $isPositional = $data.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$data[0].GetAttribute('Name'))
    if ($isPositional) {
        if ($data.Count -gt 0) {
            $candidate = [string]$data[0].InnerText
            $parsed = [Guid]::Empty
            if ([Guid]::TryParse($candidate, [ref]$parsed)) { $sessionId = $parsed.ToString() }
        }
        if ($data.Count -gt 1) {
            $candidate = [string]$data[1].InnerText
            $parsed = [Guid]::Empty
            if ([Guid]::TryParse($candidate, [ref]$parsed)) { $jobId = $parsed.ToString() }
        }

        $options = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        foreach ($entry in $data) {
            $message = [string]$entry.InnerText
            if ([string]::IsNullOrWhiteSpace($message)) { continue }

            $match = [regex]::Match($message,
                "^Veeam Agent '(?<job>.+?)' has been started(?: by user .+?)?\.", $options)
            if (-not $match.Success) {
                $match = [regex]::Match($message,
                    "^Veeam Agent (?<job>.+?) has been started(?: by user .+?)?\.", $options)
            }
            if ($match.Success) {
                $name = $match.Groups['job'].Value
                break
            }

            $match = [regex]::Match($message,
                "^Veeam Agent '(?<job>.+?)' finished with (?<status>Success|Warning|Error)(?: and will be retried)?\.", $options)
            if (-not $match.Success) {
                $match = [regex]::Match($message,
                    "^Veeam Agent (?<job>.+?) finished with (?<status>Success|Warning|Error)(?: and will be retried)?\.", $options)
            }
            if ($match.Success) {
                $name = $match.Groups['job'].Value
                $result = $match.Groups['status'].Value
                break
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($jobId)) {
        $parsed = [Guid]::Empty
        if ([Guid]::TryParse($jobId, [ref]$parsed)) { $jobId = $parsed.ToString() }
    }
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        $parsed = [Guid]::Empty
        if ([Guid]::TryParse($sessionId, [ref]$parsed)) { $sessionId = $parsed.ToString() }
    }

    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Veeam event has no structured job name' }

    $code = 0
    if ($eventId -eq 190) {
        $code = Get-StatusCode $result
        if ($code -eq 0) {
            $levelNode = $xml.SelectSingleNode('/*[local-name()="Event"]/*[local-name()="System"]/*[local-name()="Level"]')
            switch ([int]$levelNode.InnerText) {
                2 { $code = 3 }
                3 { $code = 2 }
                4 { $code = 1 }
            }
        }
    }

    return [pscustomobject]@{
        Id = $eventId
        Job = $name
        JobId = $jobId
        SessionId = $sessionId
        Epoch = [long]$timestamp.ToUnixTimeSeconds()
        StatusCode = $code
    }
}

function Convert-VeeamEventsToJobs {
    param([object[]]$Events, [long]$NowEpoch)
    $states = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($event in @($Events | Sort-Object Epoch, Id)) {
        $jobId = $null
        $jobIdProperty = $event.PSObject.Properties['JobId']
        if ($null -ne $jobIdProperty) { $jobId = [string]$jobIdProperty.Value }
        $identity = if (-not [string]::IsNullOrWhiteSpace($jobId)) { 'id:' + $jobId } else { 'name:' + [string]$event.Job }

        if (-not $states.ContainsKey($identity)) {
            $states.Add($identity, [ordered]@{ Name = $event.Job; Start = $null; Finish = $null;
                Success = $null; Result = 0; CompletedDuration = $null })
        }
        $state = $states[$identity]
        if (-not [string]::IsNullOrWhiteSpace([string]$event.Job)) { $state.Name = [string]$event.Job }

        if ($event.Id -eq 110) {
            if ($null -eq $state.Start -or ($null -ne $state.Finish -and [long]$event.Epoch -gt [long]$state.Finish)) {
                $state.Start = [long]$event.Epoch
            }
        }
        elseif ($event.Id -eq 190) {
            $previousFinish = $state.Finish
            $state.Finish = [long]$event.Epoch
            $state.Result = [int]$event.StatusCode
            if ($state.Result -eq 1) { $state.Success = [long]$event.Epoch }
            $state.CompletedDuration = $null
            if ($null -ne $state.Start -and $state.Start -le $state.Finish -and
                ($null -eq $previousFinish -or $state.Start -gt $previousFinish)) {
                $state.CompletedDuration = [long]($state.Finish - $state.Start)
            }
        }
    }

    $jobs = @()
    foreach ($identity in @($states.Keys | Sort-Object -CaseSensitive)) {
        $state = $states[$identity]
        $running = $null -ne $state.Start -and ($null -eq $state.Finish -or $state.Start -gt $state.Finish)
        $code = [int]$state.Result
        $duration = $state.CompletedDuration
        if ($running) {
            $code = 4
            $duration = $null
            if ($state.Start -le $NowEpoch) { $duration = [long]($NowEpoch - $state.Start) }
        } elseif ($null -eq $state.Finish) { $code = 6 }
        $jobs += New-JobRecord 'veeam-agent' $state.Name $null $running $code $state.Start $state.Finish $state.Success $duration $null $NowEpoch
    }
    return $jobs
}

function Get-VeeamProvider {
    param([int]$LookbackDays, [long]$NowEpoch)
    $id = 'veeam-agent'
    try { $null = Get-WinEvent -ListLog 'Veeam Agent' -ErrorAction Stop }
    catch {
        if ($_.Exception -is [System.Diagnostics.Eventing.Reader.EventLogNotFoundException] -or
            $_.FullyQualifiedErrorId -like 'NoMatchingLogsFound*') {
            return New-ProviderResult $id $false $true $null
        }
        return New-ProviderResult $id $true $false 'Cannot inspect Veeam Agent Event Log'
    }
    try {
        $start = [DateTime]::UtcNow.AddDays(-$LookbackDays)
        $raw = @(Get-WinEvent -FilterHashtable @{ LogName = 'Veeam Agent'; Id = @(110, 190, 191); StartTime = $start } -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $raw = @() }
        else { return New-ProviderResult $id $true $false 'Failed to query Veeam Agent events' }
    }
    try {
        $events = @()
        foreach ($item in $raw) { $events += Convert-VeeamEventXml $item.ToXml() }
        $jobs = @(Convert-VeeamEventsToJobs $events $NowEpoch)
        return New-ProviderResult $id $true $true $null $jobs
    } catch { return New-ProviderResult $id $true $false 'Failed to parse Veeam Agent events' }
}

function Convert-SqlJobToRecord {
    param($JobObject, $StatusObject, [long]$NowEpoch)
    # JobName and IsEnabled are documented examples. Status property names require host validation.
    $name = Get-ObjectField $JobObject @('JobName')
    if ([string]::IsNullOrWhiteSpace([string]$name)) { throw 'SQL Backup Master job has no JobName' }
    $enabledRaw = Get-ObjectField $JobObject @('IsEnabled')
    $enabled = Convert-ToNullableBool $enabledRaw
    $runningRaw = Get-ObjectField $StatusObject @('IsRunning', 'Running')
    $stateRaw = Get-ObjectField $StatusObject @('CurrentState', 'State', 'Status')
    $running = Convert-ToNullableBool $runningRaw
    if ($null -eq $running -and (Get-StatusCode $stateRaw) -eq 4) { $running = $true }
    $outcome = Get-ObjectField $StatusObject @('LastRunOutcome', 'LastOutcome', 'LastResult')
    if ($null -eq $outcome) { $outcome = Get-ObjectField $JobObject @('LastRunOutcome') }
    $code = Get-StatusCode $outcome
    if ($code -eq 0) { $code = Get-StatusCode $stateRaw }
    $start = Convert-ToEpoch (Get-ObjectField $StatusObject @('LastRunStart', 'LastStartTime', 'LastRunDate'))
    if ($null -eq $start) { $start = Convert-ToEpoch (Get-ObjectField $JobObject @('LastRunDate')) }
    $finish = Convert-ToEpoch (Get-ObjectField $StatusObject @('LastRunFinish', 'LastFinishTime', 'LastEndTime'))
    $success = Convert-ToEpoch (Get-ObjectField $StatusObject @('LastSuccessDate', 'LastSuccessfulRun', 'LastSuccessTime'))
    if ($null -eq $enabled -or $enabled) {
        if ($running -eq $true) { $code = 4 }
        elseif ($code -eq 0 -and $null -eq $start -and $null -eq $finish) { $code = 6 }
    } else { $code = 7 }
    if ($null -eq $success -and $code -eq 1) { $success = $finish }
    $next = Convert-ToEpoch (Get-ObjectField $StatusObject @('NextRunDate', 'NextScheduledRun', 'NextRunTime'))
    $duration = $null
    if ($running -eq $true -and $null -ne $start -and $start -le $NowEpoch) {
        $duration = [long]($NowEpoch - $start)
    } elseif ($null -ne $start -and $null -ne $finish -and $finish -ge $start) {
        $duration = [long]($finish - $start)
    }
    return New-JobRecord 'sql-backup-master' ([string]$name) $enabled $running $code $start $finish $success $duration $next $NowEpoch
}

function Test-SqlModuleAvailable {
    return @(Get-Module -ListAvailable SQLBackupMaster -ErrorAction Stop).Count -gt 0
}

function Get-SqlProvider {
    param([long]$NowEpoch)
    $id = 'sql-backup-master'
    try { $available = Test-SqlModuleAvailable }
    catch { return New-ProviderResult $id $true $false 'Failed to inspect SQL Backup Master module' }
    if (-not $available) { return New-ProviderResult $id $false $true $null }
    try { Import-Module SQLBackupMaster -ErrorAction Stop | Out-Null }
    catch { return New-ProviderResult $id $true $false 'Failed to import SQL Backup Master module' }
    try { $rawJobs = @(Get-SqlBackupJob -ErrorAction Stop) }
    catch { return New-ProviderResult $id $true $false 'Failed to enumerate SQL Backup Master jobs' }
    $jobs = @()
    $errorText = $null
    foreach ($rawJob in $rawJobs) {
        $name = Get-ObjectField $rawJob @('JobName')
        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            $errorText = 'SQL Backup Master returned a job without JobName'
            continue
        }
        try {
            $status = Get-SqlBackupJobStatus -JobName ([string]$name) -ErrorAction Stop
            if ($null -eq $status) { throw 'Empty status' }
            $jobs += Convert-SqlJobToRecord $rawJob $status $NowEpoch
        } catch {
            $errorText = 'Failed to query SQL Backup Master job status'
            $jobs += New-JobRecord $id ([string]$name) (Convert-ToNullableBool (Get-ObjectField $rawJob @('IsEnabled'))) $null 0 $null $null $null $null $null $NowEpoch
        }
    }
    return New-ProviderResult $id $true ($null -eq $errorText) $errorText $jobs
}

function Invoke-BackupMonitor {
    param([string]$ProviderMode = 'Auto', [int]$LookbackDays = 30, [long]$NowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $results = @()
    if ($ProviderMode -in @('Auto', 'VeeamAgent')) { $results += Get-VeeamProvider $LookbackDays $NowEpoch }
    if ($ProviderMode -in @('Auto', 'SqlBackupMaster')) { $results += Get-SqlProvider $NowEpoch }
    $states = @($results | ForEach-Object { $_.State })
    $jobs = @($results | ForEach-Object { $_.Jobs } | Sort-Object provider, job_uid)
    return [ordered]@{ schema_version = 1; collected_at_epoch = $NowEpoch; providers = $states; jobs = $jobs }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { $document = Invoke-BackupMonitor $Provider $VeeamLookbackDays }
    catch { [Console]::Error.WriteLine('Backup monitor initialization failed'); exit 2 }
    try { $json = ConvertTo-Json -InputObject $document -Depth 8 -Compress -ErrorAction Stop }
    catch { [Console]::Error.WriteLine('Backup monitor JSON serialization failed'); exit 3 }
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        [Console]::WriteLine($json)
        exit 0
    } catch { [Console]::Error.WriteLine('Backup monitor output failed'); exit 4 }
}
