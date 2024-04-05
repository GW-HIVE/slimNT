# slimNT

slimNT has been developed to provide a curated, streamlined version of the NT database. Metagenomic anaylses can be difficult and time consuming when querying against the ####total number of genomes in NT####, and the necessary indexing step is resource heavy; both time and computationally. slimNT aims to ##solve## that problem by strategically subsetting the NT database to create a compact, user-defined databse that is tailored to specific needs.

The slimNT database is derived from Representative Proteome (RPs) and Reference Proteome Groups (RPGs) provided by [Protein Information Resource (PIR)](https://proteininformationresource.org/rps/). Reference proteomes and viral reference proteomes can be selected based on a desired cutoff thresholds. Selecting a higher cutoff value will create a larger, more robust database that will lend to increased accuracy at the expense of computation time. Conversely, selecting a lower threshold will result in a database that can be queried more quickly, but may only identify more distantly related sequences.

## Data Collection

A list of non-viral proteome IDs are generated from PIR. Cut-off values of [(75%)](https://proteininformationresource.org/rps/data/current/75/rpg-75.txt), [(55%)](https://proteininformationresource.org/rps/data/current/55/rpg-55.txt), [(35%)](https://proteininformationresource.org/rps/data/current/35/rpg-35.txt), and [(15%)](https://proteininformationresource.org/rps/data/current/15/rpg-15.txt). These options will result in 18614, 11895, 6072, and 1989 RPGs respectively. 

A list of viral proteome IDs are generated similarly. Cut-off values of [(95%)](https://proteininformationresource.org/rps/viruses/data/current/95/rpg-95.txt), [(75%)](https://proteininformationresource.org/rps/viruses/data/current/75/rpg-75.txt), [(55%)](https://proteininformationresource.org/rps/viruses/data/current/55/rpg-55.txt), [(35%)](https://proteininformationresource.org/rps/viruses/data/current/35/rpg-35.txt), [(15%)](https://proteininformationresource.org/rps/viruses/data/current/15/rpg-15.txt), resiulting in 15502, 10256, 7971, 6334, 4689 RPGs. 

There is a secondary group of viral RPGs that include polyproteoms that can be found [here](https://proteininformationresource.org/download/rps/rpg_virus_all/current/).

This version of slimNT was designed to be as diverse and robust as possible, and the highest cut-offs were selected (95% cut-off for viral RPGs including polyproteomes, and 75% cutt-off for all others.)

### 1) 
###script name### downloads a .txt file and parses out proteome IDs for all selected proteomes. ###script name### then reads through .txt file and extracts genome assembly ids from the reference file ###reference file name###. zipped fasta files are then downloaded from NCBI for all assembly IDs.

### 2)
QC steps are taken to identify empty fasta files and saved to a secondary .txt file. ###python script### is then used to read the list of empty files and print a new file with alternate refseq/genbank ids. This new list is then passed back into ##script## and fastas are downloaded again. An additional check is conducted to identify any remaining empty files, and they are notated.

### 3) Optional
Eukaryotic genomic filesize can be prohibitve to a genomic databse build. One strategy to help this, is to build the database only using coding sequences for the majority of eukaryotic assemblies. Full genomes for common model organisms as well as specified organisms of interest should be used, but CDS files can be used for all others. This will decrease the overall database size, but the inclusion of coding sequences will ensure that organims are still identified. The steps taken are similar to the steps outlined above, but additional file parsing steps must be taked to ammend the fasta headers for cds files. After parsing is completed by ###script###, the modified fasta files are moved to the same directory as other files, and all fasta files are concatenated and zipped. This new zipped file is slimNT.

