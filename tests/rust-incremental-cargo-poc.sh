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
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        for log in "$root/a.log" "$root/b.log" "$root/clean.log"; do
            if [[ -f "$log" ]]; then
                echo "--- $(basename "$log"): relevant diagnostics ---" >&2
                rg 'sccache::compiler::compiler|restored Rust incremental|no Rust incremental|files hard-linked|completely ignoring cache|error:|Finished' "$log" | tail -30 >&2 || true
            fi
        done
    fi
    rm -rf "$root"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$root/a/src" "$root/b/src" "$root/cache" "$root/clean-cargo-home"
: > "$root/sccache.conf"
for checkout in a b; do
    cat > "$root/$checkout/Cargo.toml" <<'TOML'
[package]
name = "cargo_incremental_probe"
version = "0.1.0"
edition = "2021"
TOML
    cat > "$root/$checkout/src/lib.rs" <<'RS'
pub fn value() -> u32 { 7 }
pub fn source_path() -> &'static str { file!() }
RS
    cat > "$root/$checkout/src/main.rs" <<'RS'
fn main() {
    println!("{} {} {}", cargo_incremental_probe::value(),
        cargo_incremental_probe::source_path(), env!("CARGO_MANIFEST_DIR"));
}
RS
done
sed -i 's/value() -> u32 { 7 }/value() -> u32 { 8 }/' "$root/b/src/lib.rs"

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
    env -u RUSTC_WRAPPER CARGO_HOME="$root/clean-cargo-home" CARGO_TARGET_DIR=target-clean \
        RUSTFLAGS='-Z remap-cwd-prefix=/sccache-workspace -Z incremental-info' \
        "$cargo_bin" build -vv > "$root/clean.log" 2>&1
)
"$root/b/target-clean/debug/cargo_incremental_probe" > "$root/clean.out"
cmp "$root/restored.out" "$root/clean.out"
printf 'restored and clean Cargo outputs match: '
cat "$root/restored.out"
