# READ ME for Version Controlled and Separate Compression Files
The slimNT pipeline has been updated to include version control and the ability to run the compression of the database separately from the rest of the pipeline.
The steps to perform this piepline are in the Main Page READ ME. They are also posted below.

## Steps to Run the Pipeline
1. Gain access to the GW HPC Pegasus server. To gain access fill out the form on this [GW HPC help site](https://it.gwu.edu/high-performance-computing-access-request)
2. Once you have access to this pegasus server and you are logged in, navigate to this filepath **/scratch/hivelab/slimNT-sean/slimNT**
3. To run the slimNT pipeline simply write the command **sbatch run_pipeline.sh --version 1.2436** in the command line.
   - The version flag must be used in order to run the code successfully. The version number will appear after the _ in the filename ex : slimNT_##.fa
5. Use slurm commands to analyze and monitor the computation: squeue, sstat, or sacct
6. Genomes that did not map will be found in the file **missing_fna.txt** in this location: **/scratch/hivelab/slimNT-sean/slimNT/output**
7. The database file, **slimNT_##.fa** is created from the run_pipeline.sh file. In order to compress the database file, use **run_compression.sh**:
    - sbatch run_compression.sh --version 1234
9. The outputs of this pipeline is **slimNT_version.fa** and **slimNT_version.fa.gz** in the filepath: **/scratch/hivelab/slimNT-sean/slimNT/output**

Note: If you are viewing the code scripts, make sure to use Nano or Cat. Vi hides the slurm controllers at the top of the scripts.

## White List Capability
The pipeline has the capability to take in a white list file of wanted additional organisms. This is is implemented and performed in the file for step 1, **1_get_ids.sh**. 
- To create the white list, enter the names of the organisms of interest in a .txt file. Each name should be its own row, no commas or semi-colons, and no spaces after the name.
- In line 16 in the script **1_get_ids.sh**, make sure that the name of your file is entered here and associated with the variable _WHITELIST_FILE_.
- If a whitelist file was not given, a default list is there beginning at line 17. This default list can be updated as well. 


