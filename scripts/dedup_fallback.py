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

The full run takes a long time on ~100 GB of genomes, so run it detached and
follow the log:
    nohup python3 scripts/dedup_fallback.py /data/slimNT/v3.1/base \\
        > dedup_base.log 2>&1 &
    tail -f dedup_base.log

All output is timestamped and flushed line by line. Progress is logged every
--progress-interval seconds (default 30) during the genome header scan and the
slimNT.fa rebuild. The last line is "DONE" on success; SIGTERM (`kill <pid>`)
removes any partially written temp file before exiting.

Usage:
    python3 scripts/dedup_fallback.py /data/slimNT/v3.1/base            # report
    python3 scripts/dedup_fallback.py /data/slimNT/v3.1/base --apply    # fix

Requires Python 3.6+ (KVM2 runs 3.6.8).
"""

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Set, Tuple

PROGRESS_INTERVAL = 30.0  # seconds; overridden by --progress-interval


def log(msg: str = "") -> None:
    """Timestamped, immediately flushed line to stdout (safe under nohup)."""
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    for line in (msg.split("\n") if msg else [""]):
        sys.stdout.write("[{}] {}\n".format(stamp, line))
    sys.stdout.flush()


def fmt_bytes(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return "{:.1f} {}".format(n, unit)
        n /= 1024.0
    return "{:.1f} TB".format(n)


def fmt_secs(s: float) -> str:
    s = int(s)
    return "{:d}h{:02d}m{:02d}s".format(s // 3600, (s % 3600) // 60, s % 60)


class Throttle:
    """True at most once every PROGRESS_INTERVAL seconds."""

    def __init__(self) -> None:
        self.start = time.monotonic()
        self.last = self.start

    def due(self) -> bool:
        now = time.monotonic()
        if now - self.last >= PROGRESS_INTERVAL:
            self.last = now
            return True
        return False

    def elapsed(self) -> float:
        return time.monotonic() - self.start


def _sigterm(signum, frame):
    # Turn SIGTERM into SystemExit so try/except cleanup of temp files runs.
    raise SystemExit("Received signal {}; aborting.".format(signum))


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

    n_files = sum(1 for e in os.scandir(str(genomes_dir))
                  if e.name.endswith(".fna") and e.is_file())
    log("Scanning headers of {:,} files in {} ...".format(n_files, genomes_dir))

    env = dict(os.environ, LC_ALL="C")
    # find | xargs avoids ARG_MAX limits with ~34k files.
    cmd = ("find . -maxdepth 1 -name '*.fna' -print0 "
           "| xargs -0 -r grep -H '^>'")
    proc = subprocess.Popen(cmd, shell=True, cwd=str(genomes_dir), env=env,
                            stdout=subprocess.PIPE)
    n_headers = 0
    files_seen = 0
    last_fname = b""
    t = Throttle()
    try:
        for line in proc.stdout:
            # line: b'./GCA_000850105.1.fna:>NC_001940.1 description\n'
            fname, _, header = line.partition(b":")
            n_headers += 1
            if fname != last_fname:
                files_seen += 1
                last_fname = fname
            rid = record_id(header)
            if rid in wanted and rid not in found:
                found[rid] = fname[2:].decode()
            if t.due():
                log("  header scan: {:,}/{:,} files ({:.1f}%), {:,} headers, "
                    "{:,} matches, {} elapsed".format(
                        files_seen, n_files, 100.0 * files_seen / max(n_files, 1),
                        n_headers, len(found), fmt_secs(t.elapsed())))
    except BaseException:
        proc.kill()
        raise
    rc = proc.wait()
    # grep exits 1 when a batch has no matches; >1 is a real error.
    if rc > 1:
        sys.exit("ERROR: header scan of {} failed (exit {})".format(genomes_dir, rc))
    log("Scanned {:,} genome headers in {:,} files ({} elapsed); {:,} fallback IDs "
        "found in genomes/".format(n_headers, files_seen, fmt_secs(t.elapsed()), len(found)))
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
    try:
        with src.open("rb") as fin, tmp.open("wb") as fout:
            for line in fin:
                if line.startswith(b">"):
                    idx += 1
                    keep = idx not in drop_idx
                    if keep:
                        kept += 1
                if keep:
                    fout.write(line)
    except BaseException:
        if tmp.exists():
            tmp.unlink()
        raise

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

    total_bytes = sum(s.stat().st_size for s in sources)
    log("Rebuilding {} from {:,} files ({}) -> {}".format(
        target, len(sources), fmt_bytes(total_bytes), tmp.name))

    written = 0
    t = Throttle()
    try:
        with tmp.open("wb") as fout:
            for i, src in enumerate(sources, 1):
                with src.open("rb") as fin:
                    while True:
                        buf = fin.read(16 * 1024 * 1024)
                        if not buf:
                            break
                        fout.write(buf)
                        written += len(buf)
                        if t.due():
                            el = t.elapsed()
                            rate = written / el if el else 0.0
                            eta = (total_bytes - written) / rate if rate else 0.0
                            log("  rebuild: {}/{} ({:.1f}%), file {:,}/{:,}, "
                                "{}/s, {} elapsed, ~{} remaining".format(
                                    fmt_bytes(written), fmt_bytes(total_bytes),
                                    100.0 * written / max(total_bytes, 1),
                                    i, len(sources), fmt_bytes(rate),
                                    fmt_secs(el), fmt_secs(eta)))
            log("  rebuild: all data written; syncing to disk ...")
            fout.flush()
            os.fsync(fout.fileno())
    except BaseException:
        if tmp.exists():
            log("Removing partial {}".format(tmp))
            tmp.unlink()
        raise
    size = tmp.stat().st_size
    os.replace(str(tmp), str(target))
    log("Rebuild finished in {}".format(fmt_secs(t.elapsed())))
    return size


def main() -> None:
    global PROGRESS_INTERVAL
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("outdir", help="Pipeline output dir containing genomes/ and fallback_genomes/")
    ap.add_argument("--apply", action="store_true",
                    help="Rewrite files (default: dry-run report only)")
    ap.add_argument("--report", metavar="FILE",
                    help="Also write the removal list as TSV (file, record_id, reason)")
    ap.add_argument("--progress-interval", type=float, default=PROGRESS_INTERVAL,
                    metavar="SECS", help="Seconds between progress lines (default: 30)")
    args = ap.parse_args()
    PROGRESS_INTERVAL = args.progress_interval

    signal.signal(signal.SIGTERM, _sigterm)
    t_start = time.monotonic()

    outdir = Path(args.outdir).resolve()
    fb_dir = outdir / "fallback_genomes"
    gen_dir = outdir / "genomes"
    log("dedup_fallback starting (pid {}, mode: {})".format(
        os.getpid(), "APPLY" if args.apply else "dry run"))
    log("Output dir: {}".format(outdir))
    if not fb_dir.is_dir():
        sys.exit("ERROR: {} not found".format(fb_dir))

    fna_files = sorted(fb_dir.glob("*.fna"))
    if not fna_files:
        log("No fallback FNAs in {} — nothing to do.".format(fb_dir))
        log("DONE")
        return

    fb_ids = fallback_ids(fna_files)
    n_records = sum(len(v) for v in fb_ids.values())
    log("Fallback: {} files, {:,} records, {:,} unique IDs".format(
        len(fna_files), n_records, len(fb_ids)))

    in_genomes = ids_in_genomes(gen_dir, set(fb_ids))
    removals = plan_removals(fna_files, in_genomes)

    total = sum(len(v) for v in removals.values())
    n_gen = sum(1 for v in removals.values() for r in v if r[2].startswith("in genomes/"))
    log("Duplicate fallback records: {} ({} also in genomes/, {} repeated within fallback)"
        .format(total, n_gen, total - n_gen))
    for fname in sorted(removals):
        for _, rid, reason in removals[fname]:
            log("  {}\t{}\t{}".format(fname, rid.decode(), reason))

    if args.report:
        with open(args.report, "w") as rep:
            rep.write("file\trecord_id\treason\n")
            for fname in sorted(removals):
                for _, rid, reason in removals[fname]:
                    rep.write("{}\t{}\t{}\n".format(fname, rid.decode(), reason))
        log("Report written to {}".format(args.report))

    if not total:
        log("DONE in {} (no duplicates)".format(fmt_secs(time.monotonic() - t_start)))
        return
    if not args.apply:
        log("Dry run — re-run with --apply to remove these records.")
        log("DONE in {}".format(fmt_secs(time.monotonic() - t_start)))
        return

    backup_dir = outdir / "dedup_backup" / datetime.now().strftime("%Y%m%d-%H%M%S")
    emptied = []
    for n, (fname, recs) in enumerate(sorted(removals.items()), 1):
        kept = rewrite_without(fb_dir / fname, {r[0] for r in recs}, backup_dir)
        log("  [{}/{}] {}: removed {}, kept {}".format(
            n, len(removals), fname, len(recs), kept))
        if not kept:
            emptied.append(fname)

    log("Removed {} records from {} files. Originals backed up to {}".format(
        total, len(removals), backup_dir))
    if emptied:
        log("{} file(s) contained only duplicates and were removed: {}".format(
            len(emptied), ", ".join(emptied)))
        log("NOTE: re-running step 5 will re-fetch these until the root cause is fixed.")

    stale_gz = outdir / "slimNT.fa.gz"
    if stale_gz.exists():
        shutil.move(str(stale_gz), str(backup_dir / stale_gz.name))
        log("Moved stale {} to {}".format(stale_gz.name, backup_dir))

    if (outdir / "slimNT.fa").exists():
        size = rebuild_slimnt(outdir, gen_dir, fb_dir)
        log("Replaced {}/slimNT.fa ({}).".format(outdir, fmt_bytes(size)))
    else:
        log("No {}/slimNT.fa present — run step 6 to build it.".format(outdir))

    log("DONE in {}".format(fmt_secs(time.monotonic() - t_start)))


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        if e.code not in (None, 0):
            log(str(e.code) if isinstance(e.code, str) else "Exiting with code {}".format(e.code))
            log("FAILED")
            sys.exit(1 if isinstance(e.code, str) else e.code)
        raise
    except KeyboardInterrupt:
        log("Interrupted; FAILED")
        sys.exit(130)
    except BaseException:
        import traceback
        log("Unhandled error:\n" + traceback.format_exc().rstrip())
        log("FAILED")
        sys.exit(1)
