# Provider mapping and host validation

## Veeam Agent

The collector makes one bounded `Get-WinEvent` query of the local **Veeam Agent** log for IDs 110 (start), 190 (final result), and 191 (retry). The default window is 30 days. Event 191 does not count as a final success. A start newer than the latest final 190 is reported as running. Event 190 uses structured `EventData` status when available, otherwise the documented event severity: Information = Success, Warning = Warning, Error = Failed.

The XML adapter accepts named `JobName`, `Job`, or `BackupJobName` fields. It provisionally accepts the first unnamed `EventData` field as the job name. If no structured job name is available, the provider reports a parse error; it never silently reports zero jobs. The included XML fixtures are synthetic and are **not** captured Veeam records. Confirm the field mapping and severity against sanitized real samples of success, warning, failure, retry, multiple jobs, and Unicode names. The collector does not parse localized rendered messages.

The Event Log does not provide a documented stable job ID in the referenced event listing, so UID identity uses the job name. Renaming a job changes its UID. Configured jobs that have never generated an event may be missing.
The Event Log source does not expose a verified enabled flag or next schedule in this adapter, so `enabled` and `next_run_epoch` remain `null` for Veeam jobs.

## SQL Backup Master

The official documentation confirms `Get-SqlBackupJob`, `Get-SqlBackupJobStatus -JobName`, and examples of `JobName`, `IsEnabled`, `LastRunDate`, and `LastRunOutcome`. The collector enumerates all jobs without `-EnabledOnly`, imports the module once, then queries status once per job. Job names are passed as a PowerShell parameter value, not interpolated into executable code.

`Convert-SqlJobToRecord` is the only status-object adapter. It tentatively recognizes `IsRunning`/`Running`, `CurrentState`/`State`/`Status`, `LastRunStart`/`LastStartTime`/`LastRunDate`, `LastRunFinish`/`LastFinishTime`/`LastEndTime`, `LastSuccessDate`/`LastSuccessfulRun`/`LastSuccessTime`, and `NextRunDate`/`NextScheduledRun`/`NextRunTime`. These exact names are **not confirmed by the public cmdlet page**. Missing optional values remain `null`; an unknown outcome stays `Unknown` rather than becoming Success.

On an SQL Backup Master 8.x+ host, inspect objects without formatting them into text:

```powershell
Get-SqlBackupJob | Select-Object *
Get-SqlBackupJobStatus -JobName 'A test job' | Select-Object *
```

Record only sanitized property names and non-sensitive sample values. Validate zero, one, three, and many jobs; disabled, running, success, failure, never run; Unicode names; and missing optional values. Repeat under the Zabbix Agent 2 service account. If status query fails for a job, its identity remains in JSON with `Unknown` status and provider `ok=false`.

## Time and errors

All output timestamps are Unix seconds UTC. PowerShell `DateTime` values with unspecified kind are treated by .NET as local time; verify source kinds during host validation. Future or unavailable success times yield a `null` age. Provider errors use fixed messages to avoid exposing sensitive exception content. Provider absence is healthy; an installed but inaccessible provider is an error.
