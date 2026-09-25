#!/usr/bin/env python3
"""Read-only RSS/CPU samples for an app and optionally its attributable WebKit helpers.

WebKit XPC processes can be reparented to launchd. With --container-id, a
helper is attributed when lsof shows an open path inside that app container.
This is evidence of use, not proof that a shared helper belongs exclusively
to the app. RSS values overlap and are not a unique physical footprint.
"""
import argparse
import json
import re
import statistics
import subprocess
import time


def cpu_seconds(value):
    result = 0.0
    for part in value.split(":"):
        result = result * 60 + float(part)
    return result


def processes():
    rows = {}
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,rss=,time=,comm="], text=True)
    for line in output.splitlines():
        pid, parent, rss, cpu, command = line.split(maxsplit=4)
        rows[int(pid)] = (int(parent), int(rss), cpu_seconds(cpu), command)
    return rows


def descendants(root, rows):
    if root not in rows:
        raise SystemExit("Target process exited; samples are incomplete.")
    family = {root}
    while True:
        next_family = family | {pid for pid, row in rows.items() if row[0] in family}
        if next_family == family:
            return {pid: rows[pid] for pid in family}
        family = next_family


def webkit_role(command):
    if "/WebKit.framework/" not in command or "/XPCServices/com.apple.WebKit." not in command:
        return None
    if "WebContent" in command:
        return "webContent"
    if command.endswith("/com.apple.WebKit.GPU"):
        return "gpu"
    if command.endswith("/com.apple.WebKit.Networking"):
        return "networking"
    return "otherWebKit"


def has_container_file(pid, marker):
    result = subprocess.run(["/usr/sbin/lsof", "-p", str(pid), "-Fn"], capture_output=True, check=False)
    return result.returncode == 0 and marker in result.stdout


def attributed_webkit(rows, container_id):
    if not container_id:
        return {}
    marker = ("/Library/Containers/" + container_id + "/").encode()
    return {pid: (row, role) for pid, row in rows.items()
            if (role := webkit_role(row[3])) and has_container_file(pid, marker)}


def interval_cpu(current, previous, seconds):
    if previous is None or current.keys() != previous.keys():
        return None
    delta = sum(current[pid][2] - previous[pid][2] for pid in current)
    return max(0, delta) / seconds * 100


def median(values):
    return statistics.median(values) if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("--samples", type=int, default=6)
    parser.add_argument("--interval", type=float, default=2)
    parser.add_argument("--container-id", help="Bundle/container ID used to attribute reparented WebKit helpers")
    args = parser.parse_args()
    if not 2 <= args.samples <= 121 or not 0.5 <= args.interval <= 60:
        parser.error("Use 2–121 samples and 0.5–60 seconds per interval")
    if args.container_id and not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", args.container_id):
        parser.error("--container-id must be a reverse-DNS identifier")
    samples, cpu_intervals = [], {name: [] for name in ("host", "webContent", "gpu", "networking")}
    previous, previous_time, start = None, None, time.monotonic()
    for index in range(args.samples):
        rows, now = processes(), time.monotonic()
        host = descendants(args.pid, rows)
        webkit = attributed_webkit(rows, args.container_id)
        groups = {"host": host}
        for role in ("webContent", "gpu", "networking"):
            groups[role] = {pid: row for pid, (row, kind) in webkit.items() if kind == role}
        sample = {"elapsedSeconds": round(now - start, 1), "hostProcessCount": len(host),
                  "attributedWebKitCount": len(webkit)}
        for role, group in groups.items():
            sample[role + "RssMiB"] = round(sum(row[1] for row in group.values()) / 1024, 3)
        samples.append(sample)
        if previous is not None:
            seconds = now - previous_time
            for role, group in groups.items():
                value = interval_cpu(group, previous[role], seconds)
                if value is not None and group:
                    cpu_intervals[role].append(value)
        previous, previous_time = groups, now
        if index + 1 < args.samples:
            time.sleep(args.interval)
    summary = {role: {"medianRssMiB": median([sample[role + "RssMiB"] for sample in samples]),
                      "medianIntervalCPUPercent": median(cpu_intervals[role]),
                      "validCPUIntervals": len(cpu_intervals[role])}
               for role in ("host", "webContent", "gpu", "networking")}
    print(json.dumps({"samples": samples, "summary": summary,
                      "scope": "host + descendants; optional WebKit XPC attribution by open app-container file; RSS overlaps and is not physical footprint"}, indent=2))


if __name__ == "__main__":
    main()
