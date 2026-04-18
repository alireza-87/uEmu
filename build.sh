#!/bin/bash
# Build the uEmu Docker image
set -e

IMAGE="${UEMU_IMAGE:-uemu}"
TAG="${UEMU_TAG:-latest}"
DOCKERFILE="${DOCKERFILE:-$(dirname "$0")/Dockerfile}"

bold()  { echo -e "\033[1m$*\033[0m"; }
green() { echo -e "\033[1;32m$*\033[0m"; }
red()   { echo -e "\033[1;31m$*\033[0m"; }
cyan()  { echo -e "\033[1;36m$*\033[0m"; }

usage() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -i, --image NAME    Image name        (default: uemu)"
    echo "  -t, --tag   TAG     Image tag         (default: latest)"
    echo "  --no-cache          Build without cache"
    echo "  -h, --help          Show this help"
    echo
    echo "Environment overrides:"
    echo "  UEMU_IMAGE=name  UEMU_TAG=tag  ./build.sh"
    exit 0
}

NO_CACHE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--image)   IMAGE="$2";   shift 2 ;;
        -t|--tag)     TAG="$2";     shift 2 ;;
        --no-cache)   NO_CACHE="--no-cache"; shift ;;
        -h|--help)    usage ;;
        *) red "Unknown option: $1"; usage ;;
    esac
done

FULL_IMAGE="${IMAGE}:${TAG}"
CONTEXT_DIR="$(dirname "$(realpath "$0")")"

bold "╔══════════════════════════════════╗"
bold "║       uEmu Docker Builder        ║"
bold "╚══════════════════════════════════╝"
echo
cyan "  Image   : $FULL_IMAGE"
cyan "  Context : $CONTEXT_DIR"
cyan "  Cache   : ${NO_CACHE:-(enabled)}"
echo

# Sanity checks
[[ -f "$DOCKERFILE" ]] || { red "Dockerfile not found: $DOCKERFILE"; exit 1; }

for f in uEmu-helper.py launch-uEmu-template.sh launch-AFL-template.sh \
          uEmu-config-template.lua library.lua docker-entrypoint.sh; do
    [[ -f "$CONTEXT_DIR/$f" ]] || { red "Missing required file: $f"; exit 1; }
done

START=$(date +%s)

docker build \
    $NO_CACHE \
    -f "$DOCKERFILE" \
    -t "$FULL_IMAGE" \
    "$CONTEXT_DIR"

END=$(date +%s)
ELAPSED=$(( END - START ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

echo
green "Build complete: $FULL_IMAGE  (${MINS}m ${SECS}s)"
echo
echo "  Run:    ./run.sh"
echo "  Or:     UEMU_IMAGE=$IMAGE UEMU_TAG=$TAG ./run.sh"
