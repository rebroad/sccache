#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo "This experiment currently expects Linux." >&2
    exit 2
fi

cargo_bin=${CARGO_BIN:-cargo}
rustc_bin=${RUSTC_BIN:-rustc}
sccache_bin=${SCCACHE_BIN:-sccache}
root=$(mktemp -d /var/tmp/sccache-fresh-target.XXXXXX)
root=$(cd "$root" && pwd -P)
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        for log in "$root"/{a,b,c,d,e,clean,clean-c,clean-d,clean-e}.log; do
            if [[ -f "$log" ]]; then
                echo "--- $(basename "$log"): relevant diagnostics ---" >&2
                rg 'predecessor namespace=|predecessor details:|compatibility inputs:|restored Rust incremental|no Rust incremental|Cache hit|files hard-linked|asserted that the incremental cache|completely ignoring cache|retrying without|error:|Finished' "$log" >&2 || true
            fi
        done
        echo "kept fresh-target reproduction at $root" >&2
        exit "$status"
    fi
    if [[ "${SCCACHE_TEST_KEEP_TMP:-0}" == 1 ]]; then
        echo "kept fresh-target reproduction at $root"
    else
        rm -rf "$root"
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p \
    "$root/a/app/src" "$root/b/app/src" \
    "$root/shared/stable_dependency/src" \
    "$root/shared/generated_dependency/src" \
    "$root/cache"
: > "$root/sccache.conf"

for checkout in a b; do
    cat > "$root/$checkout/app/Cargo.toml" <<'TOML'
[package]
name = "fresh_target_probe"
version = "0.1.0"
edition = "2021"

[dependencies]
stable_dependency = { path = "../../shared/stable_dependency" }
generated_dependency = { path = "../../shared/generated_dependency" }

[features]
snapshot_feature = []

[profile.dev]
incremental = true

[profile.release]
incremental = true

[profile.dev.package.stable_dependency]
incremental = false
TOML
    cat > "$root/$checkout/app/src/lib.rs" <<'RS'
mod component;

pub fn value() -> u32 {
    component::value() + stable_dependency::value() + generated_dependency::value() + feature_bonus()
}

#[cfg(feature = "snapshot_feature")]
fn feature_bonus() -> u32 { 100 }
#[cfg(not(feature = "snapshot_feature"))]
fn feature_bonus() -> u32 { 0 }

pub fn generated_out_dir() -> &'static str {
    generated_dependency::generated_out_dir()
}
RS
    cat > "$root/$checkout/app/src/component.rs" <<'RS'
pub fn value() -> u32 { 10 }
RS
    cat > "$root/$checkout/app/src/main.rs" <<'RS'
fn main() {
    println!("{} {}", fresh_target_probe::value(), fresh_target_probe::generated_out_dir());
}
RS
done
sed -i 's/value() -> u32 { 10 }/value() -> u32 { 11 }/' "$root/b/app/src/component.rs"

cat > "$root/shared/stable_dependency/Cargo.toml" <<'TOML'
[package]
name = "stable_dependency"
version = "0.1.0"
edition = "2021"
TOML
cat > "$root/shared/stable_dependency/src/lib.rs" <<'RS'
pub fn value() -> u32 { 20 }
RS

cat > "$root/shared/generated_dependency/Cargo.toml" <<'TOML'
[package]
name = "generated_dependency"
version = "0.1.0"
edition = "2021"
build = "build.rs"
TOML
cat > "$root/shared/generated_dependency/build.rs" <<'RS'
fn main() {
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let generated = format!(
        "pub fn generated_out_dir() -> &'static str {{ {:?} }}\n",
        out_dir
    );
    std::fs::write(std::path::Path::new(&out_dir).join("generated.rs"), generated).unwrap();
}
RS
cat > "$root/shared/generated_dependency/src/lib.rs" <<'RS'
include!(concat!(env!("OUT_DIR"), "/generated.rs"));
pub fn value() -> u32 { 30 }
RS

cat > "$root/rustc-wrapper" <<'SH'
#!/bin/sh
compiler=$1
shift
if [ "$SCCACHE_ASSERT_INCR_STATE" = loaded ]; then
    is_probe=0
    expect_crate_name=0
    for arg in "$@"; do
        if [ "$arg" = --crate-name ]; then
            expect_crate_name=1
            continue
        fi
        if [ "$expect_crate_name" = 1 ]; then
            [ "$arg" = fresh_target_probe ] && is_probe=1
            expect_crate_name=0
        fi
        if [ "$is_probe" = 1 ] && [ "$arg" = src/lib.rs ]; then
            exec "$SCCACHE_BIN" "$compiler" "$@" -Z assert-incr-state=loaded
        fi
    done
