# Provider mapping and host validation

## Veeam Agent

The collector makes one bounded `Get-WinEvent` query of the local **Veeam Agent** log for IDs 110 (start), 190 (final result), and 191 (retry). The default window is 30 days. Event 191 does not count as a final success. A start newer than the latest final 190 is reported as running. Event 190 uses structured `EventData` status when available, otherwise the documented event severity: Information = Success, Warning = Warning, Error = Failed.

The XML adapter accepts named `JobName`, `Job`, or `BackupJobName` fields. It also supports the positional EventData layout observed on Veeam Agent for Microsoft Windows 13.x: the first GUID is the attempt/session ID, the second GUID is the stable job ID, and the final message contains the job name and result. Retry event 191 is non-final; repeated attempts are grouped by the stable job ID. If no job name can be extracted, the provider reports a parse error instead of silently returning zero jobs.

The output UID remains based on the job name for schema compatibility, so renaming a job changes its UID. Internally, retained Veeam events are correlated by stable JobId when available. Configured jobs that have never generated an event may be missing.
The Event Log source does not expose a verified enabled flag or next schedule in this adapter, so `enabled` and `next_run_epoch` remain `null` for Veeam jobs.

## SQL Backup Master

The official documentation confirms `Get-SqlBackupJob`, `Get-SqlBackupJobStatus -JobName`, and examples of `JobName`, `IsEnabled`, `LastRunDate`, and `LastRunOutcome`. SQL Backup Master 8.x exposes these cmdlets through the binary module `SQLBackupMaster.Cmdlet.dll`. The collector first uses an already loaded/auto-discoverable module, then falls back to locating the installed product from the registry and importing that DLL directly. An installed product whose cmdlet module cannot be loaded is reported as `detected=true, ok=false`, not as absent.

`Convert-SqlJobToRecord` is the only status-object adapter. It tentatively recognizes `IsRunning`/`Running`, `CurrentState`/`State`/`Status`, `LastRunStart`/`LastStartTime`/`LastRunDate`, `LastRunFinish`/`LastFinishTime`/`LastEndTime`, `LastSuccessDate`/`LastSuccessfulRun`/`LastSuccessTime`, and `NextRunDate`/`NextScheduledRun`/`NextRunTime`. These exact names are **not confirmed by the public cmdlet page**. Missing optional values remain `null`; an unknown outcome stays `Unknown` rather than becoming Success.

On an SQL Backup Master 8.x+ host, inspect objects without formatting them into text:

```powershell
Get-SqlBackupJob | Select-Object *
Get-SqlBackupJobStatus -JobName 'A test job' | Select-Object *
```

Record only sanitized property names and non-sensitive sample values. Validate zero, one, three, and many jobs; disabled, running, success, failure, never run; Unicode names; and missing optional values. Repeat under the Zabbix Agent 2 service account. If status query fails for a job, its identity remains in JSON with `Unknown` status and provider `ok=false`.

## Time and errors

All output timestamps are Unix seconds UTC. PowerShell `DateTime` values with unspecified kind are treated by .NET as local time; verify source kinds during host validation. Future or unavailable success times yield a `null` age. Provider errors use fixed messages to avoid exposing sensitive exception content. Provider absence is healthy; an installed but inaccessible provider is an error.
