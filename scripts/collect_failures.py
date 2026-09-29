#!/usr/bin/env python3
"""
Collect and categorize pipeline failures for curator review.

Reads all failure logs from a completed (or partial) pipeline run and
produces a TSV summarizing every unresolved proteome with organism name,
failure stage, and failure mode.

Failure stages (in pipeline order):
  1-no_genome_assembly    UniProt has no genome_assembly field → never entered mapped.db
  2-download_failed       NCBI datasets download failed for the assembly
  4-download_failed       Alternate assembly download failed (step 4)
  4-extraction_failed     ZIP downloaded but contained no *.fna (flat nucleotide records)
  4-empty_fna             Alternate download produced an empty FASTA
  5-uniprot_not_found     Fallback: UniProt returned 404 for this UPID
  5-no_uniprot_accessions Fallback: UniProt found the proteome but has no nucleotide xrefs
  5-efetch_failed         Fallback: accessions found but NCBI efetch failed for all of them

Usage:
    python scripts/collect_failures.py --outdir /path/to/slimNT_data
    python scripts/collect_failures.py --outdir /path/to/slimNT_data -o failures.tsv
"""

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional


def load_lines(path):
    p = Path(path)
    if not p.exists() or not p.stat().st_size:
        return []
    return [l.strip() for l in p.read_text().splitlines()
            if l.strip() and not l.startswith("#")]


def load_mapping(path):
    """UniProt mapping.txt → {upid: {organism, organism_id, genome_assembly}}"""
    result = {}
    p = Path(path)
    if not p.exists():
        return result
    for line in p.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        upid = parts[0].strip()
        if not upid.startswith("UP"):
            continue
        result[upid] = {
            "organism":        parts[1].strip() if len(parts) > 1 else "",
            "organism_id":     parts[2].strip() if len(parts) > 2 else "",
            "genome_assembly": parts[3].strip() if len(parts) > 3 else "",
        }
    return result


def load_asm_map(path):
    """assembly_to_upid.txt → {assembly: upid}"""
    result = {}
    for line in load_lines(path):
        parts = line.split("\t")
        if len(parts) == 2:
            result[parts[0].strip()] = parts[1].strip()
    return result


def load_fallback_log(path):
    """
    Parse fallback_retrieval.jsonl → {upid: final_event_object}.
    Only keeps terminal events per UPID.
    """
    terminal = {"recovery_ok", "no_accessions", "uniprot_error", "all_efetch_failed"}
    result = {}
    p = Path(path)
    if not p.exists():
        return result
    for line in p.read_text().splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        upid = obj.get("upid")
        if upid and obj.get("event") in terminal:
            result[upid] = obj
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--outdir", required=True,
                        help="Pipeline output directory")
    parser.add_argument("-o", "--output", default=None,
                        help="Output TSV path (default: stdout)")
    args = parser.parse_args()

    outdir = Path(args.outdir)
    logdir = outdir / "logs"

    mapping     = load_mapping(outdir / "mapping.txt")
    asm_to_upid = load_asm_map(outdir / "assembly_to_upid.txt")
    fallback    = load_fallback_log(logdir / "fallback_retrieval.jsonl")

    # failures: {upid_or_asm_key: row_dict}
    failures: Dict[str, dict] = {}

    def record(key, stage, mode, assembly="", notes=""):
        if key not in failures:
            failures[key] = {"stage": stage, "mode": mode,
                             "assembly": assembly, "notes": notes}

    def asm_key(asm):
        upid = asm_to_upid.get(asm, "")
        return upid if upid else asm

    # Stage 1
    for upid in load_lines(outdir / "unmapped_proteomes.txt"):
        record(upid, "1-no_genome_assembly", "no_genome_assembly_in_uniprot")

    # Stage 2
    for asm in load_lines(logdir / "2_failed_downloads.txt"):
        key = asm_key(asm)
        record(key, "2-download_failed", "ncbi_download_failed", assembly=asm,
               notes="" if key != asm else "no upid mapping")

    # Stage 4: alternate download failures
    for asm in load_lines(logdir / "4_failed_downloads.txt"):
        key = asm_key(asm)
        record(key, "4-download_failed", "ncbi_alternate_download_failed", assembly=asm,
               notes="" if key != asm else "no upid mapping")

    # Stage 4: extraction failures (ZIP has no *.fna)
    for asm in load_lines(logdir / "4_extraction_failed.txt"):
        key = asm_key(asm)
        record(key, "4-extraction_failed", "zip_contains_no_fna", assembly=asm,
               notes="" if key != asm else "no upid mapping")

    # Stage 4: empty alternate FNAs
    for asm in load_lines(outdir / "genomes" / "empty_list2.txt"):
        key = asm_key(asm)
        record(key, "4-empty_fna", "alternate_download_empty", assembly=asm,
               notes="" if key != asm else "no upid mapping")

    # Stage 5: fallback terminal events — refine or remove existing entries
    for upid, obj in fallback.items():
        ev = obj.get("event")

        if ev == "recovery_ok":
            failures.pop(upid, None)
            continue

        if ev == "no_accessions":
            stage, mode, notes = "5-no_uniprot_accessions", "no_nucleotide_xrefs_in_uniprot", ""
        elif ev == "uniprot_error":
            stage, mode, notes = "5-uniprot_not_found", "uniprot_404", ""
        elif ev == "all_efetch_failed":
            accs = obj.get("accessions", [])
            stage, mode = "5-efetch_failed", "ncbi_efetch_failed"
            notes = "accessions tried: " + ",".join(accs)
        else:
            continue

        if upid in failures:
            failures[upid].update(stage=stage, mode=mode, notes=notes)
        else:
            record(upid, stage, mode, notes=notes)

    # Build output rows
    rows = []
    for key, info in failures.items():
        upid = key if key.startswith("UP") else ""
        meta = mapping.get(upid, {}) if upid else {}
        rows.append({
            "upid":        upid or key,
            "organism":    meta.get("organism", ""),
            "organism_id": meta.get("organism_id", ""),
            "assembly":    info["assembly"] or meta.get("genome_assembly", ""),
            "stage":       info["stage"],
            "mode":        info["mode"],
            "notes":       info["notes"],
        })

    rows.sort(key=lambda r: (r["stage"], r["organism"].lower()))

    fieldnames = ["upid", "organism", "organism_id", "assembly", "stage", "mode", "notes"]
    out_fh = open(args.output, "w", newline="") if args.output else sys.stdout
    writer = csv.DictWriter(out_fh, fieldnames=fieldnames, delimiter="\t",
                            lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    if args.output:
        out_fh.close()

    stage_counts = Counter(r["stage"] for r in rows)
    print(f"\n{len(rows)} unresolved failures:", file=sys.stderr)
    for stage, count in sorted(stage_counts.items()):
        print(f"  {count:>4}  {stage}", file=sys.stderr)


if __name__ == "__main__":
    main()
