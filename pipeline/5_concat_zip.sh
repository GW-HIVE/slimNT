#!/bin/bash

source config.sh


cd "$OUTDIR" || exit 1

# Create missing_fna.txt
touch genomes/empty_list2.txt
cat genomes/empty_list.txt empty_list2.txt > missing_fna.txt

# Concatenate and compress
cat genomes/*.fna > slimNT.db
gzip slimNT.db
