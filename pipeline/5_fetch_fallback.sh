#!/bin/bash
# Step 5: Nucleotide fallback retrieval
#
# Queues for fallback every proteome the assembly path did not cover:
#   - unmapped_proteomes.txt  (no genome_assembly in UniProt; written by step 1)
#   - proteomes whose assembly has no usable FNA in genomes/ under either its
#     own accession or its alternate (resolve_genomes in config.sh). This is
#     computed from what is on disk, not from failure logs, so assemblies that
#     were recovered later (e.g. by step 4) are never queued.
#
# The queue is written to $OUTDIR/fallback_queue.txt. Step 6 includes exactly
# the fallback FNAs for these UPIDs, and nothing else in fallback_genomes/.
#
# Queries UniProt for nucleotide accessions and downloads via Entrez efetch.
# All outcomes are logged to logs/fallback_retrieval.jsonl.

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 5: Nucleotide fallback retrieval"

SCRIPT_DIR="$(cd "$(dirname "$(dirname "$0")")" && pwd)/scripts"
FALLBACK_PY="$SCRIPT_DIR/fetch_nucleotide_fallback.py"
SUPPL_FILE="$(cd "$(dirname "$0")" && pwd)/supplemental_upids.txt"
FALLBACK_DIR="$OUTDIR/fallback_genomes"
LOG_FILE="$LOGDIR/fallback_retrieval.jsonl"
QUEUE="$OUTDIR/fallback_queue.txt"

cd "$OUTDIR" || exit 1

for f in mapped.db unmapped_proteomes.txt assembly_to_upid.txt; do
  if [[ ! -f "$f" ]]; then
    log "ERROR: $OUTDIR/$f not found. Run step 1 first."
    exit 1
  fi
done

MISSING_ASMS="$LOGDIR/5_missing_assemblies.txt"
resolve_genomes "$LOGDIR/5_resolved_genomes.txt" "$MISSING_ASMS"
log "Assemblies in mapped.db: $(wc -l < mapped.db); with no usable FNA: $(wc -l < "$MISSING_ASMS")"
log "Unmapped proteomes: $(wc -l < unmapped_proteomes.txt)"

{
  cat unmapped_proteomes.txt
  awk -F'\t' -v M="$MISSING_ASMS" '
    FILENAME == M { miss[$1]; next }
    ($1 in miss) { print $2 }
  ' "$MISSING_ASMS" assembly_to_upid.txt
} | tr -d '\r ' | awk NF | sort -u > "$QUEUE"

queued=$(wc -l < "$QUEUE")
log "Fallback queue: $queued proteome(s) -> $QUEUE"

if (( queued == 0 )); then
  logstepend "Step 5 skipped (no fallback needed)"
  exit 0
fi

if (( queued > FALLBACK_MAX_UPIDS )); then
  log "ERROR: fallback queue has $queued proteomes, above the limit of $FALLBACK_MAX_UPIDS."
  log "       A normal build queues a few hundred. Check unmapped_proteomes.txt and"
  log "       mapped.db before continuing. To allow a larger queue deliberately, set"
  log "       FALLBACK_MAX_UPIDS in the environment."
  exit 1
fi

ARGS=("--outdir" "$FALLBACK_DIR" "--log" "$LOG_FILE" "--upids" "$QUEUE"
      "--max-upids" "$FALLBACK_MAX_UPIDS")
if [[ "${NO_SUPPLEMENTAL:-false}" == "true" ]]; then
  log "Skipping supplemental accessions (NO_SUPPLEMENTAL=true — base artifact)"
elif [[ -f "$SUPPL_FILE" ]]; then
  ARGS+=("--supplemental" "$SUPPL_FILE")
fi

log "Running nucleotide fallback script..."
if ! python3 "$FALLBACK_PY" "${ARGS[@]}"; then
  log "ERROR: fallback script failed — see $LOG_FILE"
  exit 1
fi

recovered=0
while IFS= read -r upid; do
  [[ -s "$FALLBACK_DIR/$upid.fna" ]] && recovered=$((recovered + 1))
done < "$QUEUE"
log "Recovered $recovered of $queued queued proteome(s) — see $LOG_FILE for failures."

if [[ -s "genomes/empty_list2.txt" ]]; then
  count=$(wc -l < "genomes/empty_list2.txt")
  log "WARNING: $count empty FNA(s) in genomes/empty_list2.txt — alternate assembly downloads produced empty sequences. Review manually."
fi

logstepend "Step 5 completed"