fi
exec "$SCCACHE_BIN" "$compiler" "$@"
SH
chmod +x "$root/rustc-wrapper"

printf 'rustc version:\n'
"$rustc_bin" -Vv
printf 'platform: '
uname -a

export SCCACHE_CONF="$root/sccache.conf"
export SCCACHE_DIR="$root/cache"
export SCCACHE_IN_PROCESS=1
export SCCACHE_RUST_INCREMENTAL=1
export RUSTC_BOOTSTRAP=1
export RUSTC_WRAPPER="$root/rustc-wrapper"
export RUSTC="$rustc_bin"
export SCCACHE_BIN="$sccache_bin"
export SCCACHE_ASSERT_INCR_STATE=not-loaded
export SCCACHE_LOG=trace
export RUSTFLAGS='-Z remap-cwd-prefix=/sccache-fresh-target -Z incremental-info'

(
    cd "$root/a/app"
    "$cargo_bin" build --target-dir "$root/target-a" -vv > "$root/a.log" 2>&1
)
if [[ -e "$root/target-b" ]]; then
    echo "Builder B target unexpectedly exists before its build" >&2
    exit 1
fi
printf 'Builder B target before build: empty (path absent)\n'
(
    cd "$root/b/app"
    SCCACHE_ASSERT_INCR_STATE=loaded "$cargo_bin" build --target-dir "$root/target-b" -vv \
        > "$root/b.log" 2>&1
)

stable_a=$(find "$root/target-a/debug/deps" -maxdepth 1 -name 'libstable_dependency-*.rmeta' -print -quit)
stable_b=$(find "$root/target-b/debug/deps" -maxdepth 1 -name 'libstable_dependency-*.rmeta' -print -quit)
generated_a=$(find "$root/target-a/debug/deps" -maxdepth 1 -name 'libgenerated_dependency-*.rmeta' -print -quit)
generated_b=$(find "$root/target-b/debug/deps" -maxdepth 1 -name 'libgenerated_dependency-*.rmeta' -print -quit)
[[ -n "$stable_a" && -n "$stable_b" && -n "$generated_a" && -n "$generated_b" ]]
stable_hash_a=$(sha256sum "$stable_a" | cut -d ' ' -f 1)
stable_hash_b=$(sha256sum "$stable_b" | cut -d ' ' -f 1)
generated_hash_a=$(sha256sum "$generated_a" | cut -d ' ' -f 1)
generated_hash_b=$(sha256sum "$generated_b" | cut -d ' ' -f 1)
[[ "$stable_hash_a" == "$stable_hash_b" ]]
[[ "$generated_hash_a" != "$generated_hash_b" ]]

grep -F '[stable_dependency]: Cache hit' "$root/b.log" >/dev/null
grep -F '[fresh_target_probe]: Rust incremental compatibility inputs:' "$root/a.log" >/dev/null
grep -F '[fresh_target_probe]: Rust incremental compatibility inputs:' "$root/b.log" >/dev/null
grep -F 'tracked_environment_value_digests=' "$root/b.log" >/dev/null
generated_out_a=$(grep -F '[generated_dependency]: Rust incremental compatibility inputs:' "$root/a.log" \
    | grep -oE 'OUT_DIR:[0-9a-f]{64}' | tail -1)
generated_out_b=$(grep -F '[generated_dependency]: Rust incremental compatibility inputs:' "$root/b.log" \
    | grep -oE 'OUT_DIR:[0-9a-f]{64}' | tail -1)
[[ -n "$generated_out_a" && -n "$generated_out_b" && "$generated_out_a" != "$generated_out_b" ]]
for log in "$root/a.log" "$root/b.log"; do
    identity_details=$(grep -F '[fresh_target_probe]: Rust incremental predecessor details:' "$log" | tail -1)
    for field in cargo_output_ids_excluded physical_cargo_env_excluded dependency_artifacts \
        logical_name=generated_dependency path= filename= byte_digest= digest_in_namespace=false; do
        if [[ "$identity_details" != *"$field"* ]]; then
            echo "predecessor diagnostics are missing $field in $(basename "$log")" >&2
            exit 1
        fi
    done
