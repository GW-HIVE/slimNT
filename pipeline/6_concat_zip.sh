#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 6: Concatenating and Zipping Results"

cd "$OUTDIR" || exit 1

log "Creating missing_fna.txt..."
touch genomes/empty_list2.txt
cat genomes/empty_list.txt genomes/empty_list2.txt > missing_fna.txt

log "Concatenating .fna files..."
cat genomes/*.fna > slimNT.fa
if ls fallback_genomes/*.fna 1>/dev/null 2>&1; then
  log "Including fallback_genomes/ FNA files..."
  cat fallback_genomes/*.fna >> slimNT.fa
fi

log "Compressing final database..."
gzip slimNT.fa

logstepend "Step 6 completed successfully"
