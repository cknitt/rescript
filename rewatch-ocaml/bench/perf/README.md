# Build performance measurements (not for merging)

Two tools:

- `compare.py` compares build times of several builds of the toolchain on one
  project: for example master (Rust rewatch), the subprocess port (#8780) and
  the in-process build (#8781). It uses ordinary, uninstrumented binaries.
- `rescript_perf.py` looks into why the in-process build doesn't scale with the
  domain count. It needs this branch (`perf-instrumentation`), whose timers the
  environment variables `RESCRIPT_PERF`, `RESCRIPT_PERF_WALL`,
  `RESCRIPT_PERF_REQUESTS` and `REWATCH_MINOR_HEAP_WORDS` enable.

## Comparing builds

1. Build each variant in its own worktree; this collects its binaries and
   runtime in one directory per variant:

   ```sh
   git fetch origin master rewatch-ocaml-port rewatch-ocaml-in-process
   rewatch-ocaml/bench/perf/build_variants.sh ~/rescript-variants \
     master=origin/master port=origin/rewatch-ocaml-port \
     in-process=origin/rewatch-ocaml-in-process
   ```

   Each variant takes a full `make && make lib`. The worktrees stay in
   `~/rescript-variants/src-*`, so a later run only rebuilds what changed.

2. Compare them on a project. The first variant is the baseline:

   ```sh
   cd rewatch-ocaml/bench/perf
   python3 compare.py --project ~/bench/tests/tests \
     --variant master=~/rescript-variants/master \
     --variant port=~/rescript-variants/port \
     --variant in-process=~/rescript-variants/in-process \
     --out ~/compare-tests
   ```

   The variants run interleaved, 5 rounds by default (`--runs`), each with a
   clean build, a no-op build, and a build after appending a comment to one
   source file (`--edit`; by default the first `.res` file of the project). The
   file is restored afterwards.

The report is printed and written to `<out>/report.md`. It contains timings,
module counts, the project's directory name and the edited file's path, but no
compiler output, so it can be shared for a closed-source project. The build
logs stay in `<out>`.

Projects:

- **In this repository:** `tests/tests` (about 630 modules). Build a copy, so
  the committed JavaScript outputs in the checkout stay untouched:
  `mkdir -p ~/bench && cp -cR tests ~/bench/tests` (an APFS clone), then pass
  `~/bench/tests/tests`.
- **Any other project** must build with the compiler of every variant: these
  are ReScript 13 development builds. Each variant uses its own runtime, and
  dependencies such as `@rescript/react` compile from source, so the version of
  `rescript` installed in the project doesn't matter.

Close other busy applications and keep the Mac on power. Peak RSS is that of
the build process and its children: for Rust rewatch, its largest `bsc`.

## Diagnosing the in-process build

```sh
make && make lib                       # on this branch
opam install runtime_events_tools      # optional: olly, for the GC sections
python3 rewatch-ocaml/bench/perf/rescript_perf.py --project path/to/project
```

The report is printed and written to `rescript-perf-out/report.md`, next to the
logs and raw data. A run does about 30 clean builds, with the runtime from this
repository (`--runtime`).

- The side-by-side section copies the project (APFS clones on macOS, so they
  take no time or space). If the project resolves dependencies from a parent
  directory, such as a monorepo root, pass that directory as `--copy-root`.
  `--copies 0` skips the section.

Sections:

1. **Clean builds:** Rust rewatch (with `bsc` processes), OCaml with the
   default domain count, and OCaml with one domain.
2. **Phases on one domain:** CPU time per compiler phase.
3. **Scaling:** for each domain count, the compile stage's wall time and the
   summed wall time of the compile requests. If the requests' wall time grows
   with the domain count while CPU time stays flat, they wait instead of
   working.
4. **Worker minor heap:** clean builds with larger minor heaps per worker.
5. **Side by side:** independent single-domain builds of copies, run at once.
   They share no GC, so their slowdown is what the machine itself costs.
6. **GC (olly):** GC time, and per domain the time waiting at the end of minor
   collections (leave barrier), promoting objects, and waiting for work.
