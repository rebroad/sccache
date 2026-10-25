#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo "This experiment currently expects Linux." >&2
    exit 2
fi

cargo_bin=${CARGO_BIN:-cargo}
rustc_bin=${RUSTC_BIN:-rustc}
sccache_bin=${SCCACHE_BIN:-sccache}
root=$(mktemp -d /var/tmp/sccache-cargo-incremental.XXXXXX)
root=$(cd "$root" && pwd -P)
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        for log in "$root/a.log" "$root/b.log" "$root/clean.log"; do
            if [[ -f "$log" ]]; then
                echo "--- $(basename "$log"): relevant diagnostics ---" >&2
                rg 'restored Rust incremental|no Rust incremental|keeping existing local Rust incremental|files hard-linked|completely ignoring cache|error:|Finished' "$log" >&2 || true
            fi
        done
    fi
    if [[ "${SCCACHE_TEST_KEEP_TMP:-0}" == 1 && "$status" -ne 0 ]]; then
        echo "kept probe workspace at $root" >&2
        exit "$status"
    fi
    rm -rf "$root"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$root/a/src" "$root/b/src" \
    "$root/a/vendor/probe_dependency/src" "$root/b/vendor/probe_dependency/src" \
    "$root/cache" "$root/clean-cargo-home"
: > "$root/sccache.conf"
for checkout in a b; do
    cat > "$root/$checkout/Cargo.toml" <<'TOML'
[package]
name = "cargo_incremental_probe"
version = "0.1.0"
edition = "2021"

[dependencies]
probe_dependency = { path = "vendor/probe_dependency" }
TOML
    cat > "$root/$checkout/vendor/probe_dependency/Cargo.toml" <<'TOML'
[package]
name = "probe_dependency"
version = "0.1.0"
edition = "2021"
TOML
    cat > "$root/$checkout/vendor/probe_dependency/src/lib.rs" <<'RS'
pub fn value() -> u32 { 11 }
RS
    cat > "$root/$checkout/src/lib.rs" <<'RS'
include!(concat!(env!("OUT_DIR"), "/generated.rs"));
mod component;
pub fn value() -> u32 { component::value() + probe_dependency::value() }
pub fn source_path() -> &'static str { file!() }
pub fn module_source_path() -> &'static str { component::source_path() }
pub fn build_output_dir() -> &'static str { env!("PROBE_BUILD_OUT") }
RS
    cat > "$root/$checkout/src/component.rs" <<'RS'
pub fn value() -> u32 { 7 }
pub fn source_path() -> &'static str { file!() }
RS
    cat > "$root/$checkout/src/main.rs" <<'RS'
fn main() {
    println!("{} {} {} {}", cargo_incremental_probe::value(),
        cargo_incremental_probe::source_path(), cargo_incremental_probe::module_source_path(),
        cargo_incremental_probe::generated_source_path());
    println!("{} {}", cargo_incremental_probe::build_output_dir(),
        env!("CARGO_MANIFEST_DIR"));
}
RS
    cat > "$root/$checkout/build.rs" <<'RS'
fn main() {
    let out_dir = std::env::var_os("OUT_DIR").unwrap();
    std::fs::write(
        std::path::Path::new(&out_dir).join("generated.rs"),
        "pub fn generated_source_path() -> &'static str { file!() }\n",
    )
    .unwrap();
    println!("cargo:rustc-env=PROBE_BUILD_OUT={}", out_dir.to_string_lossy());
}
RS
done
sed -i 's/value() -> u32 { 7 }/value() -> u32 { 8 }/' "$root/b/src/component.rs"

printf 'rustc version:\n'
"$rustc_bin" -Vv
printf 'platform: '
uname -a

export SCCACHE_CONF="$root/sccache.conf"
export SCCACHE_DIR="$root/cache"
export SCCACHE_IN_PROCESS=1
export SCCACHE_RUST_INCREMENTAL=1
export CARGO_INCREMENTAL=1
export RUSTC_BOOTSTRAP=1
export RUSTC_WRAPPER="$sccache_bin"
export RUSTC="$rustc_bin"
export SCCACHE_LOG=debug

(
    cd "$root/a"
    CARGO_TARGET_DIR=target RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info' \
        "$cargo_bin" build -vv > "$root/a.log" 2>&1
)
(
    cd "$root/b"
    CARGO_TARGET_DIR=target RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info' \
        "$cargo_bin" build -vv > "$root/b.log" 2>&1
)

grep -F 'restored Rust incremental snapshot' "$root/b.log" >/dev/null
grep -Eq 'session directory: [1-9][0-9]* files hard-linked' "$root/b.log"
if grep -F 'completely ignoring cache' "$root/b.log" >/dev/null; then
    echo "rustc rejected the Cargo cross-checkout incremental state" >&2
    exit 1
fi
printf 'Cargo snapshot restore: '
grep -F 'restored Rust incremental snapshot' "$root/b.log" | head -1
printf 'rustc reused work products: '
grep -E 'session directory: [1-9][0-9]* files hard-linked' "$root/b.log" | head -1

"$root/b/target/debug/cargo_incremental_probe" > "$root/restored.out"
(
    cd "$root/b"
    "$cargo_bin" clean > /dev/null
    env -u RUSTC_WRAPPER CARGO_HOME="$root/clean-cargo-home" CARGO_TARGET_DIR=target \
        RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info' \
        "$cargo_bin" build -vv > "$root/clean.log" 2>&1
)
"$root/b/target/debug/cargo_incremental_probe" > "$root/clean.out"
cmp "$root/restored.out" "$root/clean.out"
grep -F "$root/b/" "$root/restored.out" >/dev/null
if grep -F "$root/a/" "$root/restored.out" >/dev/null; then
    echo "restored build output leaked checkout A paths" >&2
    exit 1
fi
printf 'restored and clean Cargo outputs match: '
cat "$root/restored.out"

# Change a path dependency after the cross-checkout proof. The old predecessor
# must not be restored under the changed dependency identity.
sed -i 's/value() -> u32 { 11 }/value() -> u32 { 12 }/' \
    "$root/b/vendor/probe_dependency/src/lib.rs"
(
    cd "$root/b"
    CARGO_TARGET_DIR=target RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info' \
        "$cargo_bin" build -vv > "$root/dependency-change.log" 2>&1
)
if grep -F 'restored Rust incremental snapshot' "$root/dependency-change.log" >/dev/null; then
    echo "restored a predecessor after the path dependency changed" >&2
    exit 1
fi
"$root/b/target/debug/cargo_incremental_probe" > "$root/dependency-change.out"
(
    cd "$root/b"
    "$cargo_bin" clean > /dev/null
    env -u RUSTC_WRAPPER CARGO_HOME="$root/clean-cargo-home" CARGO_TARGET_DIR=target \
        RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info' \
        "$cargo_bin" build -vv > "$root/dependency-clean.log" 2>&1
)
"$root/b/target/debug/cargo_incremental_probe" > "$root/dependency-clean.out"
cmp "$root/dependency-change.out" "$root/dependency-clean.out"
grep -q '^20 ' "$root/dependency-change.out"
printf 'changed path dependency correctly falls back and matches a clean build: '
head -1 "$root/dependency-change.out"
