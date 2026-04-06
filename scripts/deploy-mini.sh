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
#   bash scripts/deploy-mini.sh --camofox    # deploy Camofox browser sidecar
#   bash scripts/deploy-mini.sh --openwebui  # deploy Open WebUI
#
# Prerequisites:
#   - Docker running locally
#   - SSH access to openclaw@mini (key-based auth recommended)
#   - Docker running on the Mac mini
#   - For stage: ~/.hermes-stage/ on the Mini with .env and config.yaml
# ============================================================================

set -euo pipefail

# --- Preflight: verify Docker context ----------------------------------------
CURRENT_CONTEXT=$(docker context show 2>/dev/null)
if [[ "$CURRENT_CONTEXT" != "mini" ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m Docker context is '${CURRENT_CONTEXT}', expected 'mini'."
    echo "       Run: docker context use mini"
    exit 1
fi

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

# --- Camofox defaults --------------------------------------------------------
CAMOFOX_REPO="https://github.com/jo-inc/camofox-browser.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMOFOX_BUILD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/../camofox"
CAMOFOX_IMAGE="camofox-browser:latest"
CAMOFOX_TARBALL="/tmp/camofox-image.tar.gz"
CAMOFOX_REMOTE_TARBALL="/tmp/camofox-image.tar.gz"
CAMOFOX_CONTAINER="camofox"
CAMOFOX_PORT="9377"
CAMOFOX_PROFILE_DIR="~/.camofox-profiles"

# --- Open WebUI defaults -----------------------------------------------------
OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
OPENWEBUI_CONTAINER="open-webui"
OPENWEBUI_PORT="3000"
OPENWEBUI_DATA_DIR="~/.open-webui"

# --- Options -----------------------------------------------------------------
SKIP_BUILD=false
SKIP_HERMES=false
STAGE=false
CAMOFOX=false
OPENWEBUI=false

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
        --skip-build)  SKIP_BUILD=true; shift ;;
        --skip-hermes) SKIP_HERMES=true; shift ;;
        --stage)       STAGE=true; shift ;;
        --camofox)     CAMOFOX=true; shift ;;
        --openwebui)   OPENWEBUI=true; shift ;;
        -h|--help)
            echo "Usage: deploy-mini.sh [--stage] [--skip-build] [--skip-hermes] [--camofox] [--openwebui] [-h|--help]"
            echo ""
            echo "  --stage        Deploy to stage environment (hermes-stage container)"
            echo "  --skip-build   Skip Docker build, reuse existing local image"
            echo "  --skip-hermes  Skip Hermes deployment entirely (use with --camofox/--openwebui)"
            echo "  --camofox      Deploy Camofox browser sidecar on the Mac mini"
            echo "  --openwebui    Deploy Open WebUI on the Mac mini"
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
cleanup() { rm -f "$TARBALL" "$CAMOFOX_TARBALL"; }
trap cleanup EXIT

# --- Hermes deployment (skipped with --skip-hermes) --------------------------
if [[ "$SKIP_HERMES" == true ]]; then
    warn "Skipping Hermes deployment (--skip-hermes)"
else

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

# --- Copy .env.stage for stage deployments -----------------------------------
if [[ "$STAGE" == true ]]; then
    step "Copying .env.stage to ${REMOTE_DATA_DIR}/.env"
    ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_DATA_DIR}"
    rsync -ah .env.stage "${REMOTE_HOST}:${REMOTE_DATA_DIR}/.env"
    ok ".env.stage deployed"
fi

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

fi # end --skip-hermes guard

# --- Deploy Camofox sidecar --------------------------------------------------
if [[ "$CAMOFOX" == true ]]; then
    step "Deploying Camofox browser sidecar"

    info "Building Camofox locally (ARCH=aarch64)"
    if [[ -d "$CAMOFOX_BUILD_DIR" ]]; then
        git -C "$CAMOFOX_BUILD_DIR" pull --ff-only
    else
        git clone "$CAMOFOX_REPO" "$CAMOFOX_BUILD_DIR"
    fi
    make -C "$CAMOFOX_BUILD_DIR" build ARCH=aarch64
    # The Makefile tags as camofox-browser:<version>-<arch>; re-tag for deploy
    CAMOFOX_BUILT_TAG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^camofox-browser:' | head -1)
    docker tag "$CAMOFOX_BUILT_TAG" "$CAMOFOX_IMAGE"
    ok "Image built: $CAMOFOX_IMAGE (from $CAMOFOX_BUILT_TAG)"

    info "Saving Camofox image to tarball"
    docker save "$CAMOFOX_IMAGE" | gzip > "$CAMOFOX_TARBALL"
    CAMOFOX_TARBALL_SIZE=$(du -h "$CAMOFOX_TARBALL" | cut -f1)
    ok "Saved $CAMOFOX_IMAGE ($CAMOFOX_TARBALL_SIZE)"

    info "Transferring Camofox image to $REMOTE_HOST"
    rsync -ahP "$CAMOFOX_TARBALL" "${REMOTE_HOST}:${CAMOFOX_REMOTE_TARBALL}"
    ok "Transfer complete"

    info "Loading Camofox image on $REMOTE_HOST"
    ssh "$REMOTE_HOST" "gunzip -c ${CAMOFOX_REMOTE_TARBALL} | docker load"
    ssh "$REMOTE_HOST" "rm -f ${CAMOFOX_REMOTE_TARBALL}"
    ok "Image loaded"

    info "Stopping existing Camofox container"
    ssh "$REMOTE_HOST" bash <<REMOTE_CAMOFOX_STOP
