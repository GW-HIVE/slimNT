#!/bin/bash

# Loop through each accession ID in CDS_LIST_FILENAME.txt and download the corresponding genome data
for i in `cat CDS_LIST_FILENAME.txt`; do
    curl -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=CDS_FASTA&filename=$i.zip" -H "Accept: application/zip"
done

# Extract the .fna files from the downloaded .zip files and store them in the 'unzipped' directory
for i in *.zip; do
    unzip -p $i "*.fna" > unzipped/"${i%.zip}.fna"
    rm $i
done

# Replace occurrences of '_cds_' with ' cds_' and remove '>lcl|' from each .fna file
for i in *; do
    sed -i 's/_cds_/ cds_/g' $i
    sed -i 's/>lcl|/>/g' $i
done

# Find and list all empty .fna files and store the list in empty_list.txt
find -name "*.fna" -size 0 > empty_list.txt

# Navigate back one directory and download assembly summary file from NCBI
cd ..
wget https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt

# Extract relevant columns (accession ID and GenBank assembly ID) from the assembly summary file and save in ref_gen_map.txt
awk -F '\t' '{print \$1, \$18}' assembly_summary_refseq.txt > ref_gen_map.txt
rm assembly_summary_refseq.txt     

# Extract accession IDs of empty .fna files from empty_list.txt and find corresponding GenBank assembly IDs
awk 'NR==FNR {empty[\$0]; next} {for (i=1; i<=NF; i++) if (\$i in empty) {for (j=1; j<=NF; j++) if (j != i) printf "%s", \$j; print ""}}' 'empty_list.txt' ref_gen_map.txt > alt_ids.txt

# Download genome data for accession IDs in alt_ids.txt and extract .fna files
for i in `cat alt_ids.txt`; do
    curl -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=CDS_FASTA&filename=$i.zip" -H "Accept: application/zip"
done
for i in *.zip; do
    unzip -p $i "*.fna" > unzipped/"${i%.zip}.fna"
    rm $i
done

# Find and list all empty .fna files in the 'unzipped' directory and store the list in empty_list_all.txt
find -name "*.fna" -size 0 > empty_list_all.txt

# Combine all .fna files into a single compressed file named 'all_cds_orgs.fna.gz'
cd unzipped
cat *.fna > all_cds_orgs.fna.gz
