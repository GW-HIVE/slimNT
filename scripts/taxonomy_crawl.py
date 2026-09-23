#!/usr/bin/env python3
"""
Crawl a large FASTA file and build a taxonomy summary CSV.
Reads only header lines (starting with '>') — skips sequence data entirely.
Output: CSV with organism name, count, and example accessions.
"""

import argparse
import csv
import re
import sys
from collections import defaultdict
from pathlib import Path


# Patterns to strip trailing location/strain/chromosome qualifiers from descriptions
# e.g. "Drosophila melanogaster chromosome X" -> "Drosophila melanogaster"
_STRIP_SUFFIXES = re.compile(
    r"\s+(chromosome|chr|scaffold|contig|plasmid|complete genome|partial|mRNA|"
    r"clone|strain|isolate|cultivar|ecotype|voucher|breed|subsp\.|var\.|cf\.)"
    r".*$",
    re.IGNORECASE,
)

# Common non-organism descriptions to bucket together
_UNCLASSIFIED = re.compile(
    r"^(unclassified|uncultured|environmental|synthetic|artificial|"
    r"vector|expression vector|cloning vector|unknown)",
    re.IGNORECASE,
)


def parse_organism(description: str) -> str:
    """
    Extract a normalized organism name from an NCBI FASTA description.
    Tries bracketed [Organism] first, then falls back to genus+species heuristic.
    """
    # Prefer explicit [Organism] notation: ">acc desc [Genus species]"
    bracket = re.search(r"\[([^\[\]]+)\]", description)
    if bracket:
        return bracket.group(1).strip()

    # Fall back: strip trailing qualifiers, take first two words (genus species)
    cleaned = _STRIP_SUFFIXES.sub("", description).strip()
    words = cleaned.split()
    if len(words) >= 2:
        candidate = f"{words[0]} {words[1]}"
        # If it looks like a real binomial (both words start with a letter), use it
        if candidate[0].isalpha() and words[1][0].isalpha():
            return candidate
    return cleaned or "Unknown"


def bucket_organism(name: str) -> str:
    """Normalize unclassified / environmental / synthetic entries into buckets."""
    if _UNCLASSIFIED.match(name):
        lower = name.lower()
        if "uncultured" in lower or "environmental" in lower:
            return "[uncultured/environmental]"
        if "synthetic" in lower or "artificial" in lower or "vector" in lower:
            return "[synthetic/vector]"
        return "[unclassified]"
    return name


def crawl(fasta_path: Path, max_examples: int = 3) -> dict:
    """Stream through fasta_path; return {organism: {count, accessions}}."""
    data = defaultdict(lambda: {"count": 0, "accessions": []})
    total_headers = 0

    with open(fasta_path, "r", errors="replace") as fh:
        for line in fh:
            if not line.startswith(">"):
                continue

            total_headers += 1
            if total_headers % 500_000 == 0:
                print(f"  {total_headers:,} records scanned...", file=sys.stderr)

            # Parse: ">ACCESSION rest of description"
            parts = line[1:].rstrip().split(None, 1)
            accession = parts[0] if parts else "?"
            description = parts[1] if len(parts) > 1 else ""

            organism = bucket_organism(parse_organism(description))
            entry = data[organism]
            entry["count"] += 1
            if len(entry["accessions"]) < max_examples:
                entry["accessions"].append(accession)

    return data, total_headers


def write_csv(data: dict, total: int, out_path: Path) -> None:
    rows = sorted(data.items(), key=lambda kv: kv[1]["count"], reverse=True)
    with open(out_path, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["organism", "count", "pct_of_total", "example_accessions"])
        for organism, info in rows:
            pct = 100.0 * info["count"] / total if total else 0.0
            examples = "|".join(info["accessions"])
            writer.writerow([organism, info["count"], f"{pct:.4f}", examples])
    print(f"Wrote {len(rows):,} taxonomy rows to {out_path}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fasta", type=Path, help="Path to the FASTA file")
    parser.add_argument(
        "-o", "--output", type=Path, default=None,
        help="Output CSV path (default: <fasta_stem>_taxonomy.csv)"
    )
    parser.add_argument(
        "--examples", type=int, default=3,
        help="Number of example accessions to keep per organism (default: 3)"
    )
    args = parser.parse_args()

    out = args.output or args.fasta.with_name(args.fasta.stem + "_taxonomy.csv")

    print(f"Scanning: {args.fasta}", file=sys.stderr)
    data, total = crawl(args.fasta, max_examples=args.examples)
    print(f"Done. {total:,} total records, {len(data):,} unique organisms.", file=sys.stderr)

    write_csv(data, total, out)
    print(f"Output: {out}")


if __name__ == "__main__":
    main()
