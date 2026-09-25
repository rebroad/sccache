# Rust incremental snapshot investigation

| Capability | Status | Evidence |
| --- | --- | --- |
| Same-checkout incremental restore | PASS | `tests/rust-incremental-sccache-poc.sh` |
| Different-checkout restore | PASS | `tests/rust-incremental-sccache-poc.sh`; `SCCACHE_TEST_ABSOLUTE_INPUT=1` variant |
| Genuine rustc work reuse | PASS | Both scripts above assert rustc loaded state and report hard-linked work products |
| Remote storage transfer | PASS | `tests/rust-incremental-container-reuse.sh` with Redis |
| Separate-filesystem/container reuse | PASS | `tests/rust-incremental-container-reuse.sh` |
| Fresh target-root predecessor discovery | PASS | `tests/rust-incremental-fresh-target.sh` |
| Fresh-builder real-workspace reuse | PASS | `tests/rust-incremental-workspace-benchmark.sh` |
| Dependency identity diagnostics | PASS | `tests/rust-incremental-fresh-target.sh` (trace assertions for `OUT_DIR`, paths, filenames, and artifact digests) |
| Sandbox build without daemon IPC | PASS | Fresh-target test with `SCCACHE_IN_PROCESS=1`; Redis container test with mode propagated to both builders |
| Cargo feature-change namespace fallback | PASS | `tests/rust-incremental-fresh-target.sh` Builder D case |
| Cargo profile-change namespace fallback | PASS | `tests/rust-incremental-fresh-target.sh` Builder E case (`--release`, incremental enabled) |
| Immutable snapshot publication | PASS | `cargo test --lib rust_incremental::tests` |
| Bounded candidate lookup | PASS | `candidate_index_retains_only_the_most_recent_bounded_set` |
| Concurrent publishing | PASS | `tests/rust-incremental-sccache-poc.sh`; Redis race in `tests/rust-incremental-container-reuse.sh` |
| Corruption fallback | PASS | `SCCACHE_TEST_CORRUPT_SNAPSHOTS=1 tests/rust-incremental-container-reuse.sh` |
| Eviction fallback | PASS | `SCCACHE_TEST_EVICT_SNAPSHOTS=1 tests/rust-incremental-container-reuse.sh`; bounded-index unit test |
| Partial-upload visibility safety | PASS | `incomplete_snapshot_upload_is_never_published_as_a_candidate` |
| Archive path/symlink escape rejection | PASS | `snapshot_rejects_parent_traversal`, `snapshot_rejects_absolute_path`, `snapshot_rejects_archive_symlink_escape`, and `snapshot_rejects_preexisting_symlink_escape` |
| Feature-change fallback | PASS | Container `SCCACHE_TEST_EXTRA_CFG=1` case; Cargo feature case above |
| RUSTFLAGS-change fallback | PASS | Container `SCCACHE_TEST_EXTRA_RUSTFLAGS=1` case |
| Target-triple fallback | PASS | Container `SCCACHE_TEST_TARGET_TRIPLE=i686-unknown-linux-gnu` case |
| rustc-version-mismatch fallback | PASS | Container `SCCACHE_TEST_RUSTC_VERSION_MISMATCH=1` case |
| Changed path-dependency fallback | PASS | `tests/rust-incremental-cargo-poc.sh` |
| Proc-macro expansion path behavior | PASS | `tests/rust-incremental-path-sensitive.sh` |
| Debug-info path remapping | PASS | `tests/rust-incremental-path-sensitive.sh` |
| Real-workspace benchmark completed | PASS | Three-round `tests/rust-incremental-workspace-benchmark.sh` run below |
| Demonstrated performance improvement | FAIL (tested workspace) | Three-round repeated benchmark below; 9.2–10.7× slower for remote edits |

Every PASS below names its automated test or command. The container evidence is
for separate Linux filesystems with the same host/target triple and toolchain;
it does not prove physical-machine or cross-architecture portability.

The fresh-target regression is `tests/rust-incremental-fresh-target.sh`. It
starts Builder B with no target directory, restores a normal exact-cache hit
for a dependency, verifies an `OUT_DIR`-sensitive dependency artifact differs
between target roots, then asserts rustc loaded the app predecessor and
hard-linked five work products. The restored program output matches a clean
Builder B build. A further build changes `CARGO_TARGET_DIR` and again proves
predecessor loading and clean-output equivalence. A final build enables a real
Cargo feature: it selects a distinct predecessor namespace, does not restore
the incompatible no-feature snapshot, and matches a clean feature-enabled
build. A final `--release` build with incremental mode enabled selects a
distinct namespace from the dev predecessor, does not restore it, and matches
a clean release build. Builder B has an empty target at startup; restoring
dependency artifacts through ordinary exact sccache hits is explicitly allowed
and expected. The
test proves those hits materialize dependencies into Builder B's fresh target
without inheriting Builder A's live target tree.

With trace logging enabled, the same test emits predecessor input diagnostics:
compiler arguments have per-option fingerprints, rustc-tracked environment
values have per-variable digests, and extern records show logical names,
physical paths, filenames, and artifact byte digests. Values of tracked
environment variables are not printed. In the minimal reproduction, the
`OUT_DIR` digest and generated dependency artifact digest differ between A and
B, while the dependent app's namespace is unchanged. Its restored output
matches a clean build and rustc reuses work products. The stable dependency
also produces a normal exact-cache hit into B's initially empty target; the
generated dependency's `OUT_DIR`-dependent exact-output key changes, so sccache
invokes rustc with a private incremental predecessor for that crate as well.

