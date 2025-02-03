#!/bin/bash

source config.sh

mkdir -p "$OUTDIR"

# Download and process mapping file
wget -qO - 'https://rest.uniprot.org/proteomes/stream?compressed=true&fields=upid%2Corganism%2Corganism_id%2Cgenome_assembly&format=tsv&query=%28*%29' | gzip -d > mapping.txt

# Combine proteome files and extract IDs
cat <(wget -O - "${RPG75}") <(wget -O - "${VIRUS95}") > full_proteomes.txt
grep '^>' full_proteomes.txt | awk '{ sub(/^>/, ""); print \$1 }' > ids.txt

# Create mapped.db
awk 'NR==FNR{a[\$1];next} \$1 in a {print \$NF > "mapped.db"}' ids.txt mapping.txt

# Move output to outdir
mv mapped.db "$OUTDIR"
