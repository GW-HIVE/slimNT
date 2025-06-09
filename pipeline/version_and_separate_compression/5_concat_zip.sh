#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 5: Concatenating the Results"

cd "$OUTDIR" || exit 1

log "Creating missing_fna.txt..."
# Create missing_fna.txt
touch genomes/empty_list2.txt
cat genomes/empty_list.txt genomes/empty_list2.txt > missing_fna.txt

log "Concatenating .fna files into slimNT_${VERSION}.fa..."
# Concatenate
cat genomes/*.fna > slimNT_${VERSION}.fa    #added the test_ so I can compare outputs

#Commenting out the Compressing
#log "Compressing final database..."
#gzip slimNT_test3.fa

logstepend "Step 5 completed successfully"
