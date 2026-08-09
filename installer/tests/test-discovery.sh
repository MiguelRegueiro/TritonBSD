#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LIB=$ROOT/lib/discover.sh
FIX=$ROOT/fixtures/freebsd-live
TMP=${TMPDIR:-/tmp}/triton-discovery-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
field() { awk -F '\t' -v d="$2" -v n="$3" 'NR==1 { for(i=1;i<=NF;i++) h[$i]=i } $1==d { print $h[n] }' "$1"; }
run_parse() {
	out=$TMP/$1.tsv
	diag=$TMP/$1.err
	discover_parse "$FIX/$1" "$out" 2>"$diag"
	printf '%s\n' "$out"
}

[ -r "$LIB" ] || fail 'library exists'
# shellcheck source=/dev/null
. "$LIB"

out=$(run_parse gpt)
[ "$(field "$out" nda0 available)" = yes ] || fail 'GPT target available'
[ "$(field "$out" nda0 partitions)" = 'nda0p1:efi,nda0p2:freebsd-zfs' ] || fail 'GPT partitions normalized'
[ "$(field "$out" nda0 bytes)" = 1000204886016 ] || fail 'exact disk bytes'
[ "$(field "$out" nda0 transport)" = nvme ] || fail 'proven transport retained'
pass 'GPT disk normalization'

out=$(run_parse nested-live)
[ "$(field "$out" da0 live_parent)" = yes ] || fail 'nested live parent detected'
[ "$(field "$out" da0 available)" = no ] || fail 'live USB blocked'
[ "$(field "$out" nda0 available)" = yes ] || fail 'other target remains available'
pass 'recursive MBR/BSD live-media mapping'

out=$(run_parse aliases)
[ "$(field "$out" ada0 mounted)" = yes ] || fail 'label mount resolved'
[ "$(field "$out" ada0 available)" = no ] || fail 'mounted label disk blocked'
[ "$(field "$out" nda0 available)" = yes ] || fail 'unmounted alias disk available'
pass 'glabel and diskid aliases'

out=$(run_parse mounted)
[ "$(field "$out" ada1 mounted)" = yes ] || fail 'non-root mount detected'
[ "$(field "$out" ada1 live_parent)" = no ] || fail 'non-root is not live parent'
[ "$(field "$out" ada1 reason)" = mounted ] || fail 'mounted reason'
pass 'mounted non-root disk blocked'

out=$(run_parse missing-serial)
[ "$(field "$out" ada2 ident)" = '' ] || fail 'missing serial stays empty'
[ "$(field "$out" ada2 available)" = no ] || fail 'missing serial blocked'
[ "$(field "$out" ada2 reason)" = missing-identity ] || fail 'missing identity reason'
pass 'missing serial fails closed'

out=$(run_parse missing-model)
[ "$(field "$out" nda0 descr)" = '' ] || fail 'null model normalized to empty'
[ "$(field "$out" nda0 reason)" = missing-model ] || fail 'missing model reason'
pass 'missing model fails closed'

out=$(run_parse active-swap)
[ "$(field "$out" nda0 swap_active)" = yes ] || fail 'active swap parent detected'
[ "$(field "$out" nda0 reason)" = active-swap ] || fail 'active swap reason'
pass 'active swap disk blocked'

out=$(run_parse probe-failed)
[ "$(field "$out" nda0 available)" = no ] || fail 'required probe failure blocks target'
[ "$(field "$out" nda0 reason)" = discovery-unresolved ] || fail 'probe failure reason'
pass 'required probe failure fails closed'

out=$(run_parse ambiguous)
[ "$(field "$out" ada0 available)" = no ] || fail 'ambiguous mapping blocks ada0'
[ "$(field "$out" ada1 available)" = no ] || fail 'ambiguous mapping blocks ada1'
[ "$(field "$out" ada0 reason)" = discovery-ambiguous ] || fail 'ambiguous reason'
pass 'duplicate provider fails closed globally'

out=$(run_parse unresolved)
[ "$(field "$out" nda0 available)" = no ] || fail 'unresolved mount blocks target'
[ "$(field "$out" nda0 reason)" = discovery-unresolved ] || fail 'unresolved reason'
pass 'unresolved mount fails closed globally'

base=$(run_parse drift-before)
after=$(run_parse drift-after)
if discover_verify_identity "$base" "$after" 2>"$TMP/drift.err"; then
	fail 'identity drift accepted'
fi
grep -q 'identity drift' "$TMP/drift.err" || fail 'identity drift diagnostic'
discover_verify_identity "$base" "$base" || fail 'stable identity rejected'
pass 'identity drift rejected'

# Collection must use only read-only probes and tolerate camcontrol denial.
FAKE=$TMP/fakebin
COL=$TMP/collected
LOG=$TMP/commands
mkdir -p "$FAKE"
for cmd in sysctl mount swapinfo glabel geom gpart camcontrol; do
	cat >"$FAKE/$cmd" <<'EOF'
#!/bin/sh
printf '%s\n' "$(basename "$0") $*" >>"$DISCOVER_TEST_LOG"
case "$(basename "$0")" in
  camcontrol) echo 'permission denied' >&2; exit 1 ;;
  sysctl) echo nda0 ;;
  mount) echo '/dev/ufs/Live / ufs ro 1 1' ;;
  swapinfo) echo 'Device 1K-blocks Used Avail Capacity' ;;
  *) : ;;
esac
EOF
	chmod +x "$FAKE/$cmd"
done
DISCOVER_TEST_LOG=$LOG PATH=$FAKE:/bin:/usr/bin export DISCOVER_TEST_LOG PATH
discover_collect "$COL"
[ -f "$COL/camcontrol.devlist.err" ] || fail 'camcontrol denial captured'
[ "$(sed -n '1p' "$LOG")" = 'sysctl -n kern.disks' ] || fail 'unexpected first probe'
if grep -E '(^| )(destroy|delete|add|create|recover|commit|write|mount |umount|sudo|doas)( |$)' "$LOG" >/dev/null; then
	fail 'mutating or privileged command collected'
fi
pass 'collection is read-only and camcontrol is optional'

mkdir "$TMP/real-collection"
ln -s "$TMP/real-collection" "$TMP/linked-collection"
if discover_collect "$TMP/linked-collection"; then
	fail 'symlink collection directory accepted'
fi
pass 'collection refuses symlink and stale directories'

printf '1..13\n'
