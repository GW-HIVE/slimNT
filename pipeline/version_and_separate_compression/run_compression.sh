#!/bin/bash
#SBATCH -p short                                 # Partition to run in
#SBATCH -t 11:00:00                              # Time limit (adjust as needed)
#SBATCH --job-name=slimNT_compress_pipeline      # Job name
#SBATCH --output=logs/job_%j_compress.out        # Standard output log
#SBATCH --error=logs/job_%j_compress.err         # Standard error log

#Created June 6, 2025 to run just the compression step for the slimNT.fa file created in the pipeline

# Parse command line args
VERSION=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: sbatch run_pipeline.sh --version <version>" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "ERROR: --version is required." >&2
  echo "Usage: sbatch run_pipeline.sh --version <version>" >&2
  exit 1
fi

BACKUP_DIR=""
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --backup-dir) BACKUP_DIR="$2"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

export BACKUP_DIR
export VERSION

set -e
cd /scratch/hivelab/slimNT-sean/slimNT || exit 1

mkdir -p logs

chmod +x run_compression.sh      #updated
chmod +x ./pipeline/*.sh

echo "Compression of file started at $(date)"
echo "Using backup directory: ${BACKUP_DIR:-None}"
echo "Compressing the file for version: $VERSION"
#updated so it only runs the compression script

./pipeline/6_compress_files.sh

echo "Compression done, pipeline completed at $(date)"