done
grep -F '[fresh_target_probe]: restored Rust incremental snapshot' "$root/b.log" >/dev/null
grep -F 'session directory:' "$root/b.log" | grep -Eq '[1-9][0-9]* files hard-linked'
if grep -F '[fresh_target_probe]: completely ignoring cache' "$root/b.log" >/dev/null; then
    echo "rustc restored the directory but rejected its incremental state" >&2
    exit 1
fi
if grep -F '[fresh_target_probe]: compilation failed after restoring Rust incremental state' \
    "$root/b.log" >/dev/null; then
    echo "sccache had to retry the compile without the restored snapshot" >&2
    exit 1
fi

"$root/target-b/debug/fresh_target_probe" > "$root/restored.out"
(
    cd "$root/b/app"
    RUSTC_WRAPPER= "$cargo_bin" build --target-dir "$root/target-clean" -vv \
        > "$root/clean.log" 2>&1
)
"$root/target-clean/debug/fresh_target_probe" > "$root/clean.out"
[[ "$(cut -d ' ' -f 1 "$root/restored.out")" == "$(cut -d ' ' -f 1 "$root/clean.out")" ]]
grep -q '^61 ' "$root/restored.out"
grep -F "$root/target-b/" "$root/restored.out" >/dev/null
if grep -F "$root/target-a/" "$root/restored.out" >/dev/null; then
    echo "Builder B output leaked Builder A's target path" >&2
    exit 1
fi
grep -F "$root/target-clean/" "$root/clean.out" >/dev/null

# Also vary Cargo's target directory through its environment variable. This
# commonly differs between CI workers and must not block predecessor search.
sed -i 's/value() -> u32 { 11 }/value() -> u32 { 12 }/' "$root/b/app/src/component.rs"
if [[ -e "$root/target-c" ]]; then
    echo "Builder C target unexpectedly exists before its build" >&2
    exit 1
fi
(
    cd "$root/b/app"
    CARGO_TARGET_DIR="$root/target-c" SCCACHE_ASSERT_INCR_STATE=loaded \
        "$cargo_bin" build -vv > "$root/c.log" 2>&1
)
grep -F '[fresh_target_probe]: restored Rust incremental snapshot' "$root/c.log" >/dev/null
grep -F 'CARGO_TARGET_DIR": "physical-target-directory"' "$root/c.log" >/dev/null
namespace_b=$(sed -n 's/.*\[fresh_target_probe\]: Rust incremental predecessor namespace=\([0-9a-f]*\).*/\1/p' "$root/b.log" | tail -1)
namespace_c=$(sed -n 's/.*\[fresh_target_probe\]: Rust incremental predecessor namespace=\([0-9a-f]*\).*/\1/p' "$root/c.log" | tail -1)
[[ -n "$namespace_b" && "$namespace_b" == "$namespace_c" ]]
"$root/target-c/debug/fresh_target_probe" > "$root/c.out"
(
    cd "$root/b/app"
    RUSTC_WRAPPER= CARGO_TARGET_DIR="$root/target-clean-c" "$cargo_bin" build -vv \
        > "$root/clean-c.log" 2>&1
)
"$root/target-clean-c/debug/fresh_target_probe" > "$root/clean-c.out"
[[ "$(cut -d ' ' -f 1 "$root/c.out")" == "$(cut -d ' ' -f 1 "$root/clean-c.out")" ]]
grep -q '^62 ' "$root/c.out"
grep -F "$root/target-c/" "$root/c.out" >/dev/null
grep -F "$root/target-clean-c/" "$root/clean-c.out" >/dev/null

# Cargo feature configuration must not reuse the no-feature predecessor.
if [[ -e "$root/target-d" ]]; then
    echo "Builder D target unexpectedly exists before its build" >&2
    exit 1
fi
(
    cd "$root/b/app"
    SCCACHE_ASSERT_INCR_STATE=not-loaded "$cargo_bin" build --features snapshot_feature \
        --target-dir "$root/target-d" -vv > "$root/d.log" 2>&1
)
grep -F '[fresh_target_probe]: no Rust incremental snapshot' "$root/d.log" >/dev/null
if grep -F '[fresh_target_probe]: restored Rust incremental snapshot' "$root/d.log" >/dev/null; then
    echo "restored a no-feature predecessor into the feature-enabled build" >&2
    exit 1
