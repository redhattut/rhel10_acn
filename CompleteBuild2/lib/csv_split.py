#!/usr/bin/env python3
"""
csv_split.py — splits the combined build CSV (from the Bare Metal Server
Build Template web tool) into one working directory per server.

Usage:
    csv_split.py <combined_csv_path> <work_dir_for_this_job>

For each distinct hostname in the CSV, writes:
    <work_dir>/<hostname>/server.env   - bash-sourceable KEY=VALUE server fields
    <work_dir>/<hostname>/disks.tsv    - one line per additional-disk row (tab separated)

Also writes:
    <work_dir>/hostlist.txt            - one hostname per line, for build.sh to iterate

This replaces the old split.sh (which parsed three separate Excel worksheets
via Spreadsheet::XLSX). A single, already-flat CSV needs none of that —
Python's csv module handles the quoting (commas inside mount_layout, etc.)
that the old awk/grep-based parsing had to work around with colon-collapsing
tricks.
"""
import csv
import os
import sys


SERVER_FIELDS = [
    "job_name", "hostname", "hardware", "datacenter", "location", "ci_device",
    "environment", "os_version", "boot_mode", "lacp", "mgmt_address", "org_name",
    "os_disk_gb", "root_mb", "swap_mb", "var_mb", "opt_mb", "app_mb", "home_mb",
    "tmp_mb", "optapp_mb", "extra_filesystems",
]
DISK_FIELDS = [
    "raid_level", "disk_type", "num_disks_raid10", "lvm", "mount_layout",
    "size_gb", "extra_folders",
]


def main():
    if len(sys.argv) != 3:
        print("usage: csv_split.py <combined_csv_path> <work_dir>", file=sys.stderr)
        sys.exit(1)

    csv_path, work_dir = sys.argv[1], sys.argv[2]
    os.makedirs(work_dir, exist_ok=True)

    seen_hosts = []
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        missing = [c for c in ("hostname", "hardware") if c not in reader.fieldnames]
        if missing:
            print(f"ERROR: CSV is missing required columns: {missing}", file=sys.stderr)
            sys.exit(1)

        for row in reader:
            hostname = (row.get("hostname") or "").strip()
            if not hostname:
                continue

            host_dir = os.path.join(work_dir, hostname)
            os.makedirs(host_dir, exist_ok=True)
            env_path = os.path.join(host_dir, "server.env")
            disks_path = os.path.join(host_dir, "disks.tsv")

            # Server-level fields: only need to write this once per hostname
            # (the CSV repeats them on every disk row for that server).
            if hostname not in seen_hosts:
                seen_hosts.append(hostname)
                with open(env_path, "w") as ef:
                    for field in SERVER_FIELDS:
                        val = (row.get(field) or "").strip()
                        # Uppercase env-style key, single-quote safe for bash `source`
                        key = field.upper()
                        val_escaped = val.replace("'", "'\\''")
                        ef.write(f"{key}='{val_escaped}'\n")
                # truncate/create disks.tsv even if this server has no extra disks
                open(disks_path, "w").close()

            # Disk-level fields: append a row only if this CSV row actually
            # carries disk info (raid_level or mount_layout non-empty).
            raid = (row.get("raid_level") or "").strip()
            mounts = (row.get("mount_layout") or "").strip()
            if raid or mounts:
                with open(disks_path, "a") as df:
                    values = [(row.get(f) or "").strip() for f in DISK_FIELDS]
                    df.write("\t".join(values) + "\n")

    with open(os.path.join(work_dir, "hostlist.txt"), "w") as hf:
        for h in seen_hosts:
            hf.write(h + "\n")

    print(f"Parsed {len(seen_hosts)} server(s) from {csv_path}")
    print(f"Work directory: {work_dir}")


if __name__ == "__main__":
    main()
