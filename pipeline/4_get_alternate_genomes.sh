#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 4: Getting Alternate Genomes"

cd "$OUTDIR/genomes" || exit 1

# Only proceed if alt_ids.txt exists and is not empty
if [ -s alt_ids.txt ]; then
  log "Processing alternate genomes from alt_ids.txt..."
  total_alts=$(wc -l < alt_ids.txt)
  current=0

  while IFS= read -r i; do
    ((current++))
    i=$(echo "$i" | tr -d '[:space:]')
    url="https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=CDS_FASTA&filename=$i.zip"
    log "Processing alternate genome $current/$total_alts: $i"
    curl -OJX GET "$url" -H "Accept: application/zip"
  done < "alt_ids.txt"

  log "Extracting alternate genome files..." 
  # Extract files
  for i in *.zip; do
    log "Extracting: $i"
    unzip -p "$i" "*.fna" > "${i%.zip}.fna" || true
  done

  log "Processing emtpy files..."
  # Process empty files
  find . -name "*.fna" -size 0 > empty_list2.txt
  sed -i 's/^\.\///;s/\.fna$//' empty_list2.txt
  find . -name "*.fna" -size 0 -delete
else 
  log "No alternate genomes to process (alt_ids.txt is empty or missing)"
fi

log "Step 4 completed successfully"