fi
namespace_d=$(sed -n 's/.*\[fresh_target_probe\]: Rust incremental predecessor namespace=\([0-9a-f]*\).*/\1/p' "$root/d.log" | tail -1)
[[ -n "$namespace_b" && -n "$namespace_d" && "$namespace_b" != "$namespace_d" ]]
"$root/target-d/debug/fresh_target_probe" > "$root/d.out"
(
    cd "$root/b/app"
    RUSTC_WRAPPER= "$cargo_bin" build --features snapshot_feature \
        --target-dir "$root/target-clean-d" -vv > "$root/clean-d.log" 2>&1
)
"$root/target-clean-d/debug/fresh_target_probe" > "$root/clean-d.out"
[[ "$(cut -d ' ' -f 1 "$root/d.out")" == "$(cut -d ' ' -f 1 "$root/clean-d.out")" ]]
grep -q '^162 ' "$root/d.out"
grep -F "$root/target-d/" "$root/d.out" >/dev/null
grep -F "$root/target-clean-d/" "$root/clean-d.out" >/dev/null
printf 'Cargo feature change selected a distinct namespace and matched a clean output: %s\n' "$namespace_d"

# The release profile changes compiler options and must not restore dev-profile
# state. Keep incremental mode enabled to check predecessor isolation directly.
if [[ -e "$root/target-e" ]]; then
    echo "Builder E target unexpectedly exists before its build" >&2
    exit 1
fi
(
    cd "$root/b/app"
    SCCACHE_ASSERT_INCR_STATE=not-loaded "$cargo_bin" build --release \
        --target-dir "$root/target-e" -vv > "$root/e.log" 2>&1
)
grep -F '[fresh_target_probe]: no Rust incremental snapshot' "$root/e.log" >/dev/null
if grep -F '[fresh_target_probe]: restored Rust incremental snapshot' "$root/e.log" >/dev/null; then
    echo "restored a dev-profile predecessor into the release-profile build" >&2
    exit 1
fi
namespace_e=$(sed -n 's/.*\[fresh_target_probe\]: Rust incremental predecessor namespace=\([0-9a-f]*\).*/\1/p' "$root/e.log" | tail -1)
[[ -n "$namespace_c" && -n "$namespace_e" && "$namespace_c" != "$namespace_e" ]]
"$root/target-e/release/fresh_target_probe" > "$root/e.out"
(
    cd "$root/b/app"
    RUSTC_WRAPPER= "$cargo_bin" build --release \
        --target-dir "$root/target-clean-e" -vv > "$root/clean-e.log" 2>&1
)
"$root/target-clean-e/release/fresh_target_probe" > "$root/clean-e.out"
[[ "$(cut -d ' ' -f 1 "$root/e.out")" == "$(cut -d ' ' -f 1 "$root/clean-e.out")" ]]
grep -q '^62 ' "$root/e.out"
grep -F "$root/target-e/" "$root/e.out" >/dev/null
grep -F "$root/target-clean-e/" "$root/clean-e.out" >/dev/null
printf 'Cargo release profile selected a distinct namespace and matched clean output: %s\n' "$namespace_e"

printf 'Builder B exact dependency cache hit: '
grep -F '[stable_dependency]: Cache hit' "$root/b.log" | head -1
printf 'Builder A structured predecessor identity inputs: '
grep -F '[fresh_target_probe]: Rust incremental compatibility inputs:' "$root/a.log" | head -1
printf 'Builder B structured predecessor identity inputs: '
grep -F '[fresh_target_probe]: Rust incremental compatibility inputs:' "$root/b.log" | head -1
printf 'OUT_DIR env! values are tracked but omitted from predecessor identity: %s vs %s\n' \
    "$generated_out_a" "$generated_out_b"
printf 'Dependency artifact identity diagnostics (A then B):\n'
grep -F '[fresh_target_probe]: Rust incremental predecessor details:' "$root/a.log" | tail -1
grep -F '[fresh_target_probe]: Rust incremental predecessor details:' "$root/b.log" | tail -1
printf 'sccache-restored stable dependency digest: %s\n' "$stable_hash_b"
printf 'OUT_DIR-dependent dependency artifact digests differ across target roots: %s %s\n' \
    "$generated_hash_a" "$generated_hash_b"
printf 'Builder B restored and rustc accepted predecessor: '
grep -F '[fresh_target_probe]: restored Rust incremental snapshot' "$root/b.log" | head -1
printf 'Builder B reused restored work products: '
grep -F 'session directory:' "$root/b.log" | grep -E '[1-9][0-9]* files hard-linked' | head -1
printf 'restored output matches a clean Builder B build: '
cat "$root/restored.out"
printf 'CARGO_TARGET_DIR environment change preserved predecessor namespace %s and matched clean output: ' \
    "$namespace_c"
cat "$root/c.out"
printf 'rustc version recorded above; source roots and target roots were distinct\n'
