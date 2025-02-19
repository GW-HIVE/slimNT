#!/bin/bash

OUTDIR="output"
RPG75="https://proteininformationresource.org/rps/data/current/75/rpg-75.txt"
RPG55="https://proteininformationresource.org/rps/data/current/55/rpg-55.txt"
VIRUS95="https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-95.txt"
VIRUS75="https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-75.txt"
VIRUS55="https://proteininformationresource.org/download/rps/rpg_virus_all/current/rpg-55.txt"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

logstepstart() {
  log "-------------------- $* --------------------"
}
