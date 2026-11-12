#!/bin/bash

OUTDIR=""
BACKUP_DIR=""
INPUT_DATA_DIR=""
BUILD=false
NO_SUPPLEMENTAL=false
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -o|--output) OUTDIR="$2"; shift ;;
    --backup-dir) BACKUP_DIR="$2"; shift ;;
    --input-data-dir) INPUT_DATA_DIR="$2"; shift ;;
    --build) BUILD=true ;;
    --no-supplemental) NO_SUPPLEMENTAL=true ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ -z "$OUTDIR" ]]; then
  echo "ERROR: Output directory is required. Usage: run_pipeline.sh -o /path/to/output [--build] [--backup-dir /path]" >&2
  exit 1
fi

OUTDIR="$(realpath -m "$OUTDIR")"
[[ -n "$INPUT_DATA_DIR" ]] && INPUT_DATA_DIR="$(realpath -m "$INPUT_DATA_DIR")"
mkdir -p "$OUTDIR" || { echo "ERROR: Cannot create output directory: $OUTDIR" >&2; exit 1; }

if [[ ! -w "$OUTDIR" ]]; then
  echo "ERROR: Output directory is not writable: $OUTDIR" >&2
  exit 1
fi

avail_gb=$(df -BG "$OUTDIR" | awk 'NR==2 { gsub(/G/, ""); print $4 }')
min_gb=5
[[ "$BUILD" == "true" ]] && min_gb=500
if (( avail_gb < min_gb )); then
  echo "ERROR: Insufficient disk space at $OUTDIR. Available: ${avail_gb} GB, required: ${min_gb} GB." >&2
  exit 1
fi

export OUTDIR
export BACKUP_DIR
export INPUT_DATA_DIR
export BUILD
export NO_SUPPLEMENTAL

set -e
cd "$(dirname "$0")" || exit 1

mkdir -p "$OUTDIR/logs"

chmod +x run_pipeline.sh
chmod +x ./pipeline/*.sh

echo "Pipeline started at $(date)"
echo "Output directory: $OUTDIR"
echo "Available disk: ${avail_gb} GB"
echo "Mode: $([[ "$BUILD" == "true" ]] && echo "FULL BUILD" || echo "SMOKE TEST (supplemental UPIDs only)")"
echo "Using backup directory: ${BACKUP_DIR:-None}"
echo "Input data dir: ${INPUT_DATA_DIR:-(default: \$OUTDIR/input_data)}"
echo "Supplemental UPIDs: $([[ "$NO_SUPPLEMENTAL" == "true" ]] && echo "DISABLED (base artifact)" || echo "enabled")"

./pipeline/1_get_ids.sh
if [[ "$BUILD" == "true" ]]; then
  ./pipeline/2_get_genomes.sh
  ./pipeline/3_get_alternate_ids.sh
  ./pipeline/4_get_alternate_genomes.sh
fi
./pipeline/5_fetch_fallback.sh
./pipeline/6_concat_zip.sh

echo "Pipeline completed at $(date)"
