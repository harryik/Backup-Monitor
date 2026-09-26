$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/windows-backup-monitor.ps1')

# Stubs let Pester run without either backup product installed.
function Get-SqlBackupJob { param($ErrorAction) }
function Get-SqlBackupJobStatus { param($JobName, $ErrorAction) }

function Read-VeeamFixture {
    param([string]$Name)
    Convert-VeeamEventXml (Get-Content (Join-Path $PSScriptRoot "fixtures/veeam/$Name.xml") -Raw -Encoding UTF8)
}

Describe 'Windows backup monitor schema and identity' {
    It 'makes stable provider-scoped lowercase SHA-256 identifiers' {
        $a = Get-JobUid 'veeam-agent' 'Łódź "A\B"'
        $a | Should Be (Get-JobUid 'veeam-agent' 'Łódź "A\B"')
        $a | Should Match '^veeam-agent-[0-9a-f]{32}$'
        $a | Should Not Be (Get-JobUid 'sql-backup-master' 'Łódź "A\B"')
    }
    It 'keeps unavailable times null and does not invent zero' {
        $job = New-JobRecord 'veeam-agent' 'empty' $null $false 6 $null $null $null $null $null 1000
        $job.last_success_epoch | Should BeNullOrEmpty
        $job.last_success_age_seconds | Should BeNullOrEmpty
        $job.duration_seconds | Should BeNullOrEmpty
        (New-JobRecord 'veeam-agent' 'future' $null $false 1 $null $null 2000 $null $null 1000).last_success_age_seconds | Should BeNullOrEmpty
    }
    It 'emits only valid JSON with arrays when providers are absent' {
        $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'src/windows-backup-monitor.ps1') -Provider SqlBackupMaster
        $LASTEXITCODE | Should Be 0
        @($output).Count | Should Be 1
        $json = $output | ConvertFrom-Json
        $json.schema_version | Should Be 1
        @($json.providers).Count | Should Be 1
        @($json.jobs).Count | Should Be 0
    }
}

Describe 'Veeam structured Event Log adapter' {
    It 'parses start, success, warning, failure and Unicode job names' {
        (Read-VeeamFixture '110-start').Id | Should Be 110
        (Read-VeeamFixture '190-success').StatusCode | Should Be 1
        (Read-VeeamFixture '190-warning').StatusCode | Should Be 2
        (Read-VeeamFixture '190-failed').StatusCode | Should Be 3
        (Read-VeeamFixture '190-unicode').Job | Should Be 'Łódź "SQL\A"'
    }
    It 'keeps multiple jobs independent and computes UTC duration and success age' {
        $events = @((Read-VeeamFixture '110-start'), (Read-VeeamFixture '110-second-job'),
            (Read-VeeamFixture '191-retry'), (Read-VeeamFixture '190-success'), (Read-VeeamFixture '190-unicode'))
        $jobs = @(Convert-VeeamEventsToJobs $events 1790334000)
        $jobs.Count | Should Be 3
        $a = $jobs | Where-Object job -eq 'Job A'
        $a.status_code | Should Be 1
        $a.duration_seconds | Should Be 1800
        $a.last_success_age_seconds | Should Be 1800
        $a.last_start_epoch | Should Be 1790330400
        ($jobs | Where-Object job -eq 'Job B').status_code | Should Be 4
    }
    It 'does not treat retry as final success and keeps prior success after failure' {
        $events = @((Read-VeeamFixture '110-start'), (Read-VeeamFixture '190-success'),
            (Read-VeeamFixture '191-retry'), (Read-VeeamFixture '190-failed'))
        $job = @(Convert-VeeamEventsToJobs $events 1790340000)[0]
        $job.status_code | Should Be 3
        $job.last_success_epoch | Should Be 1790332200
        $job.duration_seconds | Should BeNullOrEmpty
    }
    It 'rejects events without structured job identity' {
        { Convert-VeeamEventXml '<Event><System><EventID>190</EventID><Level>4</Level><TimeCreated SystemTime="2026-09-25T10:30:00Z"/></System></Event>' } | Should Throw
    }
}

Describe 'SQL Backup Master object adapter' {
    It 'keeps three jobs and Unicode identities independent' {
        $names = @('ENOVA', 'Sprzedaż "A\B"', 'Archive')
        $jobs = @($names | ForEach-Object {
            Convert-SqlJobToRecord ([pscustomobject]@{ JobName = $_; IsEnabled = $true }) ([pscustomobject]@{ LastRunOutcome = 'Success'; LastRunDate = [datetime]'2026-09-25T10:00:00Z'; LastRunFinish = [datetime]'2026-09-25T10:30:00Z' }) 1790334000
        })
        $jobs.Count | Should Be 3
        @($jobs | ForEach-Object { $_['job_uid'] } | Sort-Object -Unique).Count | Should Be 3
        @($jobs | Where-Object status_code -eq 1).Count | Should Be 3
    }
    It 'distinguishes disabled, running, failed and never-run jobs' {
        (Convert-SqlJobToRecord ([pscustomobject]@{JobName='D';IsEnabled=$false}) ([pscustomobject]@{}) 1790334000).status_code | Should Be 7
        (Convert-SqlJobToRecord ([pscustomobject]@{JobName='R';IsEnabled=$true}) ([pscustomobject]@{IsRunning=$true;LastRunDate=[datetime]'2026-09-25T10:00:00Z'}) 1790334000).status_code | Should Be 4
        (Convert-SqlJobToRecord ([pscustomobject]@{JobName='F';IsEnabled=$true}) ([pscustomobject]@{LastRunOutcome='Failed'}) 1790334000).status_code | Should Be 3
        (Convert-SqlJobToRecord ([pscustomobject]@{JobName='N';IsEnabled=$true}) ([pscustomobject]@{}) 1790334000).status_code | Should Be 6
        (Convert-SqlJobToRecord ([pscustomobject]@{JobName='U';IsEnabled=$true;LastRunDate=[datetime]'2026-09-25T10:00:00Z'}) ([pscustomobject]@{}) 1790334000).status_code | Should Be 0
    }
    It 'leaves missing optional timestamps null' {
        $job = Convert-SqlJobToRecord ([pscustomobject]@{JobName='N';IsEnabled=$true}) ([pscustomobject]@{}) 1790334000
        $job.last_finish_epoch | Should BeNullOrEmpty
        $job.next_run_epoch | Should BeNullOrEmpty
        $job.last_success_age_seconds | Should BeNullOrEmpty
    }
    It 'parses explicit string booleans without treating false as true' {
        $job = Convert-SqlJobToRecord ([pscustomobject]@{JobName='D';IsEnabled='False'}) ([pscustomobject]@{IsRunning='False'}) 1790334000
        $job.enabled | Should Be $false
        $job.running | Should Be $false
        $job.status_code | Should Be 7
    }
}

