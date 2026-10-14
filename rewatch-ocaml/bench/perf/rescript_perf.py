#!/usr/bin/env python3
"""Performance report for in-process OCaml rewatch against Rust rewatch.

Measurement only: needs the `perf-instrumentation` branch, whose `rescript`
understands RESCRIPT_PERF, RESCRIPT_PERF_WALL, RESCRIPT_PERF_REQUESTS and
REWATCH_MINOR_HEAP_WORDS. See README.md next to this script.

All builds are clean builds of --project. The report goes to stdout and to
<out>/report.md; raw logs and traces stay in <out>.
"""

import argparse
import collections
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


def platform_dir():
    system = {"darwin": "darwin", "linux": "linux", "win32": "win32"}[sys.platform]
    machine = platform.machine().lower()
    arch = "arm64" if machine in ("arm64", "aarch64") else "x64"
    return os.path.join(REPO, "packages", "@rescript", f"{system}-{arch}", "bin")


class Build:
    def __init__(self, wall, user, system, rss_mb, status, log):
        self.wall, self.user, self.system = wall, user, system
        self.cpu = user + system
        self.rss_mb, self.status, self.log = rss_mb, status, log


def rss_mb(rusage):
    # ru_maxrss is in bytes on macOS and in kilobytes on Linux.
    return rusage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024)


def environment(extra):
    env = os.environ.copy()
    for key in ("REWATCH_COMPILER_DOMAINS", "RESCRIPT_PERF", "RESCRIPT_PERF_WALL",
                "RESCRIPT_PERF_REQUESTS", "REWATCH_MINOR_HEAP_WORDS"):
        env.pop(key, None)
    env.update({k: str(v) for k, v in extra.items()})
    return env


def clean(exe, project, env):
    subprocess.run([exe, "clean", project], env=env, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)


def start(command, env, log):
    output = open(log, "w")
    started = time.perf_counter()
    process = subprocess.Popen(command, env=env, stdout=output, stderr=subprocess.STDOUT)
    return process, output, started


def finish(process, output, started, log):
    _, status, rusage = os.wait4(process.pid, 0)
    wall = time.perf_counter() - started
    output.close()
    process.returncode = os.waitstatus_to_exitcode(status)
    return Build(wall, rusage.ru_utime, rusage.ru_stime, rss_mb(rusage), process.returncode, log)


def build(exe, project, extra, log, command=None):
    env = environment(extra)
    clean(exe, project, env)
    process, output, started = start(command or [exe, "build", project], env, log)
    result = finish(process, output, started, log)
    if result.status != 0:
        with open(log) as f:
            tail = f.read()[-3000:]
        sys.exit(f"build failed ({result.status}), see {log}:\n{tail}")
    return result


def perf_table(path):
    rows = {}
    with open(path) as f:
        next(f)
        for line in f:
            name, calls, incl, excl, incl_mw, excl_mw = line.split()
            rows[name] = {"calls": int(calls), "incl": float(incl), "excl": float(excl),
                          "incl_mw": float(incl_mw), "excl_mw": float(excl_mw)}
    return rows


def requests_table(path):
    rows = []
    with open(path) as f:
        for line in f:
            domain, kind, source, begin, end, minor, promoted, major, heap = line.rstrip("\n").split("\t")
            rows.append({"domain": int(domain), "kind": kind, "source": source,
                         "wall": float(end) - float(begin), "minor": float(minor),
                         "promoted": float(promoted)})
    return rows


class Report:
    def __init__(self, path):
        self.path = path
        self.lines = []

    def __call__(self, line=""):
        print(line, flush=True)
        self.lines.append(line)

    def save(self):
        with open(self.path, "w") as f:
            f.write("\n".join(self.lines) + "\n")


def fmt_builds(builds):
    best = min(builds, key=lambda b: b.wall)
    walls = [b.wall for b in builds]
    return (f"wall min {best.wall:.2f} s / median {statistics.median(walls):.2f} s, "
            f"CPU {best.cpu:.2f} s (user {best.user:.2f}, sys {best.system:.2f}), "
            f"max RSS {best.rss_mb:.0f} MB")


