"""Static checks; set REQUIRE_YAML=1 after installing PyYAML for a full YAML parse."""

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "zabbix/zabbix_template_windows_backup_monitor.yaml"


def main():
    before = TEMPLATE.read_bytes()
    subprocess.run([sys.executable, str(ROOT / "tools/generate_template.py")], check=True)
    assert TEMPLATE.read_bytes() == before, "template generation is not deterministic"
    text = before.decode("utf-8").replace("\r\n", "\n")
    assert len(re.findall(r"^\s*uuid:", text, re.MULTILINE)) == len(set(re.findall(r'^\s*uuid: "([0-9a-f]{32})"$', text, re.MULTILINE)))
    assert 'version: "7.0"' in text
    for key in (
        "windows.backup.monitor.get", "windows.backup.jobs.discovery",
        "windows.backup.jobs.total", "windows.backup.jobs.failed",
        "windows.backup.jobs.warning", "windows.backup.jobs.running",
        "windows.backup.providers.errors", "windows.backup.job.status",
        "windows.backup.job.running", "windows.backup.job.enabled",
        "windows.backup.job.last_start", "windows.backup.job.last_finish",
        "windows.backup.job.last_success", "windows.backup.job.success_age",
        "windows.backup.job.duration", "windows.backup.job.next_run",
    ):
        assert key in text, key
    try:
        import yaml
    except ImportError:
        if os.environ.get("REQUIRE_YAML") == "1":
            raise
        print("PyYAML unavailable; deterministic and structural checks passed; YAML parse skipped")
        return
    document = yaml.safe_load(text)["zabbix_export"]
    assert document["version"] == "7.0"
    template = document["templates"][0]
    assert len(template["items"]) == 6
    discovery = template["discovery_rules"][0]
    assert len(discovery["item_prototypes"]) == 9
    assert len(discovery["trigger_prototypes"]) == 6
    assert discovery["lifetime"] == "7d"
    assert discovery["enabled_lifetime_type"] == "DISABLE_IMMEDIATELY"
    print("Zabbix template YAML and structure passed")


if __name__ == "__main__":
    main()
