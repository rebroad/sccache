#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo "This experiment currently expects Linux." >&2
    exit 2
fi

rustc_bin=${RUSTC_BIN:-rustc}
sccache_bin=${SCCACHE_BIN:-sccache}
root=$(mktemp -d /var/tmp/sccache-false-positive.XXXXXX)
root=$(cd "$root" && pwd -P)
cleanup() {
    local status=$?
    if [[ $status -ne 0 || ${SCCACHE_TEST_KEEP_TMP:-0} == 1 ]]; then
        echo "false-positive reproduction: $root" >&2
    else
        rm -rf "$root"
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$root/a/src" "$root/b/src" "$root/cache"
: > "$root/sccache.conf"
for checkout in a b; do
    cat > "$root/$checkout/src/dep.rs" <<'RS'
pub fn value() -> i32 { 1 }
RS
    cat > "$root/$checkout/src/app.rs" <<'RS'
pub fn value() -> i32 { changed_dep::value() }
pub fn stable_work_0() -> i32 { 10 }
pub fn stable_work_1() -> i32 { 11 }
pub fn stable_work_2() -> i32 { 12 }
pub fn stable_work_3() -> i32 { 13 }
pub fn stable_work_4() -> i32 { 14 }
RS
done
sed -i 's/value() -> i32 { 1 }/value() -> i32 { 2 }/' "$root/b/src/dep.rs"

export SCCACHE_CONF="$root/sccache.conf"
export SCCACHE_DIR="$root/cache"
export SCCACHE_IN_PROCESS=1
export SCCACHE_RUST_INCREMENTAL=1
export RUSTC_BOOTSTRAP=1
export SCCACHE_LOG=trace

"$rustc_bin" -Vv
for checkout in a b; do
    mkdir -p "$root/$checkout/out"
    (cd "$root/$checkout" && "$sccache_bin" "$rustc_bin" \
        --crate-name changed_dep --crate-type rlib --edition=2021 \
        --emit=link -C opt-level=0 -C metadata=stable \
        -Z remap-cwd-prefix=/sccache-false-positive \
        -Z assert-incr-state=not-loaded \
        --out-dir out src/dep.rs) 2> "$root/$checkout-dep.log"
done

(cd "$root/a" && "$sccache_bin" "$rustc_bin" \
    --crate-name false_positive_app --crate-type lib --edition=2021 \
    --emit=metadata,link -C opt-level=0 -C metadata=stable \
    -Z remap-cwd-prefix=/sccache-false-positive -Z incremental-info \
    -Z assert-incr-state=not-loaded -C incremental=incremental \
    --extern changed_dep=out/libchanged_dep.rlib --out-dir out src/app.rs) \
    2> "$root/a-app.log"

mkdir -p "$root/b/incremental" "$root/b/out"
(cd "$root/b" && "$sccache_bin" "$rustc_bin" \
    --crate-name false_positive_app --crate-type lib --edition=2021 \
    --emit=metadata,link -C opt-level=0 -C metadata=stable \
    -Z remap-cwd-prefix=/sccache-false-positive -Z incremental-info \
    -Z assert-incr-state=loaded -C incremental=incremental \
    --extern changed_dep=out/libchanged_dep.rlib --out-dir out src/app.rs) \
    2> "$root/b-app.log"

namespace_a=$(sed -n 's/.*predecessor namespace=\([0-9a-f]*\).*/\1/p' "$root/a-app.log" | tail -1)
namespace_b=$(sed -n 's/.*predecessor namespace=\([0-9a-f]*\).*/\1/p' "$root/b-app.log" | tail -1)
test -n "$namespace_a" && test "$namespace_a" = "$namespace_b"
grep -F 'restored Rust incremental snapshot' "$root/b-app.log" >/dev/null
grep -F 'assert-incr-state=loaded' "$root/b-app.log" >/dev/null

cat > "$root/b/src/main.rs" <<'RS'
fn main() { println!("{} {}", false_positive_app::value(), false_positive_app::stable_work_4()); }
RS
"$rustc_bin" "$root/b/src/main.rs" \
    --extern "false_positive_app=$root/b/out/libfalse_positive_app.rlib" \
    --extern "changed_dep=$root/b/out/libchanged_dep.rlib" \
    -L "dependency=$root/b/out" -o "$root/b/restored"
"$root/b/restored" > "$root/restored.out"
test "$(cat "$root/restored.out")" = "2 14"

mkdir -p "$root/b/clean"
(cd "$root/b" && RUSTC_WRAPPER= "$rustc_bin" \
    --crate-name false_positive_app --crate-type lib --edition=2021 \
    --emit=metadata,link -C opt-level=0 -C metadata=stable \
    -Z remap-cwd-prefix=/sccache-false-positive \
    -Z assert-incr-state=not-loaded -C incremental="$root/b/clean/incremental" \
    --extern changed_dep=out/libchanged_dep.rlib --out-dir clean src/app.rs) \
    2> "$root/clean-app.log"
"$rustc_bin" "$root/b/src/main.rs" \
    --extern "false_positive_app=$root/b/clean/libfalse_positive_app.rlib" \
    --extern "changed_dep=$root/b/out/libchanged_dep.rlib" \
    -L "dependency=$root/b/out" -o "$root/b/clean-app"
"$root/b/clean-app" > "$root/clean.out"
cmp "$root/restored.out" "$root/clean.out"

printf 'same predecessor namespace: %s\n' "$namespace_b"
grep -F 'restored Rust incremental snapshot' "$root/b-app.log" | head -1
grep -F 'session directory:' "$root/b-app.log" | head -1
printf 'changed dependency result matches clean build: '
cat "$root/restored.out"

# A source error is not evidence that the restored graph is corrupt. Record the
# current retry behavior explicitly: the cache wrapper will retry this failure.
rm -rf "$root/b/incremental"
cat > "$root/b/src/app.rs" <<'RS'
pub fn value() -> i32 { let _: u32 = "ordinary source error"; changed_dep::value() }
RS
set +e
(cd "$root/b" && "$sccache_bin" "$rustc_bin" \
    --crate-name false_positive_app --crate-type lib --edition=2021 \
    --emit=metadata,link -C opt-level=0 -C metadata=stable \
    -Z remap-cwd-prefix=/sccache-false-positive -Z incremental-info \
    -Z assert-incr-state=loaded -C incremental=incremental \
    --extern changed_dep=out/libchanged_dep.rlib --out-dir out src/app.rs) \
    2> "$root/source-error.log"
compile_status=$?
set -e
test "$compile_status" -ne 0
grep -F 'restored Rust incremental snapshot' "$root/source-error.log" >/dev/null
grep -F 'compilation failed after restoring Rust incremental state; retrying without the snapshot' \
    "$root/source-error.log" >/dev/null
compile_attempts=$(grep -c '\[false_positive_app\]: Compiling locally' "$root/source-error.log")
test "$compile_attempts" -eq 2
printf 'ordinary source error: rustc was invoked %s times (snapshot attempt plus clean retry)\n' \
    "$compile_attempts"
