#!/usr/bin/env bash
#
# run_tortoise_eddy_sdc.sh
#
# TORTOISE V4 -- eddy-current + motion correction WITH susceptibility
# distortion correction (SDC / DR-BUDDI), using the reverse phase-encoded
# (PA) b0 image. This is run_tortoise_eddy.sh's --epi off swapped for
# --epi DRBUDDI (plus --down_data); every other setting is unchanged, so
# this isolates exactly the addition of SDC on top of the existing
# "Eddy-current + motion correction" scope item.
#
# Input format: identical requirement to run_tortoise_eddy.sh --
# TORTOISEProcess --up_data takes exactly one NIfTI file, so this
# consumes output/concat/dwi_concat.nii produced by concatenate_inputs.sh
# (dwicat-merge of series 28 + 30). Run concatenate_inputs.sh before this
# script. The reverse-PE image (--down_data), unlike --up_data, is a
# single already-independent series and does NOT need concatenation -- it
# is read directly from input/ (series 38, V6meso_RMR_PA_Delta63, 2 vols,
# b=0, PhaseEncodingDirection "j"). --db/--dv (down bval/bvec) and its
# JSON are omitted and auto-searched next to the NIfTI by TORTOISE, same
# auto-search convention already relied on for --up_data's own sidecars.
#
# -c / --correction_mode: unchanged from run_tortoise_eddy.sh (quadratic,
#   the tool's own default -- see that script's header for full rationale).
#
# --epi DRBUDDI / -d (--down_data):
#   Per TORTOISEProcess --help, --epi selects the EPI/susceptibility
#   distortion correction method; DRBUDDI performs "blip-up blip-down
#   correction". -d/--down_data supplies the reverse-PE ("down") NIfTI.
#   -s/--structural (an optional T1 image to help guide DR-BUDDI's
#   registration) is intentionally NOT passed here, to keep parity with
#   every other script in this repo, none of which use the MPRAGE series
#   (series 9) -- confirmed as the user's preferred choice.
#
#   Step order (important, and different from DESIGNER): confirmed via
#   `TORTOISEProcess -help`'s --step option that TORTOISE's own fixed
#   internal pipeline order is Denoising -> Gibbs -> MotionEddy -> Drift
#   -> EPI (DR-BUDDI SDC) -> StructuralAlignment. I.e. TORTOISE natively
#   runs motion+eddy correction BEFORE SDC -- the reverse of DESIGNER/FSL,
#   where topup's field is computed first and fed directly into eddy (see
#   run_designer_eddy_sdc.sh's header). A single TORTOISEProcess call
#   cannot reorder this. Per the user's explicit choice, this script
#   accepts TORTOISE's native order rather than manually reversing it with
#   a two-stage run -- consistent with this repo's philosophy of using
#   each tool's own intended pipeline behavior rather than forcing one
#   tool to mimic the other's internal mechanics.
#
# --s2v 0 --repol 0: unchanged from run_tortoise_eddy.sh (out of scope).
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): eurotomania/tortoise:latest
#
# GPU: unlike FSL `eddy` (which probes nvidia-smi internally and picks
# eddy_cuda* vs eddy_cpu on its own), TORTOISE does NOT auto-detect GPU --
# confirmed by inspecting the image, which ships two separate binaries on
# PATH, TORTOISEProcess (CPU) and TORTOISEProcess_cuda (GPU). This script
# therefore both (a) adds --gpus all to `docker run` (container-level GPU
# visibility -- deliberately re-added here, unlike run_tortoise_eddy.sh,
# where it was removed in commit 98a55f6 because plain motion/eddy doesn't
# need it; DR-BUDDI's diffeomorphic registration stages do) and (b) calls
# TORTOISEProcess_cuda instead of TORTOISEProcess (TORTOISE-level GPU
# selection). Both are required together; neither alone is sufficient.
#
# End-to-end: after producing (or finding an existing) dwi_eddy_sdc.nii,
# this script chains into run_tmi.sh to fit DTI/DKI parameter maps.
#
# Usage (from the project root)
# -----
#   ./scripts/run_tortoise_eddy_sdc.sh [output_dir]
#
# output_dir defaults to output/tortoise_eddy_sdc (relative to the repo
# root). If output_dir already contains dwi_eddy_sdc.nii (i.e. TORTOISE
# has already been run there), the TORTOISE/docker step is skipped and
# this script goes straight to run_tmi.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INPUT_DIR="${PROJECT_ROOT}/input"

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

CONCAT_DIR="${PROJECT_ROOT}/output/concat"
CONCAT_NII="${CONCAT_DIR}/dwi_concat.nii"
TORTOISE_IMAGE="eurotomania/tortoise:latest"

# --- Resolve output directory (arg 1, default output/tortoise_eddy_sdc) ----
OUT_DIR_ARG="${1:-output/tortoise_eddy_sdc}"
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

if [[ -f "${FINAL_NII}" ]]; then
    echo "== run_tortoise_eddy_sdc.sh =="
    echo "Output: ${OUT_REL}/dwi_eddy_sdc.nii already exists -- skipping TORTOISE, running tmi only."
    echo
else
    if [[ ! -f "${CONCAT_NII}" ]]; then
        echo "ERROR: ${CONCAT_NII} not found." >&2
        echo "       Run ./scripts/concatenate_inputs.sh first (dwicat-merges series 28+30)." >&2
        exit 1
    fi

    PA_NII="$(find_one '*_PA_*_38.nii')"
    PA_REL="input/$(basename "${PA_NII}")"

    mkdir -p "${OUT_DIR}"

    echo "== run_tortoise_eddy_sdc.sh =="
    echo "Image:  ${TORTOISE_IMAGE}"
    echo "Input:  output/concat/dwi_concat.nii  (dwicat-merged series 28+30)"
    echo "Reverse-PE (SDC): ${PA_REL}"
    echo "Step:   -c quadratic (motion & eddy-currents) + --epi DRBUDDI (SDC)"
    echo "        (TORTOISE's own step order runs MotionEddy before EPI/SDC --"
    echo "         see script header for rationale on keeping this native order)"
    echo "Output: ${OUT_REL}/dwi_eddy_sdc.*"
    echo

    docker run --rm \
        --platform linux/amd64 \
        --gpus all \
        -v "${PROJECT_ROOT}:/data" \
        "${EXTRA_MOUNTS[@]}" \
        "${TORTOISE_IMAGE}" \
        TORTOISEProcess_cuda \
            --up_data /data/output/concat/dwi_concat.nii \
            --down_data "/data/${PA_REL}" \
            --denoising off \
            --gibbs 0 \
            -c quadratic \
            --epi DRBUDDI \
            --s2v 0 \
            --repol 0 \
            --output /data/${OUT_REL}/dwi_eddy_sdc.nii
fi

echo "== run_tortoise_eddy_sdc.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
