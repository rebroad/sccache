#!/usr/bin/env bash
set -euo pipefail

sccache_bin=/usr/local/bin/sccache
rustc_bin=/toolchain/bin/rustc
root=/checkout-b
trap 'status=$?; if [[ "$status" -ne 0 && -f /var/tmp/consumer.log ]]; then cat /var/tmp/consumer.log >&2; fi; exit "$status"' EXIT
mkdir -p "$root" /var/tmp/sccache-b-cache
: > /var/tmp/sccache-b.conf
export SCCACHE_CONF=/var/tmp/sccache-b.conf SCCACHE_DIR=/var/tmp/sccache-b-cache
export SCCACHE_IN_PROCESS=1 SCCACHE_RUST_INCREMENTAL=1 SCCACHE_SERVER_UDS=/var/tmp/unused.sock
export CARGO_INCREMENTAL=1 RUSTC_BOOTSTRAP=1 SCCACHE_LOG=debug
expect_restore=${SCCACHE_TEST_EXPECT_RESTORE:-1}
expected_rustc_state=loaded
if [[ $expect_restore == 0 ]]; then
    expected_rustc_state=not-loaded
fi
extra_args=()
if [[ ${SCCACHE_TEST_EXTRA_CFG:-0} == 1 ]]; then
    extra_args+=(--cfg 'feature="snapshot_feature"')
fi
if [[ ${SCCACHE_TEST_EXTRA_RUSTFLAGS:-0} == 1 ]]; then
    extra_args+=(-Copt-level=1)
fi
if [[ ${SCCACHE_TEST_EXPLICIT_TARGET:-0} == 1 ]]; then
    target_triple=$("$rustc_bin" -vV | sed -n 's/^host: //p')
    extra_args+=(--target "$target_triple")
fi
target_build=0
if [[ -n ${SCCACHE_TEST_TARGET_TRIPLE:-} ]]; then
    target_build=1
    extra_args+=(--target "$SCCACHE_TEST_TARGET_TRIPLE")
fi
printf 'consumer rustc:\n'
"$rustc_bin" -Vv
for i in $(seq 0 127); do
    printf 'pub fn f%s() -> u32 { %s }\n' "$i" "$i" >> "$root/lib.rs"
done
printf 'pub fn source_path() -> &\x27static str { file!() }\n' >> "$root/lib.rs"
cat >> "$root/lib.rs" <<'RS'
#[cfg(feature = "snapshot_feature")]
pub fn feature_value() -> u32 { 1 }
#[cfg(not(feature = "snapshot_feature"))]
pub fn feature_value() -> u32 { 0 }
RS
sed -i 's/f64() -> u32 { 64 }/f64() -> u32 { 640 }/' "$root/lib.rs"
cd "$root"
input=lib.rs
if [[ ${SCCACHE_TEST_ABSOLUTE_INPUT:-0} == 1 ]]; then
    input="$root/lib.rs"
fi
mkdir -p out
"$sccache_bin" "$rustc_bin" --crate-name snapshot_poc --crate-type lib --edition=2021 \
    --emit=metadata,link -Z incremental-info -C opt-level=0 \
    -Z remap-cwd-prefix=/sccache-workspace \
    -Z "assert-incr-state=$expected_rustc_state" \
    -C incremental=incremental --out-dir out "${extra_args[@]}" "$input" 2>/var/tmp/consumer.log
if [[ $expect_restore == 1 ]]; then
    grep -F 'restored Rust incremental snapshot' /var/tmp/consumer.log
    grep -E 'session directory: [1-9][0-9]* files hard-linked' /var/tmp/consumer.log
else
    if grep -F 'restored Rust incremental snapshot' /var/tmp/consumer.log; then
        echo "unexpectedly restored a damaged Rust incremental snapshot" >&2
        exit 1
    fi
    echo "no compatible snapshot restored; rustc performed a non-restored compile"
fi

if [[ $target_build == 0 ]]; then
    cat > /var/tmp/main.rs <<'RS'
fn main() {
    assert_eq!(snapshot_poc::f64(), 640);
    assert_eq!(snapshot_poc::f127(), 127);
    println!("{}", snapshot_poc::source_path());
    println!("{}", snapshot_poc::feature_value());
}
RS
    "$rustc_bin" /var/tmp/main.rs --extern snapshot_poc=/checkout-b/out/libsnapshot_poc.rlib \
        -o /var/tmp/check
    /var/tmp/check > /var/tmp/incremental.out
fi
clean_output_dir=/var/tmp/clean
if [[ $target_build == 1 ]]; then
    cp /checkout-b/out/libsnapshot_poc.rlib /var/tmp/restored.rlib
    cp /checkout-b/out/libsnapshot_poc.rmeta /var/tmp/restored.rmeta
    rm -f /checkout-b/out/libsnapshot_poc.rlib /checkout-b/out/libsnapshot_poc.rmeta
    rm -rf /var/tmp/clean-incremental
    clean_output_dir=/checkout-b/out
fi
mkdir -p "$clean_output_dir"
"$rustc_bin" --crate-name snapshot_poc --crate-type lib --edition=2021 \
    --emit=metadata,link -Z remap-cwd-prefix=/sccache-workspace \
    -Z incremental-info -Z assert-incr-state=not-loaded -C opt-level=0 \
    -C incremental=/var/tmp/clean-incremental \
    "${extra_args[@]}" "$input" --out-dir "$clean_output_dir"
if [[ $target_build == 1 ]]; then
    cmp /var/tmp/restored.rmeta /checkout-b/out/libsnapshot_poc.rmeta
    cp /checkout-b/out/libsnapshot_poc.rlib /var/tmp/clean.rlib
    for archive in /var/tmp/restored.rlib /var/tmp/clean.rlib; do
        member=$(ar t "$archive" | grep '\.o$' | head -1)
        test -n "$member"
        label=restored
        if [[ "$archive" == /var/tmp/clean.rlib ]]; then
            label=clean
        fi
        ar p "$archive" "$member" > "/var/tmp/$label-target.o"
        readelf -h "/var/tmp/$label-target.o" | grep -F 'Intel 80386' >/dev/null
    done
    echo "target-change output matches a clean compile for $SCCACHE_TEST_TARGET_TRIPLE"
    exit 0
fi
"$rustc_bin" /var/tmp/main.rs --extern snapshot_poc=/var/tmp/clean/libsnapshot_poc.rlib \
    -o /var/tmp/clean-check
/var/tmp/clean-check > /var/tmp/clean.out
cmp /var/tmp/incremental.out /var/tmp/clean.out
printf 'cross-container file!(): '
cat /var/tmp/incremental.out
printf 'local cache size: '
du -sb "$SCCACHE_DIR" | cut -f1
