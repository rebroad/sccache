#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo "This experiment currently expects Linux." >&2
    exit 2
fi

sccache_bin=${SCCACHE_BIN:-sccache}
root=$(mktemp -d /var/tmp/sccache-incremental-e2e.XXXXXX)
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        for log in "$root/first.log" "$root/second.log"; do
            if [[ -f "$log" ]]; then
                cat "$log" >&2
            fi
        done
    fi
    rm -rf "$root"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$root/checkout-a" "$root/cache"
: > "$root/sccache.conf"
export SCCACHE_CONF="$root/sccache.conf"
export SCCACHE_DIR="$root/cache"
export SCCACHE_SERVER_UDS="$root/unused-server.sock"
export SCCACHE_IN_PROCESS=1
export SCCACHE_RUST_INCREMENTAL=1
export CARGO_INCREMENTAL=1
export RUSTC_BOOTSTRAP=1
export SCCACHE_LOG=debug

for i in $(seq 0 127); do
    printf 'pub fn f%s() -> u32 { %s }\n' "$i" "$i" >> "$root/checkout-a/lib.rs"
done
compile_args=(rustc --crate-name snapshot_poc --crate-type lib --edition=2021
    --emit=metadata,link -Z incremental-info -C opt-level=0)

(
    cd "$root/checkout-a"
    mkdir -p out
    start_ns=$(date +%s%N)
    "$sccache_bin" "${compile_args[@]}" \
        -C incremental=incremental \
        --out-dir out lib.rs 2> "$root/first.log"
    elapsed_ns=$(($(date +%s%N) - start_ns))
    printf '%d.%03d\n' "$((elapsed_ns / 1000000000))" \
        "$(((elapsed_ns % 1000000000) / 1000000))" > "$root/first.seconds"
)

(
    cd "$root/checkout-a"
    sed -i 's/f64() -> u32 { 64 }/f64() -> u32 { 640 }/' lib.rs
    rm -rf incremental
    mkdir -p out
    start_ns=$(date +%s%N)
    "$sccache_bin" "${compile_args[@]}" \
        -C incremental=incremental \
        --out-dir out lib.rs 2> "$root/second.log"
    elapsed_ns=$(($(date +%s%N) - start_ns))
    printf '%d.%03d\n' "$((elapsed_ns / 1000000000))" \
        "$(((elapsed_ns % 1000000000) / 1000000))" > "$root/second.seconds"
)

grep -F 'restored Rust incremental snapshot' "$root/second.log" >/dev/null
grep -Eq 'session directory: [1-9][0-9]* files hard-linked' "$root/second.log"
if grep -F 'completely ignoring cache' "$root/second.log" >/dev/null; then
    echo "rustc rejected the restored incremental state" >&2
    exit 1
fi
test ! -e "$SCCACHE_SERVER_UDS"

cat > "$root/main.rs" <<'EOF'
fn main() {
    assert_eq!(snapshot_poc::f64(), 640);
    assert_eq!(snapshot_poc::f127(), 127);
}
EOF
rustc "$root/main.rs" --extern "snapshot_poc=$root/checkout-a/out/libsnapshot_poc.rlib" \
    -o "$root/checkout-a/check"
"$root/checkout-a/check"

mkdir -p "$root/clean"
rustc --crate-name snapshot_poc --crate-type lib --edition=2021 --emit=metadata,link \
    "$root/checkout-a/lib.rs" --out-dir "$root/clean"
rustc "$root/main.rs" --extern "snapshot_poc=$root/clean/libsnapshot_poc.rlib" \
    -o "$root/clean/check"
"$root/clean/check"

printf 'first miss compile seconds: '
cat "$root/first.seconds"
printf 'restored incremental compile seconds: '
cat "$root/second.seconds"
printf 'raw incremental snapshot bytes: '
du -sb "$root/checkout-a/incremental" | cut -f1
printf 'compressed cache directory bytes: '
du -sb "$SCCACHE_DIR" | cut -f1
printf 'rustc reuse evidence: '
grep -E 'restored Rust incremental snapshot|session directory: [1-9][0-9]* files hard-linked' \
    "$root/second.log" | tr '\n' ' '
printf '\n'
