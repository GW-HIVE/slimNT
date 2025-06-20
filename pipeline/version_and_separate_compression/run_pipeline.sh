#!/bin/bash
#SBATCH -p tiny            		# Partition to run in
#SBATCH -t 4:00:00          		# Time limit (adjust as needed)
#SBATCH --job-name=slimNT_pipeline   	# Job name
#SBATCH --output=logs/job_%j.out   	# Standard output log
#SBATCH --error=logs/job_%j.err    	# Standard error log

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
    #--version)    VERSION="$2"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done


#if [[ -z "$VERSION" ]]; then
  #echo "ERROR: you must supply --version <string> (e.g. 1.0)"; exit 1
#fi

export BACKUP_DIR
export VERSION


set -e
cd /scratch/hivelab/slimNT-sean/slimNT || exit 1

mkdir -p logs

chmod +x run_pipeline.sh
chmod +x ./pipeline/*.sh

echo "Pipeline started at $(date)"
echo "Using backup directory: ${BACKUP_DIR:-None}"
echo "Creating file version: $VERSION"

./pipeline/1_get_ids.sh
./pipeline/2_get_genomes.sh
./pipeline/3_get_alternate_ids.sh
./pipeline/4_get_alternate_genomes.sh
./pipeline/5_concat_zip.sh

echo "Pipeline completed at $(date)"
