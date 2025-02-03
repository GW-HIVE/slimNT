#!/bin/bash

source config.sh

mkdir -p "$OUTDIR/genomes"

# Read mapped.db and download genomes
while IFS= read -r i; do
  if [ ! -f "$i.zip" ]; then
    for attempt in {1..3}; do
      if curl -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=GENOME_FASTA&filename=$i.zip" -H "Accept: application/zip"; then
        break
      else
        sleep $((2**attempt * 50))
        if [ $attempt -eq 3 ]; then
          echo "Error downloading file: $i.zip" >&2
          continue 2
        fi
      fi
    done
  fi
done < "$OUTDIR/mapped.db"

# Extract files
for i in *.zip; do
  if ! unzip -p "$i" "*.fna" > "${i%.zip}.fna"; then
    echo "Error extracting file: $i" >&2
    continue
  fi
done

# Process empty files
find . -name "*.fna" -size 0 > empty_list.txt
sed -i 's/^\.\///;s/\.fna$//' empty_list.txt
find . -name "*.fna" -size 0 -delete

# Move outputs
mv *.fna "$OUTDIR/genomes" 2>/dev/null || true
mv empty_list.txt "$OUTDIR/genomes/"
