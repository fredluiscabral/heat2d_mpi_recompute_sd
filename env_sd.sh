#!/bin/bash
# Ambiente recomendado atualmente no manual do SDumont II.
module purge
module load openmpi/gnu/5.0.5.1.0
export PMIX_MCA_psec=^munge
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
