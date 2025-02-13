#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 1: Getting IDs"

mkdir -p "$OUTDIR"

log "Downloading mapping file..."
# Download and process mapping file
wget -qO - 'https://rest.uniprot.org/proteomes/stream?compressed=true&fields=upid%2Corganism%2Corganism_id%2Cgenome_assembly&format=tsv&query=%28*%29' | gzip -d > mapping.txt

log "Combining proteome files..."
# Combine proteome files and extract IDs
cat <(wget -O - "${RPG75}") <(wget -O - "${VIRUS95}") > full_proteomes.txt
grep '^>' full_proteomes.txt | awk '{ sub(/^>/, ""); print \$1 }' > ids.txt

log "Creating mapped.db..."
# Create mapped.db
awk 'NR==FNR{a[\$1];next} \$1 in a {print \$NF > "mapped.db"}' ids.txt mapping.txt

# Move output to outdir
mv mapped.db "$OUTDIR"

log "Step 1 completed successfully"
