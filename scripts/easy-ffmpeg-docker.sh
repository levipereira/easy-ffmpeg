#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# easy-ffmpeg wrapper for the dockerized CUDA image.
#
# Removes the boilerplate of typing `docker run --gpus all -v ... easy-ffmpeg:cuda`
# every time. Auto-mounts the input's directory, auto-generates the output
# filename, and passes everything else through to easy-ffmpeg.
#
# Usage:
#   easy-ffmpeg -i <input> [-f <format>] [easy-ffmpeg options...]
#
# The output filename is generated next to the input as:
#   <input_stem>_<tags>_<YYYYMMDDHHMMSS>.<format>
# where <tags> is the set of preset / mode flags passed (e.g. compress_gpu,
# vr360-full_gpu).
# -----------------------------------------------------------------------------
set -euo pipefail

IMAGE="${IMAGE:-easy-ffmpeg:cuda}"

c_cyan()  { printf '\033[1;36m%s\033[0m' "$*"; }
c_dim()   { printf '\033[2m%s\033[0m' "$*"; }

show_wrapper_help() {
  cat <<EOF
$(c_cyan "easy-ffmpeg")  Docker wrapper for the NVIDIA-accelerated CUDA image
$(c_dim "  image: $IMAGE")

$(c_cyan "Usage")
  easy-ffmpeg -i <input> [-f <format>] [easy-ffmpeg options...]

$(c_cyan "Wrapper flags")
  -i, --input PATH      Input video file (required)
  -f, --format FORMAT   Output format: mp4, mkv, mov, webm, avi, ts, gif
                        (also accepted positionally for back-compat)
  -h, --help            Show this help and the full easy-ffmpeg help below

$(c_cyan "Output")
  Auto-generated next to the input as:
    <input_stem>_<tags>_<YYYYMMDDHHMMSS>.<format>

$(c_cyan "Examples")
  easy-ffmpeg -i movie.mkv -f mp4 --compress --gpu
  easy-ffmpeg -i ~/videos/foo.mp4 -f mp4 --web --gpu
  easy-ffmpeg -i clip.ts -f mkv --streaming --gpu --scale fullhd
  easy-ffmpeg -i raw360.mp4 -f mp4 --vr360 full --gpu
  easy-ffmpeg -i stitched4k.mp4 -f mp4 --vr360 encode --gpu --scale 1080p

$(c_cyan "Environment")
  IMAGE   Override the Docker image tag (default: easy-ffmpeg:cuda)

All other options are passed through to easy-ffmpeg inside the container.

EOF
  # Forward the real CLI help so users see every inner flag.
  if command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf '\033[1;36m─── easy-ffmpeg (inside the image) ───\033[0m\n\n'
    docker run --rm "$IMAGE" --help 2>/dev/null || true
  else
    printf '\033[2m(Docker image %s not available — run scripts/docker-build.sh to install it.)\033[0m\n' "$IMAGE"
  fi
}

# ---------------------------------------------------------------------------
# Parse args. -i takes the input, -f takes the output format. Everything else
# is passed through to easy-ffmpeg.
# ---------------------------------------------------------------------------
INPUT=""
FORMAT=""
declare -a PASS_THROUGH=()

while (( $# > 0 )); do
  case "$1" in
    -i|--input)
      [ $# -ge 2 ] || { echo "error: $1 requires a path" >&2; exit 1; }
      INPUT="$2"
      shift 2
      ;;
    -i=*|--input=*)
      INPUT="${1#*=}"
      shift
      ;;
    -f|--format)
      [ $# -ge 2 ] || { echo "error: $1 requires a value (mp4, mkv, mov, webm, avi, ts, gif)" >&2; exit 1; }
      FORMAT="$2"
      shift 2
      ;;
    -f=*|--format=*)
      FORMAT="${1#*=}"
      shift
      ;;
    -h|--help)
      show_wrapper_help
      exit 0
      ;;
    *)
      PASS_THROUGH+=("$1")
      shift
      ;;
  esac
done

[ -n "$INPUT" ] || { echo "error: -i <input> is required (try -h for help)" >&2; exit 1; }
[ -f "$INPUT" ] || { echo "error: input not found: $INPUT" >&2; exit 1; }

