# Zabbix 7.0 setup

1. Install Zabbix Agent 2 on the Windows host. Copy the collector to `C:\Program Files\Zabbix Agent 2\scripts\windows-backup-monitor.ps1`.
2. Include `zabbix/windows-backup-monitor.conf` in the Agent 2 configuration. The `UserParameter` calls the script with `-NoLogo -NoProfile -NonInteractive`; it does not change execution policy.
3. Check the script's execution policy and file permissions. Run it interactively, then in the **actual service account context**. Confirm exactly one JSON document, `schema_version: 1`, two provider states, and expected jobs. If the service account cannot read the Event Log or SQL module, resolve the Windows permissions; an Administrator console test alone is insufficient.
4. Import `zabbix/zabbix_template_windows_backup_monitor.yaml` in **Data collection → Templates → Import**. Link **Windows backup monitor by Zabbix agent 2** to the host.
5. Check the master item `windows.backup.monitor.get` (5 minute interval, 1 day history), summaries, and discovered jobs. Confirm each job has a different `{#JOBUID}` and nine dependent items.
6. Set `{$BACKUP.MAX.SUCCESS.AGE}` (default `26h`) and `{$BACKUP.MAX.RUN.TIME}` (default `12h`) for your backup schedule. Validate the failed, canceled, warning, stale, long-running, provider error, and no-data triggers against safe test data.

The master preprocessing parses JSON and requires schema version 1 plus array-valued `providers` and `jobs`. Invalid output makes the master unsupported; it cannot become a healthy zero-job result. Per-job JavaScript preprocessing returns `null` for missing values, which discards them rather than writing zero. Dependent discovery extracts `$.jobs`; its lost-job policy disables immediately and deletes after 7 days.

Import the template into a real Zabbix 7.0 server before production use. This repository does not contain an exported confirmation from a live server. Check lost-job behavior and service permissions there. No supported provider installed means two healthy `detected=false` states and no provider-error alarm.