Describe 'Provider isolation' {
    It 'marks a missing SQL module absent and healthy' {
        Mock Test-SqlModuleAvailable { $false }
        $result = Get-SqlProvider 1790334000
        $result.State.detected | Should Be $false
        $result.State.ok | Should Be $true
    }
    It 'marks SQL import failure as a provider error' {
        Mock Test-SqlModuleAvailable { $true }
        Mock Import-Module { throw 'import failed' }
        $result = Get-SqlProvider 1790334000
        $result.State.detected | Should Be $true
        $result.State.ok | Should Be $false
    }
    It 'returns a healthy empty list when SQL has zero jobs' {
        Mock Test-SqlModuleAvailable { $true }
        Mock Import-Module { }
        Mock Get-SqlBackupJob { @() }
        $result = Get-SqlProvider 1790334000
        $result.State.ok | Should Be $true
        $result.Jobs.Count | Should Be 0
    }
    It 'keeps three SQL status queries and job identities separate' {
        Mock Test-SqlModuleAvailable { $true }
        Mock Import-Module { }
        Mock Get-SqlBackupJob {
            @([pscustomobject]@{JobName='A';IsEnabled=$true},
              [pscustomobject]@{JobName='B';IsEnabled=$true},
              [pscustomobject]@{JobName='Łódź';IsEnabled=$true})
        }
        Mock Get-SqlBackupJobStatus { [pscustomobject]@{LastRunOutcome='Success';CurrentState='Idle'} }
        $result = Get-SqlProvider 1790334000
        $result.State.ok | Should Be $true
        $result.Jobs.Count | Should Be 3
        @($result.Jobs | ForEach-Object { $_['job_uid'] } | Sort-Object -Unique).Count | Should Be 3
    }
    It 'passes a quoted Unicode name as a single JobName parameter' {
        Mock Test-SqlModuleAvailable { $true }
        Mock Import-Module { }
        Mock Get-SqlBackupJob { [pscustomobject]@{JobName='Łódź "A\B"';IsEnabled=$true} }
        Mock Get-SqlBackupJobStatus {
            if ($JobName -ne 'Łódź "A\B"') { throw 'JobName changed' }
            [pscustomobject]@{LastRunOutcome='Success'}
        }
        $result = Get-SqlProvider 1790334000
        $result.State.ok | Should Be $true
        $result.Jobs[0].job | Should Be 'Łódź "A\B"'
    }
    It 'reports SQL enumeration failure without inventing zero healthy jobs' {
        Mock Test-SqlModuleAvailable { $true }
        Mock Import-Module { }
        Mock Get-SqlBackupJob { throw 'query failed' }
        $result = Get-SqlProvider 1790334000
        $result.State.detected | Should Be $true
        $result.State.ok | Should Be $false
    }
    It 'retains a failed SQL job identity when its status query fails' {
        Mock Test-SqlModuleAvailable { $true }
        Mock Import-Module { }
        Mock Get-SqlBackupJob { [pscustomobject]@{JobName='ENOVA';IsEnabled=$true} }
        Mock Get-SqlBackupJobStatus { throw 'query failed' }
        $result = Get-SqlProvider 1790334000
        $result.State.ok | Should Be $false
        $result.Jobs.Count | Should Be 1
        $result.Jobs[0].status_code | Should Be 0
    }
    It 'retains healthy provider data after another provider failure' {
        Mock Get-VeeamProvider { New-ProviderResult 'veeam-agent' $true $false 'query failed' }
        Mock Get-SqlProvider { New-ProviderResult 'sql-backup-master' $true $true $null @((New-JobRecord 'sql-backup-master' 'ENOVA' $true $false 1 $null $null $null $null $null 1000)) }
        $document = Invoke-BackupMonitor 'Auto' 30 1000
        @($document.providers).Count | Should Be 2
        @($document.jobs).Count | Should Be 1
    }
    It 'defaults to a 30 day Veeam lookback' {
        Mock Get-VeeamProvider { New-ProviderResult 'veeam-agent' $false $true $null }
        $null = Invoke-BackupMonitor 'VeeamAgent'
        Assert-MockCalled Get-VeeamProvider -Times 1 -ParameterFilter { $LookbackDays -eq 30 }
    }
}






