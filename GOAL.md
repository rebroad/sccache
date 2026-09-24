============================================================
CURRENT STATUS — THIS OVERRIDES OLDER STATUS TEXT BELOW
============================================================

The following have now been demonstrated:

- Same-checkout incremental restore: PASS.
- Different-checkout incremental restore: PASS on rustc 1.98.1,
  x86_64 Linux.
- Genuine rustc work-product reuse after cross-checkout restore: PASS.
- Path-sensitive Cargo values and path-dependency changes: covered.
- Redis/shared-storage snapshot transfer: PASS.
- Separate container filesystems with restored incremental state and
  genuine rustc reuse: PASS.

The Redis/container result demonstrates separate-build-environment,
same-host-triple reuse. It does not by itself prove portability between
different physical machines, and should be described accurately.

These successful cases are now regression requirements. Do not spend the
main effort re-solving them unless a later change breaks them.

The fresh-target namespace blocker is now resolved for the sccache Cargo
workspace. `tests/rust-incremental-workspace-benchmark.sh` demonstrated that
Builder B starts with an empty target, reconstructs dependencies through
normal Cargo/sccache operation, finds the predecessor after both a small and
moderate source edit, and reuses 260 rustc work products. Both remote builds
reported more than 1,080 exact-cache hits. The dedicated
`tests/rust-incremental-fresh-target.sh` also verifies the restored output
against a clean build and exercises target-root-specific `OUT_DIR` artifacts
and `CARGO_TARGET_DIR` changes.

This resolves the fresh-builder functional milestone on rustc 1.98.1,
x86_64 Linux with Redis shared storage. It does not establish a performance
improvement: the remote edits are much slower than a local incremental edit.
Current additional test results on 2026-09-24:

- Changed Cargo feature/cfg: safe no-restore fallback, clean output matched.
- Changed `RUSTFLAGS`: safe no-restore fallback, clean output matched.
- Changed target triple to i686 on the same x86_64 host: no restore; clean
  target output verified.
- rustc 1.98.1 producer to rustc 1.93.0 consumer: no restore; clean output
  matched.
- Corrupted and evicted Redis v4 object records: fallback output matched.
- Changed path dependency: no restore; clean output matched.
- Concurrent Redis publication/read: reader restored and reused prior work.
- Interrupted manifest and index writes: no partial candidate became visible.
- Candidate index: newest eight retained; evicted newest entry skipped in favor
  of the next usable candidate.
- Proc-macro `Span::call_site().file()` output and rustc `file!()` output were
  compared between restored and clean Builder B builds; both resolved to the
  remapped `src/lib.rs`.
- The restored executable's DWARF line table contains `src/lib.rs` and no
  physical Builder A or Builder B checkout path.

Continue remaining security, portability, and reproducibility work; do not
rewrite the resolved fresh-builder milestone as a blocker.

============================================================
REGRESSION REQUIREMENT — FRESH-BUILDER PREDECESSOR DISCOVERY
============================================================

Keep this workflow passing:

    Builder A
        source root A
        fresh target root A
        build revision N
        dependencies built/restored normally
        publish incremental snapshot
              |
              v
        shared sccache storage
              |
              v
    Builder B
        different source root B
        initially empty target root B
        dependencies reconstructed normally through Cargo/sccache
        build revision N+1
              |
              v
        exact output cache miss for changed crate
              |
              v
        compatible incremental predecessor discovered
              |
              v
        snapshot restored privately
              |
              v
        rustc validates it
              |
              v
        rustc genuinely reuses previous compiler work
              |
              v
        correct output matching a clean build

Builder B MUST NOT inherit Builder A's target tree through copying,
sharing, bind mounts, or another out-of-band mechanism.

However, dependency artifacts MAY and SHOULD be restored through ordinary
sccache exact-cache hits. Cached dependency reuse is part of the intended
distributed-build workflow.

============================================================
SEPARATE EXACT-OUTPUT IDENTITY FROM PREDECESSOR IDENTITY
============================================================

Investigate whether values appropriate for an ordinary exact-output
sccache key are incorrectly being reused in the incremental predecessor
compatibility namespace.

These are different questions:

    Exact-output lookup:
        "Have these exact compilation inputs already produced an output?"

    Incremental predecessor lookup:
        "Is there a sufficiently compatible previous compiler state that
         rustc may be able to reuse?"

The predecessor namespace does NOT need to prove a snapshot valid.
It only needs to find plausible candidates.

rustc remains the authoritative validator.

Therefore prefer:

    compatibility namespace
        ->
    bounded plausible candidate set
        ->
    private restore
        ->
    rustc validity/invalidation checks

over an exact namespace so restrictive that potentially useful snapshots
are never found.

It is acceptable for predecessor lookup to produce occasional false-positive
candidates that rustc rejects.

It is undesirable for lookup to produce false negatives merely because
target-root-specific artifact names, paths, or hashes differ when rustc
could safely determine what remains reusable.

============================================================
DIAGNOSE THE DEPENDENCY IDENTITY DIFFERENCE
============================================================

