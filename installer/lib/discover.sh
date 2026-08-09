#!/bin/sh
# Read-only FreeBSD disk discovery for the Triton installer prototype.
# This file is a library.  It never performs a mutating or privileged probe.

# Capture one probe with a machine-readable success marker.
discover_probe() {
	dpb_dir=$1
	dpb_name=$2
	dpb_required=$3
	shift 3
	if "$@" >"$dpb_dir/$dpb_name" 2>"$dpb_dir/$dpb_name.err"; then
		printf '%s=ok\n' "$dpb_name" >>"$dpb_dir/collection.status"
		return 0
	fi
	printf '%s=failed\n' "$dpb_name" >>"$dpb_dir/collection.status"
	[ "$dpb_required" = optional ]
}

# Collect command output without interpreting it. The directory must not exist:
# refusing reuse prevents symlink substitution and stale mixed snapshots.
discover_collect() {
	dc_dir=$1
	[ ! -e "$dc_dir" ] && [ ! -L "$dc_dir" ] || return 1
	(umask 077 && mkdir -m 700 "$dc_dir") || return 1
	: >"$dc_dir/collection.status" || return 1
	dc_failed=0

	discover_probe "$dc_dir" kern.disks required sysctl -n kern.disks || dc_failed=1
	discover_probe "$dc_dir" mount.p required mount -p || dc_failed=1
	discover_probe "$dc_dir" swapinfo.k required swapinfo -k || dc_failed=1
	discover_probe "$dc_dir" glabel.status required glabel status || dc_failed=1
	discover_probe "$dc_dir" geom.disk.list required geom disk list || dc_failed=1
	discover_probe "$dc_dir" geom.part.list required geom part list || dc_failed=1
	discover_probe "$dc_dir" gpart.show.p optional gpart show -p || :
	discover_probe "$dc_dir" camcontrol.devlist optional camcontrol devlist || :

	chmod 600 "$dc_dir"/* 2>/dev/null || :
	[ "$dc_failed" -eq 0 ]
}

# Parse a collected directory into a deterministic, non-executable TSV.
# A mapping error for any mounted device blocks every target (fail closed).
discover_parse() {
	dp_dir=$1
	dp_out=$2
	dp_tmp=$dp_out.tmp.$$
	dp_missing=0
	for dp_file in collection.status kern.disks mount.p swapinfo.k glabel.status geom.disk.list geom.part.list; do
		[ -r "$dp_dir/$dp_file" ] || dp_missing=1
	done
	[ -r "$dp_dir/kern.disks" ] || return 1
	if [ -r "$dp_dir/collection.status" ]; then
		for dp_probe in kern.disks mount.p swapinfo.k glabel.status geom.disk.list geom.part.list; do
			grep -qx "$dp_probe=ok" "$dp_dir/collection.status" || dp_missing=1
		done
	fi

	umask 077
	awk -v K="$dp_dir/kern.disks" \
		-v M="$dp_dir/mount.p" \
		-v S="$dp_dir/swapinfo.k" \
		-v L="$dp_dir/glabel.status" \
		-v D="$dp_dir/geom.disk.list" \
		-v P="$dp_dir/geom.part.list" \
		-v missing="$dp_missing" '
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function clean(s) { gsub(/[\t\r\n]/, " ", s); return trim(s) }
function add_edge(child, parent, k) {
    child=clean(child); parent=clean(parent)
    if (child=="" || parent=="") return
    k=child SUBSEP parent
    if (!edge_seen[k]++) edge[child, ++edge_n[child]]=parent
}
function save_part(    k) {
    if (part_name=="" || geom_name=="") return
    add_edge(part_name, geom_name)
    k=part_name SUBSEP geom_name
    if (!part_seen[k]++) {
        part_order[++npart]=part_name
        part_parent[npart]=geom_name
        part_type[npart]=(part_kind=="" ? "unknown" : clean(part_kind))
    }
    part_name=""; part_kind=""
}
function roots_reset(    x) { for (x in roots) delete roots[x]; root_n=0; cycle=0 }
function walk(node, depth,    i,p) {
    if (depth>64 || visiting[node]) { cycle=1; return }
    if (physical[node]) { if (!roots[node]++) root_n++; return }
    if (edge_n[node]==0) return
    visiting[node]=1
    for (i=1; i<=edge_n[node]; i++) { p=edge[node,i]; walk(p,depth+1) }
    delete visiting[node]
}
function resolve(node) { roots_reset(); walk(node,0); return (cycle ? -1 : root_n) }
function add_partition(d, text,    k) {
    k=d SUBSEP text
    if (partition_added[k]++) return
    partitions[d]=(partitions[d]=="" ? text : partitions[d] "," text)
}
FILENAME==K {
    for (i=1;i<=NF;i++) if ($i!="" && !physical[$i]++) disks[++ndisk]=$i
    next
}
FILENAME==M {
    if (NF>=2) { mount_src[++nmount]=$1; mount_at[nmount]=$2 }
    next
}
FILENAME==S {
    if ($1=="Device" || $1=="") next
    swap_src[++nswap]=$1
    next
}
FILENAME==L {
    if (NF<3 || $1=="Name") next
    add_edge($1,$NF)
    next
}
FILENAME==D {
    if ($0 ~ /^Geom name:/) { disk_cur=trim(substr($0,index($0,":")+1)); next }
    if (disk_cur=="") next
    line=trim($0)
    if (line ~ /^Mediasize:/ && disk_bytes[disk_cur]=="") { sub(/^Mediasize:[[:space:]]*/,"",line); sub(/[[:space:](].*$/, "", line); disk_bytes[disk_cur]=line }
    else if (line ~ /^Sectorsize:/ && disk_sector[disk_cur]=="") { sub(/^Sectorsize:[[:space:]]*/,"",line); disk_sector[disk_cur]=line+0 }
    else if (line ~ /^descr:/) { sub(/^descr:[[:space:]]*/,"",line); line=clean(line); if (line=="<null>") line=""; disk_descr[disk_cur]=line }
    else if (line ~ /^ident:/) { sub(/^ident:[[:space:]]*/,"",line); line=clean(line); if (line=="<null>") line=""; disk_ident[disk_cur]=line }
    else if (line ~ /^(transport|protocol):/) { sub(/^[^:]*:[[:space:]]*/,"",line); line=tolower(clean(line)); if (line=="<null>") line=""; disk_transport[disk_cur]=line }
    next
}
FILENAME==P {
    if ($0 ~ /^Geom name:/) { save_part(); geom_name=trim(substr($0,index($0,":")+1)); in_providers=0; next }
    if ($0 ~ /^Providers:/) { save_part(); in_providers=1; next }
    if ($0 ~ /^Consumers:/) { save_part(); in_providers=0; next }
    if (in_providers && $0 ~ /^[[:space:]]*[0-9]+\. Name:/) {
        save_part(); line=$0; sub(/^[^:]*:[[:space:]]*/,"",line); part_name=clean(line); next
    }
    if (in_providers && part_name!="") {
        line=trim($0)
        if (line ~ /^type:/) { sub(/^type:[[:space:]]*/,"",line); part_kind=clean(line) }
    }
    next
}
END {
    save_part()
    global_bad=(missing ? "unresolved" : "")
    root_seen=0
    for (i=1;i<=nmount;i++) {
        src=mount_src[i]; at=mount_at[i]
        if (at=="/") root_seen=1
        if (src ~ /^\/dev\//) {
            sub(/^\/dev\//,"",src)
            n=resolve(src)
            if (n!=1) { global_bad=(n<0 || n>1 ? "ambiguous" : "unresolved"); continue }
            for (d in roots) if (roots[d]) { mounted[d]=1; if (at=="/") live[d]=1 }
        } else if (at=="/") global_bad="unresolved"
    }
    if (!root_seen) global_bad="unresolved"

    for (i=1;i<=nswap;i++) {
        src=swap_src[i]
        if (src ~ /^\/dev\//) {
            sub(/^\/dev\//,"",src)
            n=resolve(src)
            if (n!=1) { global_bad=(n<0 || n>1 ? "ambiguous" : "unresolved"); continue }
            for (d in roots) if (roots[d]) swap_active[d]=1
        } else global_bad="unresolved"
    }

    for (i=1;i<=npart;i++) {
        n=resolve(part_order[i])
        if (n==1) for (d in roots) if (roots[d]) add_partition(d,clean(part_order[i]) ":" clean(part_type[i]))
    }

    print "device\tpath\tdescr\tident\tbytes\tsector_size\ttransport\tpartitions\tmounted\tswap_active\tlive_parent\tavailable\treason"
    for (i=1;i<=ndisk;i++) {
        d=disks[i]
        reason=""; avail="yes"
        if (global_bad!="") { avail="no"; reason="discovery-" global_bad }
        else if (live[d]) { avail="no"; reason="live-media" }
        else if (mounted[d]) { avail="no"; reason="mounted" }
        else if (swap_active[d]) { avail="no"; reason="active-swap" }
        else if (disk_descr[d]=="") { avail="no"; reason="missing-model" }
        else if (disk_ident[d]=="") { avail="no"; reason="missing-identity" }
        else if (disk_bytes[d]=="" || disk_sector[d]=="") { avail="no"; reason="missing-metadata" }
        printf "%s\t/dev/%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            clean(d),clean(d),clean(disk_descr[d]),clean(disk_ident[d]),clean(disk_bytes[d]),clean(disk_sector[d]), \
            clean(disk_transport[d]),clean(partitions[d]),(mounted[d]?"yes":"no"),(swap_active[d]?"yes":"no"),(live[d]?"yes":"no"),avail,reason
    }
}' "$dp_dir/kern.disks" "$dp_dir/mount.p" "$dp_dir/swapinfo.k" "$dp_dir/glabel.status" \
		"$dp_dir/geom.disk.list" "$dp_dir/geom.part.list" >"$dp_tmp" || {
		rm -f "$dp_tmp"
		return 1
	}

	chmod 600 "$dp_tmp" 2>/dev/null || :
	mv "$dp_tmp" "$dp_out"
}

# Revalidation is deliberately strict: any topology, identity, mount, metadata,
# or availability change invalidates the snapshot selected by the UI.
discover_verify_identity() {
	dv_before=$1
	dv_after=$2
	if cmp -s "$dv_before" "$dv_after"; then
		return 0
	fi
	printf '%s\n' 'disk identity drift detected; refusing to continue' >&2
	return 1
}
