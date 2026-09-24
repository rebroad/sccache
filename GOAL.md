Continue the existing Rust incremental snapshot work in the current sccache repository.

Do NOT restart the investigation from scratch and do NOT merely produce another design document. The existing prototype has already demonstrated that:

- whole-directory rustc incremental snapshots can be captured and restored through sccache;
- rustc can genuinely reuse restored work products;
- same-host, same-checkout-path reuse works;
- the current prototype uses a single mutable compatibility key;
- remote-cache concurrency, eviction, cross-checkout portability, and cross-machine reuse are not yet solved.

Your next goal is to turn that proof of concept into a practical distributed incremental-cache prototype.

The work has TWO required milestones, in this order.

============================================================
MILESTONE 1 — MAKE SNAPSHOTS WORK ACROSS DIFFERENT CHECKOUT PATHS
============================================================

The existing experiment shows that restoring a snapshot into a different checkout path causes rustc to reject the incremental state because of differing command-line arguments.

Solve this properly.

Example:

Machine/build A:

    /home/builder-a/project
        revision A
        -> rustc incremental build
        -> snapshot stored

Later:

    /tmp/ci-job-928/project
        revision B
        -> restore snapshot from revision A
        -> rustc must accept compatible state
        -> unchanged work must actually be reused

The checkout path must NOT need to be identical.

Do not fake success by arranging for both builds to use the same absolute directory.

Investigate exactly which command-line argument, tracked compiler input, crate metadata, working-directory value, remapped path, environment variable, or incremental fingerprint causes rustc to invalidate the restored state.

Use rustc diagnostics/incremental debugging facilities to prove the cause.

Evaluate mechanisms such as:

- rustc path remapping;
- `--remap-path-prefix`;
- normalized working directories;
- canonical logical workspace roots;
- changing how sccache invokes rustc;
- changing compatibility metadata;
- changes to rustc only if unavoidable.

Do NOT disable rustc correctness checks merely to make the snapshot load.

The preferred outcome is that semantically equivalent builds from different checkout roots look equivalent to rustc while diagnostics/debug info remain correct or deliberately remapped.

Be careful about:

- `file!()`;
- `env!()` / `option_env!()`;
- debug info;
- dep-info;
- build scripts;
- proc macros;
- absolute source paths embedded into outputs;
- Cargo metadata;
- path dependencies;
- `OUT_DIR`;
- target directory differences.

If path normalization changes observable Rust program behavior, document that explicitly.

Success criterion for Milestone 1:

Create an automated test that:

1. builds revision A in checkout/path A;
2. stores the incremental snapshot;
3. creates a separate checkout/path B;
4. modifies at least one function or module;
5. deletes any naturally inherited incremental state in B;
6. restores the state from A through sccache;
7. runs rustc normally;
8. proves that rustc accepted the snapshot;
9. proves that at least some previous work products or queries were genuinely reused;
10. compares the resulting program/library against a clean build for correctness.

Do not use wall-clock timing alone as evidence of reuse.

Record the exact rustc version and platform used.

If this cannot be made correct without modifying rustc, identify the exact rustc limitation and implement the smallest appropriate rustc-side experiment rather than hiding the failure.

============================================================
MILESTONE 2 — REAL REMOTE, CROSS-MACHINE REUSE
============================================================

Once Milestone 1 works, implement and demonstrate:

    Machine A
        |
        | incremental build
        v
    sccache remote/shared storage
        |
        | snapshot transfer
        v
    Machine B
        |
        | different checkout path
        | same compatible rustc/toolchain
        v
    restored rustc incremental state
        |
        v
    genuine incremental reuse

The machines may be containers/VMs if necessary, but they must have separate filesystems and must not share the live rustc incremental directory.

Initially constrain compatibility to:

- same rustc version/build identity;
- same rustc host triple;
- same target triple;
- same relevant compiler configuration.

Do NOT attempt cross-host-architecture portability yet.

For example, proving:

    x86_64 Linux machine A
        ->
    x86_64 Linux machine B

is sufficient.

Do not claim support for:

    x86_64 host
        ->
    aarch64 host

unless separately proven.

============================================================
REPLACE THE SINGLE MUTABLE SNAPSHOT KEY
============================================================

