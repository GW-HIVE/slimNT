#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 1: Getting IDs"

mkdir -p "$OUTDIR/genomes"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WHITELIST_FILE="$SCRIPT_DIR/eukaryotes_whitelist.txt"

INPUT_DATA_DIR="${INPUT_DATA_DIR:-$OUTDIR/input_data}"
mkdir -p "$INPUT_DATA_DIR"

cd "$OUTDIR" || exit 1

if [[ "${BUILD:-false}" != "true" ]]; then
  log "SMOKE TEST MODE: skipping RPG/mapping downloads; using supplemental UPIDs only"
  SUPPL_FILE="$SCRIPT_DIR/supplemental_upids.txt"
  if [[ -f "$SUPPL_FILE" ]]; then
    grep -v '^\s*#' "$SUPPL_FILE" | grep -v '^\s*$' | awk '{print $1}' > ids.txt
    log "Loaded $(wc -l < ids.txt) UPID(s) from supplemental_upids.txt"
  else
    log "WARNING: supplemental_upids.txt not found; ids.txt will be empty"
    > ids.txt
  fi
  cp ids.txt unmapped_proteomes.txt
  > mapped.db
  > assembly_to_upid.txt
  log "$(wc -l < unmapped_proteomes.txt) UPID(s) queued for fallback retrieval"
  logstepend "Step 1 completed (smoke test)"
  exit 0
fi

MAPPING_FILE="$INPUT_DATA_DIR/mapping.txt"
MAPPING_MIN_LINES=1000
if [[ ! -f "$MAPPING_FILE" ]]; then
  log "Downloading mapping file..."
  # Download to a temp file and only cache it once it is complete and plausible;
  # a failed download must not be cached and silently reused by later runs.
  set -o pipefail
  if ! wget -qO - 'https://rest.uniprot.org/proteomes/stream?compressed=true&fields=upid%2Corganism%2Corganism_id%2Cgenome_assembly&format=tsv&query=%28*%29' \
      | gzip -d > "$MAPPING_FILE.part"; then
    rm -f "$MAPPING_FILE.part"
    log "ERROR: UniProt mapping download failed. Cannot continue."
    exit 1
  fi
  set +o pipefail
  mv -f "$MAPPING_FILE.part" "$MAPPING_FILE"
else
  log "Using cached mapping file: $MAPPING_FILE"
fi
mapping_lines=$(wc -l < "$MAPPING_FILE")
if (( mapping_lines < MAPPING_MIN_LINES )); then
  log "ERROR: $MAPPING_FILE has only $mapping_lines line(s); expected over a million."
  log "       Delete it and rerun to download it again."
  exit 1
fi
log "Mapping file: $mapping_lines lines"

log "Creating whitelist of eukaryotes to include..."
if [ ! -f "$WHITELIST_FILE" ]; then
  log "Did not find whitelist file: creating default eukaryotes whitelist at $WHITELIST_FILE"
  cat > "$WHITELIST_FILE" << 'EOF'
# Eukaryote proteome UPIDs to include in slimNT.
# One UPID per line; lines starting with # are ignored.
# Organism name shown as a comment for reference only — matching is UPID-based.
UP000001940  # Caenorhabditis elegans
UP000000803  # Drosophila melanogaster
UP000805418  # Canis lupus
UP000011712  # Felis catus
UP000000539  # Gallus gallus
UP000000589  # Mus musculus
UP000002494  # Rattus norvegicus
UP000006718  # Macaca mulatta
UP000000437  # Danio rerio
UP000029965  # Chlorocebus sabaeus
UP000006548  # Arabidopsis thaliana
UP000002311  # Saccharomyces cerevisiae
UP000266152  # Fusarium sporotrichioides
UP000000314  # Komagataella phaffii (Pichia pastoris)
UP000186698  # Xenopus laevis
UP000002277  # Pan troglodytes
UP000009136  # Bos taurus
UP000008227  # Sus scrofa
UP000000559  # Candida albicans
UP000001075  # Cricetulus griseus (Chinese hamster)
UP000002530  # Aspergillus fumigatus
EOF
  log "Default whitelist created. You can edit $WHITELIST_FILE to customize organisms."
  else
    log "Using existing eukaryotes whitelist: $WHITELIST_FILE"
fi

rpg75_ok=true
if [[ ! -f "$INPUT_DATA_DIR/rpg-75.txt" ]]; then
  log "Downloading RPG-75 proteome list..."
  if ! wget -O "$INPUT_DATA_DIR/rpg-75.txt" "${RPG75}" || [[ ! -s "$INPUT_DATA_DIR/rpg-75.txt" ]]; then
    log "WARNING: RPG-75 download failed or produced empty file"
    rm -f "$INPUT_DATA_DIR/rpg-75.txt"
    rpg75_ok=false
  fi
else
  log "Using cached RPG-75: $INPUT_DATA_DIR/rpg-75.txt"
fi

