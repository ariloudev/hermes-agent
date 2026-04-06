#!/bin/bash
# ============================================================================
# Hermes Agent — Deploy to Mac mini (prod + stage)
# ============================================================================
# Builds the Docker image locally and deploys it to the Mac mini.
# Supports both production and stage environments.
#
# Usage:
#   bash scripts/deploy-mini.sh              # deploy to prod
#   bash scripts/deploy-mini.sh --stage      # deploy to stage
#   bash scripts/deploy-mini.sh --skip-build # reuse existing image
#   bash scripts/deploy-mini.sh --stage --skip-build
#
# Prerequisites:
#   - Docker running locally
#   - SSH access to openclaw@mini (key-based auth recommended)
#   - Docker running on the Mac mini
#   - For stage: ~/.hermes-stage/ on the Mini with .env and config.yaml
# ============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
IMAGE_NAME="hermes-agent"
IMAGE_TAG="latest"
IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
REMOTE_HOST="openclaw@mini"
TARBALL="/tmp/hermes-agent-image.tar.gz"
REMOTE_TARBALL="/tmp/hermes-agent-image.tar.gz"
STOP_TIMEOUT=30

# --- Defaults (prod) — overridden by --stage --------------------------------
CONTAINER_NAME="hermes"
REMOTE_DATA_DIR="~/.hermes"
MEMORY_LIMIT="4g"
SHM_SIZE="1g"
CPU_LIMIT="2"
API_PORT="8642"

# --- Options -----------------------------------------------------------------
SKIP_BUILD=false
STAGE=false

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${BOLD}==> $*${NC}"; }

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build) SKIP_BUILD=true; shift ;;
        --stage)      STAGE=true; shift ;;
        -h|--help)
            echo "Usage: deploy-mini.sh [--stage] [--skip-build] [-h|--help]"
            echo ""
            echo "  --stage        Deploy to stage environment (hermes-stage container)"
            echo "  --skip-build   Skip Docker build, reuse existing local image"
            echo "  -h, --help     Show this help message"
            exit 0
            ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Apply stage overrides ---------------------------------------------------
if [[ "$STAGE" == true ]]; then
    CONTAINER_NAME="hermes-stage"
    REMOTE_DATA_DIR="~/.hermes-stage"
    MEMORY_LIMIT="3g"
    SHM_SIZE="512m"
    CPU_LIMIT="1.5"
    API_PORT="8643"
    info "Deploying to ${BOLD}STAGE${NC} environment"
else
    info "Deploying to ${BOLD}PRODUCTION${NC} environment"
fi

# --- Cleanup trap ------------------------------------------------------------
cleanup() { rm -f "$TARBALL"; }
trap cleanup EXIT

# --- Step 1: Build -----------------------------------------------------------
step "1/6 Building Docker image"
if [[ "$SKIP_BUILD" == true ]]; then
    warn "Skipping build (--skip-build)"
    if ! docker image inspect "$IMAGE" &>/dev/null; then
        err "Image $IMAGE not found locally. Run without --skip-build."
        exit 1
    fi
else
    docker build -t "$IMAGE" .
fi
ok "Image ready: $IMAGE"

# --- Step 2: Save to tarball -------------------------------------------------
step "2/6 Saving image to tarball"
docker save "$IMAGE" | gzip > "$TARBALL"
TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
ok "Saved $IMAGE ($TARBALL_SIZE)"

# --- Step 3: Transfer to Mac mini -------------------------------------------
step "3/6 Transferring to $REMOTE_HOST"
rsync -ahP "$TARBALL" "${REMOTE_HOST}:${REMOTE_TARBALL}"
ok "Transfer complete"

# --- Step 4: Load image on remote -------------------------------------------
step "4/6 Loading image on $REMOTE_HOST"
ssh "$REMOTE_HOST" "gunzip -c ${REMOTE_TARBALL} | docker load"
ok "Image loaded"

# --- Step 5: Stop existing container ----------------------------------------
step "5/6 Stopping existing container"
ssh "$REMOTE_HOST" bash <<REMOTE_STOP
if docker ps -a --format '{{.Names}}' | grep -qx ${CONTAINER_NAME}; then
    echo "Stopping '${CONTAINER_NAME}'..."
    docker stop -t ${STOP_TIMEOUT} ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
    echo "Removed old container."
else
    echo "No existing container found."
fi
REMOTE_STOP
ok "Ready for new container"

# --- Step 6: Start new container ---------------------------------------------
step "6/6 Starting new container"
ssh "$REMOTE_HOST" docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network claw-net \
    --memory="$MEMORY_LIMIT" \
    --cpus="$CPU_LIMIT" \
    --shm-size="$SHM_SIZE" \
    -v "${REMOTE_DATA_DIR}:/opt/data" \
    -e API_SERVER_ENABLED=true \
    -e API_SERVER_HOST=0.0.0.0 \
    -p "${API_PORT}:8642" \
    "$IMAGE" \
    gateway run
ok "Container '$CONTAINER_NAME' started"

# --- Cleanup remote tarball --------------------------------------------------
ssh "$REMOTE_HOST" "rm -f ${REMOTE_TARBALL}"

# --- Verify ------------------------------------------------------------------
step "Done — ${CONTAINER_NAME}"
ssh "$REMOTE_HOST" "docker ps --filter name=${CONTAINER_NAME} --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'"
echo ""
info "Logs:  ssh $REMOTE_HOST docker logs -f $CONTAINER_NAME"
info "Stop:  ssh $REMOTE_HOST docker stop $CONTAINER_NAME"
if [[ "$STAGE" == true ]]; then
    info "Data:  $REMOTE_DATA_DIR on $REMOTE_HOST"
    info "Nuke:  ssh $REMOTE_HOST 'docker rm -f $CONTAINER_NAME && rm -rf $REMOTE_DATA_DIR'"
fi