The current prototype's single mutable compatibility key is not sufficient for a real shared cache.

Replace it with a safe snapshot publication model.

Use immutable snapshot objects.

Conceptually:

    compatibility namespace
        |
        +--> snapshot object A
        +--> snapshot object B
        +--> snapshot object C

Each snapshot object should be immutable once published.

Snapshot objects should preferably be content-addressed or otherwise uniquely identified.

Create a bounded candidate-index mechanism so a request can find a small number of previous compatible snapshots.

The index must tolerate:

- concurrent writers;
- last-writer races;
- missing/evicted snapshot objects;
- partially failed publication;
- stale index entries.

A reader must never observe or use a partially uploaded snapshot.

Prefer this publication ordering:

    create complete snapshot
        ->
    upload immutable object
        ->
    verify/store successfully
        ->
    publish/update candidate reference

Never mutate a remotely shared rustc incremental directory in place.

Each build should:

    download snapshot
        ->
    restore into private local directory
        ->
    invoke rustc
        ->
    allow rustc to mutate private state
        ->
    publish a new immutable snapshot

============================================================
PREDECESSOR SELECTION
============================================================

Do not require Git history for the core implementation.

Create a conservative compatibility namespace from appropriate inputs such as:

- rustc compiler identity;
- rustc host triple;
- target triple;
- crate/package identity;
- relevant compiler options;
- Cargo profile/configuration;
- feature configuration;
- dependency identity where appropriate;
- codegen/backend settings;
- environment values that affect compilation.

Do NOT include the current source-content hash in the compatibility namespace in a way that makes every source edit produce a separate namespace.

The whole point is to locate previous state for a changed revision.

Keep ordinary sccache exact-output caching unchanged:

    exact output cache lookup
        |
        +-- hit --> return output immediately
        |
        +-- miss
             |
             v
        incremental predecessor lookup
             |
             +-- candidate --> restore and run rustc
             |
             +-- none ------> normal incremental/clean compilation

The existing exact cache remains the fastest path.

For the first implementation, choosing the most recent compatible snapshot is acceptable if correctness is preserved.

Support a small bounded candidate list if practical.

Do not build an elaborate Git ancestry system unless measurements prove it is necessary.

============================================================
CORRUPTION AND FALLBACK
============================================================

A bad remote snapshot must never break a build permanently.

Test:

- truncated archive;
- missing files;
- corrupted archive;
- rustc rejecting restored state;
- incompatible compiler;
- incompatible target/configuration;
- index pointing to an evicted object.

Expected behavior:

    restore attempt
        ->
    rustc or sccache rejects state
        ->
    discard private restored copy
        ->
    retry safely without the snapshot
        ->
    successful correct build

No cache state may become authoritative over rustc's own validity checks.

============================================================
CONCURRENCY TEST
============================================================

Create a test with at least two independent builders publishing into the same compatibility namespace concurrently.

Verify that:

- neither corrupts the other's snapshot;
- readers never see partial data;
- losing an index race does not invalidate a successfully stored immutable snapshot;
- subsequent builds can still find a usable candidate;
- the cache remains correct if one candidate is evicted.

============================================================
REMOTE BACKEND
============================================================

Use an actual sccache shared/remote storage implementation where practical.

If testing a production cloud backend is impractical, use the closest repository-supported backend suitable for deterministic automated tests.

Do not simulate "remote" reuse by copying directories manually outside sccache.

Snapshot storage/retrieval must flow through the sccache storage abstraction.

Document any backend assumptions.

============================================================
PERFORMANCE VALIDATION
============================================================

After correctness is established, benchmark at least one nontrivial Cargo workspace.

Measure these cases:

1. clean build with incremental disabled;
2. ordinary local rustc incremental rebuild;
3. existing sccache exact cache behavior;
4. remote incremental snapshot miss;
5. remote incremental snapshot hit after a small source edit;
6. remote incremental snapshot hit after a moderate edit.

Report:

- wall-clock build time;
- rustc time where available;
- snapshot raw size;
- compressed size;
- bytes uploaded;
- bytes downloaded;
- extraction/restoration time;
- rustc incremental reuse evidence;
- amount/type of work reused where diagnostics allow;
- resulting cache size.

