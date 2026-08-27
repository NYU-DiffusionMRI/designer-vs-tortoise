#!/usr/bin/env bash
#
# run_designer_eddy.sh
#
# DESIGNER v2 -- eddy-current and subject motion correction ONLY (FSL eddy,
# no reverse phase-encoding data). No -denoise, no -degibbs: this isolates
# exactly the "Eddy-current + motion correction" scope item.
#
# Input format / multi-series handling: identical to run_designer_denoise.sh
# / run_designer_degibbs.sh -- DESIGNER's native comma-separated list, read
# directly from input/, not pre-concatenated (see concatenate_inputs.sh and
# the plan's fair-comparison rationale: DESIGNER should be exercised exactly
# as its own docs describe, not fed TORTOISE's intensity-harmonized file):
#   Series 28 (V6meso_RMR_b1_Delta63, 21 vols, b~1000)
#   Series 30 (V6meso_RMR_b2_Delta63, 62 vols, b~2000)
#
# -eddy / -rpe_none / -pe_dir:
#   Runs FSL eddy for eddy-current and motion correction. Per `designer -h`:
#     -eddy       "run fsl eddy (note that if you choose this command you
#                  must also choose a phase encoding option"
#     -rpe_none   "Specify that no reversed phase-encoding image data is
#                  being provided; eddy will perform eddy current and motion
#                  correction only"
#   Reverse phase-encoded data (series _38/_39_ph) is intentionally NOT used
#   here -- per DESIGNER's own docs, that data is only needed for EPI/
#   susceptibility distortion correction (topup), which is a separate,
#   explicitly out-of-scope comparison for now. -rpe_none is the documented
#   mode for "eddy current and motion correction only".
#   -pe_dir j-  (PhaseEncodingDirection: "j-" in both series' JSON, same
#               value already used in run_designer_degibbs.sh) -- required
#               whenever -eddy is used.
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): nyudiffusionmri/designer2:v2.0.16
#
# End-to-end: after producing (or finding an existing) dwi_eddy.nii, this
# script chains into run_tmi.sh to fit DTI/DKI parameter maps -- so a single
# invocation goes from raw input through preprocessing to parametric maps.
#
# Usage (from the project root)
# -----
#   ./scripts/run_designer_eddy.sh [output_dir]
#
# output_dir defaults to output/designer_eddy (relative to the repo root).
# If output_dir already contains dwi_eddy.nii (i.e. DESIGNER has already
# been run there), the DESIGNER/docker step is skipped and this script goes
# straight to run_tmi.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INPUT_DIR="${PROJECT_ROOT}/input"
DESIGNER_IMAGE="nyudiffusionmri/designer2:v2.0.16"

# input/ and output/ may be symlinks to a network mount (e.g. CIFS). Docker's
# bind mount below does not follow host symlinks out of PROJECT_ROOT, so the
# container would see a dangling symlink. Mount each symlink's real target at
# the same absolute path so it resolves correctly inside the container too.
EXTRA_MOUNTS=()
for _d in input output; do
    if [[ -L "${PROJECT_ROOT}/${_d}" ]]; then
        _target="$(readlink -f "${PROJECT_ROOT}/${_d}")"
        EXTRA_MOUNTS+=(-v "${_target}:${_target}")
    fi
done

# --- Resolve output directory (arg 1, default output/designer_eddy) --------
OUT_DIR_ARG="${1:-output/designer_eddy}"
case "${OUT_DIR_ARG}" in
    /*) OUT_DIR="${OUT_DIR_ARG}" ;;
    *)  OUT_DIR="${PROJECT_ROOT}/${OUT_DIR_ARG}" ;;
esac

case "${OUT_DIR}" in
    "${PROJECT_ROOT}"/*) ;;
    *)
        echo "ERROR: output dir ${OUT_DIR} is outside the repo (${PROJECT_ROOT})." >&2
        echo "       Docker only mounts the repo root, so the output dir must live inside it." >&2
        exit 1
        ;;
esac

OUT_REL="${OUT_DIR#"${PROJECT_ROOT}"/}"
FINAL_NII="${OUT_DIR}/dwi_eddy.nii"

find_one() {
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

if [[ -f "${FINAL_NII}" ]]; then
    echo "== run_designer_eddy.sh =="
    echo "Output: ${OUT_REL}/dwi_eddy.nii already exists -- skipping DESIGNER, running tmi only."
    echo
else
    B1_NII="$(find_one '*_b1_*_28.nii')"
    B2_NII="$(find_one '*_b2_*_30.nii')"

    # Paths as seen inside the container (repo root bind-mounted at /data).
    B1_REL="input/$(basename "${B1_NII}")"
    B2_REL="input/$(basename "${B2_NII}")"

    PE_DIR="j-"

    mkdir -p "${OUT_DIR}/scratch"

    echo "== run_designer_eddy.sh =="
    echo "Image:  ${DESIGNER_IMAGE}"
    echo "Inputs: ${B1_REL} , ${B2_REL}  (native DESIGNER comma-list, not concatenated)"
    echo "Step:   -eddy only (FSL eddy), -rpe_none -pe_dir ${PE_DIR} (no reverse-PE data)"
    echo "Output: ${OUT_REL}/dwi_eddy.nii"
    echo

    docker run --rm \
        --platform linux/amd64 \
        --gpus all \
        -v "${PROJECT_ROOT}:/data" \
        "${EXTRA_MOUNTS[@]}" \
        -w /data \
        "${DESIGNER_IMAGE}" \
        designer \
            -eddy \
            -rpe_none \
            -pe_dir "${PE_DIR}" \
            -scratch "/data/${OUT_REL}/scratch" \
            -nocleanup \
            "/data/${B1_REL},/data/${B2_REL}" \
            "/data/${OUT_REL}/dwi_eddy.nii"
fi

echo "== run_designer_eddy.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
