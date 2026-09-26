"""Build a release ZIP and SHA256SUMS.txt using only the Python standard library."""

import argparse
import hashlib
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="v1-dev")
    args = parser.parse_args()
    version = args.version
    if not version or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_" for c in version):
        parser.error("version must contain only letters, numbers, dot, dash, or underscore")
    files = {
        "windows-backup-monitor.ps1": ROOT / "src/windows-backup-monitor.ps1",
        "windows-backup-monitor.conf": ROOT / "zabbix/windows-backup-monitor.conf",
        "zabbix_template_windows_backup_monitor.yaml": ROOT / "zabbix/zabbix_template_windows_backup_monitor.yaml",
        "README.md": ROOT / "README.md",
        "LICENSE": ROOT / "LICENSE",
    }
    for source in sorted((ROOT / "docs").rglob("*")):
        if source.is_file():
            files[source.relative_to(ROOT).as_posix()] = source
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    archive = output / f"windows-backup-monitor-{version}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
        for name, source in sorted(files.items()):
            package.write(source, name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    print(archive)
    print(output / "SHA256SUMS.txt")


if __name__ == "__main__":
    main()
