# Rust incremental snapshot investigation

| Capability | Status |
| --- | --- |
| Same-checkout incremental restore | PASS |
| Different-checkout restore | PASS |
| Genuine rustc work reuse | PASS |
| Remote storage transfer | PASS |
| Cross-machine same-host-triple reuse | PASS |
| Concurrent publishing | PASS |
| Corruption fallback | PASS |
| Eviction fallback | PASS |
| Real-workspace benchmark | FAIL |
| Demonstrated performance improvement | INCONCLUSIVE |

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
match a clean build in checkout B after snapshot restore. Proc-macro output,
debug information, and path dependencies still need dedicated tests. Rustc's
incremental query validation must be allowed to invalidate path-sensitive
queries; the remap flag is not a substitute for those checks.
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
   environment and dependency identity.
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

The index key is `rust-incremental-v3/<namespace>/index`; its cache object
`candidates.json` stores at most eight BLAKE3 archive ids, most recent first.
Snapshot objects use `rust-incremental-v3/<namespace>/objects/<id>` and contain
`snapshot.tar`. The archive id hashes the complete tar bytes; readers verify
the digest before extraction. The object is written to `Storage` before its id
is published in the index. Missing, evicted, and hash-mismatched objects are
skipped. `Storage` has no compare-and-swap, so concurrent index writes can lose
references but cannot mutate an immutable snapshot.

Rustc's saved option hash is a necessary final check, not a sufficient sccache
namespace: it does not promise to encode host CPU/OS compatibility or protect
the snapshot transport. The current namespace includes rustc version, host
triple, crate name, compiler options, tracked Cargo configuration variables,
dependency digests, and the compiler shared-library identity. Environment
dependencies reported by rustc dep-info remain in the exact-output key and are
revalidated by rustc after restore. `CARGO_MANIFEST_DIR` and
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
`rust-incremental-v3/.../objects/...` and `/index` records. Docker bridge
port-forwarding was unavailable on this host, so the temporary service used
host networking. This proves storage transfer through Redis, not cross-machine
reuse.

It completed without escalation or a daemon socket. In the latest local disk
run with relative source arguments, the first miss took 4.689 seconds, the
cross-checkout restored compile 0.393 seconds, and the same-checkout restored
compile 0.480 seconds. The B incremental state was 1,102,696 bytes; the full
local cache directory was 914,432 bytes. Earlier tiny
runs varied substantially, so this is not a performance claim or the requested
real-workspace benchmark. It proves state loading and work-product reuse only.

## Risks and remaining measurements

- **Correctness:** always restore privately and trust rustc's compatibility
  checks. If rustc exits unsuccessfully after a snapshot restore, sccache
  discards that crate's state and partial outputs, then retries once without
  the snapshot. The `SCCACHE_TEST_RUSTC_REJECT_RESTORED=1` mode verifies this
  path. Archive extraction failures also leave the private state empty.
- **Security:** archive traversal and pre-existing symlink escapes are covered
  by `snapshot_rejects_parent_traversal` and
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
- **Cost:** the prototype measures one snapshot's compressed and raw sizes.
  Consecutive-snapshot duplication, upload/download latency, and compile-time
  savings remain to be measured on a real Cargo workspace.

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
- `docs/RustIncrementalSnapshots.md`
- `docs/Rust.md`
- `docs/Configuration.md`
