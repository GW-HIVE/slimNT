#!/usr/bin/env python3
"""
Diagnostic: trace RSV / PERV proteome IDs through the slimNT mapping chain.

Checks each proteome ID against:
  1. UniProt proteomes API  → does a genome_assembly field exist?
  2. NCBI datasets API      → is that assembly accession downloadable?

Usage:
    python scripts/check_proteome_mapping.py
    python scripts/check_proteome_mapping.py --ids UP000002472 UP000101055
    python scripts/check_proteome_mapping.py --rpg data/rpg-95.txt --filter "respiratory syncytial|porcine endogenous"
"""

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Dict, List, Optional, Tuple


UNIPROT_API = "https://rest.uniprot.org/proteomes/{upid}?format=json"
NCBI_CHECK = (
    "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/{acc}/dataset_report"
    "?include_annotation_type=GENOME_FASTA"
)

# Default targets if no --ids or --rpg given
DEFAULT_IDS = {
    # RSV
    "UP000002472": "Human RSV B (strain B1)",
    "UP000007616": "Bovine RSV (strain A51908)",
    "UP000103294": "Human RSV",
    "UP000134464": "Human RSV A (strain A2)",
    "UP000136827": "RSV type A",
    "UP000259912": "Human RSV B",
    # PERV
    "UP000101055": "Porcine endogenous retrovirus A",
    "UP000104185": "Porcine endogenous retrovirus B",
    "UP000150221": "Porcine endogenous retrovirus",
    "UP000170184": "Porcine endogenous retrovirus C",
}


class ProteomeResult:
    def __init__(self, upid, label, uniprot_found=False, genome_assembly=None,
                 ncbi_found=None, ncbi_fasta_available=None, error=None):
        self.upid = upid
        self.label = label
        self.uniprot_found = uniprot_found
        self.genome_assembly = genome_assembly
        self.ncbi_found = ncbi_found
        self.ncbi_fasta_available = ncbi_fasta_available
        self.error = error


def fetch_json(url: str, timeout: int = 15) -> Optional[dict]:
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    except Exception as e:
        raise RuntimeError(str(e)) from e


def check_uniprot(upid: str) -> Tuple[bool, Optional[str]]:
    """Return (found, genome_assembly_accession_or_None)."""
    data = fetch_json(UNIPROT_API.format(upid=upid))
    if data is None:
        return False, None
    # genome assembly lives at data["genomeAssembly"]["assemblyId"] or similar
    ga = data.get("genomeAssembly") or {}
    acc = ga.get("assemblyId") or ga.get("genBankAssemblyAccession") or None
    return True, acc


def check_ncbi(acc: str) -> Tuple[bool, bool]:
    """Return (assembly_exists, fasta_available)."""
    data = fetch_json(NCBI_CHECK.format(acc=acc))
    if data is None:
        return False, False
    reports = data.get("reports", [])
    if not reports:
        return False, False
    # Check if FASTA annotation type is available
    for r in reports:
        avail = r.get("annotationInfo", {}).get("available", [])
        fasta_ok = any("FASTA" in str(a) for a in avail)
        return True, fasta_ok
    return True, False


def parse_rpg(path: str, pattern: Optional[str]) -> Dict[str, str]:
    """Extract seed ('>') proteome IDs from an rpg file, optionally filtered by regex."""
    ids: Dict[str, str] = {}
    rx = re.compile(pattern, re.IGNORECASE) if pattern else None
    with open(path) as fh:
        for line in fh:
            if not line.startswith(">"):
                continue
            parts = line[1:].rstrip().split("\t")
            if len(parts) < 4:
                continue
            upid, _, _, name = parts[0], parts[1], parts[2], parts[3]
            if rx is None or rx.search(name):
                ids[upid] = name
    return ids


def run(ids: Dict[str, str], delay: float = 0.3) -> List[ProteomeResult]:
    results = []
    total = len(ids)
    for i, (upid, label) in enumerate(ids.items(), 1):
        print(f"  [{i}/{total}] {upid}  {label}", file=sys.stderr)
        r = ProteomeResult(upid=upid, label=label)
        try:
            r.uniprot_found, r.genome_assembly = check_uniprot(upid)
            if r.genome_assembly:
                time.sleep(delay)
                r.ncbi_found, r.ncbi_fasta_available = check_ncbi(r.genome_assembly)
        except Exception as e:
            r.error = str(e)
        results.append(r)
        time.sleep(delay)
    return results


def print_report(results: List[ProteomeResult]) -> None:
    col = "{:<14} {:<45} {:<12} {:<20} {:<12} {:<14} {}"
    header = col.format(
        "UPID", "Label", "UniProt?", "genome_assembly", "NCBI?", "FASTA avail?", "Notes"
    )
    print("\n" + header)
    print("-" * len(header))
    for r in results:
        notes = []
        if r.error:
            notes.append(f"ERROR: {r.error}")
        if not r.uniprot_found:
            notes.append("not in UniProt → drops at ids.txt stage")
        elif not r.genome_assembly:
            notes.append("no genome_assembly → drops at mapped.db stage")
        elif not r.ncbi_found:
            notes.append("assembly not in NCBI → download fails")
        elif not r.ncbi_fasta_available:
            notes.append("assembly exists but no FASTA → extraction fails")
        else:
            notes.append("OK - should be downloadable")

        print(col.format(
            r.upid,
            r.label[:44],
            "yes" if r.uniprot_found else "NO",
            r.genome_assembly or "(none)",
            ("yes" if r.ncbi_found else "NO") if r.ncbi_found is not None else "—",
            ("yes" if r.ncbi_fasta_available else "NO") if r.ncbi_fasta_available is not None else "—",
            "; ".join(notes),
        ))

    # Summary
    no_assembly = [r for r in results if r.uniprot_found and not r.genome_assembly]
    not_in_uniprot = [r for r in results if not r.uniprot_found]
    ncbi_missing = [r for r in results if r.ncbi_found is False]
    print(f"\nSummary: {len(results)} checked | "
          f"{len(not_in_uniprot)} not in UniProt | "
          f"{len(no_assembly)} missing genome_assembly | "
          f"{len(ncbi_missing)} assembly not in NCBI")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ids", nargs="+", metavar="UPID",
                        help="Explicit proteome IDs to check (overrides defaults)")
    parser.add_argument("--rpg", metavar="FILE",
                        help="Parse seed IDs from an rpg-XX.txt file")
    parser.add_argument("--filter", metavar="REGEX", default=None,
                        help="Regex filter on organism name when using --rpg")
    parser.add_argument("--delay", type=float, default=0.3,
                        help="Seconds between API calls (default 0.3)")
    args = parser.parse_args()

    if args.rpg:
        ids = parse_rpg(args.rpg, args.filter)
        if not ids:
            sys.exit(f"No matching entries found in {args.rpg} with filter {args.filter!r}")
        print(f"Found {len(ids)} matching seed entries in {args.rpg}", file=sys.stderr)
    elif args.ids:
        ids = {upid: upid for upid in args.ids}
    else:
        ids = DEFAULT_IDS

    print(f"Checking {len(ids)} proteome IDs ...", file=sys.stderr)
    results = run(ids, delay=args.delay)
    print_report(results)


if __name__ == "__main__":
    main()
