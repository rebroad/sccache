## Incremental snapshot dogfooding

Before changing or using the experimental incremental-snapshot implementation,
read `DOGFOOD-REPORT.md` for findings from the Codex repository and other
dogfooding builds. Add concise, evidence-based results there after new
dogfooding runs, including the project/revision, toolchain and relevant
configuration, exact-cache and predecessor results, reuse evidence, timings,
and failures or fallback to normal sccache. Keep observations distinct from
verified correctness or performance conclusions.

## Keep the code quiet

Comments explain why, not what. Do not narrate the diff in the source, do not
leave "// Step 1: ..." scaffolding behind, and do not add doc comments that only
restate the function signature. Match the density of the surrounding file.

## Run what CI runs

Before sending anything:
```sh
cargo fmt -- --check
cargo clippy --locked --all-targets -- -D warnings -A unknown-lints \
    -A clippy::type_complexity -A clippy::new-without-default
cargo test --locked --lib --bins --tests
```
Also keep in mind:
- MSRV is the `rust-version` in `Cargo.toml` (kept in sync with `README.md` and
  the CI toolchain). Do not use newer language or std features.
- Storage backends are cargo features (`s3`, `gcs`, `azure`, `redis`,
  `memcached`, `gha`, `webdav`, `oss`, `cos`, `dist-client`). Code must still
  build with `--no-default-features --features <one>`; CI checks each one.
- New dependencies need a reason in the PR description. `Cargo.lock` is
  committed and CI builds `--locked`.
- Some tests need real compilers (gcc, clang, msvc, nvcc) or a running server;
  if you skipped a test locally, say so instead of claiming it passed.

## Read the docs already in this repo

Before changing anything, look at the Markdown files here - they are the actual
rules, this file is only a pointer:

- `README.md` - usage, supported compilers, build and install, MSRV
- `docs/Architecture.md` - client/server split, how a compilation is cached
- `docs/Caching.md`, `docs/Configuration.md`, `docs/Local.md` - cache layout and
  configuration; update these when you add or change a config knob
- `docs/Distributed.md`, `docs/DistributedQuickstart.md` - the scheduler/server
  side, read before touching `src/dist`
- the per-backend docs (`docs/S3.md`, `docs/Gcs.md`, `docs/Azure.md`,
  `docs/Redis.md`, `docs/Memcached.md`, `docs/Webdav.md`, `docs/GHA.md`,
  `docs/OSS.md`, `docs/COS.md`, `docs/MultiLevel.md`) when touching
  `src/cache/*`
- `docs/Rust.md`, `docs/Xcode.md`, `docs/ResponseFiles.md` - compiler-specific
  behavior
- `docs/Releasing.md`
