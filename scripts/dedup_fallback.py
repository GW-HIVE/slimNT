#!/usr/bin/env python3
"""
Remove duplicate FASTA records from fallback_genomes/ before step 6 concatenation.

A fallback record is a duplicate if its sequence ID (first token of the header)
  (a) also appears in any genomes/*.fna file, or
  (b) already appeared in an earlier fallback_genomes/*.fna file (or earlier in
      the same file). "Earlier" follows sorted filename order, which matches the
      `cat fallback_genomes/*.fna` glob order used by step 6.

Genome-assembly records are always kept; duplicates are removed from the
fallback side only.

Default is a dry run that only reports. With --apply:
  - each modified file's original is moved to <outdir>/dedup_backup/<timestamp>/
  - the cleaned file is written to a temp file and renamed into place. This
    breaks hardlinks (base/ and annotated/ share fallback FNAs via hardlinks),
    so cleaning one artifact never silently modifies another.
  - files left with zero records are moved to the backup dir and not replaced.
  - if <outdir>/slimNT.fa exists, it is rebuilt (genomes/*.fna then
    fallback_genomes/*.fna, same as step 6) into a temp file that is renamed
    over slimNT.fa only once the write fully succeeds. This needs free space
    for a second copy of slimNT.fa while it runs. A stale slimNT.fa.gz is
    moved to the backup dir.

Usage:
    python3 scripts/dedup_fallback.py /data/slimNT/v3.1/base            # report
    python3 scripts/dedup_fallback.py /data/slimNT/v3.1/base --apply    # fix

Requires Python 3.6+ (KVM2 runs 3.6.8).
"""

import argparse
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Set, Tuple


def record_id(header_line: bytes) -> bytes:
    """'>NC_001940.1 Feline leukemia virus...' -> b'NC_001940.1'"""
    parts = header_line[1:].split(None, 1)
    return parts[0] if parts else b""


def fallback_ids(fna_files: List[Path]) -> Dict[bytes, List[str]]:
    """Map record ID -> list of fallback filenames it occurs in (with repeats)."""
    ids = {}  # type: Dict[bytes, List[str]]
    for f in fna_files:
        with f.open("rb") as fh:
            for line in fh:
                if line.startswith(b">"):
                    ids.setdefault(record_id(line), []).append(f.name)
    return ids


def ids_in_genomes(genomes_dir: Path, wanted: Set[bytes]) -> Dict[bytes, str]:
    """
    Scan headers of every genomes/*.fna (via grep, which is far faster than
    Python on ~100 GB) and return {id: genome filename} for IDs in `wanted`.
    """
    found = {}  # type: Dict[bytes, str]
    if not genomes_dir.is_dir() or not wanted:
        return found

    env = dict(os.environ, LC_ALL="C")
    # find | xargs avoids ARG_MAX limits with ~34k files.
    cmd = ("find . -maxdepth 1 -name '*.fna' -print0 "
           "| xargs -0 -r grep -H '^>'")
    proc = subprocess.Popen(cmd, shell=True, cwd=str(genomes_dir), env=env,
                            stdout=subprocess.PIPE)
    n_headers = 0
    for line in proc.stdout:
        # line: b'./GCA_000850105.1.fna:>NC_001940.1 description\n'
        fname, _, header = line.partition(b":")
        n_headers += 1
        rid = record_id(header)
        if rid in wanted and rid not in found:
            found[rid] = fname[2:].decode()
    rc = proc.wait()
    # grep exits 1 when a batch has no matches; >1 is a real error.
    if rc > 1:
        sys.exit("ERROR: header scan of {} failed (exit {})".format(genomes_dir, rc))
    print("Scanned {:,} genome headers in {}".format(n_headers, genomes_dir),
          file=sys.stderr)
    return found


def plan_removals(fna_files: List[Path],
                  in_genomes: Dict[bytes, str]) -> Dict[str, List[Tuple[int, bytes, str]]]:
    """
    Decide which records to drop. Returns
      {filename: [(record_index, id, reason), ...]}
    record_index is the 0-based position of the record within its file.
    """
    removals = {}  # type: Dict[str, List[Tuple[int, bytes, str]]]
    first_seen = {}  # type: Dict[bytes, str]
    for f in fna_files:
        idx = -1
        with f.open("rb") as fh:
            for line in fh:
                if not line.startswith(b">"):
                    continue
                idx += 1
                rid = record_id(line)
                if rid in in_genomes:
                    reason = "in genomes/{}".format(in_genomes[rid])
                elif rid in first_seen:
                    reason = "dup of fallback_genomes/{}".format(first_seen[rid])
                else:
                    first_seen[rid] = f.name
                    continue
                removals.setdefault(f.name, []).append((idx, rid, reason))
    return removals


