# slimNT

slimNT has been developed to provide a curated, streamlined version of the NT database. Metagenomic analysis can be difficult and time consuming when querying against the 368001 genomes in NT, and the necessary indexing step is resource heavy; both time and computationally. slimNT aims to ##solve## that problem by strategically sub setting the NT database to create a compact, user-defined database that is tailored to specific needs.

The slimNT database is derived from Representative Proteome (RPs) and Reference Proteome Groups (RPGs) provided by [Protein Information Resource (PIR)](https://proteininformationresource.org/rps/). Reference proteomes and viral reference proteomes can be selected based on a desired cutoff thresholds. Selecting a higher cutoff value will create a larger, more robust database that will lend to increased accuracy at the expense of computation time. Conversely, selecting a lower threshold will result in a database that can be queried more quickly, but may only identify more distantly related sequences.

To ensure a portable, reproducible workflow, a nextflow pipeline was developed to aggregate and build the slimNT database. Detailed instructions to install nextflow can be found here https://www.nextflow.io/docs/latest/index.html. 

## Data Collection

A list of non-viral proteome ids are generated from PIR. Cut-off values of [(75%)](https://proteininformationresource.org/rps/data/current/75/rpg-75.txt), [(55%)](https://proteininformationresource.org/rps/data/current/55/rpg-55.txt), [(35%)](https://proteininformationresource.org/rps/data/current/35/rpg-35.txt), and [(15%)](https://proteininformationresource.org/rps/data/current/15/rpg-15.txt). These options will result in 18614, 11895, 6072, and 1989 RPGs respectively. 

A list of viral proteome ids are generated similarly. Cut-off values of [(95%)](https://proteininformationresource.org/rps/viruses/data/current/95/rpg-95.txt), [(75%)](https://proteininformationresource.org/rps/viruses/data/current/75/rpg-75.txt), [(55%)](https://proteininformationresource.org/rps/viruses/data/current/55/rpg-55.txt), [(35%)](https://proteininformationresource.org/rps/viruses/data/current/35/rpg-35.txt), [(15%)](https://proteininformationresource.org/rps/viruses/data/current/15/rpg-15.txt), resulting in 15502, 10256, 7971, 6334, 4689 RPGs. 

There is a secondary group of viral RPGs that include polyproteomes that can be found [here](https://proteininformationresource.org/download/rps/rpg_virus_all/current/).

UniProt provides a dataset that can be used to map proteome ids to their associated Genbank or RefSeq IDS [(mapping dataset)](https://www.uniprot.org/proteomes?query=*) . 

This version of slimNT was designed to be as diverse and robust as possible, and the highest cut-offs were selected (95% cut-off for viral RPGs including polyproteomes, and 75% cut-off for all others.)

nextflow Pipeline
---

![slimNT Pipeline](slimNT.pipeline.pdf)

### 1) getIds
The process **getIds** downloads a mapping file from UniProt and parses out proteome ids and genome assembly ids for all selected proteomes. The viral and non-viral representative proteome list files are then downloaded from PIR and the selected representative proteomes are extracted. **getIds** then matches proteome and assembly ids and outputs a mapping file mapped.db. 

### 2) getGenomes
The process **getGenomes** takes the mapped.db output of **getIds** as an input and downloads the assembly summary file from NCBI and extracts the FASTA genome assemblies. **getGenomes**  includes error handling steps, and will identify genomes that were not properly downloaded. This will account for broken urls that cause the download of a particular assembly to fail, but also in the event that the download is successful but the assembly summary file does not include a fasta file. **getGenomes** will output a directory of .fna files as well as a .txt file containing a list of all assembly Ids that were not successfully downloaded. 


### 3) getAlternateIds
The process **getAlternateIds** downloads an assembly summary file from NCBI and extracts matched RefSeq and Genbank assembly ids. **getAlternateIds** then reads the .txt file of missing .fna files output by **getGenomes** and identifies the alternate assembly. For example, if an error occurs with a RefSeq assembly file, this process will identify the matched Genbank file. **getAlternateIds** outputs a .txt file containing a list of alternate assembly ids.

**Note:** **getAlternateIds** and the downstream **getAlternateGenomes** will only execute if **getGenomes** identifies genome assemblies that were not successfully downloaded. 

### 4) getAlternateGenome
The process **getAlternateGenomes** takes the .txt output by **getAlternateIds** and repeats the process of **getGenomes**. **getAlternateGenomes** will output any newly downloaded .fna files as well as a second list of genomes that were not successfully downloaded.

### 5) concatZip
The process **concatZip** takes all previously downloaded .fna files as input, concatenates and then compresses the concatenated database file. **concatZip** also takes the two .txt files containing genomes that were not successfully downloaded and combines them into a single list.


###  Optional
Eukaryotic genome file size can be prohibitive to a genomic database build. One strategy to help this is to build the database only using coding sequences for the majority of eukaryotic assemblies. Full genomes for common model organisms as well as specified organisms of interest should be used, but CDS files can be used for all others. This will decrease the overall database size, but the inclusion of coding sequences will ensure that organisms are still identified. The steps taken are similar to the steps outlined above, but additional file parsing steps must be taken to amend the fasta headers for cds files. After parsing is completed by the modified fasta files are moved to the same directory as other files, and all fasta files are concatenated and zipped. This process is not included in the **slimNT.nf** workflow, and the shell script **cds_orgs.sh** must be run separately. The output .gz database file from **cds_orgs.sh** can then be passed into the concatZip process of **slimNT.nf**

