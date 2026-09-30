#!/bin/bash
# Step 5: Nucleotide fallback retrieval
#
# For proteomes that the main pipeline couldn't handle via NCBI genome assemblies:
#   - unmapped_proteomes.txt    (no genome_assembly in UniProt → never reached mapped.db)
#   - 2_failed_downloads.txt    (assembly accession existed but NCBI download failed)
#   - 4_extraction_failed.txt   (ZIP downloaded but contained no *.fna — flat nucleotide
#                                records like RSV/PERV stored outside assembly packages)
#
# Queries UniProt for nucleotide accessions and downloads via Entrez efetch.
# Recovered .fna files are written to fallback_genomes/ for step 6 to concatenate.
# All failures are logged to logs/fallback_retrieval.jsonl for later investigation.

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 5: Nucleotide fallback retrieval"

SCRIPT_DIR="$(cd "$(dirname "$(dirname "$0")")" && pwd)/scripts"
FALLBACK_PY="$SCRIPT_DIR/fetch_nucleotide_fallback.py"
FALLBACK_DIR="$OUTDIR/fallback_genomes"
LOG_FILE="$LOGDIR/fallback_retrieval.jsonl"

UNMAPPED="$OUTDIR/unmapped_proteomes.txt"
FAILED_DL="$LOGDIR/2_failed_downloads.txt"
FAILED_EXT="$LOGDIR/4_extraction_failed.txt"
ASM_MAP="$OUTDIR/assembly_to_upid.txt"
COMBINED_ASMS="$LOGDIR/combined_failed_assemblies.txt"

# Confirm at least one input source exists
has_unmapped=false
has_asms=false
[[ -s "$UNMAPPED" ]] && has_unmapped=true
[[ -s "$FAILED_DL" || -s "$FAILED_EXT" ]] && has_asms=true

if ! $has_unmapped && ! $has_asms; then
  log "No unmapped proteomes and no failed downloads — nothing to do."
  logstepend "Step 5 skipped (no fallback needed)"
  exit 0
fi

$has_unmapped && log "Unmapped proteomes: $(wc -l < "$UNMAPPED") entries"

# Merge assembly failure sources into one deduplicated list
if $has_asms; then
  if [[ ! -f "$ASM_MAP" ]]; then
    log "WARNING: assembly failures exist but assembly_to_upid.txt is missing."
    log "         Assembly fallback will be skipped. Re-run step 1 to regenerate it."
    has_asms=false
  else
    > "$COMBINED_ASMS"
    [[ -s "$FAILED_DL"  ]] && cat "$FAILED_DL"  >> "$COMBINED_ASMS"
    [[ -s "$FAILED_EXT" ]] && cat "$FAILED_EXT" >> "$COMBINED_ASMS"
    sort -u -o "$COMBINED_ASMS" "$COMBINED_ASMS"
    log "Failed assembly accessions (downloads + extraction): $(wc -l < "$COMBINED_ASMS") entries"
  fi
fi

# Build the argument list for the Python script
SUPPL_FILE="$(dirname "$0")/supplemental_upids.txt"
ARGS=("--outdir" "$FALLBACK_DIR" "--log" "$LOG_FILE")
$has_unmapped && ARGS+=("--upids" "$UNMAPPED")
$has_asms     && ARGS+=("--assemblies" "$COMBINED_ASMS" "--assembly-map" "$ASM_MAP")
[[ -f "$SUPPL_FILE" ]] && ARGS+=("--supplemental" "$SUPPL_FILE")

log "Running nucleotide fallback script..."
cd "$OUTDIR" || exit 1
python3 "$FALLBACK_PY" "${ARGS[@]}"

if ls "$FALLBACK_DIR"/*.fna 1>/dev/null 2>&1; then
  recovered=$(ls "$FALLBACK_DIR"/*.fna | wc -l)
  log "Recovered $recovered FNA file(s) — step 6 will include them in the final FASTA."
else
  log "No FNA files recovered — see $LOG_FILE for details."
fi

if [[ -s "genomes/empty_list2.txt" ]]; then
  count=$(wc -l < "genomes/empty_list2.txt")
  log "WARNING: $count empty FNA(s) in genomes/empty_list2.txt — alternate assembly downloads produced empty sequences. Review manually."
fi

logstepend "Step 5 completed"