The real-workspace command and data are recorded under [real-workspace
benchmark](#real-workspace-benchmark). It uses separate source checkouts and
empty target roots for each remote case, Redis shared storage, and exact-cache
dependency restoration. It is a functional PASS, but the measurements do not
show a net performance improvement.

The path-sensitive proc-macro and debug-info regression is
`tests/rust-incremental-path-sensitive.sh`. It builds Builder A and B from
different source roots with fresh target directories, changes the function,
asserts rustc loaded the snapshot and reused work products, and compares the
program output with a clean Builder B build. Both `Span::call_site().file()`
from the proc macro and rustc `file!()` resolve to `src/lib.rs` under the
explicit logical path remap. `readelf --debug-dump=decodedline` confirms the
restored binary includes `src/lib.rs` line entries and contains neither
physical checkout root. This validates the tested remapped debug path; it does
not prove behavior for every debug format or platform.

Same-checkout, different-checkout, and genuine-reuse PASS evidence:
`tests/rust-incremental-sccache-poc.sh` (including its
`SCCACHE_TEST_ABSOLUTE_INPUT=1` mode) with rustc 1.98.1 on x86_64 Linux. The
test uses `-Z assert-incr-state=loaded` and reports hard-linked work products.
The retry path is exercised by
`SCCACHE_TEST_RUSTC_REJECT_RESTORED=1 tests/rust-incremental-sccache-poc.sh`:
the test makes rustc fail after it loads the restored work products, then
verifies sccache discards that crate's private state, retries successfully, and
matches a clean build. This tests sccache's retry handling with rustc's
diagnostic assertion; it does not simulate arbitrary incremental-format
corruption inside rustc.
The verified retry command used was:

```sh
TMPDIR=/var/tmp \
SCCACHE_TEST_RUSTC_REJECT_RESTORED=1 \
RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc \
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
tests/rust-incremental-sccache-poc.sh
```

Cargo's different-checkout PASS evidence, including `file!()`, generated source,
build-script `OUT_DIR`, and `CARGO_MANIFEST_DIR`, is
`tests/rust-incremental-cargo-poc.sh` with Cargo and rustc both pinned to
1.98.1. The same script changes a path dependency after the cross-checkout
build and proves the no-restore fallback matches a clean build. Cross-
machine same-host-triple reuse is demonstrated by
`tests/rust-incremental-container-reuse.sh`: separate container filesystems
share only read-only toolchain/binary mounts and Redis. Container B reports
five hard-linked work-product files, compares output with a clean build, and
has an empty local cache directory. Corruption fallback is exercised by
`SCCACHE_TEST_CORRUPT_SNAPSHOTS=1 tests/rust-incremental-container-reuse.sh`:
the test truncates all immutable snapshot records in its disposable Redis
instance, asserts that rustc did not load incremental state, then compares the
successful build with a clean output. Eviction fallback passes in
`immutable_publication_restores_and_skips_evicted_or_corrupt_objects`
from `cargo test --lib rust_incremental::tests`: removing a referenced object
returns a normal miss, and corrupt bytes under its immutable id are skipped
without populating the private directory. A successful retry after rustc exits
unsuccessfully on restored state passes through the assertion mode above;
arbitrary compiler ICEs or format-specific rejections remain untested.
`truncated_snapshot_with_valid_object_id_is_rejected_cleanly` also verifies a
truncated tar whose digest matches its published id is rejected and its private
restore directory removed; the surrounding build retry remains unverified.
`incomplete_snapshot_upload_is_never_published_as_a_candidate` injects a
storage failure during manifest upload and during index publication. In both
cases restore sees no candidate; the latter leaves only an orphaned complete
immutable object.
`candidate_index_retains_only_the_most_recent_bounded_set` publishes more than
eight objects, verifies only the newest eight remain indexed, evicts the newest
candidate, and verifies restore selects the next valid candidate.
Remote transfer passes with the repository's Redis backend: Redis contained
incremental object and index keys, and the consumer's local cache stayed empty.
Concurrent publishing passes in both backends. The direct script exercises two
writers and a later reader in local disk storage. The container script passes
the same producer through `SCCACHE_REDIS`, so those writers publish into one
Redis namespace concurrently and the reader restores and proves rustc loaded
prior work products.

This remains an opt-in prototype. Snapshot archives use content-addressed,
immutable object keys. A bounded eight-entry candidate index is the only
mutable entry and is published after the complete object. Concurrent index
updates are last-writer-wins hints: one writer may orphan an immutable object,
but cannot alter or corrupt another writer's snapshot. Local disk and Redis
backends, including concurrent Redis writers, have been tested.

### Compatibility and fallback matrix

These Redis/container cases ran with the v4 chunked object format on
rustc 1.98.1 / x86_64 Linux. Each run builds a producer in a separate
container filesystem, then runs a consumer against the same Redis backend.
The negative cases assert rustc did not load incremental state and compare the
result with a clean build. Every command below was run with
`TMPDIR=/var/tmp`, `SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache`,
and `RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc`.

| Case | Command/environment | Result |
| --- | --- | --- |
| Feature/cfg change | `SCCACHE_TEST_EXTRA_CFG=1 tests/rust-incremental-container-reuse.sh` | no predecessor restore; clean output matched |
| Cargo profile change | Builder E in `tests/rust-incremental-fresh-target.sh` | dev predecessor rejected for incremental release profile; clean output matched |
| Compiler flag change | `SCCACHE_TEST_EXTRA_RUSTFLAGS=1 tests/rust-incremental-container-reuse.sh` | no predecessor restore; clean output matched |
| Target change | `SCCACHE_TEST_TARGET_TRIPLE=i686-unknown-linux-gnu tests/rust-incremental-container-reuse.sh` | no restore; clean i686 object verified |
| rustc version mismatch | `SCCACHE_TEST_RUSTC_VERSION_MISMATCH=1 tests/rust-incremental-container-reuse.sh` | rustc 1.93 consumer did not restore rustc 1.98 state; clean output matched |
| Corrupt object records | `SCCACHE_TEST_CORRUPT_SNAPSHOTS=1 tests/rust-incremental-container-reuse.sh` | all Redis manifest/chunk records corrupted; fallback output matched clean |
| Evicted objects / stale index | `SCCACHE_TEST_EVICT_SNAPSHOTS=1 tests/rust-incremental-container-reuse.sh` | objects removed while index retained; fallback output matched clean |
| Changed path dependency | `tests/rust-incremental-cargo-poc.sh` | predecessor rejected; output matched clean |
| Concurrent Redis publishers | default `tests/rust-incremental-container-reuse.sh` | two independent writers raced; later reader loaded and reused rustc state |
| Bounded index | `candidate_index_retains_only_the_most_recent_bounded_set` | index retained exactly the latest eight candidates |
| Interrupted publication | `incomplete_snapshot_upload_is_never_published_as_a_candidate` | failed manifest/index writes were invisible to restore |

All scenarios above passed on 2026-09-24. These checks cover one Linux host
architecture and compiler family. Cross-architecture host portability,
other debug formats, and proc macros with additional external state remain
unverified.

## Current sccache behavior

There are two independent rejection points in current `main`:

1. `src/commands.rs` exits in the CLI when `CARGO_BUILD_INCREMENTAL=1` or
   `CARGO_INCREMENTAL=1` is present. This happens before the compiler request
   reaches the server.
2. `src/compiler/rust.rs::parse_arguments` returns `CannotCache("incremental")`
   for `-C incremental=...` even when the Cargo environment check did not fire.

The parser's comment records the actual gap: rustc writes additional mutable
compiler state, while sccache only understands the requested output artifacts.
Removing either guard alone would therefore be wrong.

For ordinary Rust requests, `RustHasher::generate_hash_key` hashes the source
files rustc reports through dep-info, extern and static library contents,
target JSON contents, parsed arguments, relevant environment dependencies,
Cargo environment, compiler verbose version, sysroot shared-library digests,
and the current working directory. Rust's argument hash currently does not use
`SCCACHE_BASEDIRS`; that normalization is applied to C/C++ hashing. The cwd is
explicitly included because it can be embedded in an rlib. Thus ordinary exact
Rust cache keys are deliberately checkout-sensitive today.

`RustCompilation::outputs` describes the emitted files. On a successful exact
miss, `compiler.rs` zstd-compresses those named outputs into the cache zip and
the `Storage` trait writes that immutable entry under its key. A hit extracts
each output through a temporary file and an atomic rename. The incremental
directory is neither enumerated nor included in this archive. The snapshot
prototype writes archives to content-addressed keys through `Storage`, then
updates a bounded candidate index. `Storage` has no candidate enumeration or
compare-and-swap operation, so concurrent index replacement can orphan an
object; missing references are skipped during lookup.

## rustc behavior relevant to importing a snapshot

With `-C incremental=DIR`, rustc uses a crate-specific directory based on the
crate name and stable crate id, then creates a uniquely named, locked session
directory. The session contains the dep graph, query-result cache, work-product
index, and codegen objects. The current session is staged and finalized after
queries complete; rustc garbage-collects old session directories. Concurrent
rustc processes use separate session directories rather than mutating one
session in place.

Before using previous state, rustc checks incremental file headers, decodes the
dep graph and work-product index, checks the saved dependency-tracking hash
against the current compiler options, and verifies referenced work-product
files exist. Missing work products are dropped. A stale dep graph is discarded;
corrupt graph data is diagnosed and treated as out of date. The on-disk query
result cache independently falls back to an empty cache when it cannot be
loaded. Query dependency fingerprints then drive rustc's red-green algorithm:
unchanged queries/work products are reused and changed or dependent work is
recomputed. These checks make a copied snapshot a candidate, not an authority.

### Cross-checkout rejection and fix

On rustc 1.93.0, two otherwise identical compilations with relative input,
incremental, and output paths but different current directories produced
`completely ignoring cache because of differing commandline arguments`.
The exact rustc 1.93 source shows `Options.working_dir` is tracked in
`compiler/rustc_session/src/options.rs`; `rustc_incremental::persist::load`
compares `sess.opts.dep_tracking_hash(false)` with the hash saved in the dep
graph and discards the graph on mismatch. This is a validity guard, not a
sccache key rejection.

`-Z remap-cwd-prefix=/sccache-workspace` alone did not fix rustc 1.93. That
version folded the physical cwd into the tracked `remap_path_prefix` option.
Rust PR [#157348](https://github.com/rust-lang/rust/pull/157348), included in
the tested rustc 1.98.1, keeps that physical mapping out of the tracked option
while applying it to `FilePathMapping`. With that fix, the logical tracked
working directory is the same across checkouts and rustc accepts the previous
state. The test keeps real, distinct checkout directories; it does not alias
them to one path.

The opt-in cross-checkout command needs the same logical remap on both builds:

```sh
RUSTC_WRAPPER=sccache \
CARGO_INCREMENTAL=1 \
SCCACHE_RUST_INCREMENTAL=1 \
RUSTC_BOOTSTRAP=1 \
RUSTFLAGS='-Zremap-cwd-prefix=/sccache-workspace' \
cargo build
```

`-Z remap-cwd-prefix` is unstable. The `RUSTC_BOOTSTRAP=1` setting in this
example enables that compiler flag with the tested stable toolchain; use a
nightly toolchain instead if preferred. The in-process switch is only needed
when a sandbox blocks local IPC: add `SCCACHE_IN_PROCESS=1` in that case.

This was verified in the restricted Codex shell: the host's system sccache
0.10 daemon attempt failed with `Operation not permitted`, while the fork's
sccache 0.18 completed the fresh-target Cargo regression with
`SCCACHE_IN_PROCESS=1`. The Redis container regression also passes with this
setting propagated to both builders; those sccache processes talk directly to
the configured Redis backend and do not depend on Codex-provided local IPC.
The Docker orchestration itself required access to the host Docker socket.

The in-process fresh-target command was:

```sh
TMPDIR=/var/tmp SCCACHE_IN_PROCESS=1 \
CARGO_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/cargo \
RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc \
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
tests/rust-incremental-fresh-target.sh
```

The separate-container Redis command was:

```sh
TMPDIR=/var/tmp SCCACHE_IN_PROCESS=1 \
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
tests/rust-incremental-container-reuse.sh
```

The checked-in test passes the input as relative `lib.rs` from each checkout's
own working directory, then compares the program output against a clean build.
This keeps the physical checkout roots different while rustc sees the same
input argument; `file!()` returns `lib.rs` in both builds. The same harness also
supports an absolute-input variant with
`SCCACHE_TEST_ABSOLUTE_INPUT=1`. Both the restored and clean rustc invocations
run from checkout B and receive the same absolute input. The separate-container
Redis test passes in this mode as well: `file!()` returned
`/sccache-workspace/lib.rs` for both restored and clean outputs, rustc accepted
the snapshot, and the consumer reported five hard-linked work-product files.
The earlier failure report compared different invocations (different input
spelling and working directory) and was not evidence of an incremental-cache
correctness defect. Absolute paths are not rewritten by sccache; rustc's path
mapping and query validation preserve the current checkout's observable path.

The Cargo test verifies that `CARGO_MANIFEST_DIR`, `OUT_DIR`, a build-script
export derived from `OUT_DIR`, generated-source `file!()`, and source `file!()`
match a clean build in checkout B after snapshot restore. Dedicated proc-macro,
debug-info, and changed-path-dependency tests are listed in the status table.
Rustc's incremental query validation must be allowed to invalidate
path-sensitive queries; the remap flag is not a substitute for those checks.
`-Z remap-cwd-prefix` can change the value observable by programs and users
must account for that behavior.

The rustc incremental format remains compiler-internal. The evidence is for
rustc 1.98.1 on x86_64 Linux only; it does not establish cross-version or
cross-architecture portability.

## Smallest architecture supported by the evidence

Crate-scoped rustc incremental snapshots work without rustc changes. Keep the
exact-output lookup first. On an exact miss only:

1. Derive a conservative compatibility namespace from compiler identity and
   host triple, crate identity, target, options/profile/features, relevant
   environment and logical extern-crate names. Physical dependency artifact
   paths, filenames, and byte digests are diagnostic-only: fresh targets can
   change them (notably through `OUT_DIR`), and rustc validates dependency
   compatibility after restore.
2. Look up up to eight predecessor ids in a bounded candidate index. The
   namespace does not require Git ancestry. Rustc-tracked environment
   dependencies are left for rustc to revalidate after restore.
3. Restore into a private incremental directory. Never run rustc against a
   remote/shared mutable directory.
4. Let rustc load, reject, or invalidate that state normally. Archive and digest
   failures discard the private copy and continue with empty state. If rustc
   exits unsuccessfully after loading a restored snapshot, sccache discards the
   crate state and partial outputs, then retries once without the snapshot;
   this path is exercised with rustc's `assert-incr-state` diagnostic.
5. After success, publish a complete immutable snapshot object, then update the
   bounded candidate index. Readers must never use a partial upload.

Each immutable archive contains only the rustc directory for the crate being
compiled. This lets Cargo's build-script crate and package crates share the
normal target incremental root without blocking one another's restore or
overwriting sibling crate state. Extraction rejects entries outside that
crate-specific directory and checks existing path components for symlinks.
Debug logs record snapshot archive bytes, object fetch time, extraction time,
and object upload time. With Redis, the cache-record payload size and total
server-side network byte deltas can be measured separately from those raw
archive bytes.

The index key is `rust-incremental-v4/<namespace>/index`; its cache object
`candidates.json` stores at most eight BLAKE3 archive ids, most recent first.
Each immutable object has a `manifest.json` key and numbered 8 MiB chunk keys
under `objects/<id>/`. The manifest is stored only after every chunk, and the
candidate index is updated only after the manifest. This sibling-key layout
works with hierarchical local storage as well as Redis. The archive id hashes
the complete reconstructed tar bytes; readers verify the digest before
extraction. Missing, evicted, malformed, and hash-mismatched objects are
skipped. `Storage` has no compare-and-swap, so concurrent index writes can lose
references but cannot mutate an immutable snapshot. The archive limit is 2 GiB.

Rustc's saved option hash is a necessary final check, not a sufficient sccache
namespace: it does not promise to encode host CPU/OS compatibility or protect
the snapshot transport. The current namespace includes rustc version, host
triple, crate name, compiler options, tracked Cargo configuration variables,
logical extern-crate names, and compiler shared-library identity. Dependency
artifact paths, filenames, and byte digests are logged at trace level but do
not enter predecessor identity. Environment dependencies reported by rustc
dep-info remain in the exact-output key and are revalidated by rustc after
restore. `CARGO_MANIFEST_DIR` and
`CARGO_MANIFEST_PATH` are omitted from the predecessor namespace because they
name the physical checkout; they remain in the exact-output key. The Cargo
integration test demonstrates path-sensitive values from the checkout and
build script match a clean build after restore. Target options are included.
The container test proves only the same x86_64 Linux host/target triple and
toolchain; other host/target pairs remain unsupported.

The current sccache cache key cannot double as the predecessor key: it includes
source contents, so a revision change necessarily misses. A separate
compatibility namespace plus immutable snapshot ids is implemented. The generic
Storage API has key-based get/put but no compare-and-swap or listing. The
bounded index tolerates last-writer wins by allowing an unreferenced immutable
object to be orphaned; readers skip missing references. Build-script `OUT_DIR`
and build-script environment output now pass the focused Cargo test; broader
workspace and path-dependency coverage remains.

Approach B (new rustc export/import API) is not justified yet. Rustc already
does the essential validation after a private copy. A compiler-owned snapshot
API may later be warranted to formalize portability, expose compatibility
metadata, or avoid copying irrelevant sessions; it must be developed in the
rust-lang/rust repository and cannot be invented in sccache. Fine-grained
content-addressed query/work-product storage is a later optimization: rustc
currently finalizes coupled graph/index/session data, so extracting individual
files first adds protocol and consistency risk.

## Prototype

`tests/rust-incremental-sccache-poc.sh` drives the actual sccache path through
two distinct checkout directories. It first proves a same-checkout edit, then
restores the published snapshot in checkout B after a separate edit. Both
compiles assert rustc loaded incremental state; the logs must report at least
one hard-linked previous work product. It compares B's runtime assertions
against a clean B build and verifies the `file!()` value. Run it with
`RUSTC_BIN=/path/to/rustc-1.98.1` and
`SCCACHE_BIN=/path/to/sccache tests/rust-incremental-sccache-poc.sh`. It prints
the exact `rustc -Vv` identity and platform. The script uses
`RUSTC_BOOTSTRAP=1` to enable `-Z remap-cwd-prefix` and rustc's diagnostic flags.

The Cargo cross-checkout regression must pin Cargo and rustc to the same
toolchain (Cargo's executable path alone does not select rustc):

```sh
CARGO_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/cargo \
RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc \
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
tests/rust-incremental-cargo-poc.sh
```

It creates independent A and B checkouts and target directories, edits a Rust
module, confirms sccache restored the predecessor and rustc hard-linked prior
work products, then compares source/generated `file!()`, `OUT_DIR`, and
`CARGO_MANIFEST_DIR` program output with a clean B Cargo build. It then changes
a local path dependency and confirms the changed-dependency build does not
restore the old predecessor and matches a clean build. The dependency-change
case is a conservative rejection; it does not demonstrate reuse across an
unchanged dependency artifact with a changed source checkout.

To combine the experimental snapshot path with a sandbox that denies local
IPC, set both `SCCACHE_RUST_INCREMENTAL=1` and `SCCACHE_IN_PROCESS=1`. The
in-process option accesses the configured cache backend directly and does not
start the sccache daemon. It does not alter bwrap or other sandbox policy.
Daemon-aggregated statistics are unavailable in this mode.

The command used for the passing restricted invocation was:

```sh
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc \
tests/rust-incremental-sccache-poc.sh
```

The automated same-host-triple, separate-filesystem transfer test is:

```sh
tests/rust-incremental-container-reuse.sh
```

It builds a small Debian image with a C linker, starts a temporary Redis 7
container, runs the producer and consumer in separate Docker root filesystems,
and removes the containers and test image on exit. It needs Docker, network
access for Debian packages and the Redis image, and the host rustc/sccache paths
shown in the script. The only shared compiler files are read-only mounts; the
incremental directories and checkouts are private to each container.

Remote-storage transfer was verified against a temporary Redis 7 container
using the same test and toolchain:

```sh
SCCACHE_REDIS=redis://127.0.0.1:6389 \
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc \
tests/rust-incremental-sccache-poc.sh
```

The E2E left its `SCCACHE_DIR` empty, and `redis-cli --scan` showed the
`rust-incremental-v4/.../objects/...` and `/index` records. Docker bridge
port-forwarding was unavailable on this host, so the temporary service used
host networking. This proves storage transfer through Redis, not cross-machine
reuse.

It completed without escalation or a daemon socket. In the latest local disk
run with relative source arguments, the first miss took 4.689 seconds, the
cross-checkout restored compile 0.393 seconds, and the same-checkout restored
compile 0.480 seconds. The B incremental state was 1,102,696 bytes; the full
local cache directory was 914,432 bytes. This tiny project is correctness
evidence, not a performance claim.

## Real-workspace benchmark

The exact command was:

```sh
TMPDIR=/var/tmp \
CARGO_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/cargo \
RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc \
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
BENCH_BUILD_ROOT=/mnt/kingston/builds/rebroad/src/sccache.build \
tests/rust-incremental-workspace-benchmark.sh
```

The workspace is this sccache repository (`randomize_readdir`, `sccache`),
rustc 1.98.1 (`48a229ceaefd4985c50990b14116b6d856af0985`), x86_64 Linux. The
baseline run is in
`/mnt/kingston/builds/rebroad/src/sccache.build/workspace-benchmark-20260924T195603Z`;
the final chunked-Redis run is in
`/mnt/kingston/builds/rebroad/src/sccache.build/workspace-benchmark-20260924T203743Z`.
Remote runs use separate source roots and empty target directories. Redis is
the sccache storage backend; Builder B receives dependencies through exact
cache hits. Each remote edit restored 260 hard-linked rustc work products.

| Case | Wall seconds | rustc compile seconds | Snapshot evidence |
| --- | ---: | ---: | --- |
| Clean build, incremental disabled | 91.712 | 313.243 | no snapshot |
| Local incremental seed | 99.045 | 324.047 | seed |
| Local incremental small edit | 10.924 | 306.185 | 268 hard-linked files |
| sccache exact-cache seed | 152.737 | 345.604 | 312,016,704 B local cache |
| sccache exact-cache hit | 58.578 | 0 | 1,135 exact hits |
| Remote incremental miss | 163.475 | 362.073 | raw snapshot 364,955,648 B; compressed record 95,637,953 B |
| Remote small edit | 119.504 | 88.778 | restored 364,955,648 B; fetch 2,319.290 ms; unpack 242.974 ms; uploaded compressed payload 191,436,447 B |
| Remote moderate edit | 123.705 | 94.761 | restored 730,066,432 B; fetch 4,487.078 ms; unpack 550.708 ms; uploaded compressed payload 191,824,058 B |

Redis byte totals include exact-cache artifacts, metadata, and protocol overhead;
the compressed snapshot payload column above isolates the v4 snapshot records.
The final dataset is the measured Redis string payload size after each case.

| Remote case | Raw snapshot published | Raw snapshot restored | Snapshot payload written | Redis bytes uploaded | Redis bytes downloaded | Redis dataset after case |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Seed miss | 364,955,648 B | 0 B | 95,637,953 B | 415,484,270 B | 19,615 B | 410,315,692 B |
| Small edit | 730,066,432 B | 364,955,648 B | 191,436,447 B | 322,187,157 B | 284,753,999 B | 732,487,078 B |
| Moderate edit | 731,663,360 B | 730,066,432 B | 191,824,058 B | 317,804,806 B | 385,449,708 B | 1,050,276,075 B |

The exact-cache baseline's local cache directory was 312,016,704 B. In the
remote cases, the per-builder local cache directories were empty; Redis held
the shared cache dataset shown above. Each edit reused 260 hard-linked
work-product files. The moderate edit restored a larger prior snapshot because
the preceding small edit had itself published updated compiler state.

The three-round controlled comparison below supersedes the earlier single-run
performance interpretation.

### Controlled repeated comparison

The exact command was:

```sh
TMPDIR=/var/tmp \
BENCH_REPEATS=3 \
CARGO_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/cargo \
RUSTC_BIN=/home/rebroad/.rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/rustc \
SCCACHE_BIN=/mnt/kingston/builds/rebroad/src/sccache.build/target/debug/sccache \
BENCH_BUILD_ROOT=/mnt/kingston/builds/rebroad/src/sccache.build \
tests/rust-incremental-workspace-benchmark.sh
```

This ran cleanly from revision `fc7c1fa3eb2cb5802f765481dc26242cfa4944a2`
on rustc 1.98.1, x86_64 Linux, sccache 0.18.0. The three rounds used the same
compiler inputs, benchmark order, and Redis 7 instance; Redis was flushed
between rounds. The benchmark recorded medians and ranges in
`/mnt/kingston/builds/rebroad/src/sccache.build/workspace-benchmark-20260924T211056Z/repeated-summary.tsv`.
Each local run retained its target directory between seed and edits. Every
remote edit used a different source root and an initially empty target; its
dependencies came through Redis exact-cache hits. Builder B must not inherit
Builder A's live target directory, but dependency artifacts may and should be
materialized by normal exact sccache hits into B's empty target. Targets and
per-builder caches were removed after each round to control disk use.

| Edit case | Local incremental wall median [min, max] | Fresh-target Redis wall median [min, max] | Remote/local wall ratio median | Work reused |
| --- | ---: | ---: | ---: | --- |
| Small | 11.738 s [10.751, 12.343] | 120.750 s [117.335, 125.434] | 10.686x | 268 local; 260 remote work products per round |
| Moderate | 13.417 s [12.704, 13.561] | 118.510 s [117.169, 126.538] | 9.223x | 268 local; 260 remote work products per round |

Remote small edit medians: rustc compile elapsed 90.990 s, 364,956,160 B raw
snapshot restored, 730,067,456 B raw snapshots published, 191,436,621 B
compressed snapshot payload written, 322,186,674 B Redis uploaded, 284,756,583 B
downloaded, 2,252.893 ms fetch, 237.602 ms unpack, and 732,493,715 B dataset
after the case. The moderate edit medians were 91.355 s rustc compile elapsed,
730,067,456 B restored, 731,663,872 B published, 191,823,882 B compressed
payload written, 317,805,135 B uploaded, 385,450,535 B downloaded, 4,465.049 ms
fetch, 529.443 ms unpack, and 1,050,274,803 B dataset after the case. Redis
wire totals include exact-cache artifacts and metadata; snapshot payload counts
only the immutable snapshot records. Each remote edit also recorded over 1,080
exact-cache hits.

The result is a performance **FAIL for this tested workspace and configuration**:
fresh-target Redis edits took about 9.2–10.7 times longer than local
incremental edits in all three paired rounds, despite genuine rustc reuse.
The snapshot representation and transfer costs exceed the time saved here.
This does not prove that every workspace or backend will regress, but the
prototype must not claim a performance improvement based on these results.

## Performance root-cause follow-up (2026-09-25)

The earlier label “rustc compile elapsed ~91 s” was misleading. In the saved
three-round logs, the benchmark's remote `rustc_compile_s` field sums sccache
`Compiled in ...` durations across every cache miss in the Cargo build. It is
not one rustc invocation and it is not directly comparable to the local
case's sum of `-Z time-passes` records. For round 3 small-edit, the saved log
has **54 Rust cache misses** with a summed compiler duration of **92.727 s**,
alongside **1,081 exact-cache hits**. The largest individual misses include
`sccache` (15.041 s), `redis` (11.049 s), `opendal_core` (5.101 s), `jiff`
(4.555 s), and `reqwest` (3.784 s).

For the edited `sccache` crate itself, the saved `-Z time-passes` records show
about **12.5 s total** in rustc in the remote small-edit case; sccache reports
15.041 s for that compile operation. The local incremental `sccache` crate
records about **10.5 s** of rustc phase time. Thus the “91 s after snapshot
restore” is not evidence that rustc spent 91 s validating or recomputing the
restored crate. The observed dominant additional work is Cargo rebuilding
dependencies whose ordinary exact keys miss in a fresh target build. Snapshot
fetch and unpack remain only a few seconds.

An exact-key example is `serde_core` in
`r03-remote-incremental-miss.log` versus
`r03-remote-incremental-small-edit.log`: source path, crate name, compiler
options, Cargo metadata ID, and dependency artifact identity are otherwise
the same, but `--out-dir` and `-L dependency` point under `remote-a/target`
versus `remote-small/target`, and the exact hash changes from
`a24a907858b535de...` to `149a47729febc198...`. The ordinary exact key remains
path-sensitive for outputs/arguments where relocation could change output
semantics. This is direct evidence that target-path differences can defeat
exact artifact hits. It is not yet a controlled test proving that normalizing
those paths makes the full workspace fast; some output bytes can also encode
paths.

### Path and rustc phase comparison

| Configuration | Wall | rustc metric | Reused work products | Total work products | Status/evidence |
| --- | ---: | ---: | ---: | ---: | --- |
| Local incremental, same checkout/target | 11.738 s median | `sccache` crate about 10.5 s rustc phase time; aggregate benchmark metric is not comparable | 268 files in rustc session diagnostics | Not recorded | Three-round workspace benchmark, `r03-local-incremental-small-edit.log` |
| Restored snapshot, same logical source/target paths in separate filesystems | Not measured for workspace | Not measured for workspace | Five files in the small container POC | Not recorded | `tests/rust-incremental-container-reuse.sh` exercises a small POC; it does not time the workspace |
| Restored snapshot, different source, normalized target | Not measured | Not measured | Not measured | Not recorded | No controlled case in the saved benchmark |
| Restored snapshot, different source and target roots | 120.750 s median | 92.727 s summed across 54 cache-miss compiles; edited `sccache` crate about 12.5 s rustc phase time | 260 files for edited crate | Not recorded | Three-round workspace benchmark, `r03-remote-incremental-small-edit.log` |
| Clean build, incremental disabled | 91.712 s in prior single-run benchmark | 313.243 s summed across rustc phase records | 0 | Not recorded | Prior baseline; not a paired sample in the repeated run |

`-Z incremental-info` reports reused hard-linked files and query statistics,
but the saved logs do not report the total number of work products in the
snapshot or a reliable reused/available fraction. They also do not give a
comparable total of reused versus invalidated codegen units. Therefore “260
out of how many?” and the fraction of compiler work reused remain
**unmeasured**; hard-link count alone cannot answer them. The existing logs do
show nontrivial rustc work after restore: the edited crate's rustc time is
near the local incremental time, rather than 7x higher.

No controlled workspace self-profile or path-factorial experiment has yet
measured B, C, or the combinations of identical/different source and target
paths. Rustc time-passes data for the existing remote build shows the edited
crate's main link phase at about **11.1 s**, compared with about **7.4 s** in
the local incremental run. That roughly 3.7 s difference is material for the
edited crate but is not the 91-second sum across 54 misses. Query validation
time and exact invalidation counts are not separately reported. Safe source
and target path normalization has not been shown to change user-visible
`file!()`, debug-info, or macro-path behavior for this full workspace.

### Snapshot growth

The saved benchmark establishes that the restored archive is about 365 MB and
the next published archive about 730 MB. It does **not** preserve the archive
file listing or incremental directory tree, so this run cannot establish the
number or sizes of session directories, count the files/work products, or
attribute the added bytes to particular files. Rustc's time-passes output
shows its incremental session-GC phase ran, but that alone does not establish
which session directories were retained or when they were removed relative
to sccache snapshot capture. The cause of the approximately 365 MB growth and
whether all captured sessions are needed are therefore **unresolved**. No
files were removed.

### Coarse-namespace false-positive and retry tests

`tests/rust-incremental-false-positive.sh` builds `changed_dep::value()` as
`1` in Builder A and `2` in Builder B while holding crate name, target,
profile, features, rustc, and compiler options constant. It asserts the app
predecessor namespace is identical, the candidate is restored, and
`-Z assert-incr-state=loaded` succeeds. The restored executable prints `2 14`
and matches a clean Builder B build. This proves correctness of the tested
dependency-change case and confirms rustc/sccache discovery does not hash
dependency artifact bytes into the predecessor namespace. The test does not
yet assert exact red/green query counts, so the amount of invalidation is not
quantified.

The same script changes the app to contain an ordinary type error after a
valid candidate has been published. Observed behavior: sccache restores the
snapshot, rustc fails with the source error, and sccache invokes rustc a
second time after discarding the restored state. The test observes exactly
two `Compiling locally` attempts and returns failure. The current fallback
therefore double-compiles ordinary source errors. Restricting retry to errors
reasonably attributable to restored incremental state needs a reliable
rustc diagnostic/API signal; no such policy change was made here.

### Answers and remaining measurements

1. The apparent ~91 s component is principally **dependency compilation after
   exact-cache misses**, not 91 s of incremental-state validation. Snapshot
   transport is smaller; the edited crate itself is about 12.5 s in the
   inspected rustc phase log. The 92.727 s number is a sum across 54 compiles.
2. Snapshot growth from ~365 MB to ~730 MB is **not yet explained at file or
   session level**. The run discarded the directory inventories needed to do
   that accounting.
3. The reused fraction is **unknown**: 260 reused work products are observed,
   but total available work products are not recorded.
4. Target-root path differences demonstrably change at least some ordinary
   exact keys (`serde_core` example above). Whether same logical paths
   materially improve full-workspace reuse has not yet been measured.
5. **Yes.** The false-positive dependency test restores the old candidate and
   produces the new dependency's value, matching a clean build.
6. **Yes.** An ordinary source type error is compiled twice under the current
   unconditional retry-after-restored-failure behavior.
7. The highest-leverage next measurement is to rerun the workspace with
   identical logical source and target paths in independent filesystems, then
   separate dependency exact-hit/miss time from the edited crate's rustc
   phases. If that removes the 54 misses, path-stable builder layouts may
   solve most of this measured regression without changing snapshot storage.

The controlled same/different path matrix, full-workspace session inventory,
self-profile, total-work-product counts, and query/codegen reuse fractions
remain open investigation items; no storage optimization was attempted.

## Risks and remaining measurements

- **Correctness:** always restore privately and trust rustc's compatibility
  checks. If rustc exits unsuccessfully after a snapshot restore, sccache
  discards that crate's state and partial outputs, then retries once without
  the snapshot. The `SCCACHE_TEST_RUSTC_REJECT_RESTORED=1` mode verifies this
  path. Archive extraction failures also leave the private state empty.
- **Security:** archive traversal and pre-existing symlink escapes are covered
  by `snapshot_rejects_parent_traversal`, `snapshot_rejects_absolute_path`,
  `snapshot_rejects_archive_symlink_escape`, and
  `snapshot_rejects_preexisting_symlink_escape`. Serialized compiler state is
  still untrusted input to rustc, so keep the feature opt-in and use only a
  trusted cache until the rustc parser is reviewed.
- **Concurrency/eviction:** immutable objects and concurrent local/Redis
  publication are exercised by `tests/rust-incremental-sccache-poc.sh` and
  `tests/rust-incremental-container-reuse.sh`. Index updates remain
  last-writer-wins hints; an update can orphan an immutable object. The unit
  test `immutable_publication_restores_and_skips_evicted_or_corrupt_objects`
  covers missing-object fallback. Never share a live incremental directory.
- **Portability:** separate Linux containers on x86_64 with the same host and
  target triples passed. This does not prove other kernel, OS, CPU-feature, or
  architecture combinations. x86_64-host to aarch64-target is not equivalent
  to aarch64-host to aarch64-target.
- **Cost:** a controlled three-round real-workspace benchmark is recorded
  above. Snapshot transfer and writes are large, and remote edits were 9.2–10.7×
  slower than local incremental edits for this workspace/configuration. This is
  a measured performance failure here; no broader backend/workspace claim is
  justified.

## Upstreaming boundary

An sccache proposal needs a Rust-specific experimental setting, CLI rejection
changes, snapshot enumeration/capture/restore, compatibility-key and index
logic, stats/logging, bounded retention, corruption fallback, and local/remote
tests. Existing exact hits must remain first. No rustc or Cargo changes are
currently required by the demonstrated same-host prototype. Any later portable
snapshot API belongs in rustc and requires a separate compiler-side design and
review.

## Files changed in this prototype

- `GOAL.md`
- `src/compiler/c.rs`
- `src/compiler/compiler.rs`
- `src/compiler/rust.rs`
- `src/compiler/rust_incremental.rs`
- `tests/rust-incremental-cargo-poc.sh`
- `tests/rust-incremental-sccache-poc.sh`
- `tests/Dockerfile.rust-incremental`
- `tests/rust-incremental-container-consumer.sh`
- `tests/rust-incremental-container-reuse.sh`
- `tests/rust-incremental-fresh-target.sh`
- `tests/rust-incremental-workspace-benchmark.sh`
- `tests/rust-incremental-path-sensitive.sh`
- `docs/RustIncrementalSnapshots.md`
- `docs/Rust.md`
- `docs/Configuration.md`