Do not claim the approach improves performance unless measurements show it.

If snapshot transfer costs exceed saved compilation time, report that clearly.

============================================================
TEST MATRIX
============================================================

At minimum, automate:

- same checkout, small edit;
- different checkout, small edit;
- different checkout, module edit;
- same architecture, separate machine/container;
- feature change;
- `RUSTFLAGS` change;
- dependency change;
- target change;
- rustc version mismatch;
- corrupted snapshot;
- missing snapshot;
- evicted snapshot;
- concurrent writers.

The correct result for some configuration changes may be snapshot rejection.

That is success if the fallback is correct.

============================================================
SECURITY
============================================================

Keep this feature experimental and opt-in.

Do not treat remote incremental compiler state as inherently trusted.

Document the trust boundary.

Ensure archive extraction cannot trivially write outside the intended incremental-state directory.

Check for unsafe archive paths such as:

    ../../something
    /absolute/path
    symlink-based escapes

If the current prototype extracts archives unsafely, fix that before remote-cache support is considered usable.

Do not claim arbitrary untrusted remote caches are safe unless that has actually been established.

============================================================
CONFIGURATION
============================================================

Keep the feature behind an explicit experimental flag.

Preserve current default sccache behavior.

Existing non-incremental Rust caching and other compiler caching must continue working unchanged.

Do not require users to set undocumented combinations of environment variables just to make the normal prototype work.

Document the minimal configuration.

============================================================
DO NOT DO THESE THINGS
============================================================

Do NOT:

- merely remove the incremental-compilation rejection;
- fake cross-checkout testing with identical filesystem paths;
- infer incremental reuse from wall-clock timing;
- use a manually copied directory instead of the sccache storage path;
- disable rustc validity checks;
- declare cross-machine support after testing only one filesystem namespace;
- declare concurrency solved while retaining a single mutable snapshot key;
- claim cross-architecture support without testing it;
- redesign rustc's entire query system;
- start with fine-grained distributed query caching;
- spend the entire task writing another architecture document.

Modify code, run tests, and demonstrate the behavior.

============================================================
DELIVERABLE
============================================================

At the end, update `RustIncrementalSnapshots.md`.

Start it with a concise status table:

    Capability                              Status
    ---------------------------------------------------------
    Same-checkout incremental restore       PASS/FAIL
    Different-checkout restore              PASS/FAIL
    Genuine rustc work reuse                PASS/FAIL
    Remote storage transfer                 PASS/FAIL
    Cross-machine same-host-triple reuse    PASS/FAIL
    Concurrent publishing                   PASS/FAIL
    Corruption fallback                     PASS/FAIL
    Eviction fallback                       PASS/FAIL
    Real-workspace benchmark                PASS/FAIL
    Demonstrated performance improvement    PASS/FAIL/INCONCLUSIVE

For every PASS, provide the exact automated test or command that demonstrates it.

For every FAIL or INCONCLUSIVE result, explain the blocker without disguising it as completed work.

Also include:

- files changed;
- architecture implemented;
- cache key/namespace design;
- snapshot/index format;
- rustc compatibility behavior;
- test results;
- benchmark results;
- security limitations;
- remaining blockers;
- what would be required before proposing the feature upstream.

============================================================
DEFINITION OF SUCCESS
============================================================

The main goal is achieved only when this workflow works:

    separate build environment A
        |
        | build revision N
        v
    sccache stores incremental snapshot
        |
        v
    shared/remote cache
        |
        v
    separate build environment B
        |
        | different checkout path
        | revision N+1
        v
    ordinary exact sccache lookup misses
        |
        v
    sccache finds compatible incremental predecessor
        |
        v
    snapshot restored privately
        |
        v
    rustc validates snapshot
        |
        v
    rustc genuinely reuses previous work
        |
        v
    correct output produced
        |
        v
    updated immutable snapshot safely published

while concurrent builders and cache corruption cannot cause incorrect compiler output.

Begin with the different-checkout failure. Determine exactly why rustc currently rejects the restored state, fix or correctly normalize that incompatibility, and prove genuine incremental reuse before moving on to remote cross-machine support.
