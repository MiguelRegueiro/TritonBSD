#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

REPO="${TRITON_GITHUB_REPO:-MiguelRegueiro/TritonBSD}"
ARTIFACT_NAME="${TRITON_ARTIFACT_NAME:-tritonbsd-live-memstick}"
BOOT_AFTER_DOWNLOAD=0
KEEP_ZIP=0
RUN_ID=""
OUT_DIR=""
TMP_WORK=""

usage() {
    cat <<'EOF'
usage: download-live-artifact.sh [options] RUN_ID

Downloads and prepares a TritonBSD live image from a successful GitHub Actions
run. The artifact is downloaded with resumable parallel connections when aria2c
is available, then its ZIP and XZ integrity are checked. SHA-256 is printed for
both the compressed image and final flashable image.

This script never writes to a disk device.

Options:
  --boot             Boot the prepared image in QEMU after verification
  --repo OWNER/NAME  GitHub repository (default: MiguelRegueiro/TritonBSD)
  --artifact NAME    Artifact name (default: tritonbsd-live-memstick)
  --out DIR          Output directory (default: artifacts/RUN_ID)
  --keep-zip         Keep the downloaded artifact ZIP after extraction
  -h, --help         Show this help

Examples:
  ./scripts/download-live-artifact.sh 30752617529
  ./scripts/download-live-artifact.sh --keep-zip 30752617529
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
    if [ -n "$TMP_WORK" ] && [ -d "$TMP_WORK" ]; then
        rm -rf -- "$TMP_WORK" || :
    fi
}

file_size() {
    wc -c <"$1" | tr -d '[:space:]'
}

human_bytes() {
    awk -v bytes="$1" '
        BEGIN {
            split("B KiB MiB GiB TiB", unit)
            value = bytes + 0
            idx = 1
            while (value >= 1024 && idx < 5) {
                value = value / 1024
                idx++
            }
            printf "%.1f %s", value, unit[idx]
        }
    '
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v sha256 >/dev/null 2>&1; then
        sha256 -q "$1"
    else
        fail "Missing SHA-256 command: install sha256sum or sha256"
    fi
}

find_image_xz() {
    found=$(find "$1" -maxdepth 1 -type f -name '*.img.xz' -print | sort)
    [ -n "$found" ] || {
        printf '\n'
        return
    }
    count=$(printf '%s\n' "$found" | awk 'NF { total++ } END { print total + 0 }')
    [ "$count" -eq 1 ] || fail "Artifact contains multiple .img.xz files"
    printf '%s\n' "$found"
}

check_zip_paths() {
    members="$TMP_WORK/zip-members"
    unzip -Z1 "$1" >"$members" || fail "Could not list artifact ZIP contents"
    awk '
        {
            path = $0
            gsub(/\\/, "/", path)
            if (path ~ /^\// || path ~ /^[A-Za-z]:\//) {
                exit 1
            }
            count = split(path, part, "/")
            for (i = 1; i <= count; i++) {
                if (part[i] == "..") {
                    exit 1
                }
            }
        }
    ' "$members" || fail "Artifact ZIP contains an unsafe path"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    --boot)
        BOOT_AFTER_DOWNLOAD=1
        shift
        ;;
    --keep-zip)
        KEEP_ZIP=1
        shift
        ;;
    --repo)
        [ "$#" -ge 2 ] || fail "--repo requires owner/name"
        REPO="$2"
        shift 2
        ;;
    --artifact)
        [ "$#" -ge 2 ] || fail "--artifact requires a name"
        ARTIFACT_NAME="$2"
        shift 2
        ;;
    --out)
        [ "$#" -ge 2 ] || fail "--out requires a directory"
        OUT_DIR="$2"
        shift 2
        ;;
    -*)
        usage >&2
        fail "Unknown option: $1"
        ;;
    *)
        [ -z "$RUN_ID" ] || fail "Unexpected extra argument: $1"
        RUN_ID="$1"
        shift
        ;;
    esac
done

[ -n "$RUN_ID" ] || {
    usage >&2
    exit 1
}

case "$RUN_ID" in
*[!0-9]* | '') fail "RUN_ID must contain only digits" ;;
esac

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$PROJECT_DIR/artifacts/$RUN_ID"
fi

need_command gh
need_command curl
need_command unzip
need_command xz
need_command awk
need_command find
need_command cmp

mkdir -p -- "$OUT_DIR"
TMP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/triton-artifact.XXXXXX")
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077

echo "TritonBSD live artifact"
echo "  Repository: $REPO"
echo "  Run:        $RUN_ID"
echo "  Artifact:   $ARTIFACT_NAME"
echo "  Output:     $OUT_DIR"
echo

