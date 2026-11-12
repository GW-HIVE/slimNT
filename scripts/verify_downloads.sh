#!/bin/bash
# Verify that all expected genome downloads are present and non-empty
# in a slimNT output directory before rebuilding final artifacts.
#
# Usage: verify_downloads.sh /data/slimNT/v3.1

set -euo pipefail

OUTDIR="${1:-}"
if [[ -z "$OUTDIR" ]]; then
  echo "Usage: $0 /path/to/slimNT/output" >&2
  exit 1
fi

if [[ ! -d "$OUTDIR" ]]; then
  echo "ERROR: Directory not found: $OUTDIR" >&2
  exit 1
fi

GENOME_DIR="$OUTDIR/genomes"
FALLBACK_DIR="$OUTDIR/fallback_genomes"
ASM_MAP="$OUTDIR/assembly_to_upid.txt"
UNMAPPED="$OUTDIR/unmapped_proteomes.txt"

pass=0
warn=0
fail=0

ok()   { echo "  [OK]   $*"; (( pass++ )) || true; }
warn() { echo "  [WARN] $*"; (( warn++ )) || true; }
fail() { echo "  [FAIL] $*"; (( fail++ )) || true; }

echo "=== slimNT download verification: $OUTDIR"
echo "    $(date)"
echo ""

# ── 1. assembly_to_upid.txt ───────────────────────────────────────────────────
echo "── Genome assemblies (assembly_to_upid.txt → genomes/*.fna) ──"

if [[ ! -f "$ASM_MAP" ]]; then
  fail "assembly_to_upid.txt not found — was step 1 completed?"
else
  total_asm=$(wc -l < "$ASM_MAP")
  ok "assembly_to_upid.txt: $total_asm entries"

  # Build sorted lists and diff with comm — one pass each, no per-file stat calls
  expected=$(awk '{print $1}' "$ASM_MAP" | sort)
  actual=$(find "$GENOME_DIR" -maxdepth 1 -name "*.fna" -printf "%f\n" \
           | sed 's/\.fna$//' | sort)

  missing_asm=$(comm -23 <(echo "$expected") <(echo "$actual"))
  missing_count=$(echo "$missing_asm" | grep -c . || true)

  zero_asm=$(find "$GENOME_DIR" -maxdepth 1 -name "*.fna" -empty -printf "%f\n" \
             | sed 's/\.fna$//' | sort)
  zero_count=$(echo "$zero_asm" | grep -c . || true)

  present=$(( total_asm - missing_count - zero_count ))
  ok "FNAs present and non-empty: $present / $total_asm"

  if (( zero_count > 0 )); then
    warn "$zero_count FNA(s) are zero bytes:"
    echo "$zero_asm" | while read -r acc; do
      upid=$(awk -v a="$acc" '$1==a{print $2}' "$ASM_MAP")
      echo "         $acc ($upid)"
    done
  fi

  if (( missing_count > 0 )); then
    # Cross-check: some may have been recovered via fallback by UPID
    recovered_via_fallback=0
    truly_missing=0
    echo "$missing_asm" | while read -r acc; do
      upid=$(awk -v a="$acc" '$1==a{print $2}' "$ASM_MAP")
      if [[ -s "$FALLBACK_DIR/${upid}.fna" ]]; then
        echo "  [OK]   $acc ($upid) — missing from genomes/ but recovered in fallback_genomes/"
      else
        echo "  [FAIL] $acc ($upid) — not in genomes/ or fallback_genomes/"
      fi
    done
    # Recount truly missing for summary (approximate — subshell above can't update counters)
    truly_missing=$(echo "$missing_asm" | while read -r acc; do
      upid=$(awk -v a="$acc" '$1==a{print $2}' "$ASM_MAP")
      [[ ! -s "$FALLBACK_DIR/${upid}.fna" ]] && echo "$acc"
    done | grep -c . || true)
    if (( truly_missing > 0 )); then
      fail "$truly_missing assembly FNA(s) unrecovered (not in genomes/ or fallback_genomes/)"
    else
      ok "All $missing_count missing assembly FNAs were recovered via fallback"
    fi
  else
    ok "No missing assembly FNAs"
  fi
