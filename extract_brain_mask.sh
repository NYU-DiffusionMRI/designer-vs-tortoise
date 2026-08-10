#!/usr/bin/env bash
#
# extract_brain_mask.sh
#
# Purpose
# -------
# Neither DESIGNER nor TORTOISE has been run with brain masking enabled yet
# (per the current denoise/degibbs-only scope), and no brain mask exists
# anywhere in this repo. NYU's `tmi` fitting tool (the DESIGNER-v2 companion
# used for DTI/DKI/WDKI/SMI parameter estimation) takes an optional
# `-mask <path>` -- this script produces that mask directly from the
# concatenated DWI, independent of either pipeline.
#
# Pipeline:
#   4D DWI (output/concat/dwi_concat.nii)
#     -> select volumes where bval <= 50 s/mm^2 ("b0 volumes")
#     -> average those b0 volumes voxel-wise (mean b0, 3D)
#     -> FSL bet (skull-strip) on the mean b0
#     -> brain mask
#
# b0 threshold: 50 s/mm^2, not exact-zero -- a common dMRI convention that
# still tolerates near-zero (rather than exactly 0) b-values. On this
# dataset's dwi_concat.bval it selects exactly the 3 true b=0 volumes.
#
# bet -f: 0.2 (more inclusive than FSL's own default of 0.5).
#
# This script is run directly on the HOST (FSL assumed installed locally --
# `bet`/`fslmaths`/`fslselectvols` confirmed present under $FSLDIR on this
# machine), not inside a container -- no FSL Docker image is used anywhere
# else in this repo.
#
# Input
# -----
#   output/concat/dwi_concat.nii   (from concatenate_inputs.sh)
#   output/concat/dwi_concat.bval
#
# Output
# ------
#   output/brain_mask/b0_vols.nii.gz    -- the extracted b0 volumes
#   output/brain_mask/mean_b0.nii.gz    -- voxel-wise mean of the b0 volumes
#   output/brain_mask/brain.nii.gz      -- bet's skull-stripped brain image
#   output/brain_mask/brain_mask.nii.gz -- the binary brain mask (bet -m)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONCAT_DIR="${SCRIPT_DIR}/output/concat"
DWI_NII="${CONCAT_DIR}/dwi_concat.nii"
BVAL_FILE="${CONCAT_DIR}/dwi_concat.bval"
OUT_DIR="${SCRIPT_DIR}/output/brain_mask"

B0_THRESHOLD=50

for tool in bet fslmaths fslselectvols; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "ERROR: '${tool}' not found on PATH. This script assumes a local" >&2
        echo "       FSL install (FSLDIR=${FSLDIR:-<unset>})." >&2
        exit 1
    fi
done

if [[ ! -f "${DWI_NII}" ]] || [[ ! -f "${BVAL_FILE}" ]]; then
    echo "ERROR: ${DWI_NII} and/or ${BVAL_FILE} not found." >&2
    echo "       Run concatenate_inputs.sh first." >&2
    exit 1
fi

B0_INDICES="$(awk -v thr="${B0_THRESHOLD}" '{
    n = 0
    for (i = 1; i <= NF; i++) {
        if ($i <= thr) {
            if (n > 0) printf ","
            printf "%d", i - 1
            n++
        }
    }
}' "${BVAL_FILE}")"

if [[ -z "${B0_INDICES}" ]]; then
    echo "ERROR: no volumes with bval <= ${B0_THRESHOLD} found in ${BVAL_FILE}." >&2
    exit 1
fi

echo "== extract_brain_mask.sh =="
echo "Input: ${DWI_NII}"
echo "b0 volumes (bval <= ${B0_THRESHOLD}): ${B0_INDICES}"
echo

mkdir -p "${OUT_DIR}"

fslselectvols -i "${DWI_NII}" -o "${OUT_DIR}/b0_vols" --vols="${B0_INDICES}"
fslmaths "${OUT_DIR}/b0_vols" -Tmean "${OUT_DIR}/mean_b0"
bet "${OUT_DIR}/mean_b0" "${OUT_DIR}/brain" -m -f 0.2

echo "Wrote:"
echo "  ${OUT_DIR}/b0_vols.nii.gz"
echo "  ${OUT_DIR}/mean_b0.nii.gz"
echo "  ${OUT_DIR}/brain.nii.gz"
echo "  ${OUT_DIR}/brain_mask.nii.gz"
