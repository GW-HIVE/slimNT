#!/bin/bash

OUTDIR=""
BACKUP_DIR=""
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -o|--output) OUTDIR="$2"; shift ;;
    --backup-dir) BACKUP_DIR="$2"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ -z "$OUTDIR" ]]; then
  echo "ERROR: Output directory is required. Usage: run_pipeline.sh -o /path/to/output [--backup-dir /path]" >&2
  exit 1
fi

OUTDIR="$(realpath -m "$OUTDIR")"
mkdir -p "$OUTDIR" || { echo "ERROR: Cannot create output directory: $OUTDIR" >&2; exit 1; }

if [[ ! -w "$OUTDIR" ]]; then
  echo "ERROR: Output directory is not writable: $OUTDIR" >&2
  exit 1
fi

avail_gb=$(df -BG "$OUTDIR" | awk 'NR==2 { gsub(/G/, ""); print $4 }')
if (( avail_gb < 500 )); then
  echo "ERROR: Insufficient disk space at $OUTDIR. Available: ${avail_gb} GB, required: 500 GB." >&2
  exit 1
fi

export OUTDIR
export BACKUP_DIR

set -e
cd "$(dirname "$0")" || exit 1

mkdir -p "$OUTDIR/logs"

chmod +x run_pipeline.sh
chmod +x ./pipeline/*.sh

echo "Pipeline started at $(date)"
echo "Output directory: $OUTDIR"
echo "Available disk: ${avail_gb} GB"
echo "Using backup directory: ${BACKUP_DIR:-None}"

./pipeline/1_get_ids.sh
./pipeline/2_get_genomes.sh
./pipeline/3_get_alternate_ids.sh
./pipeline/4_get_alternate_genomes.sh
./pipeline/5_concat_zip.sh
./pipeline/6_fetch_fallback.sh

echo "Pipeline completed at $(date)"
