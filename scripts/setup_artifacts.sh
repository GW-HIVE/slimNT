#!/bin/bash
# One-time setup for the base/annotated artifact structure inside a slimNT output dir.
#
# Phase 1 (run before any artifact build):
#   setup_artifacts.sh /data/slimNT/v3.1
#
#   - Moves old slimNT.fa* → deprecated/
#   - Creates base/genomes/ and hardlinks all *.fna and *.zip from genomes/
#   - Creates base/fallback_genomes/ and annotated/fallback_genomes/,
#     hardlinking the existing fallback FNAs into both
#   - Creates base/logs/ and annotated/logs/
#
# Phase 2 (run after the base artifact build completes):
#   setup_artifacts.sh --phase2 /data/slimNT/v3.1
#
#   - Hardlinks everything in base/genomes/ (which now includes freshly downloaded
#     eukaryote FNAs and ZIPs) into annotated/genomes/

set -euo pipefail

PHASE=1
OUTDIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase2) PHASE=2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  OUTDIR="$1" ;;
  esac
  shift
done

if [[ -z "$OUTDIR" ]]; then
  echo "Usage: $0 [--phase2] /path/to/slimNT/output" >&2
  exit 1
fi

OUTDIR="$(realpath "$OUTDIR")"
if [[ ! -d "$OUTDIR" ]]; then
  echo "ERROR: Directory not found: $OUTDIR" >&2
  exit 1
fi

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

hardlink_dir() {
  local src_dir="$1" dst_dir="$2" pattern="$3"
  local count=0
  find "$src_dir" -maxdepth 1 -name "$pattern" -print0 \
    | xargs -0 -P 8 -I{} bash -c '
        src="$1"; dst_dir="$2"
        dst="$dst_dir/$(basename "$src")"
        [[ -e "$dst" ]] && exit 0
        ln "$src" "$dst"
      ' _ {} "$dst_dir"
  count=$(find "$dst_dir" -maxdepth 1 -name "$pattern" | wc -l)
  echo "$count"
}

# ── Phase 1 ───────────────────────────────────────────────────────────────────
if [[ $PHASE -eq 1 ]]; then
  log "=== Phase 1: initial artifact directory setup ==="

  # Deprecate old top-level artifacts
  DEPR="$OUTDIR/deprecated"
  mkdir -p "$DEPR"
  for f in slimNT.fa slimNT.fa.gz; do
    if [[ -f "$OUTDIR/$f" ]]; then
      log "Moving $f → deprecated/"
      mv "$OUTDIR/$f" "$DEPR/"
    fi
  done

  # base directories
  mkdir -p "$OUTDIR/base/genomes" "$OUTDIR/base/fallback_genomes" "$OUTDIR/base/logs"

  # annotated directories (no genomes/ yet — populated in phase 2)
  mkdir -p "$OUTDIR/annotated/fallback_genomes" "$OUTDIR/annotated/logs"

  # Hardlink genomes (FNAs + ZIPs) → base/genomes/
  SRC_GENOMES="$OUTDIR/genomes"
  DST_GENOMES="$OUTDIR/base/genomes"
  if [[ ! -d "$SRC_GENOMES" ]]; then
    log "WARNING: $SRC_GENOMES does not exist — skipping genome hardlinks"
  else
    log "Hardlinking *.fna from genomes/ → base/genomes/ ..."
    n_fna=$(hardlink_dir "$SRC_GENOMES" "$DST_GENOMES" "*.fna")
    log "  FNAs: $n_fna"

    log "Hardlinking *.zip from genomes/ → base/genomes/ ..."
    n_zip=$(hardlink_dir "$SRC_GENOMES" "$DST_GENOMES" "*.zip")
    log "  ZIPs: $n_zip"

    # Also hardlink step-2/4 support files so step 3 can find empty_list.txt
    for f in empty_list.txt empty_list2.txt; do
      [[ -f "$SRC_GENOMES/$f" ]] && ln -f "$SRC_GENOMES/$f" "$DST_GENOMES/$f" || true
    done
  fi

  # Hardlink fallback FNAs into both artifact directories
  SRC_FALLBACK="$OUTDIR/fallback_genomes"
  if [[ ! -d "$SRC_FALLBACK" ]]; then
    log "WARNING: $SRC_FALLBACK does not exist — skipping fallback hardlinks"
  else
    log "Hardlinking fallback FNAs → base/fallback_genomes/ ..."
    n_fb_base=$(hardlink_dir "$SRC_FALLBACK" "$OUTDIR/base/fallback_genomes" "*.fna")
    log "  FNAs: $n_fb_base"

    log "Hardlinking fallback FNAs → annotated/fallback_genomes/ ..."
    n_fb_ann=$(hardlink_dir "$SRC_FALLBACK" "$OUTDIR/annotated/fallback_genomes" "*.fna")
    log "  FNAs: $n_fb_ann"
  fi

  log ""
  log "=== Phase 1 complete ==="
  log ""
  log "Next: build the base artifact:"
  log "  ./run_pipeline.sh -o $OUTDIR/base --build --input-data-dir $OUTDIR/input_data --no-supplemental"
  log ""
  log "Then run phase 2 to set up annotated/genomes/:"
  log "  ./scripts/setup_artifacts.sh --phase2 $OUTDIR"

# ── Phase 2 ───────────────────────────────────────────────────────────────────
elif [[ $PHASE -eq 2 ]]; then
  log "=== Phase 2: populate annotated/genomes/ from completed base/ ==="

  SRC="$OUTDIR/base/genomes"
  DST="$OUTDIR/annotated/genomes"

  if [[ ! -d "$SRC" ]]; then
    echo "ERROR: $SRC not found — run base artifact build before phase 2" >&2
    exit 1
  fi

  mkdir -p "$DST"

  log "Hardlinking *.fna from base/genomes/ → annotated/genomes/ ..."
  n_fna=$(hardlink_dir "$SRC" "$DST" "*.fna")
  log "  FNAs: $n_fna"

  log "Hardlinking *.zip from base/genomes/ → annotated/genomes/ ..."
  n_zip=$(hardlink_dir "$SRC" "$DST" "*.zip")
  log "  ZIPs: $n_zip"

  for f in empty_list.txt empty_list2.txt; do
    [[ -f "$SRC/$f" ]] && ln -f "$SRC/$f" "$DST/$f" || true
  done

  log ""
  log "=== Phase 2 complete ==="
  log ""
  log "Next: build the annotated artifact:"
  log "  ./run_pipeline.sh -o $OUTDIR/annotated --build --input-data-dir $OUTDIR/input_data"
fi
