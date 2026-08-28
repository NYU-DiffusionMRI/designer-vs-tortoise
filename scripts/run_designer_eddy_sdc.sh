#!/usr/bin/env bash
#
# run_designer_eddy_sdc.sh
#
# DESIGNER v2 -- eddy-current + motion correction WITH susceptibility
# distortion correction (SDC), using the reverse phase-encoded (PA) b0
# image. This is run_designer_eddy.sh's -rpe_none swapped for -rpe_pair;
# every other setting is unchanged, so this isolates exactly the addition
# of SDC on top of the existing "Eddy-current + motion correction" scope
# item.
#
# Input format / multi-series handling: identical to run_designer_eddy.sh
# -- DESIGNER's native comma-separated list, read directly from input/:
#   Series 28 (V6meso_RMR_b1_Delta63, 21 vols, b~1000)
#   Series 30 (V6meso_RMR_b2_Delta63, 62 vols, b~2000)
# Plus the reverse-PE input for SDC:
#   Series 38 (V6meso_RMR_PA_Delta63, 2 vols, b=0, PhaseEncodingDirection
#              "j", opposite of series 28/30's "j-")
#
# -eddy / -rpe_pair / -pe_dir:
#   Runs FSL eddy for eddy-current and motion correction, using the PA
#   image for EPI/susceptibility distortion correction. Per `designer -h`:
#     -eddy       "run fsl eddy (note that if you choose this command you
#                  must also choose a phase encoding option"
#     -rpe_pair   "Specify the reverse phase encoding image" (a reverse PE
#                  b=0 image -- just the raw NIfTI, no bval/bvec needed)
#   -pe_dir j-  (unchanged from run_designer_eddy.sh) describes the
#               *forward* series' PhaseEncodingDirection; the PA image's
#               own opposite direction ("j") is read from its own JSON
#               sidecar automatically.
#
#   How SDC feeds into eddy (verified against DESIGNER v2.0.16's own
#   source, /app/lib/utils.py and designer_func_wrappers.py, inside the
#   nyudiffusionmri/designer2:v2.0.16 image): DESIGNER does NOT call
#   MRtrix3's dwifslpreproc wrapper -- its own run_eddy() orchestrates FSL
#   directly. run_topup_and_prepare_for_eddy() runs FSL `topup` on the
#   forward/PA b0 pair, then run_fsl_eddy() runs FSL `eddy` with the
#   resulting topup field appended as `--topup=<prefix>` on the eddy
#   command line -- i.e. eddy consumes topup's output via FSL's own native
#   mechanism, all within this single `designer -eddy -rpe_pair ...` call.
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): nyudiffusionmri/designer2:v2.0.16
#
# --gpus all: required for both the FSL `eddy` and FSL `topup` steps
# DESIGNER runs internally (same requirement as run_designer_eddy.sh's
# eddy-only case; topup itself is lightweight but eddy's CUDA path needs
# the GPU visible to the container).
#
# End-to-end: after producing (or finding an existing) dwi_eddy_sdc.nii,
# this script chains into run_tmi.sh to fit DTI/DKI parameter maps.
#
# Usage (from the project root)
# -----
#   ./scripts/run_designer_eddy_sdc.sh [output_dir]
#
# output_dir defaults to output/designer_eddy_sdc (relative to the repo
# root). If output_dir already contains dwi_eddy_sdc.nii (i.e. DESIGNER
# has already been run there), the DESIGNER/docker step is skipped and
# this script goes straight to run_tmi.sh.

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

# --- Resolve output directory (arg 1, default output/designer_eddy_sdc) ----
OUT_DIR_ARG="${1:-output/designer_eddy_sdc}"
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
FINAL_NII="${OUT_DIR}/dwi_eddy_sdc.nii"

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
    echo "== run_designer_eddy_sdc.sh =="
    echo "Output: ${OUT_REL}/dwi_eddy_sdc.nii already exists -- skipping DESIGNER, running tmi only."
    echo
else
    B1_NII="$(find_one '*_b1_*_28.nii')"
    B2_NII="$(find_one '*_b2_*_30.nii')"
    PA_NII="$(find_one '*_PA_*_38.nii')"

    # Paths as seen inside the container (repo root bind-mounted at /data).
    B1_REL="input/$(basename "${B1_NII}")"
    B2_REL="input/$(basename "${B2_NII}")"
    PA_REL="input/$(basename "${PA_NII}")"

    PE_DIR="j-"

    mkdir -p "${OUT_DIR}/scratch"

    echo "== run_designer_eddy_sdc.sh =="
    echo "Image:  ${DESIGNER_IMAGE}"
    echo "Inputs: ${B1_REL} , ${B2_REL}  (native DESIGNER comma-list, not concatenated)"
    echo "Reverse-PE (SDC): ${PA_REL}"
    echo "Step:   -eddy (FSL eddy) + SDC, -rpe_pair ${PA_REL} -pe_dir ${PE_DIR}"
    echo "        (DESIGNER runs FSL topup on the forward/PA b0 pair, then FSL"
    echo "         eddy with --topup=<topup output> -- topup's output feeds eddy"
    echo "         directly, all within this one designer invocation)"
    echo "Output: ${OUT_REL}/dwi_eddy_sdc.nii"
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
            -rpe_pair "/data/${PA_REL}" \
            -pe_dir "${PE_DIR}" \
            -scratch "/data/${OUT_REL}/scratch" \
            -nocleanup \
            "/data/${B1_REL},/data/${B2_REL}" \
            "/data/${OUT_REL}/dwi_eddy_sdc.nii"
fi

echo "== run_designer_eddy_sdc.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