def main():
    bin_dir = platform_dir()
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", required=True, help="project directory to build")
    parser.add_argument("--ocaml", default=os.path.join(bin_dir, "rescript.exe"))
    parser.add_argument("--rust", default=os.path.join(bin_dir, "rescript-rust.exe"))
    parser.add_argument("--bsc", default=os.path.join(bin_dir, "bsc.exe"),
                        help="bsc.exe for Rust rewatch")
    parser.add_argument("--runtime", default=os.path.join(REPO, "packages", "@rescript", "runtime"),
                        help="the repository's built runtime; must match the compiler")
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "rescript-perf-out"))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--domains", default="1,2,4,8")
    parser.add_argument("--heaps", default="2097152,8388608,16777216",
                        help="worker minor heap sizes in words")
    parser.add_argument("--copies", type=int, default=4,
                        help="independent single-domain builds run side by side (0 skips)")
    parser.add_argument("--copy-root",
                        help="directory to copy for the side-by-side builds, when the project "
                        "resolves dependencies from a parent directory (default: the project)")
    parser.add_argument("--skip-olly", action="store_true")
    args = parser.parse_args()

    project = os.path.abspath(args.project)
    os.makedirs(args.out, exist_ok=True)
    out = os.path.abspath(args.out)
    log = lambda name: os.path.join(out, name)
    report = Report(log("report.md"))
    base = {"RESCRIPT_RUNTIME": args.runtime}
    rust_env = dict(base, RESCRIPT_BSC_EXE=args.bsc)
    domains = [int(d) for d in args.domains.split(",")]
    raw = {}

    report("# OCaml rewatch performance report")
    report()
    report(f"- machine: {platform.platform()}, {platform.machine()}, {os.cpu_count()} CPUs")
    report(f"- load average before: {', '.join(f'{x:.2f}' for x in os.getloadavg())}")
    report(f"- project: {project}")
    report(f"- ocaml: {args.ocaml}")
    report(f"- rust: {args.rust}")
    version = subprocess.run([args.ocaml, "--version"], capture_output=True, text=True).stdout.strip()
    report(f"- version: {version}")
    report()

    # 1. Rust against OCaml at the default domain count and at one domain.
    report("## Clean builds")
    report()
    builds = collections.defaultdict(list)
    for run in range(args.runs):
        builds["rust"].append(build(args.rust, project, rust_env, log(f"rust-{run}.log")))
        builds["ocaml"].append(build(args.ocaml, project, base, log(f"ocaml-{run}.log")))
        builds["ocaml-1"].append(build(args.ocaml, project,
                                       dict(base, REWATCH_COMPILER_DOMAINS=1),
                                       log(f"ocaml1-{run}.log")))
    labels = {"rust": "Rust rewatch + bsc processes", "ocaml": "OCaml in-process, default domains",
              "ocaml-1": "OCaml in-process, 1 domain"}
    for key, label in labels.items():
        report(f"- {label}: {fmt_builds(builds[key])}")
    rust_best = min(b.wall for b in builds["rust"])
    ocaml_best = min(b.wall for b in builds["ocaml"])
    report(f"- OCaml is {rust_best / ocaml_best:.2f}x faster than Rust (min wall)")
    with open(builds["ocaml"][0].log) as f:
        report(f"- build output: {' / '.join(l.strip() for l in f if l.strip())[:300]}")
    report()
    raw["clean_builds"] = {k: [vars(b) for b in v] for k, v in builds.items()}

    # 2. Phase breakdown on one domain (CPU time).
    report("## Phases on one domain (CPU, exclusive)")
    report()
    build(args.ocaml, project, dict(base, REWATCH_COMPILER_DOMAINS=1, RESCRIPT_PERF=log("phases1.txt")),
          log("phases1.log"))
    phases = perf_table(log("phases1.txt"))
    compiler = {k: v for k, v in phases.items()
                if not k.startswith(("wall", "minor_gcs", "request_"))}
    total = sum(v["excl"] for v in compiler.values()) or 1
    report("| phase | calls | CPU s | share | minor Mwords |")
    report("|---|---|---|---|---|")
    for name, row in sorted(compiler.items(), key=lambda kv: -kv[1]["excl"])[:14]:
        report(f"| {name} | {row['calls']} | {row['excl']:.3f} | {100 * row['excl'] / total:.0f}% "
               f"| {row['excl_mw']:.1f} |")
    report()
    raw["phases1"] = phases

    # 3. Scaling with the domain count (wall-clock phase timers).
    report("## Scaling")
    report()
    report("| domains | wall s | CPU s | compile stage s | summed request wall s "
           "| avg busy workers | request slowdown vs 1 |")
    report("|---|---|---|---|---|---|---|")
    scaling = {}
    for d in domains:
        runs = []
        for run in range(2):
            table = log(f"scale-{d}-{run}.txt")
            b = build(args.ocaml, project,
                      dict(base, REWATCH_COMPILER_DOMAINS=d, RESCRIPT_PERF=table, RESCRIPT_PERF_WALL=1),
                      log(f"scale-{d}-{run}.log"))
            rows = perf_table(table)
            runs.append((b, rows))
        b, rows = min(runs, key=lambda r: r[0].wall)
        compile_stage = rows.get("wall7:compile", {}).get("incl", 0.0)
        requests = rows.get("wall_request_compile", {}).get("incl", 0.0)
        scaling[d] = {"wall": b.wall, "cpu": b.cpu, "compile": compile_stage, "requests": requests}
    for d, s in scaling.items():
        base_requests = scaling[domains[0]]["requests"] or 1
        busy = s["requests"] / s["compile"] if s["compile"] else 0
        report(f"| {d} | {s['wall']:.2f} | {s['cpu']:.2f} | {s['compile']:.2f} | {s['requests']:.2f} "
               f"| {busy:.1f} | {s['requests'] / base_requests:.2f}x |")
    report()
    raw["scaling"] = scaling

    # 4. Worker minor heap size at the default domain count.
    report("## Worker minor heap (default domains)")
    report()
    for heap in [int(h) for h in args.heaps.split(",")]:
        hb = [build(args.ocaml, project, dict(base, REWATCH_MINOR_HEAP_WORDS=heap),
                    log(f"heap-{heap}-{run}.log")) for run in range(2)]
        report(f"- {heap // (1024 * 1024)}M words: {fmt_builds(hb)}")
    report()

    # 5. Independent processes: do separate single-domain builds slow each other down?
    if args.copies > 0:
        report(f"## {args.copies} independent single-domain builds side by side")
        report()
        copies_dir = log("copies")
        copy_root = os.path.abspath(args.copy_root or project)
        inside = os.path.relpath(project, copy_root)
        copies = []
        for i in range(args.copies):
            target = os.path.join(copies_dir, f"copy-{i}")
            if not os.path.isdir(target):
                os.makedirs(copies_dir, exist_ok=True)
                # APFS clones are instant; fall back to a plain copy.
                cloned = sys.platform == "darwin" and subprocess.run(
                    ["cp", "-cR", copy_root, target], capture_output=True).returncode == 0
                if not cloned:
                    shutil.copytree(copy_root, target, symlinks=True)
            copies.append(os.path.normpath(os.path.join(target, inside)))
        env = environment(dict(base, REWATCH_COMPILER_DOMAINS=1))
        alone = build(args.ocaml, copies[0], dict(base, REWATCH_COMPILER_DOMAINS=1), log("alone.log"))
        for target in copies:
            clean(args.ocaml, target, env)
        started = [start([args.ocaml, "build", target], env, log(f"copy-{i}.log")) + (log(f"copy-{i}.log"),)
                   for i, target in enumerate(copies)]
        together = [finish(p, o, s, l) for p, o, s, l in started]
        report(f"- alone: wall {alone.wall:.2f} s, CPU {alone.cpu:.2f} s")
        for i, b in enumerate(together):
            report(f"- copy {i}: wall {b.wall:.2f} s ({b.wall / alone.wall:.2f}x alone), CPU {b.cpu:.2f} s"
                   + ("" if b.status == 0 else f", FAILED {b.status}"))
        report(f"- {args.copies} builds took {max(b.wall for b in together):.2f} s together")
        report()

    # 6. GC behaviour, with olly from opam's runtime_events_tools.
    olly = shutil.which("olly")
    if olly and not args.skip_olly:
        report("## GC (olly)")
        report()
        for d in (None, 1):
            extra = dict(base) if d is None else dict(base, REWATCH_COMPILER_DOMAINS=d)
            env = environment(extra)
            clean(args.ocaml, project, env)
            stats = subprocess.run([olly, "gc-stats", args.ocaml, "build", project], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True).stdout
            with open(log(f"olly-gc-stats-{d or 'default'}.txt"), "w") as f:
                f.write(stats)
            keep = [l for l in stats.splitlines()
                    if l.startswith(("Wall time", "GC time", "GC overhead"))]
            report(f"- {'default domains' if d is None else '1 domain'}: " + "; ".join(keep))
        trace = log("trace.json")
        env = environment(dict(base, RESCRIPT_PERF_REQUESTS=log("requests.tsv")))
        clean(args.ocaml, project, env)
        subprocess.run([olly, "trace", "--format=json", "--log-wsize=20", "--freq=0.005", trace,
                        args.ocaml, "build", project], env=env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        summarize_trace(trace, report)
        summarize_requests(log("requests.tsv"), report)
    else:
        report("## GC: skipped (install olly with `opam install runtime_events_tools`)")
        report()

    with open(log("raw.json"), "w") as f:
        json.dump(raw, f, indent=1)
    report(f"Logs and raw data: {out}")
    report.save()


def trace_events(path):
    with open(path) as f:
        for line in f:
            line = line.strip().lstrip("[").rstrip(",").rstrip("]")
            if line.startswith("{"):
                yield json.loads(line)


def summarize_trace(path, report):
    """Per domain: time in the minor GC's leave barrier, promotion, and idle
    condition waits, and how many stop-the-world pauses it led."""
    stacks = collections.defaultdict(list)
    excl = collections.defaultdict(collections.Counter)
    leads = collections.Counter()
    first, last = {}, {}
    for e in trace_events(path):
        tid, ph = e["tid"], e.get("ph")
        first.setdefault(tid, e["ts"])
        last[tid] = e["ts"]
        if ph == "B":
            stacks[tid].append([e["name"], e["ts"], 0])
            if e["name"] == "stw_leader":
                leads[tid] += 1
        elif ph == "E":
            st = stacks[tid]
            i = next((k for k in range(len(st) - 1, -1, -1) if st[k][0] == e["name"]), None)
            if i is None:
                continue
            name, begin, child = st[i]
            del st[i:]
            dur = e["ts"] - begin
            excl[tid][name] += dur - child
            if st:
                st[-1][2] += dur
    report()
    report("| domain | span ms | leave barrier ms | promotion ms | idle wait ms | STW led |")
    report("|---|---|---|---|---|---|")
    for tid in sorted(excl):
        c = excl[tid]
        promote = c["minor_remembered_set_promote"] + c["minor_local_roots_promote"]
        report(f"| {tid} | {(last[tid] - first[tid]) / 1000:.0f} | {c['minor_leave_barrier'] / 1000:.0f} "
               f"| {promote / 1000:.0f} | {c['domain_condition_wait'] / 1000:.0f} | {leads[tid]} |")
    report()


def summarize_requests(path, report):
    if not os.path.exists(path):
        return
    rows = [r for r in requests_table(path) if r["kind"] == "request_compile"]
    per_domain = collections.defaultdict(lambda: [0, 0.0, 0.0, 0.0])
    for r in rows:
        d = per_domain[r["domain"]]
        d[0] += 1
        d[1] += r["wall"]
        d[2] += r["minor"]
        d[3] += r["promoted"]
    report("| compile domain | requests | busy s | allocated Mwords | promoted Mwords |")
    report("|---|---|---|---|---|")
    for domain in sorted(per_domain):
        n, wall, minor, promoted = per_domain[domain]
        report(f"| {domain} | {n} | {wall:.2f} | {minor / 1e6:.1f} | {promoted / 1e6:.1f} |")
    report()


if __name__ == "__main__":
    main()
