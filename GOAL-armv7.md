### Handover: investigate sccache for ARMv7 builds

Goal: Find out whether the ARMv7 cross-build can safely use the existing sccache source and cache.

Starting evidence:

- The Pi3 builder sets `CARGO_INCREMENTAL=0`, but also clears `RUSTC_WRAPPER` with `RUSTC_WRAPPER=`.
- The comment at that line says sccache cannot handle the builder’s incremental cross-compilation mode. Check why that restriction exists; the current non-incremental setting makes the rationale unclear.
- sccache documents Rust support and notes that incremental compilation needs special handling. It also cannot cache crate types that invoke the system linker, so expect the final binary link itself to remain uncached. https://github.com/mozilla/sccache/blob/main/docs/Rust.md

Suggested investigation:

1. Reproduce an ARMv7 Rust library build with the same toolchain, target, linker, and environment, but with the project’s sccache wrapper enabled.
2. Build it twice and compare sccache --show-stats; confirm the second run gets cache hits and produces valid artifacts.
3. If that works, try a scoped opt-in for build_armv7.sh, keeping the existing default until a complete Pi3 release build succeeds.
4. Check both the Rust compile and final link paths, and document which parts actually benefit.
