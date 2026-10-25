#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo "This experiment currently expects Linux." >&2
    exit 2
fi

root=$(mktemp -d /var/tmp/sccache-rust-incremental.XXXXXX)
trap 'rm -rf "$root"' EXIT

checkout_a="$root/checkout-a"
checkout_b="$root/checkout-b"
mkdir -p "$checkout_a" "$checkout_b"

source="$checkout_a/lib.rs"
for i in $(seq 0 127); do
    printf 'pub fn f%s() -> u32 { %s }\n' "$i" "$i" >> "$source"
done

rustc_args=(--crate-name snapshot_poc --crate-type lib --edition=2021 --emit=metadata,link)
RUSTC_BOOTSTRAP=1 rustc "${rustc_args[@]}" \
    -C incremental="$checkout_a/incremental" \
    "$source" -o "$checkout_a/libsnapshot_poc.rlib"

cp "$source" "$checkout_b/lib.rs"
mkdir -p "$checkout_b/incremental"
cp -a "$checkout_a/incremental/snapshot_poc-"* "$checkout_b/incremental/"
sed -i 's/f64() -> u32 { 64 }/f64() -> u32 { 640 }/' "$checkout_b/lib.rs"

RUSTC_BOOTSTRAP=1 rustc "${rustc_args[@]}" \
    -C incremental="$checkout_b/incremental" \
    -Z assert-incr-state=loaded -Z incremental-info \
    "$checkout_b/lib.rs" -o "$checkout_b/libsnapshot_poc.rlib" \
    2> "$checkout_b/incremental.log"

grep -Eq 'session directory: [1-9][0-9]* files hard-linked' "$checkout_b/incremental.log"

cat > "$root/main.rs" <<'EOF'
fn main() {
    assert_eq!(snapshot_poc::f64(), 640);
    assert_eq!(snapshot_poc::f127(), 127);
}
EOF
rustc "$root/main.rs" --extern "snapshot_poc=$checkout_b/libsnapshot_poc.rlib" \
    -o "$checkout_b/check"
"$checkout_b/check"

mkdir -p "$root/clean"
rustc "${rustc_args[@]}" "$checkout_b/lib.rs" -o "$root/clean/libsnapshot_poc.rlib"
rustc "$root/main.rs" --extern "snapshot_poc=$root/clean/libsnapshot_poc.rlib" \
    -o "$root/clean/check"
"$root/clean/check"

archive="$root/snapshot.tar.zst"
tar -C "$checkout_a/incremental" -cf - . | zstd -q -o "$archive"
printf 'incremental snapshot bytes: '
du -sb "$checkout_a/incremental" | cut -f1
printf 'compressed snapshot bytes: '
stat -c %s "$archive"
printf 'rustc reuse evidence: '
grep -E 'assert-incr-state|session directory: [1-9][0-9]* files hard-linked' \
    "$checkout_b/incremental.log" | tr '\n' ' '
printf '\n'
