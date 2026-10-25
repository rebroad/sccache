# Incremental sccache dogfooding report

This report collects real-project results from opt-in use of
`/usr/local/bin/sccache-incremental`. Record commands and observable evidence;
separate successful compilation from output-correctness comparisons and
performance conclusions.

## Initial setup

- Launcher: `/usr/local/bin/sccache-incremental` (sccache 0.18.0 sidecar).
- It opts into Rust incremental snapshots and in-process operation. In-process
  statistics are local to each invocation.
- Normal `/usr/bin/sccache` (0.10.0) remains available for fallback.
- Cross-checkout reuse requires a compatible rustc and the same
  `-Z remap-cwd-prefix=<logical-root>` setting on both builds.
- No Codex project build has been recorded here yet.

## Results

Add one dated subsection per project/build. Include the source revision,
toolchain, command and relevant environment, cache backend, exact-cache
hits/misses, predecessor restoration and reuse evidence, wall/rustc timing,
correctness comparison, and any fallback or unresolved issue.
