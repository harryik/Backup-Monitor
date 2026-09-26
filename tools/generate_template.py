"""Generate the committed Zabbix 7.0 YAML template without third-party packages."""

import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = "Windows backup monitor by Zabbix agent 2"
MASTER = "windows.backup.monitor.get"
NAMESPACE = uuid.UUID("744a02f0-fadf-4a1c-9ee5-a4e138a73d03")


def uid(name):
    return uuid.uuid5(NAMESPACE, name).hex


def step(script):
    return {"type": "JAVASCRIPT", "parameters": [script]}


def item(name, key, script, history="30d"):
    return {
        "uuid": uid("item:" + key),
        "name": name,
        "type": "DEPENDENT",
        "key": key,
        "history": history,
        "trends": "0",
        "value_type": "UNSIGNED",
        "preprocessing": [step(script)],
        "master_item": {"key": MASTER},
    }


def trigger(name, expression, priority, identity=None):
    return {
        "uuid": uid("trigger:" + (identity or name)),
        "expression": expression,
        "name": name,
        "priority": priority,
    }


def job_script(field, boolean=False):
    conversion = "return v ? 1 : 0;" if boolean else "return v;"
    return (
        "var d=JSON.parse(value);var uid='{#JOBUID}';"
        "for(var i=0;i<d.jobs.length;i++){"
        "if(d.jobs[i].job_uid===uid){"
        f"var v=d.jobs[i].{field};"
        "if(v===null||typeof v==='undefined')return null;"
        + conversion
        + "}}return null;"
    )


def job_item(label, suffix, field, boolean=False, units=None, history="30d", valuemap=False):
    key = f"windows.backup.job.{suffix}[{{#JOBUID}}]"
    result = item(f"Backup [{{#PROVIDER}}] {{#JOB}}: {label}", key, job_script(field, boolean), history)
    result["tags"] = [
        {"tag": "Application", "value": "Backup Monitoring"},
        {"tag": "component", "value": "backup-job"},
        {"tag": "provider", "value": "{#PROVIDER}"},
        {"tag": "job", "value": "{#JOB}"},
        {"tag": "jobuid", "value": "{#JOBUID}"},
    ]
    if units:
        result["units"] = units
    if valuemap:
        result["valuemap"] = {"name": "Windows backup job status"}
    return result


def yaml_lines(value, indent=0):
    pad = " " * indent
    if isinstance(value, dict):
        for key, child in value.items():
            if isinstance(child, (dict, list)):
                yield f"{pad}{key}:"
                yield from yaml_lines(child, indent + 2)
            else:
                yield f"{pad}{key}: {json.dumps(child, ensure_ascii=False)}"
    elif isinstance(value, list):
        for child in value:
            if isinstance(child, (dict, list)):
                yield f"{pad}-"
                yield from yaml_lines(child, indent + 2)
            else:
                yield f"{pad}- {json.dumps(child, ensure_ascii=False)}"


