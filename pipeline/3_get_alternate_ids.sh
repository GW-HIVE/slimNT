#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 3: Getting Alternate IDs"

cd "$OUTDIR/genomes" || exit 1

# Assemblies that need an alternate accession: FNAs that came out empty in
# step 2, plus assemblies whose download failed outright.
cat empty_list.txt "$LOGDIR/2_failed_downloads.txt" 2>/dev/null \
  | tr -d '\r ' | awk NF | sort -u > need_alt.txt

: > alt_map.txt
: > alt_ids.txt

if [[ ! -s need_alt.txt ]]; then
  log "No empty or failed assemblies; no alternates needed."
  logstepend "Step 3 completed (nothing to do)"
  exit 0
fi
log "$(wc -l < need_alt.txt) assembly(ies) need an alternate accession"

log "Downloading assembly summary..."
SUMMARY=assembly_summary_refseq.txt
if ! wget -q -O "$SUMMARY.part" https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt \
    || [[ ! -s "$SUMMARY.part" ]]; then
  rm -f "$SUMMARY.part"
  log "ERROR: failed to download $SUMMARY"
  exit 1
fi
mv -f "$SUMMARY.part" "$SUMMARY"

# Column 1 = RefSeq accession (GCF_), column 18 = paired GenBank accession (GCA_).
awk -F'\t' '!/^#/ && $18 != "" && $18 != "na" { print $1 "\t" $18 }' "$SUMMARY" > ref_gen_map.txt
rm -f "$SUMMARY"

log "Matching alternates..."
# alt_map.txt: <original accession> TAB <alternate accession>.
# Steps 5 and 6 use it to recognise an assembly recovered under its alternate.
awk -F'\t' -v NEED="need_alt.txt" '
  FILENAME == NEED { need[$1]; next }
  ($1 in need) { print $1 "\t" $2 }
  ($2 in need) { print $2 "\t" $1 }
' need_alt.txt ref_gen_map.txt | sort -u > alt_map.txt
cut -f2 alt_map.txt | sort -u > alt_ids.txt

log "Found alternates for $(cut -f1 alt_map.txt | sort -u | wc -l) of $(wc -l < need_alt.txt) assembly(ies)"

logstepend "Step 3 completed successfully"