def rewrite_without(src: Path, drop_idx: Set[int], backup_dir: Path) -> int:
    """Write src minus the dropped records; back up the original. Returns kept count."""
    tmp = src.with_name(src.name + ".dedup.tmp")
    kept = 0
    idx = -1
    keep = True
    with src.open("rb") as fin, tmp.open("wb") as fout:
        for line in fin:
            if line.startswith(b">"):
                idx += 1
                keep = idx not in drop_idx
                if keep:
                    kept += 1
            if keep:
                fout.write(line)

    backup_dir.mkdir(parents=True, exist_ok=True)
    shutil.move(str(src), str(backup_dir / src.name))
    if kept:
        os.replace(str(tmp), str(src))
    else:
        tmp.unlink()
    return kept


def rebuild_slimnt(outdir: Path, gen_dir: Path, fb_dir: Path) -> int:
    """
    Regenerate outdir/slimNT.fa exactly as step 6 does, writing to a temp file
    and renaming over the original only after the write fully succeeds.
    Returns the number of bytes written.
    """
    target = outdir / "slimNT.fa"
    tmp = outdir / "slimNT.fa.dedup.tmp"
    sources = sorted(gen_dir.glob("*.fna")) + sorted(fb_dir.glob("*.fna"))
    if not sources:
        sys.exit("ERROR: no FNA files found to rebuild {}".format(target))
    try:
        with tmp.open("wb") as fout:
            for src in sources:
                with src.open("rb") as fin:
                    shutil.copyfileobj(fin, fout, 16 * 1024 * 1024)
            fout.flush()
            os.fsync(fout.fileno())
    except BaseException:
        if tmp.exists():
            tmp.unlink()
        raise
    size = tmp.stat().st_size
    os.replace(str(tmp), str(target))
    return size


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir", help="Pipeline output dir containing genomes/ and fallback_genomes/")
    ap.add_argument("--apply", action="store_true",
                    help="Rewrite files (default: dry-run report only)")
    ap.add_argument("--report", metavar="FILE",
                    help="Also write the removal list as TSV (file, record_id, reason)")
    args = ap.parse_args()

    outdir = Path(args.outdir).resolve()
    fb_dir = outdir / "fallback_genomes"
    gen_dir = outdir / "genomes"
    if not fb_dir.is_dir():
        sys.exit("ERROR: {} not found".format(fb_dir))

    fna_files = sorted(fb_dir.glob("*.fna"))
    if not fna_files:
        print("No fallback FNAs in {} — nothing to do.".format(fb_dir))
        return

    fb_ids = fallback_ids(fna_files)
    n_records = sum(len(v) for v in fb_ids.values())
    print("Fallback: {} files, {:,} records, {:,} unique IDs".format(
        len(fna_files), n_records, len(fb_ids)), file=sys.stderr)

    in_genomes = ids_in_genomes(gen_dir, set(fb_ids))
    removals = plan_removals(fna_files, in_genomes)

    total = sum(len(v) for v in removals.values())
    n_gen = sum(1 for v in removals.values() for r in v if r[2].startswith("in genomes/"))
    print("\nDuplicate fallback records: {} ({} also in genomes/, {} repeated within fallback)"
          .format(total, n_gen, total - n_gen))
    for fname in sorted(removals):
        for _, rid, reason in removals[fname]:
            print("  {}\t{}\t{}".format(fname, rid.decode(), reason))

    if args.report:
        with open(args.report, "w") as rep:
            rep.write("file\trecord_id\treason\n")
            for fname in sorted(removals):
                for _, rid, reason in removals[fname]:
                    rep.write("{}\t{}\t{}\n".format(fname, rid.decode(), reason))
        print("Report written to {}".format(args.report))

    if not total:
        return
    if not args.apply:
        print("\nDry run — re-run with --apply to remove these records.")
        return

    backup_dir = outdir / "dedup_backup" / datetime.now().strftime("%Y%m%d-%H%M%S")
    emptied = []
    for fname, recs in sorted(removals.items()):
        kept = rewrite_without(fb_dir / fname, {r[0] for r in recs}, backup_dir)
        if not kept:
            emptied.append(fname)

    print("\nRemoved {} records from {} files. Originals backed up to {}".format(
        total, len(removals), backup_dir))
    if emptied:
        print("{} file(s) contained only duplicates and were removed: {}".format(
            len(emptied), ", ".join(emptied)))
        print("NOTE: re-running step 5 will re-fetch these until the root cause is fixed.")

    stale_gz = outdir / "slimNT.fa.gz"
    if stale_gz.exists():
        shutil.move(str(stale_gz), str(backup_dir / stale_gz.name))
        print("Moved stale {} to {}".format(stale_gz.name, backup_dir))

    if (outdir / "slimNT.fa").exists():
        print("\nRebuilding {}/slimNT.fa ...".format(outdir), file=sys.stderr)
        size = rebuild_slimnt(outdir, gen_dir, fb_dir)
        print("Replaced {}/slimNT.fa ({:,} bytes).".format(outdir, size))
    else:
        print("No {}/slimNT.fa present — run step 6 to build it.".format(outdir))


if __name__ == "__main__":
    main()
