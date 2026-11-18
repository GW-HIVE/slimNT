#!/bin/bash

usage() {
  cat <<'EOF'
Usage: run_pipeline.sh -o /path/to/output [options]

  -o, --output DIR        Output directory (required; created if missing)
  --build                 Full production build (downloads PIR/UniProt data and
                          all genomes; needs ~500 GB). Without it, runs a quick
                          smoke test on the supplemental UPIDs only (~5 GB).
  --input-data-dir DIR    Reuse cached rpg-75.txt / rpg-virus-95.txt / mapping.txt
                          (default: OUTPUT/input_data)
  --no-supplemental       Leave out pipeline/supplemental_upids.txt (base artifact)
  --backup-dir DIR        Copy genome ZIP/FNA files from DIR/genomes when present
  -h, --help              Show this help

Environment:
  NCBI_API_KEY            Optional; raises the NCBI efetch rate limit in step 5
  FALLBACK_MAX_UPIDS      Step 5 refuses larger fallback queues (default 5000)
EOF
}

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
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ -z "$OUTDIR" ]]; then
  echo "ERROR: Output directory is required." >&2
  usage >&2
  exit 1
fi

OUTDIR="$(realpath -m "$OUTDIR")"
[[ -n "$INPUT_DATA_DIR" ]] && INPUT_DATA_DIR="$(realpath -m "$INPUT_DATA_DIR")"
mkdir -p "$OUTDIR" || { echo "ERROR: Cannot create output directory: $OUTDIR" >&2; exit 1; }

if [[ ! -w "$OUTDIR" ]]; then
  echo "ERROR: Output directory is not writable: $OUTDIR" >&2
  exit 1
fi

# Only one pipeline run per output directory. Two runs sharing a directory
# interleave downloads and logs and can put unrelated files into the build.
exec 9>"$OUTDIR/.pipeline.lock"
if ! flock -n 9; then
  echo "ERROR: another run_pipeline.sh is already using $OUTDIR" >&2
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

echo "Pipeline started at $(date)"
echo "Output directory: $OUTDIR"
echo "Available disk: ${avail_gb} GB"
echo "Mode: $([[ "$BUILD" == "true" ]] && echo "FULL BUILD" || echo "SMOKE TEST (supplemental UPIDs only; use --build for a real build)")"
echo "Using backup directory: ${BACKUP_DIR:-None}"
echo "Input data dir: ${INPUT_DATA_DIR:-(default: \$OUTDIR/input_data)}"
echo "Supplemental UPIDs: $([[ "$NO_SUPPLEMENTAL" == "true" ]] && echo "DISABLED (base artifact)" || echo "enabled")"
echo "NCBI API key: $([[ -n "${NCBI_API_KEY:-}" ]] && echo "set" || echo "not set (slower efetch rate limit)")"

bash ./pipeline/1_get_ids.sh
if [[ "$BUILD" == "true" ]]; then
  bash ./pipeline/2_get_genomes.sh
  bash ./pipeline/3_get_alternate_ids.sh
  bash ./pipeline/4_get_alternate_genomes.sh
fi
bash ./pipeline/5_fetch_fallback.sh
bash ./pipeline/6_concat_zip.sh

echo "Pipeline completed at $(date)"