rpg_virus_ok=true
if [[ ! -f "$INPUT_DATA_DIR/rpg-virus-95.txt" ]]; then
  log "Downloading virus RPG-95 proteome list..."
  if ! wget -O "$INPUT_DATA_DIR/rpg-virus-95.txt" "${VIRUS95}" || [[ ! -s "$INPUT_DATA_DIR/rpg-virus-95.txt" ]]; then
    log "WARNING: Virus RPG-95 download failed or produced empty file"
    rm -f "$INPUT_DATA_DIR/rpg-virus-95.txt"
    rpg_virus_ok=false
  fi
else
  log "Using cached RPG-95: $INPUT_DATA_DIR/rpg-virus-95.txt"
fi

log "Combining proteome files..."
if $rpg75_ok && $rpg_virus_ok; then
  cat "$INPUT_DATA_DIR/rpg-75.txt" "$INPUT_DATA_DIR/rpg-virus-95.txt" > full_proteomes.txt
elif [[ -f "$INPUT_DATA_DIR/full_proteomes.txt" && -s "$INPUT_DATA_DIR/full_proteomes.txt" ]]; then
  log "WARNING: PIR download(s) failed; falling back to cached full_proteomes.txt at $INPUT_DATA_DIR/full_proteomes.txt"
  cp "$INPUT_DATA_DIR/full_proteomes.txt" full_proteomes.txt
else
  log "ERROR: PIR download(s) failed and no cached full_proteomes.txt found in $INPUT_DATA_DIR. Cannot continue."
  exit 1
fi

log "Filtering organisms..."
grep -v "Euk/" full_proteomes.txt > non_eukaryotes.txt

# For the eukaryotes, only keep those in the whitelist
grep "Euk/" full_proteomes.txt > all_eukaryotes.txt

# Process each whitelisted organism by UPID (not name) to avoid partial/strain mismatches
> whitelisted_eukaryotes.txt
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  upid=$(echo "$line" | awk '{print $1}')
  grep "^>$upid" all_eukaryotes.txt >> whitelisted_eukaryotes.txt || true
done < "$WHITELIST_FILE"

# Combine the results
cat non_eukaryotes.txt whitelisted_eukaryotes.txt > filtered_proteomes.txt

# Extract IDs from filtered proteomes
grep '^>' filtered_proteomes.txt | awk '{ sub(/^>/, ""); print $1 }' > ids.txt

# Check before supplemental UPIDs are appended, so they can't mask an empty
# PIR selection.
pir_count=$(wc -l < ids.txt)
if (( pir_count == 0 )); then
  log "ERROR: no proteome IDs were selected from the PIR lists."
  log "       Check $INPUT_DATA_DIR/rpg-*.txt and the filtering above. Cannot continue."
  exit 1
fi
log "Selected $pir_count proteome ID(s) from PIR"

# Append supplemental UPIDs not covered by PIR reference lists
# Skipped for the base artifact (NO_SUPPLEMENTAL=true).
SUPPL_FILE="$SCRIPT_DIR/supplemental_upids.txt"
if [[ "${NO_SUPPLEMENTAL:-false}" == "true" ]]; then
  log "Skipping supplemental UPIDs (NO_SUPPLEMENTAL=true — base artifact)"
elif [[ -f "$SUPPL_FILE" ]]; then
  suppl=$(grep -v '^\s*#' "$SUPPL_FILE" | grep -v '^\s*$' | awk '{print $1}')
  if [[ -n "$suppl" ]]; then
    echo "$suppl" >> ids.txt
    log "Appended $(echo "$suppl" | wc -l) supplemental UPID(s) from supplemental_upids.txt"
  fi
fi

id_count=$(wc -l < ids.txt)

log "Creating mapped.db..."
# Create mapped.db, recording unmapped proteomes and assembly→upid reverse mapping.
# Uses $4 explicitly (upid, organism, organism_id, genome_assembly) rather than $NF
# to avoid picking up organism_id when the genome_assembly field is empty/absent.
#
# All three outputs are truncated first: awk only opens a file when it writes to
# it, so without this a rerun could append to (or leave behind) a previous run's
# list. The first file is identified by FILENAME rather than NR==FNR, which
# would treat the whole mapping file as the ID list if ids.txt were empty.
: > mapped.db
: > assembly_to_upid.txt
: > unmapped_proteomes.txt
awk -F'\t' -v IDS="ids.txt" '
  FILENAME == IDS { if ($1 != "") seen[$1] = 0; next }
  $1 in seen {
    seen[$1] = 1
    if ($4 != "") {
      print $4 >> "mapped.db"
      print $4 "\t" $1 >> "assembly_to_upid.txt"
    } else {
      print $1 >> "unmapped_proteomes.txt"
    }
  }
  END {
    for (id in seen)
      if (seen[id] == 0) print id >> "unmapped_proteomes.txt"
  }
' ids.txt "$MAPPING_FILE"

unmapped_count=$(wc -l < "unmapped_proteomes.txt")
log "$(wc -l < mapped.db) proteome(s) mapped to a genome assembly (mapped.db)"
log "$unmapped_count proteome(s) with no genome assembly written to unmapped_proteomes.txt"
if (( unmapped_count > id_count )); then
  log "ERROR: more unmapped proteomes ($unmapped_count) than selected IDs ($id_count). Cannot continue."
  exit 1
fi

logstepend "Step 1 completed successfully"
