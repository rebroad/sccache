#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo "This experiment currently expects Linux." >&2
    exit 2
fi

sccache_bin=${SCCACHE_BIN:-sccache}
rustc_bin=${RUSTC_BIN:-rustc}
root=$(mktemp -d /var/tmp/sccache-incremental-e2e.XXXXXX)
cleanup() {
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        for log in "$root/first.log" "$root/same-checkout.log" "$root/second.log" \
            "$root/concurrent-a.log" "$root/concurrent-b.log" "$root/concurrent-reader.log"; do
            if [[ -f "$log" ]]; then
                echo "--- $(basename "$log"): relevant diagnostics ---" >&2
                rg 'restored Rust incremental|retrying without|asserted that the incremental cache|hard-linked|completely ignoring cache|error:|CompileFailed' "$log" >&2 || true
            fi
        done
    fi
    if [[ "${SCCACHE_TEST_KEEP_TMP:-0}" == 1 && "$status" -ne 0 ]]; then
        echo "kept incremental probe workspace at $root" >&2
        exit "$status"
    fi
    rm -rf "$root"
    exit "$status"
}
trap cleanup EXIT

if [[ ${SCCACHE_TEST_RUSTC_REJECT_RESTORED:-0} == 1 ]]; then
    cat > "$root/rustc-capture-rejection" <<SH
#!/usr/bin/env bash
args=" \$* "
if [[ "\$args" == *assert-incr-state=not-loaded* && "\$args" == *incremental=incremental* ]]; then
    stderr_file="$root/rustc.stderr.\$\$"
    "$rustc_bin" "\$@" 2>"\$stderr_file"
    status=\$?
    cat "\$stderr_file" >> "$root/rejected-rustc.stderr"
    cat "\$stderr_file" >&2
    rm -f "\$stderr_file"
    exit "\$status"
fi
exec "$rustc_bin" "\$@"
SH
    chmod +x "$root/rustc-capture-rejection"
    rustc_bin="$root/rustc-capture-rejection"
fi

source_arg() {
    local checkout=$1
    if [[ ${SCCACHE_TEST_ABSOLUTE_INPUT:-0} == 1 ]]; then
        printf '%s' "$root/$checkout/lib.rs"
    else
        printf 'lib.rs'
    fi
}

printf 'rustc version:\n'
"$rustc_bin" -Vv
printf 'platform: '
uname -a

mkdir -p "$root/checkout-a" "$root/checkout-b" "$root/cache"
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
printf 'pub fn source_path() -> &\x27static str { file!() }\n' >> "$root/checkout-a/lib.rs"
cat >> "$root/checkout-a/lib.rs" <<'RS'
#[cfg(feature = "snapshot_feature")]
pub fn feature_value() -> u32 { 1 }
#[cfg(not(feature = "snapshot_feature"))]
pub fn feature_value() -> u32 { 0 }
RS
cp "$root/checkout-a/lib.rs" "$root/checkout-b/lib.rs"
compile_args=("$rustc_bin" --crate-name snapshot_poc --crate-type lib --edition=2021
    --emit=metadata,link -Z incremental-info -C opt-level=0
    -Z remap-cwd-prefix=/sccache-workspace)

(
    cd "$root/checkout-a"
    mkdir -p out
    start_ns=$(date +%s%N)
    "$sccache_bin" "${compile_args[@]}" \
        -Z assert-incr-state=not-loaded -C incremental=incremental \
        --out-dir out "$(source_arg checkout-a)" 2> "$root/first.log"
    elapsed_ns=$(($(date +%s%N) - start_ns))
    printf '%d.%03d\n' "$((elapsed_ns / 1000000000))" \
        "$(((elapsed_ns % 1000000000) / 1000000))" > "$root/first.seconds"
)

(
    cd "$root/checkout-a"
    sed -i 's/f1() -> u32 { 1 }/f1() -> u32 { 10 }/' lib.rs
    rm -rf incremental
    mkdir -p out
    start_ns=$(date +%s%N)
    "$sccache_bin" "${compile_args[@]}" \
        -Z assert-incr-state=loaded -C incremental=incremental \
        --out-dir out "$(source_arg checkout-a)" 2> "$root/same-checkout.log"
    elapsed_ns=$(($(date +%s%N) - start_ns))
    printf '%d.%03d\n' "$((elapsed_ns / 1000000000))" \
        "$(((elapsed_ns % 1000000000) / 1000000))" > "$root/same-checkout.seconds"
)

grep -F 'restored Rust incremental snapshot' "$root/same-checkout.log" >/dev/null
grep -Eq 'session directory: [1-9][0-9]* files hard-linked' "$root/same-checkout.log"
if grep -F 'completely ignoring cache' "$root/same-checkout.log" >/dev/null; then
    echo "rustc rejected the restored incremental state" >&2
    exit 1
fi

(
    cd "$root/checkout-b"
    sed -i 's/f64() -> u32 { 64 }/f64() -> u32 { 640 }/' lib.rs
    rm -rf incremental
    mkdir -p out
    second_assert_state=loaded
    if [[ ${SCCACHE_TEST_RUSTC_REJECT_RESTORED:-0} == 1 ]]; then
        second_assert_state=not-loaded
    fi
    start_ns=$(date +%s%N)
    "$sccache_bin" "${compile_args[@]}" \
        -Z "assert-incr-state=$second_assert_state" -C incremental=incremental \
        --out-dir out "$(source_arg checkout-b)" 2> "$root/second.log"
    elapsed_ns=$(($(date +%s%N) - start_ns))
    printf '%d.%03d\n' "$((elapsed_ns / 1000000000))" \
        "$(((elapsed_ns % 1000000000) / 1000000))" > "$root/second.seconds"
)

