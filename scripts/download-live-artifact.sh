#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

REPO="${TRITON_GITHUB_REPO:-MiguelRegueiro/TritonBSD}"
ARTIFACT_NAME="${TRITON_ARTIFACT_NAME:-tritonbsd-live-memstick}"
BOOT_AFTER_DOWNLOAD=0
RUN_ID=""
OUT_DIR=""

usage() {
    cat <<'EOF'
usage: download-live-artifact.sh [--boot] [--repo owner/name] [--artifact name] [--out dir] RUN_ID

Downloads a GitHub Actions artifact, extracts the .img.xz file, decompresses it,
and prints the image path.

Examples:
  ./scripts/download-live-artifact.sh 29367425435
  ./scripts/download-live-artifact.sh --boot 29367425435
EOF
}

need_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
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

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --boot)
            BOOT_AFTER_DOWNLOAD=1
            shift
            ;;
        --repo)
            if [ "$#" -lt 2 ]; then
                echo "--repo requires owner/name" >&2
                exit 1
            fi
            REPO="$2"
            shift 2
            ;;
        --artifact)
            if [ "$#" -lt 2 ]; then
                echo "--artifact requires a name" >&2
                exit 1
            fi
            ARTIFACT_NAME="$2"
            shift 2
            ;;
        --out)
            if [ "$#" -lt 2 ]; then
                echo "--out requires a directory" >&2
                exit 1
            fi
            OUT_DIR="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [ -n "$RUN_ID" ]; then
                echo "Unexpected extra argument: $1" >&2
                usage >&2
                exit 1
            fi
            RUN_ID="$1"
            shift
            ;;
    esac
done

if [ -z "$RUN_ID" ]; then
    usage >&2
    exit 1
fi

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$PROJECT_DIR/artifacts/$RUN_ID"
fi

need_command gh
need_command curl
need_command unzip
need_command xz
need_command awk

mkdir -p "$OUT_DIR"

echo "Looking up artifact"
echo "  repo:     $REPO"
echo "  run:      $RUN_ID"
echo "  artifact: $ARTIFACT_NAME"
echo "  output:   $OUT_DIR"
echo

ARTIFACT_INFO=$(gh api "/repos/$REPO/actions/runs/$RUN_ID/artifacts" \
    --jq ".artifacts[] | select(.name == \"$ARTIFACT_NAME\") | [.id, .size_in_bytes, .expired, .archive_download_url] | @tsv")

if [ -z "$ARTIFACT_INFO" ]; then
    echo "Could not find artifact '$ARTIFACT_NAME' on run $RUN_ID." >&2
    echo "Check the run URL or artifact name." >&2
    exit 1
fi

set -- $ARTIFACT_INFO
ARTIFACT_ID="$1"
ARTIFACT_SIZE="$2"
ARTIFACT_EXPIRED="$3"
ARCHIVE_URL="$4"

if [ "$ARTIFACT_EXPIRED" = "true" ]; then
    echo "Artifact $ARTIFACT_ID is expired." >&2
    exit 1
fi

echo "Found artifact $ARTIFACT_ID ($(human_bytes "$ARTIFACT_SIZE"))"

ZIP_FILE="$OUT_DIR/$ARTIFACT_NAME.zip"
ZIP_PART="$ZIP_FILE.part"

if [ -f "$ZIP_FILE" ]; then
    echo "Using existing artifact zip: $ZIP_FILE"
else
    TOKEN=$(gh auth token)
    echo "Downloading artifact zip"
    curl --fail --location --progress-bar \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$ARCHIVE_URL" \
        -o "$ZIP_PART"
    mv "$ZIP_PART" "$ZIP_FILE"
fi

echo
echo "Extracting artifact zip"
unzip -o "$ZIP_FILE" -d "$OUT_DIR"

XZ_FILE=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*-live-memstick.img.xz' | sort | head -n 1)
if [ -z "$XZ_FILE" ]; then
    XZ_FILE=$(find "$OUT_DIR" -maxdepth 1 -type f -name '*.img.xz' | sort | head -n 1)
fi

if [ -z "$XZ_FILE" ]; then
    echo "No .img.xz file found in $OUT_DIR after extraction." >&2
    exit 1
fi

IMG_FILE=${XZ_FILE%.xz}

if [ -f "$IMG_FILE" ]; then
    echo "Using existing decompressed image: $IMG_FILE"
else
    echo
    echo "Decompressing image"
    xz -dkv "$XZ_FILE"
fi

echo
echo "Image ready:"
echo "  $IMG_FILE"
echo
echo "Boot it with:"
echo "  ./scripts/run-bootstrap-qemu.sh $IMG_FILE"

if [ "$BOOT_AFTER_DOWNLOAD" -eq 1 ]; then
    echo
    "$PROJECT_DIR/scripts/run-bootstrap-qemu.sh" "$IMG_FILE"
fi
