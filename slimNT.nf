params.outdir = 'output'
params.rpg75 = 'https://proteininformationresource.org/rps/data/current/75/rpg-75.txt'
params.rpg55 = 'https://proteininformationresource.org/rps/data/current/55/rpg-55.txt'
params.virus95 = 'https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-95.txt'
params.virus75 = 'https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-75.txt'
params.virus55 = 'https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-55.txt'

process getIds {
    publishDir "$params.outdir", mode: 'copy'
    output:
    path 'mapped.db', emit: db
    
    script:
    """
    wget -qO - 'https://rest.uniprot.org/proteomes/stream?compressed=true&fields=upid%2Corganism%2Corganism_id%2Cgenome_assembly&format=tsv&query=%28*%29' | gzip -d > mapping.txt
    cat <(wget -O - ${params.rpg75}) <(wget -O - ${params.virus95}) > full_proteomes.txt
    grep '^>' full_proteomes.txt | awk '{ sub(/^>/, ""); print \$1 }' > ids.txt
    awk 'NR==FNR{a[\$1];next} \$1 in a {print \$NF > "mapped.db"}' ids.txt mapping.txt
    """
}

process getGenomes {
    publishDir "$params.outdir/genomes", mode: 'copy', overwrite: true
    input:
    file "mapped.db"
    output:
    path '*.fna', emit: fna
    path '*.txt', emit: txt

    errorStrategy { sleep(Math.pow(2, task.attempt) * 50 as long); return 'retry' }
    maxRetries 3

    script:
    """
    for i in \$(cat mapped.db); do
        # Check if the file exists
        if [ ! -f "\$i.zip" ]; then
            # File does not exist, download it
            if ! curl -OJX GET "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/\$i/download?include_annotation_type=GENOME_FASTA&filename=\$i.zip" -H "Accept: application/zip"; then
                echo "Error downloading file: \$i.zip" >&2
                continue
            fi
        fi
    done

    for i in *.zip; do
        # Extract files, skipping any entry that causes an error
        if ! unzip -p \$i "*.fna" > "\${i%.zip}.fna"; then
            echo "Error extracting file: \$i" >&2
            continue
        fi
    done

    # Create a text file listing all .fna files
    find -name "*.fna" -size 0 > empty_list.txt
    awk -i inplace '{gsub(/^\\.\\//, ""); gsub(/\\.fna\$/, ""); print}' empty_list.txt
    find -name "*.fna" -size 0 -print0 | xargs -0 rm
    """
}

process getAlternateIds {
    publishDir "$params.outdir/genomes", mode: 'copy', overwrite: true
    input:
    
    file 'empty_list.txt'

    output:
    path 'alt_ids.txt', emit: txt

    script:
    """
    wget https://ftp.ncbi.nlm.nih.gov/genomes/refseq/assembly_summary_refseq.txt
    awk -F '\t' '{print \$1, \$18}' assembly_summary_refseq.txt > ref_gen_map.txt
    rm assembly_summary_refseq.txt     
    awk 'NR==FNR {empty[\$0]; next} {for (i=1; i<=NF; i++) if (\$i in empty) {for (j=1; j<=NF; j++) if (j != i) printf "%s", \$j; print ""}}' 'empty_list.txt' ref_gen_map.txt > alt_ids.txt
    """
}

process getAlternateGenome {
    publishDir "$params.outdir/genomes/", mode: 'copy', overwrite: true
    input:
    file "alt_ids.txt"
  
    output:
    file '*.fna'
    path '*.fna', emit: fna
    path '*.txt', emit: txt2

    script:
    """
    set -e
    while IFS= read -r i; do    
    i=\$(echo "\$i" | tr -d '[:space:]')
    url="https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/\$i/download?include_annotation_type=CDS_FASTA&filename=\$i.zip"
    echo "Downloading \$url"
    curl -OJX GET "\$url" -H "Accept: application/zip"
    done < "alt_ids.txt"


    for i in *.zip; do
        # Extract files, skipping any entry that causes an error
        echo "Extracting: \$i"
        unzip -p \$i "*.fna" > "\${i%.zip}.fna" || true
    done

    find -name "*.fna" -size 0 > empty_list2.txt
    awk -i inplace '{gsub(/^\\.\\//, ""); gsub(/\\.fna\$/, ""); print}' empty_list2.txt      
    find -name "*.fna" -size 0 -delete
    """
}

process concatZip {
    publishDir "$params.outdir/", mode: 'copy', overwrite: true

    input:
    path fna
    path txt
    path txt2
    
    output:
    file 'slimNT.db.gz'
    file 'missing_fna.txt'
    
    script:
    """
    touch empty_list2.txt
    cat empty_list.txt empty_list2.txt > missing_fna.txt
    cat *.fna > slimNT.db
    gzip slimNT.db
    """
}

workflow {
    getIds()
    getGenomes(getIds.out.db)
    getAlternateIds(getGenomes.out.txt)
    if (file('alt_ids.txt').isFile() && file('alt_ids.txt').text) {
        getAlternateGenome(getAlternateIds.out)
        concatZip(getAlternateGenome.out.fna, getAlternateGenome.out.txt2, getGenomes.out.txt)
    } else {
        concatZip(getGenomes.out.fna, getAlternateIds.out.txt, getGenomes.out.txt)
    }
}