# Resolve to absolute paths so the docker mount works for relative inputs too.
INPUT_ABS="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
INPUT_DIR="$(dirname "$INPUT_ABS")"
INPUT_NAME="$(basename "$INPUT_ABS")"
INPUT_STEM="${INPUT_NAME%.*}"

# ---------------------------------------------------------------------------
# Resolve the output format.
#   1. -f / --format (canonical, recommended)
#   2. First positional in pass-through (backwards-compatible: matches
#      easy-ffmpeg's own positional <format> arg)
# ---------------------------------------------------------------------------
if [ -z "$FORMAT" ]; then
  for arg in "${PASS_THROUGH[@]}"; do
    if [[ "$arg" != -* ]]; then
      FORMAT="$arg"
      break
    fi
  done
fi

[ -n "$FORMAT" ] || {
  echo "error: missing output format" >&2
  echo "       pass it with -f <format> (mp4, mkv, mov, webm, avi, ts, gif)" >&2
  echo "       usage: $0 -i <input> -f <format> [options...]" >&2
  exit 1
}

# If -f was used, we own the format and must NOT also put it in the
# positional slot (easy-ffmpeg would treat it as a duplicate). If the user
# typed it positionally (backwards-compat path), it stays in PASS_THROUGH.
USED_F_FLAG=false
case " ${PASS_THROUGH[*]:-} " in
  *" $FORMAT "*) : ;;          # format is already in PASS_THROUGH (positional)
  *) USED_F_FLAG=true ;;       # format came from -f / --format
esac

# ---------------------------------------------------------------------------
# Build the auto-generated output filename. Includes the preset/mode flags
# the user passed so different runs don't clobber each other.
# ---------------------------------------------------------------------------
declare -a TAGS=()
prev=""
for arg in "${PASS_THROUGH[@]}"; do
  case "$arg" in
    --web|--mobile|--streaming|--compress|--gpu|--no-subs|--crop|--force)
      TAGS+=("${arg#--}")
      ;;
    --vr360)
      ;;  # value captured on next iteration via $prev
    *)
      if [ "$prev" = "--vr360" ]; then
        TAGS+=("vr360-${arg}")
      fi
      ;;
  esac
  prev="$arg"
done

TIMESTAMP="$(date +%Y%m%d%H%M%S)"

SUFFIX=""
if [ ${#TAGS[@]} -gt 0 ]; then
  joined="$(IFS=_; echo "${TAGS[*]}")"
  SUFFIX="_${joined}"
fi

AUTO_OUTPUT_NAME="${INPUT_STEM}${SUFFIX}_${TIMESTAMP}.${FORMAT}"

# Refuse to overwrite if the user happened to also pass -o themselves.
USER_PROVIDED_OUTPUT=false
for arg in "${PASS_THROUGH[@]}"; do
  case "$arg" in
    -o|--output|-o=*|--output=*) USER_PROVIDED_OUTPUT=true; break ;;
  esac
done

if $USER_PROVIDED_OUTPUT; then
  echo "error: this wrapper auto-generates the output path." >&2
  echo "       drop -o from your args, or invoke 'docker run' directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------
CONTAINER_INPUT="/work/${INPUT_NAME}"
CONTAINER_OUTPUT="/work/${AUTO_OUTPUT_NAME}"

printf '\033[1;36m▶ input:  \033[0m%s\n'  "$INPUT_ABS"
printf '\033[1;36m▶ format: \033[0m%s\n'  "$FORMAT"
printf '\033[1;36m▶ output: \033[0m%s/%s\n' "$INPUT_DIR" "$AUTO_OUTPUT_NAME"
printf '\033[1;36m▶ image:  \033[0m%s\n'  "$IMAGE"
echo ""

# Compose the container command. When -f was used, prepend the format to the
# positional slot ourselves. When it came positionally, it's already in
# PASS_THROUGH so we just pass it through unchanged.
if $USED_F_FLAG; then
  exec docker run --rm --gpus all \
    -v "$INPUT_DIR:/work" \
    "$IMAGE" \
    "$CONTAINER_INPUT" "$FORMAT" \
    "${PASS_THROUGH[@]}" \
    -o "$CONTAINER_OUTPUT"
else
  exec docker run --rm --gpus all \
    -v "$INPUT_DIR:/work" \
    "$IMAGE" \
    "$CONTAINER_INPUT" \
    "${PASS_THROUGH[@]}" \
    -o "$CONTAINER_OUTPUT"
fi
