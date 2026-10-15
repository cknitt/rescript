#!/usr/bin/env python3
"""Compares build times of several rescript variants on one project.

Each variant is a directory made by build_variants.sh, holding bin/ (with
rescript.exe and bsc.exe) and runtime/. For every variant, interleaved over
--runs rounds, it measures:

- a clean build;
- a no-op build right after it;
- an edit build: a comment is appended to --edit (default: a source file of the
  project), the project rebuilt, and the file restored.

The report holds only timings and module counts, never compiler output, so it
can be shared for closed-source projects. It is printed and written to
<out>/report.md; build logs stay in <out>.
"""

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import time


class Variant:
    def __init__(self, spec):
        label, sep, rest = spec.partition("=")
        if not sep:
            sys.exit(f"--variant needs label=DIR[:exe], got {spec}")
        directory, _, exe = rest.partition(":")
        self.label = label
        self.directory = os.path.abspath(os.path.expanduser(directory))
        self.exe = os.path.join(self.directory, "bin", exe or "rescript.exe")
        self.env = os.environ.copy()
        self.env["RESCRIPT_RUNTIME"] = os.path.join(self.directory, "runtime")
        # Rust rewatch runs this bsc; OCaml rewatch ignores it or uses the same one.
        self.env["RESCRIPT_BSC_EXE"] = os.path.join(self.directory, "bin", "bsc.exe")
        commit_file = os.path.join(self.directory, "commit")
        self.commit = open(commit_file).read().strip()[:10] if os.path.exists(commit_file) else "?"
        for path in (self.exe, self.env["RESCRIPT_RUNTIME"]):
            if not os.path.exists(path):
                sys.exit(f"{label}: missing {path}")


def rss_mb(rusage):
    return rusage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024)


def run(variant, command, project, log):
    with open(log, "w") as output:
        started = time.perf_counter()
        process = subprocess.Popen([variant.exe, command, project], env=variant.env,
                                   stdout=output, stderr=subprocess.STDOUT)
        _, status, rusage = os.wait4(process.pid, 0)
        wall = time.perf_counter() - started
    process.returncode = os.waitstatus_to_exitcode(status)
    return {"wall": wall, "cpu": rusage.ru_utime + rusage.ru_stime, "rss_mb": rss_mb(rusage),
            "status": process.returncode, "log": log}


def build(variant, project, log):
    result = run(variant, "build", project, log)
    if result["status"] != 0:
        tail = open(log).read()[-3000:]
        sys.exit(f"{variant.label}: build failed ({result['status']}), see {log}:\n{tail}")
    return result


def default_edit_file(project):
    """A source file of the project itself, not of a dependency."""
    for root, dirs, files in os.walk(project):
        dirs[:] = sorted(d for d in dirs if d not in ("node_modules", "lib", ".git"))
        for name in sorted(files):
            if name.endswith(".res"):
                return os.path.join(root, name)
    sys.exit("no .res file found; pass --edit")


def counts(log):
    """'Parsed N source files' and 'Compiled N modules' lines, nothing else."""
    lines = [line.strip() for line in open(log)]
    return " / ".join(line for line in lines
                      if line.startswith(("Parsed ", "Compiled ", "Cleaned ")))


def machine():
    info = f"{platform.platform()}, {platform.machine()}, {os.cpu_count()} CPUs"
    if sys.platform == "darwin":
        def sysctl(key):
            return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True).stdout.strip()
        memory = int(sysctl("hw.memsize") or 0) // (1024 ** 3)
        info += f", {sysctl('machdep.cpu.brand_string')}, {memory} GB"
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", required=True)
    parser.add_argument("--variant", action="append", required=True,
                        help="label=DIR[:exe], DIR from build_variants.sh; the first is the baseline")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--edit", help="file to append a comment to for the edit build")
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "rescript-compare-out"))
    args = parser.parse_args()

    project = os.path.abspath(os.path.expanduser(args.project))
    variants = [Variant(spec) for spec in args.variant]
    edit_file = os.path.abspath(args.edit) if args.edit else default_edit_file(project)
    os.makedirs(os.path.expanduser(args.out), exist_ok=True)
    out = os.path.abspath(os.path.expanduser(args.out))
    results = {v.label: {"clean": [], "noop": [], "edit": []} for v in variants}
    original = open(edit_file, "rb").read()

    lines = []

    def report(line=""):
        print(line, flush=True)
        lines.append(line)

    report("# rescript build comparison")
    report()
    report(f"- machine: {machine()}")
    report(f"- load average before: {', '.join(f'{x:.2f}' for x in os.getloadavg())}")
    report(f"- project: {os.path.basename(project)}")
    report(f"- edited file: {os.path.relpath(edit_file, project)}")
    report(f"- runs: {args.runs}, variants interleaved")
    for v in variants:
        report(f"- {v.label}: {v.exe} (commit {v.commit})")
    report()

    try:
        for round_ in range(args.runs):
            for v in variants:
                prefix = os.path.join(out, f"{v.label}-{round_}")
                run(v, "clean", project, prefix + "-clean.log")
                results[v.label]["clean"].append(build(v, project, prefix + "-build.log"))
                results[v.label]["noop"].append(build(v, project, prefix + "-noop.log"))
                with open(edit_file, "ab") as f:
                    f.write(f"\n// rescript compare edit {round_}\n".encode())
                try:
                    results[v.label]["edit"].append(build(v, project, prefix + "-edit.log"))
                finally:
                    with open(edit_file, "wb") as f:
                        f.write(original)
            print(f"round {round_ + 1}/{args.runs} done", file=sys.stderr, flush=True)
    finally:
        with open(edit_file, "wb") as f:
            f.write(original)

    def median(key, kind, field):
        return statistics.median(r[field] for r in results[key][kind])

    def best(key, kind, field):
        return min(r[field] for r in results[key][kind])

    baseline = variants[0].label
    report("| variant | clean wall (min / median) | clean CPU | peak RSS | no-op | edit one file | clean vs " + baseline + " |")
    report("|---|---|---|---|---|---|---|")
    for v in variants:
        k = v.label
        speedup = median(baseline, "clean", "wall") / median(k, "clean", "wall")
        report(f"| {k} | {best(k, 'clean', 'wall'):.2f} s / {median(k, 'clean', 'wall'):.2f} s "
               f"| {median(k, 'clean', 'cpu'):.2f} s | {max(r['rss_mb'] for r in results[k]['clean']):.0f} MB "
               f"| {median(k, 'noop', 'wall'):.3f} s | {median(k, 'edit', 'wall'):.3f} s | {speedup:.2f}x |")
    report()
    report("Times are medians unless noted; CPU is user + system time of the build process and its children.")
    report()
    for v in variants:
        report(f"- {v.label} clean build: {counts(results[v.label]['clean'][0]['log'])}")
        report(f"- {v.label} edit build: {counts(results[v.label]['edit'][0]['log'])}")
    report()

    with open(os.path.join(out, "report.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "raw.json"), "w") as f:
        json.dump(results, f, indent=1)


if __name__ == "__main__":
    main()
