#!/bin/bash
# Step 6: Nucleotide fallback retrieval
#
# For proteomes that the main pipeline couldn't handle via NCBI genome assemblies:
#   - unmapped_proteomes.txt  (no genome_assembly in UniProt → never reached mapped.db)
#   - 2_failed_downloads.txt  (had an assembly accession but NCBI download failed)
#
# Queries UniProt for nucleotide accessions and downloads via Entrez efetch.
# Successfully recovered sequences are appended to the main slimNT FASTA.
# All failures are logged to logs/fallback_retrieval.jsonl for later investigation.

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 6: Nucleotide fallback retrieval"

SCRIPT_DIR="$(dirname "$(dirname "$0")")/scripts"
FALLBACK_PY="$SCRIPT_DIR/fetch_nucleotide_fallback.py"
FALLBACK_DIR="$OUTDIR/fallback_genomes"
LOG_FILE="../../logs/fallback_retrieval.jsonl"

UNMAPPED="$OUTDIR/unmapped_proteomes.txt"
FAILED_DL="../../logs/2_failed_downloads.txt"
ASM_MAP="$OUTDIR/assembly_to_upid.txt"

# Confirm at least one input source exists
has_unmapped=false
has_failed=false
[[ -s "$UNMAPPED" ]]  && has_unmapped=true
[[ -s "$FAILED_DL" ]] && has_failed=true

if ! $has_unmapped && ! $has_failed; then
  log "No unmapped proteomes and no failed downloads — nothing to do."
  logstepend "Step 6 skipped (no fallback needed)"
  exit 0
fi

$has_unmapped && log "Unmapped proteomes: $(wc -l < "$UNMAPPED") entries"
$has_failed   && log "Failed assembly downloads: $(wc -l < "$FAILED_DL") entries"

# Build the argument list for the Python script
ARGS=("--outdir" "$FALLBACK_DIR" "--log" "$LOG_FILE")
$has_unmapped && ARGS+=("--upids" "$UNMAPPED")
if $has_failed; then
  if [[ ! -f "$ASM_MAP" ]]; then
    log "WARNING: 2_failed_downloads.txt exists but assembly_to_upid.txt is missing."
    log "         Failed-assembly fallback will be skipped. Re-run step 1 to regenerate it."
  else
    ARGS+=("--assemblies" "$FAILED_DL" "--assembly-map" "$ASM_MAP")
  fi
fi

log "Running nucleotide fallback script..."
cd "$OUTDIR" || exit 1
python3 "$FALLBACK_PY" "${ARGS[@]}"

# Append recovered FNA files to the main concatenated FASTA (if it already exists)
if ls "$FALLBACK_DIR"/*.fna 1>/dev/null 2>&1; then
  recovered=$(ls "$FALLBACK_DIR"/*.fna | wc -l)
  log "Recovered $recovered FNA file(s). Appending to main slimNT FASTA..."
  for fna in "$FALLBACK_DIR"/*.fna; do
    [[ -s "$fna" ]] && cat "$fna" >> slimNT.fa
  done
  log "Append complete."
else
  log "No FNA files recovered — see $LOG_FILE for details."
fi

logstepend "Step 6 completed"