echo "[1/6] Checking workflow run"
RUN_INFO=$(gh api "/repos/$REPO/actions/runs/$RUN_ID" \
    --jq '[.status, (.conclusion // ""), .head_sha, .html_url] | @tsv') ||
    fail "Could not query workflow run $RUN_ID"

old_ifs=$IFS
IFS=$(printf '\t')
set -- $RUN_INFO
IFS=$old_ifs
RUN_STATUS=${1:-}
RUN_CONCLUSION=${2:-}
RUN_SHA=${3:-}
RUN_URL=${4:-}

[ "$RUN_STATUS" = "completed" ] || fail "Workflow run is not complete (status: $RUN_STATUS)"
[ "$RUN_CONCLUSION" = "success" ] || fail "Workflow run did not succeed (conclusion: $RUN_CONCLUSION)"

echo "  Commit: ${RUN_SHA:-unknown}"
echo "  URL:    ${RUN_URL:-unknown}"

echo
echo "[2/6] Looking up artifact"
ARTIFACT_LIST="$TMP_WORK/artifacts.tsv"
gh api --paginate "/repos/$REPO/actions/runs/$RUN_ID/artifacts?per_page=100" \
    --jq '.artifacts[] | [.id, .name, .size_in_bytes, .expired] | @tsv' \
    >"$ARTIFACT_LIST" || fail "Could not query artifacts for run $RUN_ID"
ARTIFACT_INFO=$(awk -F '\t' -v wanted="$ARTIFACT_NAME" \
    '$2 == wanted { print $1 "\t" $3 "\t" $4; exit }' "$ARTIFACT_LIST")

[ -n "$ARTIFACT_INFO" ] || fail "Artifact '$ARTIFACT_NAME' was not found on run $RUN_ID"
IFS=$(printf '\t')
set -- $ARTIFACT_INFO
IFS=$old_ifs
ARTIFACT_ID=$1
ARTIFACT_SIZE=$2
ARTIFACT_EXPIRED=$3

[ "$ARTIFACT_EXPIRED" != "true" ] || fail "Artifact $ARTIFACT_ID has expired"
echo "  ID:   $ARTIFACT_ID"
echo "  Size: $(human_bytes "$ARTIFACT_SIZE") ($ARTIFACT_SIZE bytes)"

ZIP_FILE="$OUT_DIR/$ARTIFACT_NAME.zip"
ZIP_PART="$ZIP_FILE.part"

echo
echo "[3/6] Downloading artifact"

if [ -f "$ZIP_FILE" ]; then
    ACTUAL_ZIP_SIZE=$(file_size "$ZIP_FILE")
    [ "$ACTUAL_ZIP_SIZE" = "$ARTIFACT_SIZE" ] ||
        fail "Existing ZIP has the wrong size ($ACTUAL_ZIP_SIZE, expected $ARTIFACT_SIZE); remove $ZIP_FILE and retry"
    echo "  Using existing complete ZIP: $ZIP_FILE"
