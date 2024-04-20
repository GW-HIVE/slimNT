#!/bin/bash

# Create a directory to store extracted files
mkdir unzipped

# Download genome data files specified in "files.txt" using
for i in $(cat files.txt); do
    curl -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=CDS_FASTA&filename=$i.zip" -H "Accept: application/zip"
done

# Extract the .fna files from the downloaded .zip files and store them in the "unzipped" directory
for i in *.zip; do
    unzip -p $i "*.fna" > unzipped/"${i%.zip}.fna"
    rm $i
done
cd unzipped

# Modify each .fna file by replacing occurrences of "_cds_" with " cds_" and removing ">lcl|"
for i in *; do
    sed -i 's/_cds_/ cds_/g' $i
    sed -i 's/>lcl|/>/g' $i
done

# Find and list all empty .fna files, and save the list in "empty_list.txt"
find -name "*.fna" -size 0 > empty_list.txt

# Move "empty_list.txt" to the parent directory
mv empty_list.txt ..

# Move back to the parent directory
cd ..

# Download an assembly summary file from the NCBI database using wget
wget https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt

# Extract relevant columns (accession ID and GenBank assembly ID) from the assembly summary file and save them in "ref_gen_map.txt"
awk -F '\t' '{print $1, $18}' assembly_summary_refseq.txt > ref_gen_map.txt
rm assembly_summary_refseq.txt

# Use "awk" to find the GenBank assembly IDs corresponding to the empty .fna files and save the list in "alt_ids.txt"
awk 'NR==FNR {empty[$0]; next} {for (i=1; i<=NF; i++) if ($i in empty) {for (j=1; j<=NF; j++) if (j != i) printf "%s", $j; print ""}}' 'empty_list.txt' ref_gen_map.txt > alt_ids.txt

# Download genome data for the accession IDs in "alt_ids.txt" and extract .fna files
for i in $(cat alt_ids.txt); do
    curl -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/$i/download?include_annotation_type=CDS_FASTA&filename=$i.zip" -H "Accept: application/zip"
done
for i in *.zip; do
    unzip -p $i "*.fna" > unzipped/"${i%.zip}.fna"
    rm $i
done

# Modify each .fna file in the "unzipped" directory again
for i in unzipped/*; do
    sed -i 's/_cds_/ cds_/g' $i
    sed -i 's/>lcl|/>/g' $i
done

# Find and list all empty .fna files in the "unzipped" directory, save the list in "empty_list_all.txt", and remove the leading "./" and trailing ".fna" from each line
find -name "*.fna" -size 0 > empty_list_all.txt
sed -i -E 's/^\.\/|\.fna$//g' empty_list_all.txt

# Move "empty_list_all.txt" to the parent directory
mv empty_list_all.txt ..

# Delete all empty .fna files in the "unzipped" directory
find -name "*.fna" -size 0 -delete

# Combine all .fna files into a single compressed file named "all_cds_orgs.fna.gz" and move it to the parent directory
cd unzipped
cat *.fna > all_cds_orgs.fna.gz
mv all_cds_orgs.fna.gz ..

# Move back to the parent directory and remove the "unzipped" directory and "empty_list.txt"
cd ..
rm -r unzipped
rm empty_list.txt