Add structured diagnostics explaining why two builds do or do not share
an incremental predecessor namespace.

For representative dependencies compare:

- logical dependency identity;
- artifact filename;
- absolute artifact path;
- artifact byte digest;
- rustc invocation;
- `-C metadata`;
- `-C extra-filename`;
- `--extern` values;
- build-script outputs;
- OUT_DIR-derived values;
- relevant environment variables;
- Cargo feature/profile configuration.

When no predecessor is found, provide a diagnostic resembling:

    rustc identity                    equal
    host triple                       equal
    target triple                     equal
    crate/package identity            equal
    profile                           equal
    features                          equal

    dependency foo logical identity   equal
    dependency foo artifact path      DIFFERENT
    dependency foo filename           DIFFERENT
    dependency foo byte digest        equal/different

Do not stop at "dependency hashes differ."

Determine exactly which dependency value differs and why.

Distinguish clearly between:

    A. sccache did not discover a candidate

and:

    B. sccache restored a candidate but rustc rejected/invalidated it

Those are separate failures.

============================================================
MINIMAL REPRODUCTION
============================================================

Before repeatedly debugging the large workspace, create a small Cargo
workspace that reproduces the fresh-target-root divergence:

    app
      -> path dependency lib

Build it in:

    source root A + target root A

and:

    source root B + target root B

Compare the dependency identity inputs listed above.

Then progressively add, where necessary:

- dependency source changes;
- features;
- build.rs;
- OUT_DIR;
- proc macros;
- transitive dependencies.

Use this to identify which values should participate in predecessor
discovery and which should instead be left to rustc's final validation.

============================================================
REAL-WORKSPACE REQUIREMENT
============================================================

Keep the real-workspace requirement strict.

The real-workspace functional milestone now passes for the sccache workspace
on the platform and toolchain recorded above. Keep it as a regression
requirement. Broader target/configuration combinations remain to be tested.

- Builder B begins with an empty target tree;
- dependencies are reconstructed normally, including sccache exact hits;
- a source edit causes the normal exact output lookup to miss;
- sccache still discovers an incremental predecessor;
- rustc actually loads useful restored state;
- rustc demonstrably reuses compiler work;
- the output agrees with a clean build.

Do not preserve Builder A's target/deps merely to make this pass.

============================================================
PERFORMANCE
============================================================

Latest real-workspace snapshot measurements are approximately:

    362 MB raw
    95 MB compressed/Redis payload

should be recorded as a concern.

Snapshot chunks were introduced because the Redis client response timeout
prevented retrieval of large single records. The current chunked layout uses
8 MiB chunks; this correctness fix does not establish that the overall format
is efficient. Continue to measure separately:

1. FUNCTIONAL SUCCESS
   - Was a predecessor discovered?
   - Was it restored?
   - Did rustc reuse compiler work?

2. PERFORMANCE SUCCESS
   - Was retrieving/restoring the snapshot actually cheaper than recomputing
     the compiler work?

A functional PASS with a performance FAIL or INCONCLUSIVE result is a valid
research outcome.

============================================================
REMAINING DISTRIBUTED-CACHE WORK
============================================================

Continue to track these independently:

- immutable snapshot publication;
- bounded candidate indexing;
- concurrent publisher safety;
- stale-index handling;
- eviction fallback;
- corruption fallback;
- archive/path traversal safety;
- partial-upload safety.

Redis transfer alone does not make these PASS.

============================================================
UPDATED STATUS TABLE
============================================================

Use at least:

    Capability                                      Status
    -----------------------------------------------------------------
    Same-checkout restore                           PASS/FAIL
    Different-checkout restore                      PASS/FAIL
    Genuine rustc work reuse                        PASS/FAIL
    Redis/shared-storage snapshot transfer          PASS/FAIL
    Separate-filesystem/container reuse             PASS/FAIL
    Fresh target-root predecessor discovery         PASS/FAIL
    Fresh-builder real-workspace reuse              PASS/FAIL
    Immutable snapshot publication                  PASS/FAIL
    Bounded candidate lookup                        PASS/FAIL
    Concurrent publishing                           PASS/FAIL
    Corruption fallback                             PASS/FAIL
    Eviction/stale-index fallback                   PASS/FAIL
    Real-workspace functional reuse                 PASS/FAIL
    Real-workspace benchmark completed              PASS/FAIL
    Demonstrated net performance improvement        PASS/FAIL/INCONCLUSIVE

Every PASS must point to the exact automated test demonstrating it.

============================================================
CURRENT DEFINITION OF SUCCESS
============================================================

This milestone is achieved when a genuinely fresh Builder B,
with a different source root and initially empty target root, reconstructs
dependencies through normal Cargo/sccache operation, misses the exact cache
for the changed crate, discovers a compatible incremental predecessor,
restores it privately, and rustc demonstrably reuses prior work while
producing output matching a clean build.

The remaining questions are:

    Which required configuration, corruption, eviction, concurrency, and
    platform cases remain unverified, and what controlled repeated benchmark
    is needed to assess performance?
