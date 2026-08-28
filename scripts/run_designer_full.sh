#!/usr/bin/env bash
#
# run_designer_full.sh
#
# DESIGNER v2 -- FULL pipeline in one invocation: denoising (MP-PCA) +
# Gibbs de-ringing (RPG) + eddy-current/motion correction + susceptibility
# distortion correction (SDC), all via a single `designer` call. Unlike the
# per-stage scripts in this repo (run_designer_denoise.sh,
# run_designer_degibbs.sh, run_designer_eddy.sh, run_designer_eddy_sdc.sh),
# which each isolate exactly one algorithm starting fresh from raw input/,
# this script exercises DESIGNER's actual end-to-end production usage --
# `designer` accepts all of -denoise/-degibbs/-eddy together and internally
# sequences them itself (denoise -> degibbs -> eddy), regardless of the
# order the flags are given on the command line.
#
# Input format / multi-series handling: identical to the other DESIGNER
# scripts -- DESIGNER's native comma-separated list, read directly from
# input/:
#   Series 28 (V6meso_RMR_b1_Delta63, 21 vols, b~1000)
#   Series 30 (V6meso_RMR_b2_Delta63, 62 vols, b~2000)
# Plus the reverse-PE input for SDC:
#   Series 38 (V6meso_RMR_PA_Delta63, 2 vols, b=0, PhaseEncodingDirection
#              "j", opposite of series 28/30's "j-")
#
# Flags:
#   -denoise                  MP-PCA denoising (default box patch), same as
#                              run_designer_denoise.sh.
#   -degibbs -pf 0.75          RPG Gibbs de-ringing, same as
#                              run_designer_degibbs.sh.
#   -eddy -rpe_pair <PA> -pe_dir j-
#                              FSL eddy for motion/eddy-current correction
#                              with SDC via the PA reverse-PE b0 pair, same
#                              as run_designer_eddy_sdc.sh (DESIGNER runs FSL
#                              topup on the forward/PA b0 pair, then FSL eddy
#                              with --topup=<prefix>, within this one call).
#
#   -normalize: considered and intentionally NOT used here. It rescales each
#   input series so all b=0 images share the same mean intensity, meant to
#   correct scanner-gain drift between separate series -- confirmed with the
#   user that series 28 and 30's intensity scales already match, so this
#   correction is unneeded (would be a no-op at best).
#
#   Known DESIGNER v2.0.16 -rpe_pair bug, worked around below (same as
#   run_designer_eddy_sdc.sh): given a multi-volume RPE image, DESIGNER
#   never imports a gradient table before calling `dwiextract -bzero` on it,
#   so it always fails. Worked around by pre-averaging the PA pair into a
#   single mean b0 volume ourselves, which routes through DESIGNER's
#   single-volume -rpe_pair path instead.
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): nyudiffusionmri/designer2:v2.0.16
#
# --gpus all: required for the FSL `eddy` step DESIGNER runs internally
# (same requirement as run_designer_eddy_sdc.sh; topup itself is
# lightweight but eddy's CUDA path needs the GPU visible to the container).
#
# End-to-end: after producing (or finding an existing) dwi_full.nii, this
# script chains into run_tmi.sh to fit DTI/DKI parameter maps.
#
# Usage (from the project root)
# -----
#   ./scripts/run_designer_full.sh [output_dir]
#
# output_dir defaults to output/designer_full (relative to the repo root).
# If output_dir already contains dwi_full.nii (i.e. DESIGNER has already
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

# --- Resolve output directory (arg 1, default output/designer_full) --------
OUT_DIR_ARG="${1:-output/designer_full}"
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
    echo "== run_designer_full.sh =="
    echo "Output: ${OUT_REL}/dwi_full.nii already exists -- skipping DESIGNER, running tmi only."
    echo
else
    B1_NII="$(find_one '*_b1_*_28.nii')"
    B2_NII="$(find_one '*_b2_*_30.nii')"
    PA_NII="$(find_one '*_PA_*_38.nii')"

    # Paths as seen inside the container (repo root bind-mounted at /data).
    B1_REL="input/$(basename "${B1_NII}")"
    B2_REL="input/$(basename "${B2_NII}")"

    PE_DIR="j-"

    mkdir -p "${OUT_DIR}/scratch"

    # Work around a bug in DESIGNER v2.0.16's own -rpe_pair handling (see
    # run_designer_eddy_sdc.sh for the full explanation): pre-average the PA
    # pair into a single mean-b0 volume so it routes through DESIGNER's
    # single-volume -rpe_pair code path instead of the broken multi-volume one.
    PA_NII_BASENAME="$(basename "${PA_NII%.nii}")"
    PA_MEAN_REL="${OUT_REL}/scratch/${PA_NII_BASENAME}_mean_b0.nii"
    docker run --rm \
        --platform linux/amd64 \
        -v "${PROJECT_ROOT}:/data" \
        "${EXTRA_MOUNTS[@]}" \
        "${DESIGNER_IMAGE}" \
        mrmath "/data/input/$(basename "${PA_NII}")" mean "/data/${PA_MEAN_REL}" -axis 3
    # DESIGNER looks for a .json sidecar at the same basename as -rpe_pair.
    cp "${PA_NII%.nii}.json" "${OUT_DIR}/scratch/${PA_NII_BASENAME}_mean_b0.json"

    echo "== run_designer_full.sh =="
    echo "Image:  ${DESIGNER_IMAGE}"
    echo "Inputs: ${B1_REL} , ${B2_REL}  (native DESIGNER comma-list, not concatenated)"
    echo "Reverse-PE (SDC): ${PA_MEAN_REL}  (mean b0 of input/$(basename "${PA_NII}"))"
    echo "Steps:  -denoise -degibbs -eddy -rpe_pair ${PA_MEAN_REL} -pe_dir ${PE_DIR}"
    echo "        (one designer call; DESIGNER sequences denoise -> degibbs -> eddy"
    echo "         internally, and fuses topup+eddy for SDC within the eddy step)"
    echo "Output: ${OUT_REL}/dwi_full.nii"
    echo

    docker run --rm \
        --platform linux/amd64 \
        --gpus all \
        -v "${PROJECT_ROOT}:/data" \
        "${EXTRA_MOUNTS[@]}" \
        -w /data \
        "${DESIGNER_IMAGE}" \
        designer \
            -denoise \
            -degibbs -pf 0.75 \
            -eddy \
            -rpe_pair "/data/${PA_MEAN_REL}" \
            -pe_dir "${PE_DIR}" \
            -scratch "/data/${OUT_REL}/scratch" \
            -nocleanup \
            "/data/${B1_REL},/data/${B2_REL}" \
            "/data/${OUT_REL}/dwi_full.nii"
fi

echo "== run_designer_full.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
