#!/bin/bash

source config.sh

cd "$OUTDIR/genomes" || exit 1

# Only proceed if alt_ids.txt exists and is not empty
if [ -s alt_ids.txt ]; then
    while IFS= read -r i; do
        i=$(echo "$i" | tr -d '[:space:]')
        url="https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=CDS_FASTA&filename=$i.zip"
        echo "Downloading $url"
        curl -OJX GET "$url" -H "Accept: application/zip"
    done < "alt_ids.txt"

    # Extract files
    for i in *.zip; do
        echo "Extracting: $i"
        unzip -p "$i" "*.fna" > "${i%.zip}.fna" || true
    done

    # Process empty files
    find . -name "*.fna" -size 0 > empty_list2.txt
    sed -i 's/^\.\///;s/\.fna$//' empty_list2.txt
    find . -name "*.fna" -size 0 -delete
fi
