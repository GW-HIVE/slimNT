#!/bin/bash

source "$(dirname "$0")/config.sh"

logstepstart "Starting Step 2: Getting Genomes"

mkdir -p "$OUTDIR/genomes"
cd "$OUTDIR/genomes" || exit 1

# Get backup directory from env variable
BACKUP_DIR="${BACKUP_DIR:-}"
if [ -n "$BACKUP_DIR" ]; then
  log "Using backup directory: $BACKUP_DIR"
fi

log "Beginning genome downloads..."
total_genomes=$(wc -l < "../mapped.db")
current=0
failed_downloads=0
copied_from_backup=0

# Create a download log
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>"../../logs/2_download_progress.log" 2>&1

# Read mapped.db and download genomes
while IFS= read -r genome_id; do
  ((current++))
  genome_id=$(echo "$genome_id" | tr -d '[:space:]')  # Remove any whitespace

  log "Processing genome $current/$total_genomes: $genome_id"

  if [ -f "${genome_id}.zip" ]; then
    log "File already exists for ${genome_id}, skipping"
    continue
  fi 

  # Try to copy from backup directory first is specified
  if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/genomes/${genome_id}.zip" ]; then
    log "Copying ${genome_id}.zip from backup directory"
    cp "$BACKUP_DIR/genomes/${genome_id}.zip" .
    ((copied_from_backup++))
    continue
  fi

  for attempt in {1..3}; do
    log "Download attempt $attempt for $genome_id"

    if curl -f -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/${genome_id}/download?include_annotation_type=GENOME_FASTA&filename=${genome_id}.zip" -H "Accept: application/zip" 2>&1; then
      if [ -f "${genome_id}.zip" ] && [ -s "${genome_id}.zip" ]; then
          log "Successfully downloaded ${genome_id}.zip"
          break
      else
          log "Download appeared successful but file is missing or empty: ${genome_id}"
          rm -f "${genome_id}.zip"
      fi
    else
      log "Attempt $attempt failed, retrying in $((2**attempt * 50)) seconds..."
      sleep $((2**attempt * 50))
      if [ $attempt -eq 3 ]; then
          log "Error: Failed all download attempts for: ${genome_id}"
          echo "${genome_id}" >> "../../logs/2_failed_downloads.txt"
          ((failed_downloads++))
          continue 2
      fi
    fi
  done

  # Progress update every 100 genomes
  if ((current % 100 == 0)); then
      log "Progress: $current/$total_genomes genomes processed ($failed_downloads failed)"
  fi
done < "../mapped.db"

# Restore stdout/stderr before changing logs
exec 1>&3 2>&4

log "Download phase complete. Total: $total_genomes, Failed: $failed_downloads, Copied from backup: $copied_from_backup"

# Only proceed with extraction if we have zip files
if ls *.zip 1> /dev/null 2>&1; then

    log "Extracting downloaded files..."

    # Create a separate extraction log
    exec 3>&1 4>&2
    trap 'exec 2>&4 1>&3' 0 1 2 3
    exec 1>"../../logs/2_extract_progress.log" 2>&1

    for zip_file in *.zip; do
        base_name="${zip_file%.zip}"
        log "Processing: $zip_file"

        # Skip extraction if the FNA file already exists and isn't empty
        if [ -f "${base_name}.fna" ] && [ -s "${base_name}.fna" ]; then
            log "FNA file already exists for ${base_name}, skipping extraction"
            continue
        fi

        # Try to copy from backup directory if extraction fails
        if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/genomes/${base_name}.fna" ]; then
          log "FNA file available in backup, copying ${base_name}.fna"
          cp "$BACKUP_DIR/genomes/${base_name}.fna" .
          continue
        fi

        log "Extracting: $zip_file"
        if ! unzip -p "$zip_file" "*.fna" > "${base_name}.fna"; then
            log "Error extracting file: $zip_file"
            echo "${base_name}" >> "../../logs/2_extraction_failed.txt"
            continue
        fi
        log "Successfully extracted ${base_name}.fna"
    done

    # Restore stdout/stderr
    exec 1>&3 2>&4
else
    # Restore stdout/stderr
    exec 1>&3 2>&4

    log "ERROR: No zip files found to extract"
    exit 1
fi

log "Extracting phase complete."
log "Processing empty files..."
find . -name "*.fna" -size 0 > empty_list.txt
sed -i 's/^\.\///;s/\.fna$//' empty_list.txt
find . -name "*.fna" -size 0 -delete

logstepend "Step 2 completed with $failed_downloads failed downloads"
