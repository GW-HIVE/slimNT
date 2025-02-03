#!/bin/bash

chmod +x ./pipeline/*.sh

./pipeline/1_get_ids.sh
./pipeline/2_get_genomes.sh
./pipeline/3_get_alternate_ids.sh
./pipeline/4_get_alternate_genomes.sh
./pipeline/5_concat_zip.sh
