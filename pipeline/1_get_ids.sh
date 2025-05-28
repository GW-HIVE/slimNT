#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 1: Getting IDs"

mkdir -p "$OUTDIR/genomes"
cd "$OUTDIR" || exit 1

log "Downloading mapping file..."
# Download and process mapping file
wget -qO - 'https://rest.uniprot.org/proteomes/stream?compressed=true&fields=upid%2Corganism%2Corganism_id%2Cgenome_assembly&format=tsv&query=%28*%29' | gzip -d > mapping.txt

log "Creating whitelist of eukaryotes to include..."
WHITELIST_FILE="../eukaryotes_whitelist.csv"
if [ ! -f "$WHITELIST_FILE" ]; then
  log "Did not find whitelist file: creating default eukaryotes whitelist at $WHITELIST_FILE"
  cat > "$WHITELIST_FILE" << EOF
organism,uniprot_ID,genbank_ID,superkingdom
Caenorhabditis elegans,UP000001940,GCA_000002985.3,Euk/Animal
Drosophila melanogaster,UP000000803,GCA_000001215.4,Euk/Animal
Canis lupus,UP000805418,GCA_014441545.1,Euk/Animal
Felis catus,UP000011712,GCA_000181335.4,Euk/mammal
Gallus gallus,UP000000539,GCA_016699485.1,Euk/bird
Mus musculus,UP000000589,GCA_000001635.9,Euk/mammal
Rattus norvegicus,UP000002494,GCA_015227675.2,Euk/mammal
Macaca mulatta,UP000006718,GCA_003339765.3,Euk/mammal
Danio rerio,UP000000437,GCF_000002035.6,Euk/Animal
Chlorocebus sabaeus,UP000029965,GCA_000409795.2,Euk/mammal
Arabidopsis thaliana,UP000006548,GCA_000001735.1,Euk/Plant
Saccharomyces cerevisiae,UP000002311,GCA_000146045.2,Euk/Fungi-Metazoa
Fusarium sporotrichioides,UP000266152,GCA_003012315.1,Euk/Fungi-Metazoa
Komagataella phaffii (strain GS115 / ATCC 20864) (Yeast) (Pichia pastoris),UP000000314,GCA_000027005.1,Euk/Fungi-Metazoa
Xenopus laevis,UP000186698,GCF_017654675.1,Euk/amphibian
Pan troglodytes,UP000002277,GCA_000001515.5,Euk/mammal
Bos taurus,UP000009136,GCA_002263795.3,Euk/mammal
Sus scrofa,UP000008227,GCA_000003025.6,Euk/mammal
Candida albicans (strain SC5314 / ATCC MYA-2876) (Yeast),UP000000559,GCA_000182965.3,Euk/Fungi-Metazoa
E coli K12,UP000000625,GCA_000005845.2,Bac/Gamma-proteo
Shigella flexneri (301 / Serotype 2a),UP000001006,GCA_000006925.2,Bac/Gamma-proteo
Cricetulus griseus,UP000001075,GCA_000223135.1,Euk/mammal
Aspergillus fumigatus (strain ATCC MYA-4609 / CBS 101355 / FGSC A1100 / Af293) (Neosartorya fumigata),UP000002530,GCA_000002655.,Euk/Fungi-Metazoa
Pseudomonas aeruginosa (strain ATCC 15692 / DSM 22644 / CIP 104116 / JCM 14847 / LMG 12228 / 1C / PRS 101 / PAO1),UP000002438,GCA_000006765.1,Bac/Gamma-proteo
Pseudomonas syringae pv. tomato (strain ATCC BAA-871 / DC3000),UP000002515,GCA_000007805.1,Bac/Gamma-proteo
Alkalihalophilus pseudofirmus (strain ATCC BAA-2126 / JCM 17055 / OF4) (Bacillus pseudofirmus),UP000001544,GCA_000005825.2,Bac/Firmicute
Bacillus cereus (strain ATCC 14579 / DSM 31 / CCUG 7414 / JCM 2152 / NBRC 15305 / NCIMB 9373 / NCTC 2599 / NRRL B-3711),UP000001417,GCA_000007825.1,Bac/Firmicute
Bacillus subtilis (strain 168),UP000001570,GCA_000009045.1,Bac/Firmicute
Lactiplantibacillus plantarum (strain ATCC BAA-793 / NCIMB 8826 / WCFS1),UP000000432,GCA_000203855.3,Bac/Firmicute
Geobacillus kaustophilus (strain HTA426),UP000001172,GCA_000009785.1,Bac/Firmicute
Mycoplasma genitalium (strain ATCC 33530 / DSM 19775 / NCTC 10195 / G37),UP000000807,GCA_000027325.1,Other Bacteria
Mycoplasma mycoides subsp. mycoides SC (strain CCUG 32753 / NCTC 10114 / PG1),UP000001016,GCA_000011445.1,Other Bacteria
EOF
  log "Default whitelist created. You can edit $WHITELIST_FILE to customize organisms."
  else
    log "Using existing eukaryotes whitelist: $WHITELIST_FILE"
fi

log "Extracting UniProt IDs from whitelist..."
# Extract UniProt IDs from CSV (skip header, get column 2)
tail -n +2 "$WHITELIST_FILE" | cut -d',' -f2 > whitelisted_uniprot_ids.txt

log "Combining proteome files..."
# Combine proteome files and extract IDs
cat <(wget -O - "${RPG75}") <(wget -O - "${VIRUS95}") > full_proteomes.txt

log "Filtering organisms using UniProt IDs..."
# Extract non-eukaryotic proteomes
grep -v "Euk/" full_proteomes.txt > non_eukaryotes.txt

# For the eukaryotes, filter using the specific UniProt IDs from the whitelist
> whitelisted_eukaryotes.txt
while IFS= read -r uniprot_id; do
  # Skip empty lines
  [[ -z "$uniprot_id" ]] && continue
  
  # Look for exact UniProt ID match at the beginning of lines
  grep "^>${uniprot_id}" full_proteomes.txt >> whitelisted_eukaryotes.txt || true
done < whitelisted_uniprot_ids.txt

# Combine the results
cat non_eukaryotes.txt whitelisted_eukaryotes.txt > filtered_proteomes.txt

# Extract IDs from filtered proteomes 
grep '^>' filtered_proteomes.txt | awk '{ sub(/^>/, ""); print $1 }' > ids.txt

log "Creating mapped.db..."
# Create mapped.db
awk 'NR==FNR{a[$1];next} $1 in a {print $NF > "mapped.db"}' ids.txt mapping.txt

# Report statistics
total_whitelisted=$(wc -l < whitelisted_uniprot_ids.txt)
found_proteomes=$(wc -l < whitelisted_eukaryotes.txt)
total_mapped=$(wc -l < mapped.db)
log "Processed $total_whitelisted whitelisted organisms, found $found_proteomes matching proteomes, mapped to $total_mapped assembly IDs"

logstepend "Step 1 completed successfully"