def main():
    validate = (
        "var d=JSON.parse(value);"
        "if(d.schema_version!==1||!Array.isArray(d.providers)||!Array.isArray(d.jobs))"
        "throw 'Invalid backup monitor schema';"
        "return value;"
    )
    master = {
        "uuid": uid("item:" + MASTER),
        "name": "Backup: Collector JSON",
        "type": "ZABBIX_PASSIVE",
        "key": MASTER,
        "delay": "1h",
        "history": "1d",
        "trends": "0",
        "value_type": "TEXT",
        "preprocessing": [step(validate)],
        "triggers": [
            trigger(
                "Backup: No valid collector data for 3 hours",
                f"nodata(/{TEMPLATE}/{MASTER},3h)=1",
                "WARNING",
                identity="Backup: No valid collector data for 15 minutes",
            )
        ],
    }
    summaries = [
        item("Backup: Total discovered jobs", "windows.backup.jobs.total", "return JSON.parse(value).jobs.length;"),
        item("Backup: Failed jobs", "windows.backup.jobs.failed", "var j=JSON.parse(value).jobs,n=0;for(var i=0;i<j.length;i++)if(j[i].status_code===3)n++;return n;"),
        item("Backup: Warning jobs", "windows.backup.jobs.warning", "var j=JSON.parse(value).jobs,n=0;for(var i=0;i<j.length;i++)if(j[i].status_code===2)n++;return n;"),
        item("Backup: Running jobs", "windows.backup.jobs.running", "var j=JSON.parse(value).jobs,n=0;for(var i=0;i<j.length;i++)if(j[i].running===true)n++;return n;"),
        item("Backup: Provider errors", "windows.backup.providers.errors", "var p=JSON.parse(value).providers,n=0;for(var i=0;i<p.length;i++)if(p[i].detected===true&&p[i].ok===false)n++;return n;"),
    ]
    summaries[-1]["triggers"] = [
        trigger("Backup: Provider query error", f"last(/{TEMPLATE}/windows.backup.providers.errors)>0", "WARNING")
    ]
    prototypes = [
        job_item("Last status", "status", "status_code", valuemap=True),
        job_item("Running", "running", "running", boolean=True),
        job_item("Enabled", "enabled", "enabled", boolean=True),
        job_item("Last start", "last_start", "last_start_epoch", units="unixtime"),
        job_item("Last finish", "last_finish", "last_finish_epoch", units="unixtime"),
        job_item("Last successful backup", "last_success", "last_success_epoch", units="unixtime"),
        job_item("Last successful backup age", "success_age", "last_success_age_seconds", units="s"),
        job_item("Duration", "duration", "duration_seconds", units="s"),
        job_item("Next run", "next_run", "next_run_epoch", units="unixtime", history="7d"),
    ]
    status = f"/{TEMPLATE}/windows.backup.job.status[{{#JOBUID}}]"
    age = f"/{TEMPLATE}/windows.backup.job.success_age[{{#JOBUID}}]"
    duration = f"/{TEMPLATE}/windows.backup.job.duration[{{#JOBUID}}]"
    discovery = {
        "uuid": uid("discovery:jobs"),
        "name": "Backup jobs discovery",
        "type": "DEPENDENT",
        "key": "windows.backup.jobs.discovery",
        "lifetime_type": "DELETE_AFTER",
        "lifetime": "7d",
        "enabled_lifetime_type": "DISABLE_IMMEDIATELY",
        "master_item": {"key": MASTER},
        "preprocessing": [{"type": "JSONPATH", "parameters": ["$.jobs"]}],
        "lld_macro_paths": [
            {"lld_macro": "{#JOBUID}", "path": "$.job_uid"},
            {"lld_macro": "{#PROVIDER}", "path": "$.provider"},
            {"lld_macro": "{#JOB}", "path": "$.job"},
        ],
        "item_prototypes": prototypes,
        "trigger_prototypes": [
            trigger("Backup [{#PROVIDER}] {#JOB}: Failed", f"last({status})=3", "HIGH"),
            trigger("Backup [{#PROVIDER}] {#JOB}: Canceled", f"last({status})=5", "WARNING"),
            trigger("Backup [{#PROVIDER}] {#JOB}: Warning result", f"last({status})=2", "WARNING"),
            trigger("Backup [{#PROVIDER}] {#JOB}: Never run", f"last({status})=6", "HIGH"),
            trigger("Backup [{#PROVIDER}] {#JOB}: No recent success", f"last({age})>{{$BACKUP.MAX.SUCCESS.AGE}}", "HIGH"),
            trigger("Backup [{#PROVIDER}] {#JOB}: Running too long", f"last({status})=4 and last({duration})>{{$BACKUP.MAX.RUN.TIME}}", "WARNING"),
        ],
    }
    template = {
        "uuid": uid("template"),
        "template": TEMPLATE,
        "name": TEMPLATE,
        "description": "Read-only local Veeam Agent and SQL Backup Master monitoring. Validate on real hosts before production use.",
        "groups": [{"name": "Templates/Applications"}],
        "items": [master] + summaries,
        "discovery_rules": [discovery],
        "tags": [
            {"tag": "class", "value": "backup"},
            {"tag": "target", "value": "windows"},
            {"tag": "component", "value": "backup-monitor"},
        ],
        "macros": [
            {"macro": "{$BACKUP.MAX.SUCCESS.AGE}", "value": "26h"},
            {"macro": "{$BACKUP.MAX.RUN.TIME}", "value": "12h"},
        ],
        "valuemaps": [{
            "uuid": uid("valuemap:status"),
            "name": "Windows backup job status",
            "mappings": [
                {"value": str(code), "newvalue": label}
                for code, label in enumerate(("Unknown", "Success", "Warning", "Failed", "Running", "Canceled", "Never run", "Disabled"))
            ],
        }],
    }
    data = {
        "zabbix_export": {
            "version": "7.0",
            "template_groups": [{"uuid": "a571c0d144b14fd4a87a9d9b2aa9fcd6", "name": "Templates/Applications"}],
            "templates": [template],
        }
    }
    output = ROOT / "zabbix/zabbix_template_windows_backup_monitor.yaml"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(yaml_lines(data)) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
