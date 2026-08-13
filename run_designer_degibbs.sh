#!/usr/bin/env bash
#
# run_designer_degibbs.sh
#
# DESIGNER v2 -- Gibbs-ringing removal step ONLY (RPG). No -denoise, no
# -eddy, no -rpe_*: this isolates exactly the "Gibbs removal: DESIGNER = RPG"
# scope item. Runs on the ORIGINAL input (independent of
# run_designer_denoise.sh's output), per the confirmed "step isolation"
# decision -- each script tests one algorithm in isolation rather than
# chaining denoise -> degibbs.
#
# Input format / multi-series handling: identical to run_designer_denoise.sh
# -- DESIGNER's native comma-separated list, read directly from input/:
#   Series 28 (V6meso_RMR_b1_Delta63, 21 vols, b~1000)
#   Series 30 (V6meso_RMR_b2_Delta63, 62 vols, b~2000)
# Both shells share identical PartialFourier (0.75) and
# PhaseEncodingDirection ("j-"), so a single -pf/-pe_dir pair is valid for
# both -- values taken directly from the JSON sidecars, not guessed.
#
# -degibbs:
#   RPG (Removal of Partial-Fourier induced Gibbs-ringing, Lee et al. 2021).
#   Requires the partial-Fourier factor and phase-encoding direction:
#     -pf 0.75      (PartialFourier: 0.75 in both series' JSON, i.e. 6/8)
#     -pe_dir j-    (PhaseEncodingDirection: "j-" in both series' JSON)
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): nyudiffusionmri/designer2:v2.0.16

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="${SCRIPT_DIR}/input"
OUT_DIR="${SCRIPT_DIR}/output/designer_degibbs"
DESIGNER_IMAGE="nyudiffusionmri/designer2:v2.0.16"

find_one() {
    local pattern="$1"
    local matches=()
    while IFS= read -r -d '' f; do
        matches+=("$f")
    done < <(find "${INPUT_DIR}" -maxdepth 1 -name "${pattern}" -print0)

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

B1_REL="input/$(basename "${B1_NII}")"
B2_REL="input/$(basename "${B2_NII}")"

PF="0.75"
PE_DIR="j-"

mkdir -p "${OUT_DIR}/scratch"

echo "== run_designer_degibbs.sh =="
echo "Image:  ${DESIGNER_IMAGE}"
echo "Inputs: ${B1_REL} , ${B2_REL}  (native DESIGNER comma-list, not concatenated)"
echo "Step:   -degibbs only (RPG), -pf ${PF} -pe_dir ${PE_DIR}"
echo "Output: output/designer_degibbs/dwi_degibbs.nii"
echo

docker run --rm \
    --platform linux/amd64 \
    -v "${SCRIPT_DIR}:/data" \
    -w /data \
    "${DESIGNER_IMAGE}" \
    designer \
        -degibbs \
        -pf "${PF}" \
        -pe_dir "${PE_DIR}" \
        -scratch /data/output/designer_degibbs/scratch \
        -nocleanup \
        "/data/${B1_REL},/data/${B2_REL}" \
        /data/output/designer_degibbs/dwi_degibbs.nii
