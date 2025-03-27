#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 1: Getting IDs"

mkdir -p "$OUTDIR/genomes"
cd "$OUTDIR" || exit 1

log "Downloading mapping file..."
# Download and process mapping file
wget -qO - 'https://rest.uniprot.org/proteomes/stream?compressed=true&fields=upid%2Corganism%2Corganism_id%2Cgenome_assembly&format=tsv&query=%28*%29' | gzip -d > mapping.txt

log "Creating whitelist of eukaryotes to include..."
cat > eukaryotes_whitelist.txt << EOF
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

log "Combining proteome files..."
# Combine proteome files and extract IDs
cat <(wget -O - "${RPG75}") <(wget -O - "${VIRUS95}") > full_proteomes.txt

log "Filtering organisms..."
grep -v "Euk/" full_proteomes.txt > non_eukaryotes.txt

# For the eukaryotes, only keep those in the whitelist
grep "Euk/" full_proteomes.txt > all_eukaryotes.txt

# Process each whitelisted organism
while IFS= read -r org; do
  grep "$org" all_eukaryotes.txt >> whitelisted_eukaryotes.txt || true
done < eukaryotes_whitelist.txt

# Combine the results
cat non_eukaryotes.txt whitelisted_eukaryotes.txt > filtered_proteomes.txt

# Extract IDs from filtered proteomes 
grep '^>' filtered_proteomes.txt | awk '{ sub(/^>/, ""); print $1 }' > ids.txt

log "Creating mapped.db..."
# Create mapped.db
awk 'NR==FNR{a[$1];next} $1 in a {print $NF > "mapped.db"}' ids.txt mapping.txt

logstepend "Step 1 completed successfully"
