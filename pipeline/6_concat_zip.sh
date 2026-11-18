#!/bin/bash
# Step 6: build slimNT.fa from an explicit manifest.
#
# Only these files are included:
#   - one genome FNA per assembly in mapped.db (or its alternate), from
#     resolve_genomes in config.sh
#   - fallback_genomes/<UPID>.fna for each UPID in fallback_queue.txt (step 5)
# Any other *.fna in genomes/ or fallback_genomes/ (leftovers from earlier runs,
# shared caches, runaway downloads) is reported and left out.
#
# Fallback records whose sequence ID already appears in an included genome FNA,
# or earlier in the fallback set, are dropped while streaming; no input files
# are modified. Dropped IDs are listed in logs/6_dropped_fallback_records.txt.
#
# Outputs:
#   slimNT.fa           (written to a temp file, renamed on success)
#   slimNT.manifest.txt (the exact files concatenated, in order)
#   missing_fna.txt     (assemblies with no FNA under either accession)

source "$(dirname "$0")/config.sh"
set -o pipefail

logstepstart "Starting Step 6: Concatenating Results"

cd "$OUTDIR" || exit 1

for f in mapped.db unmapped_proteomes.txt; do
  if [[ ! -f "$f" ]]; then
    log "ERROR: $OUTDIR/$f not found. Run step 1 first."
    exit 1
  fi
done
if [[ ! -f fallback_queue.txt ]]; then
  log "ERROR: $OUTDIR/fallback_queue.txt not found. Run step 5 first."
  exit 1
fi

GEN_LIST="$LOGDIR/6_genome_fnas.txt"
FB_LIST="$LOGDIR/6_fallback_fnas.txt"
DROPPED="$LOGDIR/6_dropped_fallback_records.txt"
MANIFEST=slimNT.manifest.txt
TMP=slimNT.fa.part

log "Resolving genome FNAs from mapped.db..."
resolve_genomes "$GEN_LIST" missing_fna.txt
log "Genome FNAs: $(wc -l < "$GEN_LIST"); assemblies with no FNA: $(wc -l < missing_fna.txt) (missing_fna.txt)"

: > "$FB_LIST"
while IFS= read -r upid; do
  [[ -s "fallback_genomes/$upid.fna" ]] && echo "fallback_genomes/$upid.fna" >> "$FB_LIST"
done < fallback_queue.txt
log "Fallback FNAs: $(wc -l < "$FB_LIST") of $(wc -l < fallback_queue.txt) queued UPIDs"

# Report files on disk that are not part of this build.
report_extras() {
  local dir="$1" list="$2"
  find "$dir" -maxdepth 1 -name '*.fna' -printf '%p\t%s\n' 2>/dev/null \
    | awk -F'\t' -v L="$list" '
        FILENAME == L { keep[$1]; next }
        !($1 in keep) { n++; s += $2 }
        END { if (n) printf "%d file(s), %.2f GiB\n", n, s / 2^30 }
      ' "$list" -
}
for pair in "genomes:$GEN_LIST" "fallback_genomes:$FB_LIST"; do
  extra=$(report_extras "${pair%%:*}" "${pair#*:}")
  [[ -n "$extra" ]] && log "NOTE: ${pair%%:*}/ has FNAs not in this build, excluded: $extra"
done

cat "$GEN_LIST" "$FB_LIST" > "$MANIFEST"

log "Collecting fallback record IDs..."
FB_IDS="$LOGDIR/.6_fallback_ids.txt"
OVERLAP="$LOGDIR/.6_overlap_ids.txt"
# grep exits 1 when an xargs batch has no matches, so its status is not checked
# here; unreadable files are caught by the concatenation below.
xargs -d '\n' -r grep -h '^>' < "$FB_LIST" \
  | awk '{ print substr($1, 2) }' | LC_ALL=C sort -u > "$FB_IDS" || true

: > "$OVERLAP"
if [[ -s "$FB_IDS" ]]; then
  log "Scanning genome headers for $(wc -l < "$FB_IDS") fallback ID(s) (reads every genome FNA)..."
  xargs -d '\n' -r grep -h '^>' < "$GEN_LIST" \
    | awk -v W="$FB_IDS" '
        FILENAME == W { want[$1]; next }
        { id = substr($1, 2); if (id in want) print id }
      ' "$FB_IDS" - | LC_ALL=C sort -u > "$OVERLAP" || true
  log "Fallback IDs already present in genome FNAs: $(wc -l < "$OVERLAP")"
fi

log "Concatenating $(wc -l < "$MANIFEST") file(s) into $TMP..."
rm -f "$TMP"
if ! xargs -d '\n' -r cat < "$GEN_LIST" > "$TMP"; then
  rm -f "$TMP"
  log "ERROR: failed while concatenating genome FNAs"
  exit 1
fi

# Fallback records: drop any whose ID is in a genome FNA or was already written.
: > "$DROPPED"
if ! xargs -d '\n' -r cat < "$FB_LIST" \
    | awk -v O="$OVERLAP" -v D="$DROPPED" '
        FILENAME == O { drop[$1]; next }
        /^>/ {
          id = substr($1, 2)
          keep = !(id in drop) && !(id in seen)
          if (!keep) print id "\t" ((id in drop) ? "in_genome_fna" : "repeated_in_fallback") > D
          seen[id]
        }
        keep
      ' "$OVERLAP" - >> "$TMP"; then
  rm -f "$TMP"
  log "ERROR: failed while concatenating fallback FNAs"
  exit 1
fi
dropped=$(wc -l < "$DROPPED")
(( dropped > 0 )) && log "Dropped $dropped duplicate fallback record(s); see $DROPPED"

mv -f "$TMP" slimNT.fa
rm -f "$FB_IDS" "$OVERLAP"
log "slimNT.fa: $(du -h --apparent-size slimNT.fa | cut -f1); manifest: $MANIFEST"

# slimNT.fa is left uncompressed: the next step is makeblastdb, which reads it directly.

logstepend "Step 6 completed successfully"