grep -F 'restored Rust incremental snapshot' "$root/second.log" >/dev/null
if [[ ${SCCACHE_TEST_RUSTC_REJECT_RESTORED:-0} == 1 ]]; then
    grep -F 'compilation failed after restoring Rust incremental state; retrying without the snapshot' \
        "$root/second.log" >/dev/null
    grep -F 'asserted that the incremental cache should not be loaded, but it was loaded' \
        "$root/rejected-rustc.stderr" >/dev/null
    grep -Eq 'session directory: [1-9][0-9]* files hard-linked' "$root/rejected-rustc.stderr"
    echo "rustc rejected the restored state; sccache retried clean and matched a clean build"
else
    grep -Eq 'session directory: [1-9][0-9]* files hard-linked' "$root/second.log"
fi
if grep -F 'completely ignoring cache' "$root/second.log" >/dev/null; then
    echo "rustc rejected the cross-checkout incremental state" >&2
    exit 1
fi
test ! -e "$SCCACHE_SERVER_UDS"

cat > "$root/main.rs" <<EOF
fn main() {
    assert_eq!(snapshot_poc::f64(), 640);
    assert_eq!(snapshot_poc::f1(), 1);
    assert_eq!(snapshot_poc::f127(), 127);
    println!("{}", snapshot_poc::source_path());
}
EOF
RUSTC_BOOTSTRAP=1 "$rustc_bin" "$root/main.rs" --extern "snapshot_poc=$root/checkout-b/out/libsnapshot_poc.rlib" \
    -o "$root/checkout-a/check"
"$root/checkout-a/check" > "$root/incremental-program.out"

mkdir -p "$root/clean"
(
    cd "$root/checkout-b"
    RUSTC_BOOTSTRAP=1 "$rustc_bin" --crate-name snapshot_poc --crate-type lib --edition=2021 \
        --emit=metadata,link -Z remap-cwd-prefix=/sccache-workspace \
        "$(source_arg checkout-b)" --out-dir "$root/clean"
)
RUSTC_BOOTSTRAP=1 "$rustc_bin" "$root/main.rs" --extern "snapshot_poc=$root/clean/libsnapshot_poc.rlib" \
    -o "$root/clean/check"
"$root/clean/check" > "$root/clean-program.out"
printf 'incremental file! value: '
cat "$root/incremental-program.out"
printf 'clean file! value: '
cat "$root/clean-program.out"
cmp "$root/incremental-program.out" "$root/clean-program.out"
printf 'file!() runtime value: '
cat "$root/incremental-program.out"

# Publish from two independent compiler processes into the same compatibility
# namespace. Their checkout and incremental directories are private.
for builder in concurrent-a concurrent-b concurrent-reader; do
    mkdir -p "$root/$builder"
    cp "$root/checkout-b/lib.rs" "$root/$builder/lib.rs"
done
sed -i 's/f2() -> u32 { 2 }/f2() -> u32 { 20 }/' "$root/concurrent-a/lib.rs"
sed -i 's/f3() -> u32 { 3 }/f3() -> u32 { 30 }/' "$root/concurrent-b/lib.rs"
sed -i 's/f4() -> u32 { 4 }/f4() -> u32 { 40 }/' "$root/concurrent-reader/lib.rs"

for builder in concurrent-a concurrent-b; do
    (
        cd "$root/$builder"
        mkdir -p out
        "$sccache_bin" "${compile_args[@]}" \
            -Z assert-incr-state=not-loaded -C incremental=incremental \
            --out-dir out "$(source_arg "$builder")" 2> "$root/$builder.log"
    ) &
done
wait

(
    cd "$root/concurrent-reader"
    mkdir -p out
    "$sccache_bin" "${compile_args[@]}" \
        -Z assert-incr-state=loaded -C incremental=incremental \
        --out-dir out "$(source_arg concurrent-reader)" 2> "$root/concurrent-reader.log"
)
grep -F 'restored Rust incremental snapshot' "$root/concurrent-reader.log" >/dev/null
grep -Eq 'session directory: [1-9][0-9]* files hard-linked' "$root/concurrent-reader.log"
if grep -F 'completely ignoring cache' "$root/concurrent-reader.log" >/dev/null; then
    echo "rustc rejected snapshots published by concurrent builders" >&2
    exit 1
fi

printf 'first miss compile seconds: '
cat "$root/first.seconds"
printf 'restored incremental compile seconds: '
cat "$root/second.seconds"
printf 'same-checkout restored compile seconds: '
cat "$root/same-checkout.seconds"
printf 'raw incremental snapshot bytes: '
du -sb "$root/checkout-b/incremental" | cut -f1
printf 'compressed cache directory bytes: '
du -sb "$SCCACHE_DIR" | cut -f1
printf 'rustc reuse evidence: '
for log in "$root/same-checkout.log" "$root/second.log" "$root/concurrent-reader.log"; do
    grep -E 'restored Rust incremental snapshot|session directory: [1-9][0-9]* files hard-linked' \
        "$log" | tr '\n' ' '
done
printf '\n'