else
    AUTH_CONFIG="$TMP_WORK/github-auth.conf"
    HEADERS_FILE="$TMP_WORK/headers"
    SIGNED_URL_FILE="$TMP_WORK/signed-url"
    TOKEN=$(gh auth token) || fail "Could not read the GitHub CLI authentication token"
    {
        printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
        printf 'header = "Accept: application/vnd.github+json"\n'
        printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
    } >"$AUTH_CONFIG"
    chmod 600 "$AUTH_CONFIG"
    unset TOKEN

    curl --fail --silent --show-error \
        --config "$AUTH_CONFIG" \
        --dump-header "$HEADERS_FILE" \
        --output /dev/null \
        "https://api.github.com/repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" ||
        fail "GitHub did not provide an artifact download redirect"

    SIGNED_URL=$(awk '
            tolower(substr($0, 1, 9)) == "location:" {
                sub(/^[^:]*:[[:space:]]*/, "")
                sub(/\r$/, "")
                print
                exit
            }
        ' "$HEADERS_FILE")
    [ -n "$SIGNED_URL" ] || fail "GitHub artifact response did not contain a signed download URL"
    {
        printf '%s\n' "$SIGNED_URL"
        printf '  dir=%s\n' "$OUT_DIR"
        printf '  out=%s\n' "$(basename "$ZIP_PART")"
    } >"$SIGNED_URL_FILE"
    chmod 600 "$SIGNED_URL_FILE"
    unset SIGNED_URL

    if command -v aria2c >/dev/null 2>&1; then
        echo "  Downloader: aria2c (16 parallel connections, resumable)"
        aria2c \
            --continue=true \
            --max-connection-per-server=16 \
            --split=16 \
            --min-split-size=4M \
            --file-allocation=none \
            --summary-interval=5 \
            --console-log-level=warn \
            --show-console-readout=true \
            --input-file="$SIGNED_URL_FILE" ||
            fail "Artifact download failed; rerun to resume $ZIP_PART"
    else
        echo "  Downloader: curl (resumable; install aria2c for parallel download)"
        CURL_DOWNLOAD_CONFIG="$TMP_WORK/curl-download.conf"
        {
            printf 'url = "%s"\n' "$(sed -n '1p' "$SIGNED_URL_FILE")"
        } >"$CURL_DOWNLOAD_CONFIG"
        chmod 600 "$CURL_DOWNLOAD_CONFIG"
        curl --fail --location --continue-at - --progress-bar \
            --output "$ZIP_PART" \
            --config "$CURL_DOWNLOAD_CONFIG" ||
            fail "Artifact download failed; rerun to resume $ZIP_PART"
    fi

    ACTUAL_ZIP_SIZE=$(file_size "$ZIP_PART")
    [ "$ACTUAL_ZIP_SIZE" = "$ARTIFACT_SIZE" ] ||
        fail "Downloaded ZIP size mismatch ($ACTUAL_ZIP_SIZE, expected $ARTIFACT_SIZE); partial file kept for retry"
    mv -- "$ZIP_PART" "$ZIP_FILE"
fi

echo
echo "[4/6] Testing and extracting artifact ZIP"
unzip -tq "$ZIP_FILE" >/dev/null || fail "Artifact ZIP integrity test failed; remove $ZIP_FILE and retry"
check_zip_paths "$ZIP_FILE"
EXTRACT_DIR="$TMP_WORK/extract"
mkdir -p "$EXTRACT_DIR"
unzip -q "$ZIP_FILE" -d "$EXTRACT_DIR" || fail "Artifact extraction failed"
EXTRACTED_XZ=$(find_image_xz "$EXTRACT_DIR")
[ -n "$EXTRACTED_XZ" ] || fail "Artifact does not contain a .img.xz file"
XZ_FILE="$OUT_DIR/$(basename "$EXTRACTED_XZ")"
mv -- "$EXTRACTED_XZ" "$XZ_FILE"

if [ "$KEEP_ZIP" -eq 0 ]; then
    rm -f -- "$ZIP_FILE"
    echo "  Removed verified ZIP after extraction"
fi

echo
echo "[5/6] Verifying compressed image"
xz -t "$XZ_FILE" || fail "XZ integrity test failed: $XZ_FILE"
XZ_SIZE=$(file_size "$XZ_FILE")
XZ_SHA256=$(sha256_file "$XZ_FILE")
echo "  xz -t:  passed"
echo "  SHA-256: $XZ_SHA256"

IMG_FILE=${XZ_FILE%.xz}
IMG_PART="$IMG_FILE.part"

if [ -f "$IMG_FILE" ]; then
    echo
    echo "[6/6] Verifying existing decompressed image"
    if command -v pv >/dev/null 2>&1; then
        pv -ptebar "$XZ_FILE" | xz -dc | cmp -s - "$IMG_FILE" ||
            fail "Existing image does not match the verified compressed image"
    else
        xz -dc "$XZ_FILE" | cmp -s - "$IMG_FILE" ||
            fail "Existing image does not match the verified compressed image"
    fi
else
    echo
    echo "[6/6] Decompressing flashable image"
    rm -f -- "$IMG_PART"
    if command -v pv >/dev/null 2>&1; then
        pv -ptebar "$XZ_FILE" | xz -dc >"$IMG_PART" || {
            rm -f -- "$IMG_PART"
            fail "Image decompression failed"
        }
    else
        xz -dc "$XZ_FILE" >"$IMG_PART" || {
            rm -f -- "$IMG_PART"
            fail "Image decompression failed"
        }
    fi
    mv -- "$IMG_PART" "$IMG_FILE"
fi

IMG_SIZE=$(file_size "$IMG_FILE")
IMG_SHA256=$(sha256_file "$IMG_FILE")

echo
echo "READY: TritonBSD live image downloaded and verified"
echo "  Run:              $RUN_ID"
echo "  Commit:           ${RUN_SHA:-unknown}"
echo "  Compressed image: $XZ_FILE"
echo "  Compressed size:  $(human_bytes "$XZ_SIZE") ($XZ_SIZE bytes)"
echo "  Compressed SHA:   $XZ_SHA256"
echo "  Flashable image:  $IMG_FILE"
echo "  Flashable size:   $(human_bytes "$IMG_SIZE") ($IMG_SIZE bytes)"
echo "  Flashable SHA:    $IMG_SHA256"
echo "  ZIP test:         passed"
echo "  XZ test:          passed"
echo "  Decompression:    verified"
echo "  Flashing:         not performed"

if [ "$BOOT_AFTER_DOWNLOAD" -eq 1 ]; then
    echo
    "$PROJECT_DIR/scripts/run-bootstrap-qemu.sh" "$IMG_FILE"
fi
