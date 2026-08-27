#!/usr/bin/env bash
#
# concatenate_inputs.sh
#
# Purpose
# -------
# TORTOISE V4's `TORTOISEProcess --up_data` accepts exactly ONE NIfTI file
# (confirmed against the TORTOISEV4 README usage examples: no comma-list /
# multi-series support like DESIGNER has). Our acquisition has two DWI shells
# as separate series, so they must be merged into a single 4D file before
# TORTOISE can see them at all.
#
# The correct MRtrix3 tool for this is `dwicat`, NOT raw `mrcat`. `dwicat` is
# purpose-built to "concatenate multiple DWI series accounting for
# differential intensity scaling" (see `dwicat -help`) -- it matches b=0
# intensities across series before concatenating. Raw `mrcat -axis 3` is a
# generic image-concatenation command with no DWI-aware handling of gradient
# tables or inter-series intensity drift, so it is the wrong tool here.
#
# This script is run directly on the HOST (MRtrix3 assumed installed
# locally), not inside a container -- concatenation is not part of either
# vendor's Docker image and is upstream of both pipelines.
#
# What gets combined, and why
# ----------------------------
# Series 28 (V6meso_RMR_b1_Delta63, 21 vols, b~1000) and series 30
# (V6meso_RMR_b2_Delta63, 62 vols, b~2000) are the two DWI shells of the
# SAME acquisition: identical matrix/geometry, identical
# PhaseEncodingDirection ("j-"), identical PartialFourier (0.75). These are
# the only two series combined here, producing an 83-volume multi-shell DWI.
#
# Explicitly excluded, and why:
#   - series 9  (MPRAGE)            -- anatomical T1, not a DWI series.
#   - series 29_ph / 31_ph          -- these are NOT reverse phase-encoded
#     acquisitions. Their JSON sidecars show ImageType containing "P"/
#     "PHASE", SeriesDescription suffixed "_PHASE", BidsGuess tagged
#     "part-phase", and an all-zero bval/bvec placeholder identical in
#     volume count/geometry/PE-direction to their magnitude twin (28, 30).
#     They are the scanner's complex-reconstruction PHASE image paired with
#     each magnitude series -- relevant only to complex-valued MP-PCA
#     denoising (DESIGNER's `-phase` flag), which is out of scope here per
#     the current denoising/Gibbs-only, magnitude-pipeline comparison.
#   - series 38 / 39_ph (V6meso_RMR_PA_Delta63) -- this IS the true
#     reverse-phase-encoded pair (PhaseEncodingDirection "j", opposite of
#     "j-" on series 28/30). It exists solely for topup/eddy susceptibility
#     distortion correction, which is explicitly out of the current scope
#     (denoising + Gibbs removal only).
#
# DESIGNER does NOT consume this script's output. Per the documented,
# intended DESIGNER usage (`designer [opts] seriesA.nii,seriesB.nii output`),
# the DESIGNER scripts read series 28/30 directly from input/ as a native
# comma-separated multi-series input. Feeding DESIGNER the dwicat-harmonized
# file instead would silently import TORTOISE-only intensity rescaling into
# the DESIGNER arm, which biases rather than neutralizes the comparison.
#
# Output
# ------
#   output/concat/dwi_concat.nii
#   output/concat/dwi_concat.bval
#   output/concat/dwi_concat.bvec
#   output/concat/dwi_concat.json
#
# This output is consumed by run_tortoise_denoise.sh and
# run_tortoise_degibbs.sh only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INPUT_DIR="${PROJECT_ROOT}/input"
OUT_DIR="${PROJECT_ROOT}/output/concat"
OUT_BASENAME="dwi_concat"

if ! command -v dwicat >/dev/null 2>&1; then
    echo "ERROR: 'dwicat' not found on PATH. This script assumes a local" >&2
    echo "       MRtrix3 install (per user's confirmed setup choice)." >&2
    exit 1
fi

