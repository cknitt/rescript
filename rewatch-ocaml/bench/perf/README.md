# Performance report (measurement only)

`rescript_perf.py` compares clean builds of a project with Rust rewatch and the
in-process OCaml rewatch, and looks at why the domains don't scale. It needs
this branch (`perf-instrumentation`), which adds timers that the environment
variables `RESCRIPT_PERF`, `RESCRIPT_PERF_WALL`, `RESCRIPT_PERF_REQUESTS` and
`REWATCH_MINOR_HEAP_WORDS` enable. Not for merging.

## Running

```sh
make && make lib                       # same setup as for the OCaml rewatch stack
opam install runtime_events_tools      # optional: olly, for the GC sections
python3 rewatch-ocaml/bench/perf/rescript_perf.py --project path/to/project
```

The report is printed and written to `rescript-perf-out/report.md`, next to the
logs and raw data. A run does about 30 clean builds.

- The project must build with this branch's compiler. The runtime comes from
  the repository (`--runtime`); dependencies such as `@rescript/react` compile
  from source.
- The side-by-side section copies the project (APFS clones on macOS, so they
  take no time or space). If the project resolves dependencies from a parent
  directory, such as a monorepo root, pass that directory as `--copy-root`.
  `--copies 0` skips the section.
- Close other busy applications and keep the Mac on power.

## Sections

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
