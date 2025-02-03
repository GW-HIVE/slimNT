#!/bin/bash

source config.sh

logstepstart "Starting Step 2: Getting Genomes"

mkdir -p "$OUTDIR/genomes"

log "Beginning genome downloads..."
total_genomes=$(wc -l < "$OUTDIR/mapped.db")
current=0

# Read mapped.db and download genomes
while IFS= read -r i; do
  ((current++))
  if [ ! -f "$i.zip" ]; then
    log "Processing genome $current/$total_genomes: $i"
    for attempt in {1..3}; do
      if curl -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=GENOME_FASTA&filename=$i.zip" -H "Accept: application/zip"; then
        break
      else
        log "Attempt $attempt failed, retrying in $((2**attempt * 50)) seconds..."
        sleep $((2**attempt * 50))
        if [ $attempt -eq 3 ]; then
          log "Error downloading file: $i.zip"
          continue 2
        fi
      fi
    done
  fi
done < "$OUTDIR/mapped.db"

log "Extracting downloaded files..."
# Extract files
for i in *.zip; do
  log "Extracting: $i"
  if ! unzip -p "$i" "*.fna" > "${i%.zip}.fna"; then
    log "Error extracting file: $i"
    continue
  fi
done

log "Processing empty files..."
# Process empty files
find . -name "*.fna" -size 0 > empty_list.txt
sed -i 's/^\.\///;s/\.fna$//' empty_list.txt
find . -name "*.fna" -size 0 -delete

log "Moving outputs to final location..."
# Move outputs
mv *.fna "$OUTDIR/genomes" 2>/dev/null || true
mv empty_list.txt "$OUTDIR/genomes/"

log "Step 2 completed successfully"
