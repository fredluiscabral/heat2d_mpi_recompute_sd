#!/bin/bash
set -euo pipefail

source ./env_sd.sh
make clean
make -j5
mpicxx --version | head -n 2