if docker ps -a --format '{{.Names}}' | grep -qx ${CAMOFOX_CONTAINER}; then
    echo "Stopping '${CAMOFOX_CONTAINER}'..."
    docker stop -t ${STOP_TIMEOUT} ${CAMOFOX_CONTAINER} 2>/dev/null || true
    docker rm ${CAMOFOX_CONTAINER} 2>/dev/null || true
    echo "Removed old container."
else
    echo "No existing Camofox container found."
fi
REMOTE_CAMOFOX_STOP
    ok "Ready for new Camofox container"

    ssh "$REMOTE_HOST" "mkdir -p ${CAMOFOX_PROFILE_DIR}"
    ssh "$REMOTE_HOST" docker run -d \
        --name "$CAMOFOX_CONTAINER" \
        --restart unless-stopped \
        --network claw-net \
        --memory="1g" \
        --cpus="1" \
        --shm-size="512m" \
        -e CAMOFOX_PORT="$CAMOFOX_PORT" \
        -e CAMOFOX_PROFILE_DIR=/profiles \
        -v "${CAMOFOX_PROFILE_DIR}:/profiles" \
        -p "${CAMOFOX_PORT}:${CAMOFOX_PORT}" \
        "$CAMOFOX_IMAGE"
    ok "Container '$CAMOFOX_CONTAINER' started on port $CAMOFOX_PORT"
fi

# --- Deploy Open WebUI -------------------------------------------------------
if [[ "$OPENWEBUI" == true ]]; then
    step "Deploying Open WebUI"

    info "Pulling $OPENWEBUI_IMAGE on $REMOTE_HOST"
    ssh "$REMOTE_HOST" "docker pull $OPENWEBUI_IMAGE"
    ok "Image pulled"

    info "Stopping existing Open WebUI container"
    ssh "$REMOTE_HOST" bash <<REMOTE_OPENWEBUI_STOP
if docker ps -a --format '{{.Names}}' | grep -qx ${OPENWEBUI_CONTAINER}; then
    echo "Stopping '${OPENWEBUI_CONTAINER}'..."
    docker stop -t ${STOP_TIMEOUT} ${OPENWEBUI_CONTAINER} 2>/dev/null || true
    docker rm ${OPENWEBUI_CONTAINER} 2>/dev/null || true
    echo "Removed old container."
else
    echo "No existing Open WebUI container found."
fi
REMOTE_OPENWEBUI_STOP
    ok "Ready for new Open WebUI container"

    ssh "$REMOTE_HOST" "mkdir -p ${OPENWEBUI_DATA_DIR}"
    ssh "$REMOTE_HOST" docker run -d \
        --name "$OPENWEBUI_CONTAINER" \
        --restart unless-stopped \
        --network claw-net \
        --memory="2g" \
        --cpus="1" \
        -v "${OPENWEBUI_DATA_DIR}:/app/backend/data" \
        -p "${OPENWEBUI_PORT}:8080" \
        "$OPENWEBUI_IMAGE"
    ok "Container '$OPENWEBUI_CONTAINER' started on port $OPENWEBUI_PORT"
fi

# --- Verify ------------------------------------------------------------------
step "Done — ${CONTAINER_NAME}"
ssh "$REMOTE_HOST" "docker ps --filter name=${CONTAINER_NAME} --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'"
if [[ "$CAMOFOX" == true ]]; then
    ssh "$REMOTE_HOST" "docker ps --filter name=${CAMOFOX_CONTAINER} --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'"
fi
if [[ "$OPENWEBUI" == true ]]; then
    ssh "$REMOTE_HOST" "docker ps --filter name=${OPENWEBUI_CONTAINER} --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'"
fi
echo ""
info "Logs:  ssh $REMOTE_HOST docker logs -f $CONTAINER_NAME"
info "Stop:  ssh $REMOTE_HOST docker stop $CONTAINER_NAME"
if [[ "$CAMOFOX" == true ]]; then
    info "Camofox logs:  ssh $REMOTE_HOST docker logs -f $CAMOFOX_CONTAINER"
    info "Camofox stop:  ssh $REMOTE_HOST docker stop $CAMOFOX_CONTAINER"
    info "Set CAMOFOX_URL=http://${CAMOFOX_CONTAINER}:${CAMOFOX_PORT} in your Hermes .env"
fi
if [[ "$OPENWEBUI" == true ]]; then
    info "Open WebUI logs:  ssh $REMOTE_HOST docker logs -f $OPENWEBUI_CONTAINER"
    info "Open WebUI stop:  ssh $REMOTE_HOST docker stop $OPENWEBUI_CONTAINER"
    info "Open WebUI UI:    http://mini:${OPENWEBUI_PORT}"
fi
if [[ "$STAGE" == true ]]; then
    info "Data:  $REMOTE_DATA_DIR on $REMOTE_HOST"
    info "Nuke:  ssh $REMOTE_HOST 'docker rm -f $CONTAINER_NAME && rm -rf $REMOTE_DATA_DIR'"
fi
