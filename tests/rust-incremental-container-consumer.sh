#!/usr/bin/env bash
set -euo pipefail

sccache_bin=/usr/local/bin/sccache
rustc_bin=/toolchain/bin/rustc
root=/checkout-b
mkdir -p "$root" /var/tmp/sccache-b-cache
: > /var/tmp/sccache-b.conf
export SCCACHE_CONF=/var/tmp/sccache-b.conf SCCACHE_DIR=/var/tmp/sccache-b-cache
export SCCACHE_IN_PROCESS=1 SCCACHE_RUST_INCREMENTAL=1 SCCACHE_SERVER_UDS=/var/tmp/unused.sock
export CARGO_INCREMENTAL=1 RUSTC_BOOTSTRAP=1 SCCACHE_LOG=debug
printf 'consumer rustc:\n'
"$rustc_bin" -Vv
for i in $(seq 0 127); do
    printf 'pub fn f%s() -> u32 { %s }\n' "$i" "$i" >> "$root/lib.rs"
done
printf 'pub fn source_path() -> &\x27static str { file!() }\n' >> "$root/lib.rs"
sed -i 's/f64() -> u32 { 64 }/f64() -> u32 { 640 }/' "$root/lib.rs"
cd "$root"
input=lib.rs
if [[ ${SCCACHE_TEST_ABSOLUTE_INPUT:-0} == 1 ]]; then
    input="$root/lib.rs"
fi
mkdir -p out
"$sccache_bin" "$rustc_bin" --crate-name snapshot_poc --crate-type lib --edition=2021 \
    --emit=metadata,link -Z incremental-info -C opt-level=0 \
    -Z remap-cwd-prefix=/sccache-workspace -Z assert-incr-state=loaded \
    -C incremental=incremental --out-dir out "$input" 2>/var/tmp/consumer.log
grep -F 'restored Rust incremental snapshot' /var/tmp/consumer.log
grep -E 'session directory: [1-9][0-9]* files hard-linked' /var/tmp/consumer.log

cat > /var/tmp/main.rs <<'RS'
fn main() {
    assert_eq!(snapshot_poc::f64(), 640);
    assert_eq!(snapshot_poc::f127(), 127);
    println!("{}", snapshot_poc::source_path());
}
RS
"$rustc_bin" /var/tmp/main.rs --extern snapshot_poc=/checkout-b/out/libsnapshot_poc.rlib \
    -o /var/tmp/check
/var/tmp/check > /var/tmp/incremental.out
mkdir -p /var/tmp/clean
"$rustc_bin" --crate-name snapshot_poc --crate-type lib --edition=2021 \
    --emit=metadata,link -Z remap-cwd-prefix=/sccache-workspace \
    "$input" --out-dir /var/tmp/clean
"$rustc_bin" /var/tmp/main.rs --extern snapshot_poc=/var/tmp/clean/libsnapshot_poc.rlib \
    -o /var/tmp/clean-check
/var/tmp/clean-check > /var/tmp/clean.out
cmp /var/tmp/incremental.out /var/tmp/clean.out
printf 'cross-container file!(): '
cat /var/tmp/incremental.out
printf 'local cache size: '
du -sb "$SCCACHE_DIR" | cut -f1
