#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 5: Concatenating and Zipping Results"

cd "$OUTDIR" || exit 1

log "Creating missing_fna.txt..."
# Create missing_fna.txt
touch genomes/empty_list2.txt
cat genomes/empty_list.txt genomes/empty_list2.txt > missing_fna.txt

log "Concatenating .fna files..."
# Concatenate and compress
cat genomes/*.fna > slimNT.db

log "Compressing final database..."
gzip slimNT.db

log "Step 5 completed successfully"
