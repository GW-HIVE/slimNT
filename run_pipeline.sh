#!/bin/bash
#SBATCH -p tiny             # Partition to run in
#SBATCH -t 8:00:00          # Time limit (adjust as needed)
#SBATCH --job-name=my_pipeline   # Job name
#SBATCH --output=logs/job_%j.out   # Standard output log
#SBATCH --error=logs/job_%j.err    # Standard error log

set -e
cd /scratch/hivelab/slimNT-sean/slimNT || exit 1

chmod +x ./pipeline/*.sh

echo "Pipeline started at $(date)"

./pipeline/1_get_ids.sh
./pipeline/2_get_genomes.sh
./pipeline/3_get_alternate_ids.sh
./pipeline/4_get_alternate_genomes.sh
./pipeline/5_concat_zip.sh

echo "Pipeline completed at $(date)"
