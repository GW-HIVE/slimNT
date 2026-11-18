#!/bin/bash

if [[ -z "${OUTDIR:-}" ]]; then
  echo "ERROR: OUTDIR is not set. Run the pipeline via: run_pipeline.sh -o /path/to/output" >&2
  exit 1
fi

LOGDIR="$OUTDIR/logs"
mkdir -p "$LOGDIR"

RPG75="https://proteininformationresource.org/rps/data/current/75/rpg-75.txt"
RPG55="https://proteininformationresource.org/rps/data/current/55/rpg-55.txt"
VIRUS95="https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-95.txt"
VIRUS75="https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-75.txt"
VIRUS55="https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-55.txt"

NCBI_DATASETS_URL="https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession"

# Step 5 refuses to run if more proteomes than this are queued for fallback
# retrieval. A normal build queues a few hundred; a queue in the hundreds of
# thousands means step 1 produced a bad unmapped list (see README).
FALLBACK_MAX_UPIDS="${FALLBACK_MAX_UPIDS:-5000}"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

logstepstart() {
  log "-------------------- $* --------------------"
  export STEP_START_TIME=$(date +%s)
}

logstepend() {
  local end_time=$(date +%s)
  local elapsed=$((end_time - STEP_START_TIME))
  local hours=$((elapsed / 3600))
  local minutes=$(( (elapsed % 3600) / 60 ))
  local seconds=$((elapsed % 60))

  log "Step completed in ${hours}h ${minutes}m ${seconds}s"
  log "$*"
}

# download_genome_zip ACCESSION
# Downloads the GENOME_FASTA package for ACCESSION into ./ACCESSION.zip, with up
# to 3 attempts and exponential backoff. Writes to a .part file and renames only
# on success, so an interrupted download never leaves a truncated .zip behind.
# Returns 0 on success, 1 if every attempt failed.
download_genome_zip() {
  local acc="$1"
  local url="${NCBI_DATASETS_URL}/${acc}/download?include_annotation_type=GENOME_FASTA&filename=${acc}.zip"
  local part="${acc}.zip.part"
  local attempt wait
  for attempt in 1 2 3; do
    log "Download attempt $attempt for $acc"
    rm -f "$part"
    if curl -sS -f -o "$part" -H "Accept: application/zip" "$url" && [[ -s "$part" ]]; then
      mv -f "$part" "${acc}.zip"
      log "Successfully downloaded ${acc}.zip"
      return 0
    fi
    rm -f "$part"
    if (( attempt < 3 )); then
      wait=$(( 2**attempt * 50 ))
      log "Attempt $attempt failed for $acc; retrying in ${wait}s"
      sleep "$wait"
    fi
  done
  log "Error: failed all download attempts for $acc"
  return 1
}

# extract_fna ZIPFILE
# Extracts the genomic FASTA from ZIPFILE to ./<base>.fna via a temp file, so a
# failed extraction never leaves a partial .fna that later runs would skip.
# Returns 0 on success, 1 on failure.
extract_fna() {
  local zip_file="$1"
  local base="${zip_file%.zip}"
  local tmp="${base}.fna.part"
  if unzip -p "$zip_file" "*.fna" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "${base}.fna"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# resolve_genomes RESOLVED_OUT MISSING_OUT
# Must be run from $OUTDIR. For every assembly in mapped.db, picks the FNA that
# represents it: genomes/<asm>.fna if non-empty, otherwise the alternate
# accession's FNA from genomes/alt_map.txt (written by step 3) if non-empty.
#   RESOLVED_OUT: one relative FNA path per line (deduplicated, mapped.db order)
#   MISSING_OUT:  assemblies with no usable FNA under either accession
# This is the single definition of "which genome FNAs belong in this build",
# shared by step 5 (what needs fallback) and step 6 (what gets concatenated).
resolve_genomes() {
  local resolved="$1" missing="$2"
  local present="$LOGDIR/.present_fnas.txt"
  local altmap="genomes/alt_map.txt"
  find genomes -maxdepth 1 -name '*.fna' -size +0 -printf '%f\n' 2>/dev/null \
    | sed 's/\.fna$//' > "$present"
  [[ -f "$altmap" ]] || altmap=/dev/null
  : > "$resolved"
  : > "$missing"
  # FILENAME checks (not NR==FNR) so an empty input file can't shift the
  # meaning of the files after it.
  awk -F'\t' -v R="$resolved" -v M="$missing" -v P="$present" -v A="$altmap" '
    FILENAME == P { have[$1]; next }
    FILENAME == A { if ($1 != "" && $2 != "") alt[$1] = $2; next }
    {
      a = $1; gsub(/[[:space:]]/, "", a)
      if (a == "" || (a in done)) next
      done[a]
      if (a in have) f = a
      else if ((a in alt) && (alt[a] in have)) f = alt[a]
      else { print a >> M; next }
      if (!(f in used)) { used[f]; print "genomes/" f ".fna" >> R }
    }' "$present" "$altmap" mapped.db
  rm -f "$present"
}