fi

echo ""

# ── 2. fallback_genomes/ ─────────────────────────────────────────────────────
echo "── Fallback genomes (unmapped_proteomes.txt → fallback_genomes/*.fna) ──"

if [[ ! -f "$UNMAPPED" ]]; then
  warn "unmapped_proteomes.txt not found — skipping fallback check"
elif [[ ! -d "$FALLBACK_DIR" ]]; then
  warn "fallback_genomes/ directory not found"
else
  total_unmapped=$(wc -l < "$UNMAPPED")
  ok "unmapped_proteomes.txt: $total_unmapped entries"

  fallback_fnas=$(find "$FALLBACK_DIR" -maxdepth 1 -name "*.fna" | wc -l)
  ok "fallback_genomes/ FNA count: $fallback_fnas"

  zero_fallback=$(find "$FALLBACK_DIR" -maxdepth 1 -name "*.fna" -empty | wc -l)
  if (( zero_fallback > 0 )); then
    warn "$zero_fallback zero-byte FNA(s) in fallback_genomes/"
    find "$FALLBACK_DIR" -maxdepth 1 -name "*.fna" -empty | sort | \
      while read -r f; do echo "         $(basename "$f")"; done
  else
    ok "No zero-byte fallback FNAs"
  fi

  # Check fallback_retrieval.jsonl for no_accessions count
  FALLBACK_LOG="$OUTDIR/logs/fallback_retrieval.jsonl"
  if [[ -f "$FALLBACK_LOG" ]]; then
    # Parse the session_end summary line written by fetch_nucleotide_fallback.py
    session_end=$(grep '"event":"session_end"' "$FALLBACK_LOG" | tail -1)
    if [[ -n "$session_end" ]]; then
      fl_total=$(echo "$session_end" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null) || fl_total="?"
      fl_rec=$(echo "$session_end"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('recovered',0))" 2>/dev/null) || fl_rec="?"
      fl_fail=$(echo "$session_end"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('failed',0))" 2>/dev/null) || fl_fail="?"
      no_acc=$(grep -c '"event":"no_accessions"' "$FALLBACK_LOG" 2>/dev/null) || no_acc=0
      errors=$(grep -c '"event":"uniprot_error"' "$FALLBACK_LOG" 2>/dev/null) || errors=0
      ok "Fallback log: $fl_rec/$fl_total recovered, $no_acc no_accessions, $errors uniprot_errors, $fl_fail total failed"
    else
      warn "No session_end entry in fallback log — run may have been incomplete"
    fi
  else
    warn "logs/fallback_retrieval.jsonl not found — cannot summarise fallback outcomes"
  fi
fi

echo ""

# ── 3. Final artifact ─────────────────────────────────────────────────────────
echo "── Existing final artifact ──"

for f in slimNT.fa slimNT.fa.gz; do
  full="$OUTDIR/$f"
  if [[ -f "$full" ]]; then
    size=$(du --apparent-size -sh "$full" | cut -f1)
    ok "$f exists ($size)"
  else
    warn "$f not found"
  fi
done

echo ""

# ── 4. Summary ───────────────────────────────────────────────────────────────
echo "── Summary ──"
echo "  PASS: $pass   WARN: $warn   FAIL: $fail"
echo ""

if (( fail > 0 )); then
  echo "RESULT: NOT safe to proceed — fix failures above before rebuilding."
  exit 1
elif (( warn > 0 )); then
  echo "RESULT: Proceed with caution — review warnings above."
  exit 0
else
  echo "RESULT: All checks passed — safe to rebuild artifacts."
  exit 0
fi
