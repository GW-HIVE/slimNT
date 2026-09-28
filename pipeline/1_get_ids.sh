#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 1: Getting IDs"

mkdir -p "$OUTDIR/genomes"

WHITELIST_FILE="$(dirname "$0")/eukaryotes_whitelist.txt"

cd "$OUTDIR" || exit 1

log "Downloading mapping file..."
# Download and process mapping file
wget -qO - 'https://rest.uniprot.org/proteomes/stream?compressed=true&fields=upid%2Corganism%2Corganism_id%2Cgenome_assembly&format=tsv&query=%28*%29' | gzip -d > mapping.txt

log "Creating whitelist of eukaryotes to include..."
if [ ! -f "$WHITELIST_FILE" ]; then
  log "Did not find whitelist file: creating default eukaryotes whitelist at $WHITELIST_FILE"
  cat > "$WHITELIST_FILE" << EOF
Caenorhabditis elegans
Drosophila melanogaster
Canis lupus
Felis catus
Gallus gallus
Mus musculus
Rattus norvegicus
Macaca mulatta
Danio rerio
Chlorocebus sabaeus
Arabidopsis thaliana
Saccharomyces cerevisiae
Fusarium sporotrichioides
Pichia pastoris
Xenopus laevis
Pan troglodytes
Bos taurus
Sus scrofa
EOF
  log "Default whitelist created. You can edit $WHITELIST_FILE to customize organisms."
  else
    log "Using existing eukaryotes whitelist: $WHITELIST_FILE"
fi

log "Combining proteome files..."
# Combine proteome files and extract IDs
cat <(wget -O - "${RPG75}") <(wget -O - "${VIRUS95}") > full_proteomes.txt

log "Filtering organisms..."
grep -v "Euk/" full_proteomes.txt > non_eukaryotes.txt

# For the eukaryotes, only keep those in the whitelist
grep "Euk/" full_proteomes.txt > all_eukaryotes.txt

# Process each whitelisted organism
> whitelisted_eukaryotes.txt
while IFS= read -r org; do
  [[ -z "$org" || "$org" =~ ^[[:space:]]*# ]] && continue
  grep "$org" all_eukaryotes.txt >> whitelisted_eukaryotes.txt || true
done < "$WHITELIST_FILE"

# Combine the results
cat non_eukaryotes.txt whitelisted_eukaryotes.txt > filtered_proteomes.txt

# Extract IDs from filtered proteomes 
grep '^>' filtered_proteomes.txt | awk '{ sub(/^>/, ""); print $1 }' > ids.txt

log "Creating mapped.db..."
# Create mapped.db, recording unmapped proteomes and assembly→upid reverse mapping.
# Uses $4 explicitly (upid, organism, organism_id, genome_assembly) rather than $NF
# to avoid picking up organism_id when the genome_assembly field is empty/absent.
awk -F'\t' '
  NR==FNR { seen[$1] = 0; next }
  $1 in seen {
    seen[$1] = 1
    if ($4 != "") {
      print $4 > "mapped.db"
      print $4 "\t" $1 > "assembly_to_upid.txt"
    } else {
      print $1 > "unmapped_proteomes.txt"
    }
  }
  END {
    for (id in seen)
      if (seen[id] == 0) print id >> "unmapped_proteomes.txt"
  }
' ids.txt mapping.txt

unmapped_count=$(wc -l < "unmapped_proteomes.txt" 2>/dev/null || echo 0)
log "$unmapped_count proteome(s) with no genome assembly written to unmapped_proteomes.txt"

logstepend "Step 1 completed successfully"