find_one() {
    # find_one <glob pattern relative to INPUT_DIR>
    local pattern="$1"
    local matches=()
    while IFS= read -r -d '' f; do
        matches+=("$f")
    done < <(find -L "${INPUT_DIR}" -maxdepth 1 -name "${pattern}" -print0)

    if [[ ${#matches[@]} -eq 0 ]]; then
        echo "ERROR: no file in ${INPUT_DIR} matching '${pattern}'" >&2
        exit 1
    elif [[ ${#matches[@]} -gt 1 ]]; then
        echo "ERROR: multiple files in ${INPUT_DIR} matching '${pattern}':" >&2
        printf '  %s\n' "${matches[@]}" >&2
        exit 1
    fi
    printf '%s\n' "${matches[0]}"
}

B1_NII="$(find_one '*_b1_*_28.nii')"
B2_NII="$(find_one '*_b2_*_30.nii')"

# MRtrix3 does NOT auto-detect identically-named .bval/.bvec sidecars next
# to a plain .nii -- that auto-pairing is a dcm2niix/FSL/BIDS-tooling
# convention, not an MRtrix3 one (confirmed against the dw_scheme docs,
# which only document -grad/-fslgrad and header-embedded schemes). Passing
# the raw .nii straight to dwicat therefore fails with "does not contain a
# gradient table". Fix: explicitly embed each series' gradient table (and
# JSON metadata) into a .mif first via mrconvert -fslgrad/-json_import, then
# hand dwicat the .mif files, which do carry the DW scheme in their headers.
B1_BVEC="${B1_NII%.nii}.bvec"
B1_BVAL="${B1_NII%.nii}.bval"
B1_JSON="${B1_NII%.nii}.json"
B2_BVEC="${B2_NII%.nii}.bvec"
B2_BVAL="${B2_NII%.nii}.bval"
B2_JSON="${B2_NII%.nii}.json"

for f in "${B1_BVEC}" "${B1_BVAL}" "${B1_JSON}" "${B2_BVEC}" "${B2_BVAL}" "${B2_JSON}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: expected sidecar file not found: ${f}" >&2
        exit 1
    fi
done

echo "== concatenate_inputs.sh =="
echo "Shell 1 (b~1000, 21 vols): ${B1_NII}"
echo "Shell 2 (b~2000, 62 vols): ${B2_NII}"
echo "Tool: dwicat (MRtrix3) -- intensity-scaling-aware DWI series concatenation"
echo "Excluded from concatenation: series 9 (MPRAGE), 29_ph, 31_ph (phase recon"
echo "  pairs, not reverse-PE), 38/39_ph (reverse-PE topup pair, out of scope)."
echo

mkdir -p "${OUT_DIR}/tmp"

# Embed each series' gradient table + JSON header into a .mif so dwicat has
# a DW scheme to work with.
mrconvert "${B1_NII}" -fslgrad "${B1_BVEC}" "${B1_BVAL}" -json_import "${B1_JSON}" \
    "${OUT_DIR}/tmp/b1.mif" -force
mrconvert "${B2_NII}" -fslgrad "${B2_BVEC}" "${B2_BVAL}" -json_import "${B2_JSON}" \
    "${OUT_DIR}/tmp/b2.mif" -force

dwicat \
    "${OUT_DIR}/tmp/b1.mif" \
    "${OUT_DIR}/tmp/b2.mif" \
    "${OUT_DIR}/tmp/${OUT_BASENAME}.mif" \
    -force

# Convert the concatenated .mif to plain NIfTI + FSL bvec/bval + JSON for
# TORTOISE. This mrconvert call also carries the concatenated DW gradient
# table (dwicat merges the two input DW schemes when it merges the volumes)
# through to the exported bvec/bval.
mrconvert "${OUT_DIR}/tmp/${OUT_BASENAME}.mif" "${OUT_DIR}/${OUT_BASENAME}.nii" \
    -export_grad_fsl "${OUT_DIR}/${OUT_BASENAME}.bvec" "${OUT_DIR}/${OUT_BASENAME}.bval" \
    -json_export "${OUT_DIR}/${OUT_BASENAME}.json" \
    -force

echo "Wrote:"
echo "  ${OUT_DIR}/${OUT_BASENAME}.nii"
echo "  ${OUT_DIR}/${OUT_BASENAME}.bval"
echo "  ${OUT_DIR}/${OUT_BASENAME}.bvec"
echo "  ${OUT_DIR}/${OUT_BASENAME}.json"
echo "(this is TORTOISE's --up_data input only -- DESIGNER reads input/ directly)"

rm -rf "${OUT_DIR}/tmp"
