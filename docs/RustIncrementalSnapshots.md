# Rust incremental snapshot investigation

Status: opt-in sccache prototype. The storage and in-process paths are implemented, but
snapshot lookup is deliberately a single mutable compatibility key and is not ready
for untrusted or concurrent remote-cache use. Only the local disk backend has been
tested; the prototype does not enforce a backend restriction.

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
directory is neither enumerated nor included in this archive. `Storage` does
provide generic `get` and `put` operations, so separate immutable snapshot
objects are possible; it has no candidate enumeration or atomic mutable-index
primitive. A snapshot design therefore needs a bounded lookup key/list and a
publication protocol that tolerates concurrent writers and eviction.

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

The crate id and working directory are separate issues. A snapshot copied to a
different checkout was restored by sccache, but rustc 1.93 rejected it with
`completely ignoring cache because of differing commandline arguments`. A
follow-up using the same checkout path and same rustc arguments did load the
state and reuse work products after a one-function edit. Cross-checkout reuse
therefore remains unproven and currently fails in this experiment. The state
format is compiler-internal, host tools may
produce host-specific work products, and the format/header checks are not a
cross-version or cross-architecture portability promise.

## Smallest architecture supported by the evidence

Approach A, whole-directory snapshotting, works as a first experiment without
rustc changes. Keep the exact-output lookup first. On an exact miss only:

1. Derive a conservative compatibility namespace from compiler identity and
   host triple, crate identity, target, options/profile/features, relevant
   environment and dependency identity.
2. Look up a small bounded list of immutable snapshots in that namespace.
   The prototype uses one mutable key and does not require Git ancestry.
3. Restore into a private incremental directory. Never run rustc against a
   remote/shared mutable directory.
4. Let rustc load, reject, or invalidate that state normally. On load errors,
   remove the private copy and retry once with an empty incremental directory.
5. After success, publish a complete immutable snapshot object, then update the
   bounded candidate index atomically. Readers must never use a partial upload.

Rustc's saved option hash is a necessary final check, not a sufficient sccache
namespace: it does not promise to encode host CPU/OS compatibility or protect
the snapshot transport. The first remote-capable version should namespace at
least by rustc `-vV` identity, host triple, target triple, crate id and the
existing sccache toolchain identity. Cross-host reuse stays disabled until
tested for the specific pair.

The current sccache cache key cannot double as the predecessor key: it includes
source contents, so a revision change necessarily misses. A separate
compatibility namespace plus immutable snapshot ids is needed. The generic
Storage API can carry the objects, but an index must cope with storage backends
that only support key-based get/put, bounded size, last-writer races, and index
references to evicted objects. Content-addressed manifests with atomic replace
or append-only candidate slots are preferable to mutating a shared snapshot.

Approach B (new rustc export/import API) is not justified yet. Rustc already
does the essential validation after a private copy. A compiler-owned snapshot
API may later be warranted to formalize portability, expose compatibility
metadata, or avoid copying irrelevant sessions; it must be developed in the
rust-lang/rust repository and cannot be invented in sccache. Fine-grained
content-addressed query/work-product storage is a later optimization: rustc
currently finalizes coupled graph/index/session data, so extracting individual
files first adds protocol and consistency risk.

## Prototype

Run `tests/rust-incremental-snapshot-poc.sh` on Linux with rustc, tar and zstd
for a low-level copy experiment. `tests/rust-incremental-sccache-poc.sh` drives
the actual opt-in sccache path: it builds revision A, deletes the local
incremental directory, edits one function at the same checkout path, restores
through sccache, and verifies rustc hard-links previous work-product files.
It then compares runtime assertions with a clean build. The script uses
`RUSTC_BOOTSTRAP=1` only to enable rustc's diagnostic flags.

To combine the experimental snapshot path with a sandbox that denies local
IPC, set both `SCCACHE_RUST_INCREMENTAL=1` and `SCCACHE_IN_PROCESS=1`. The
in-process option accesses the configured cache backend directly and does not
start the sccache daemon. It does not alter bwrap or other sandbox policy.
Daemon-aggregated statistics are unavailable in this mode.

On rustc 1.93.0, the no-escalation restricted run completed through
`SCCACHE_IN_PROCESS=1` with no daemon socket created. The same-checkout run
reported `restored Rust incremental snapshot` and
`session directory: 5 files hard-linked`; both the changed output and a clean
non-incremental output passed the runtime assertions. The raw incremental
directory was 1,087,136 bytes. The isolated cache directory was 256,785 bytes
after storing the snapshot and exact output. Measured wall times in that run
were 0.826 seconds for the first compile and 0.756 seconds for the restored
compile; other restricted and escalated runs varied from 0.467 to 0.811 seconds
for the first compile and 0.407 to 0.756 seconds for the restored compile. These
tiny sample timings show no reliable speedup. They establish the restore path,
not the value of the approach on a real Cargo workspace.

## Risks and remaining measurements

- **Correctness:** always restore privately and trust rustc's compatibility
  checks. A failed/partial restore must degrade to an empty state, never reuse
  outputs based only on the sccache namespace.
- **Security:** serialized compiler state is untrusted input to rustc. Existing
  cache formats do not establish that hostile incremental state is safe. Keep
  this feature opt-in and trusted-cache-only until the rustc parser and archive
  extraction attack surfaces are reviewed.
- **Concurrency/eviction:** immutable objects avoid readers seeing partially
  written bytes, but this prototype overwrites one mutable key and has no
  concurrent-writer protocol. Remote-backend consistency, eviction and
  concurrent use are untested. Never share a live incremental directory.
- **Portability:** x86_64-host to aarch64-target is not equivalent to
  aarch64-host to aarch64-target. The host triple must be a namespace key;
  whether even same-triple machines can share state remains experimentally
  unverified.
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
