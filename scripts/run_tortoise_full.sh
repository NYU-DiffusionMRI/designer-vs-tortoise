#!/usr/bin/env bash
#
# run_tortoise_full.sh
#
# TORTOISE V4 -- FULL pipeline in one invocation: denoising + Gibbs
# de-ringing + motion/eddy-current correction + susceptibility distortion
# correction (SDC / DR-BUDDI), all via a single `TORTOISEProcess_cuda` call.
# Unlike the per-stage scripts in this repo (run_tortoise_denoise.sh,
# run_tortoise_degibbs.sh, run_tortoise_eddy.sh, run_tortoise_eddy_sdc.sh),
# which each isolate exactly one algorithm, this script exercises TORTOISE's
# actual end-to-end production usage: TORTOISEProcess's own fixed internal
# step order is Denoising -> Gibbs -> MotionEddy -> Drift -> EPI (DR-BUDDI
# SDC) -> StructuralAlignment (per `TORTOISEProcess -help`'s --step option;
# see run_tortoise_eddy_sdc.sh's header), so all of these run in sequence
# within this one call.
#
# Input format: identical requirement to the other TORTOISE scripts --
# TORTOISEProcess --up_data takes exactly one NIfTI file, so this consumes
# output/concat/dwi_concat.nii produced by concatenate_inputs.sh
# (dwicat-merge of series 28 + 30). Run concatenate_inputs.sh before this
# script. The reverse-PE image (--down_data) is a single already-independent
# series and does NOT need concatenation -- it is read directly from input/
# (series 38, V6meso_RMR_PA_Delta63, 2 vols, b=0, PhaseEncodingDirection
# "j"). --db/--dv (down bval/bvec) and its JSON are omitted and auto-searched
# next to the NIfTI by TORTOISE, same as run_tortoise_eddy_sdc.sh.
#
# Flags:
#   --denoising for_final   denoising, same as run_tortoise_denoise.sh.
#   --gibbs 1                Gibbs-ringing correction, same as
#                             run_tortoise_degibbs.sh.
#   -c quadratic              motion & eddy-current correction, same as
#                             run_tortoise_eddy.sh / run_tortoise_eddy_sdc.sh
#                             (tool's own default).
#   --epi DRBUDDI --down_data <PA>
#                             SDC via blip-up/blip-down correction, same as
#                             run_tortoise_eddy_sdc.sh. -s/--structural (T1)
#                             is intentionally omitted, for parity with every
#                             other script in this repo.
#   --s2v 0 --repol 0         intra-volume motion + outlier replacement,
#                             disabled (out of scope, same as every other
#                             TORTOISE script).
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): eurotomania/tortoise:latest
#
# GPU: unlike FSL `eddy` (which auto-detects CUDA), TORTOISE does NOT --
# it ships separate TORTOISEProcess (CPU) and TORTOISEProcess_cuda (GPU)
# binaries. Since DR-BUDDI's SDC stage needs it, this script adds --gpus all
# to `docker run` and calls TORTOISEProcess_cuda, same as
# run_tortoise_eddy_sdc.sh.
#
# End-to-end: after producing (or finding an existing) dwi_full.nii, this
# script chains into run_tmi.sh to fit DKI/WDKI parameter maps.
#
# Usage (from the project root)
# -----
#   ./scripts/run_tortoise_full.sh [output_dir]
#
# output_dir defaults to output/tortoise_full (relative to the repo root).
# If output_dir already contains dwi_full.nii (i.e. TORTOISE has already
# been run there), the TORTOISE/docker step is skipped and this script goes
# straight to run_tmi.sh.

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

# --- Resolve output directory (arg 1, default output/tortoise_full) --------
OUT_DIR_ARG="${1:-output/tortoise_full}"
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
FINAL_NII="${OUT_DIR}/dwi_full.nii"

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
    echo "== run_tortoise_full.sh =="
    echo "Output: ${OUT_REL}/dwi_full.nii already exists -- skipping TORTOISE, running tmi only."
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

    echo "== run_tortoise_full.sh =="
    echo "Image:  ${TORTOISE_IMAGE}"
    echo "Input:  output/concat/dwi_concat.nii  (dwicat-merged series 28+30)"
    echo "Reverse-PE (SDC): ${PA_REL}"
    echo "Steps:  --denoising for_final --gibbs 1 -c quadratic --epi DRBUDDI"
    echo "        (one TORTOISEProcess_cuda call; TORTOISE's own step order runs"
    echo "         Denoising -> Gibbs -> MotionEddy -> EPI/SDC internally)"
    echo "Output: ${OUT_REL}/dwi_full.*"
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
            --denoising for_final \
            --gibbs 1 \
            -c quadratic \
            --epi DRBUDDI \
            --s2v 0 \
            --repol 0 \
            --output /data/${OUT_REL}/dwi_full.nii
fi

echo "== run_tortoise_full.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
