sccache includes support for caching Rust compilation. This includes many caveats, and is primarily focused on caching rustc invocations as produced by cargo. A (possibly-incomplete) list follows:
* `--emit` is required.
* `--crate-name` is required.
* Only `link`, `metadata` and `dep-info` are supported as `--emit` values, and `link` must be present.
* `--out-dir` is required.
* `-o file` is not supported.
* Compilation from stdin is not supported, a source file must be provided.
* Values from `env!` require Rust >= 1.46 to be tracked in caching.
* Procedural macros that read files from the filesystem may not be cached properly.
* Incremental Rust compilation is unsupported by default. Experimental whole-directory snapshot support can be enabled with `SCCACHE_RUST_INCREMENTAL=1`; see [Rust incremental snapshots](RustIncrementalSnapshots.md). Cross-checkout reuse also requires a rustc containing the `remap-cwd-prefix` incremental fix and the same `-Z remap-cwd-prefix=<logical-root>` setting on every build. This is unstable and requires nightly or `RUSTC_BOOTSTRAP=1` with stable rustc. Use only with a trusted cache. Incremental compilations run locally, not through distributed compilation.
* Crates that invoke the system linker cannot be cached. Examples are `bin`, `dylib`, `cdylib`, and `proc-macro` crates.

If you are using Rust 1.18 or later, you can ask cargo to wrap all compilation with sccache by setting `RUSTC_WRAPPER=sccache` in your build environment.
