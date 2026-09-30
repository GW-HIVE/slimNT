#!/usr/bin/env python3
"""
Fallback retrieval for proteomes the main pipeline couldn't map to a genome assembly.

For each proteome ID, queries the UniProt API to find RefSeq/GenBank nucleotide
accessions, then downloads FASTA via NCBI Entrez efetch.

Usage:
    # UPIDs that had no genome_assembly in mapped.db:
    python scripts/fetch_nucleotide_fallback.py \\
        --upids output/unmapped_proteomes.txt \\
        --outdir output/fallback_genomes

    # Assembly accessions that failed to download (reverse-looked up via assembly_to_upid.txt):
    python scripts/fetch_nucleotide_fallback.py \\
        --assemblies logs/2_failed_downloads.txt \\
        --assembly-map output/assembly_to_upid.txt \\
        --outdir output/fallback_genomes

Output:
    output/fallback_genomes/<UPID>.fna   — one FASTA per proteome
    logs/fallback_retrieval.jsonl        — structured log (one JSON object per event)
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


UNIPROT_PROTEOME = "https://rest.uniprot.org/proteomes/{upid}?format=json"
ENTREZ_EFETCH = (
    "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
    "?db=nuccore&id={acc}&rettype=fasta&retmode=text{api_key}"
)

# NCBI requests up to 3/sec without key, 10/sec with key
NCBI_DELAY = 0.35
UNIPROT_DELAY = 0.3

# Proteomes whose UniProt record has zero components (no nucleotide cross-references)
# but whose sequences exist in NCBI nuccore under known accessions. Use this for
# UPIDs that DO enter the pipeline via PIR lists but have no UniProt nucleotide links.
# For UPIDs absent from PIR entirely, put them (with accessions) in
# pipeline/supplemental_upids.txt instead.
MANUAL_ACCESSIONS: Dict[str, List[str]] = {
    # UP000101055: PERV-A has no UniProt components; sequences exist as standalone
    # NCBI records. AF038600.1 is the accession called out by the target replication
    # study; KY484771.1 was used in parallel studies.
    "UP000101055": ["AF038600.1", "KY484771.1"],
}


def _api_key_param() -> str:
    key = os.environ.get("NCBI_API_KEY", "")
    return f"&api_key={key}" if key else ""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _fetch(url: str, timeout: int = 30, binary: bool = False):
    """Return response body (str or bytes). Raises on HTTP error."""
    req = urllib.request.Request(url, headers={"Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read() if binary else resp.read().decode("utf-8", errors="replace")


def log_event(log_fh, **fields) -> None:
    fields.setdefault("timestamp", _now())
    print(json.dumps(fields), file=log_fh, flush=True)


# ── UniProt lookup ────────────────────────────────────────────────────────────

def get_nucleotide_accessions(upid: str) -> Tuple[List[str], dict]:
    """
    Query UniProt proteomes API and extract nucleotide accessions.
    Returns (accessions, raw_data_subset) for logging.
    """
    url = UNIPROT_PROTEOME.format(upid=upid)
    raw = _fetch(url)
    data = json.loads(raw)

    accessions: List[str] = []

    for component in data.get("components", []):
        # Pattern 1: genomeAccession is a list of strings or dicts
        for entry in component.get("genomeAccession", []):
            if isinstance(entry, str):
                accessions.append(entry)
            elif isinstance(entry, dict):
                val = entry.get("value") or entry.get("id") or entry.get("accession")
                if val:
                    accessions.append(val)

        # Pattern 2: proteomeCrossReferences list
        # UniProt uses database="GenomeAccession" for nucleotide cross-references.
        for xref in component.get("proteomeCrossReferences", []):
            db = xref.get("database", "")
            acc = xref.get("id") or xref.get("value")
            if db in ("GenomeAccession", "RefSeq", "GenBank", "EMBL", "ENA") and acc:
                accessions.append(acc)

    # Deduplicate, preserve order
    seen: Set[str] = set()
    unique = [a for a in accessions if not (a in seen or seen.add(a))]  # type: ignore[func-returns-value]

    summary = {
        "organism": data.get("taxonomy", {}).get("scientificName", ""),
        "genomeAssembly": (data.get("genomeAssembly") or {}).get("assemblyId"),
        "component_count": len(data.get("components", [])),
    }
    return unique, summary


# ── NCBI efetch ──────────────────────────────────────────────────────────────

def fetch_fasta(accession: str) -> str:
    """Download FASTA for a nucleotide accession via Entrez efetch."""
    url = ENTREZ_EFETCH.format(acc=accession, api_key=_api_key_param())
    text = _fetch(url)
    if not text.startswith(">"):
        raise ValueError(f"Unexpected efetch response (not FASTA): {text[:120]!r}")
    return text


# ── Per-proteome orchestration ────────────────────────────────────────────────

def recover_proteome(upid: str, outdir: Path, log_fh,
                     manual_accessions: Dict[str, List[str]]) -> bool:
    """
    Full recovery attempt for one proteome ID.
    Returns True if at least one sequence was written.
    """
    out_fna = outdir / f"{upid}.fna"
    if out_fna.exists() and out_fna.stat().st_size > 0:
        log_event(log_fh, event="skip", upid=upid, reason="already_exists", path=str(out_fna))
        return True

    # Step A: UniProt lookup
    try:
        time.sleep(UNIPROT_DELAY)
        accessions, summary = get_nucleotide_accessions(upid)
    except urllib.error.HTTPError as e:
        log_event(log_fh, event="uniprot_error", upid=upid,
                  http_status=e.code, error=str(e),
                  action="logged_for_investigation")
        return False
    except Exception as e:
        log_event(log_fh, event="uniprot_error", upid=upid,
                  error=str(e), action="logged_for_investigation")
        return False

    log_event(log_fh, event="uniprot_lookup", upid=upid,
              accessions_found=accessions, **summary)

    if not accessions:
        manual = manual_accessions.get(upid)
        if manual:
            log_event(log_fh, event="manual_accessions", upid=upid,
                      accessions=manual,
                      note="UniProt has no components; using known NCBI accessions")
            accessions = manual
        else:
            log_event(log_fh, event="no_accessions", upid=upid,
                      organism=summary.get("organism", ""),
                      action="logged_for_investigation",
                      note="No nucleotide accessions found in UniProt components")
            return False

    # Step B: efetch each accession
    fasta_parts: List[str] = []
    for acc in accessions:
        try:
            time.sleep(NCBI_DELAY)
            fasta = fetch_fasta(acc)
            fasta_parts.append(fasta)
            log_event(log_fh, event="efetch_ok", upid=upid, accession=acc,
                      sequences=fasta.count(">"))
        except urllib.error.HTTPError as e:
            log_event(log_fh, event="efetch_error", upid=upid, accession=acc,
                      http_status=e.code, error=str(e),
                      action="logged_for_investigation")
        except Exception as e:
            log_event(log_fh, event="efetch_error", upid=upid, accession=acc,
                      error=str(e), action="logged_for_investigation")

    if not fasta_parts:
        log_event(log_fh, event="all_efetch_failed", upid=upid,
                  accessions=accessions, action="logged_for_investigation")
        return False

    out_fna.write_text("".join(fasta_parts))
    log_event(log_fh, event="recovery_ok", upid=upid,
              path=str(out_fna), accessions=accessions,
              total_sequences=sum(f.count(">") for f in fasta_parts))
    return True


# ── Input helpers ─────────────────────────────────────────────────────────────

def load_upids(path: str) -> List[str]:
    return [l.strip() for l in Path(path).read_text().splitlines()
            if l.strip() and not l.startswith("#")]


def load_supplemental_accessions(path: str) -> Dict[str, List[str]]:
    """Parse supplemental_upids.txt for lines that carry accessions.
    Format: <UPID>  <acc1>[,<acc2>...]  (second column optional)
    Returns only entries that have at least one accession."""
    result: Dict[str, List[str]] = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            accessions = [a for a in parts[1].split(",") if a]
            if accessions:
                result[parts[0]] = accessions
    return result


def load_assembly_map(path: str) -> Dict[str, str]:
    """Load assembly_to_upid.txt → {assembly: upid}."""
    mapping: Dict[str, str] = {}
    for line in Path(path).read_text().splitlines():
        parts = line.strip().split("\t")
        if len(parts) == 2:
            mapping[parts[0]] = parts[1]
    return mapping


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--upids", metavar="FILE",
                        help="File of proteome IDs (one per line) to recover")
    parser.add_argument("--assemblies", metavar="FILE",
                        help="File of failed assembly accessions; requires --assembly-map")
    parser.add_argument("--assembly-map", metavar="FILE",
                        help="Tab-separated assembly→upid file (assembly_to_upid.txt)")
    parser.add_argument("--outdir", metavar="DIR", default="output/fallback_genomes",
                        help="Directory for recovered .fna files (default: output/fallback_genomes)")
    parser.add_argument("--log", metavar="FILE", default="logs/fallback_retrieval.jsonl",
                        help="JSON-lines log path (default: logs/fallback_retrieval.jsonl)")
    parser.add_argument("--supplemental", metavar="FILE",
                        help="supplemental_upids.txt — UPIDs with accessions in column 2 "
                             "are added to the manual accession lookup")
    parser.add_argument("--delay", type=float, default=None,
                        help="Override inter-request delay in seconds")
    args = parser.parse_args()

    if not args.upids and not args.assemblies:
        parser.error("Provide --upids, --assemblies, or both.")
    if args.assemblies and not args.assembly_map:
        parser.error("--assemblies requires --assembly-map.")

    global NCBI_DELAY, UNIPROT_DELAY
    if args.delay is not None:
        NCBI_DELAY = UNIPROT_DELAY = args.delay

    manual_accessions = dict(MANUAL_ACCESSIONS)
    if args.supplemental and Path(args.supplemental).exists():
        from_suppl = load_supplemental_accessions(args.supplemental)
        manual_accessions.update(from_suppl)
        if from_suppl:
            print(f"Loaded {len(from_suppl)} accession mapping(s) from supplemental file",
                  file=sys.stderr)

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    Path(args.log).parent.mkdir(parents=True, exist_ok=True)

    # Collect UPIDs from both sources
    upids: List[str] = []
    if args.upids:
        upids.extend(load_upids(args.upids))

    if args.assemblies:
        assembly_map = load_assembly_map(args.assembly_map)
        for asm in load_upids(args.assemblies):
            upid = assembly_map.get(asm)
            if upid:
                upids.append(upid)
            else:
                print(f"WARNING: no UPID found for assembly {asm!r} — skipping", file=sys.stderr)

    # Deduplicate, preserving order
    seen: Set[str] = set()
    upids = [u for u in upids if not (u in seen or seen.add(u))]  # type: ignore[func-returns-value]

    if not upids:
        sys.exit("No valid proteome IDs to process.")

    print(f"Processing {len(upids)} proteome IDs → {outdir}", file=sys.stderr)
    print(f"Logging to {args.log}", file=sys.stderr)

    recovered = 0
    with open(args.log, "a") as log_fh:
        log_event(log_fh, event="session_start", total_upids=len(upids),
                  outdir=str(outdir))
        for i, upid in enumerate(upids, 1):
            print(f"  [{i}/{len(upids)}] {upid}", file=sys.stderr)
            if recover_proteome(upid, outdir, log_fh, manual_accessions):
                recovered += 1
        log_event(log_fh, event="session_end",
                  total=len(upids), recovered=recovered,
                  failed=len(upids) - recovered)

    print(f"\nDone: {recovered}/{len(upids)} recovered. "
          f"{len(upids) - recovered} logged for investigation → {args.log}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
