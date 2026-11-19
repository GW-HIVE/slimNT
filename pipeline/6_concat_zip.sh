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
# Every sequence ID is written once (makeblastdb -parse_seqids rejects repeats).
# Genome FNAs can share records: a host bacterium's assembly can include a
# prophage that UniProt also maps to its own phage-only assembly. The first
# copy in manifest order is kept and later ones are dropped while streaming. Any
# fallback record whose ID is in a genome FNA, or earlier in the fallback set,
# is dropped too. No input files are modified. Dropped records are listed in
# logs/6_dropped_records.txt (id, reason, and the source file for genome FNAs).
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
DROPPED="$LOGDIR/6_dropped_records.txt"
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

FB_IDS="$LOGDIR/.6_fallback_ids.txt"
GEN_IDS="$LOGDIR/.6_genome_ids.txt"
GEN_DROP="$LOGDIR/.6_genome_drops.txt"
OVERLAP="$LOGDIR/.6_overlap_ids.txt"

log "Collecting fallback record IDs..."
# grep exits 1 when an xargs batch has no matches, so its status is not checked
# here; unreadable files are caught by the concatenation below.
xargs -d '\n' -r grep -h '^>' < "$FB_LIST" \
  | awk '{ print substr($1, 2) }' | LC_ALL=C sort -u > "$FB_IDS" || true

# Every genome header as "id <TAB> manifest position <TAB> file", sorted by ID
# and then position, so all copies of an ID are adjacent and the first one in
# manifest order (the one kept) comes first.
log "Scanning genome FNA headers for repeated IDs (reads every genome FNA)..."
xargs -d '\n' -r grep -H '^>' < "$GEN_LIST" \
  | awk -v G="$GEN_LIST" '
      FILENAME == G { pos[$0] = FNR; next }
      {
        p = index($0, ":>")
        f = substr($0, 1, p - 1)
        id = substr($0, p + 2); sub(/[ \t].*/, "", id)
        if (id != "") print id "\t" pos[f] "\t" f
      }' "$GEN_LIST" - \
  | LC_ALL=C sort -t$'\t' -k1,1 -k2,2n -S 2G -T "$LOGDIR" > "$GEN_IDS" || true

# Later copies to drop, as "file <TAB> id <TAB> keepfirst": keepfirst is 1 when
# that file also holds the kept copy (repeat within one file), else 0.
awk -F'\t' '
  $1 != id { id = $1; keeper = $3; next }
  { print $3 "\t" $1 "\t" ($3 == keeper) }
' "$GEN_IDS" | LC_ALL=C sort -u > "$GEN_DROP"
log "IDs repeated in genome FNAs: $(cut -f2 "$GEN_DROP" | LC_ALL=C sort -u | wc -l) (later copies dropped)"

: > "$OVERLAP"
if [[ -s "$FB_IDS" ]]; then
  cut -f1 "$GEN_IDS" | LC_ALL=C uniq | LC_ALL=C comm -12 - "$FB_IDS" > "$OVERLAP"
  log "Fallback IDs ($(wc -l < "$FB_IDS")) already present in genome FNAs: $(wc -l < "$OVERLAP")"
fi

# Genome FNAs listed in GEN_DROP go through an awk filter; the rest are copied
# with plain cat, in batches, keeping manifest order.
declare -A FILTER
while IFS=$'\t' read -r f _; do FILTER[$f]=1; done < "$GEN_DROP"

cat_genomes() {
  if (( ${#FILTER[@]} == 0 )); then
    xargs -d '\n' -r cat < "$GEN_LIST"
    return
  fi
  local batch=() f
  while IFS= read -r f; do
    if [[ -z "${FILTER[$f]:-}" ]]; then
      batch+=("$f")
      (( ${#batch[@]} < 500 )) && continue
    else
      if (( ${#batch[@]} )); then cat "${batch[@]}" || return 1; fi
      batch=()
      awk -v F="$f" -v L="$GEN_DROP" -v D="$DROPPED" '
        FILENAME == L {
          split($0, a, "\t")
          if (a[1] == F) { drop[a[2]]; keepfirst[a[2]] = a[3] }
          next
        }
        /^>/ {
          id = substr($1, 2)
          keep = !(id in drop) || (keepfirst[id] && ++n[id] == 1)
          if (!keep) print id "\t" (keepfirst[id] ? "repeated_in_file" : "in_earlier_genome_fna") "\t" F >> D
        }
        keep
      ' "$GEN_DROP" "$f" || return 1
      continue
    fi
    cat "${batch[@]}" || return 1
    batch=()
  done < "$GEN_LIST"
  if (( ${#batch[@]} )); then cat "${batch[@]}" || return 1; fi
}

log "Concatenating $(wc -l < "$MANIFEST") file(s) into $TMP..."
rm -f "$TMP"
: > "$DROPPED"
if ! cat_genomes > "$TMP"; then
  rm -f "$TMP"
  log "ERROR: failed while concatenating genome FNAs"
  exit 1
fi

# Fallback records: drop any whose ID is in a genome FNA or was already written.
if ! xargs -d '\n' -r cat < "$FB_LIST" \
    | awk -v O="$OVERLAP" -v D="$DROPPED" '
        FILENAME == O { drop[$1]; next }
        /^>/ {
          id = substr($1, 2)
          keep = !(id in drop) && !(id in seen)
          if (!keep) print id "\t" ((id in drop) ? "in_genome_fna" : "repeated_in_fallback") >> D
          seen[id]
        }
        keep
      ' "$OVERLAP" - >> "$TMP"; then
  rm -f "$TMP"
  log "ERROR: failed while concatenating fallback FNAs"
  exit 1
fi
dropped=$(wc -l < "$DROPPED")
(( dropped > 0 )) && log "Dropped $dropped duplicate record(s); see $DROPPED"

mv -f "$TMP" slimNT.fa
rm -f "$FB_IDS" "$GEN_IDS" "$GEN_DROP" "$OVERLAP"
log "slimNT.fa: $(du -h --apparent-size slimNT.fa | cut -f1); manifest: $MANIFEST"

# slimNT.fa is left uncompressed: the next step is makeblastdb, which reads it directly.

logstepend "Step 6 completed successfully"
