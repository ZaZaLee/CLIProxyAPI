#!/usr/bin/env bash
#
# Update CLIProxyAPI from Git and rebuild the Docker image on a Linux server.
#
# Default behavior is safe for production:
# - use the existing source checkout; it never clones
# - update the existing repository with a fast-forward merge
# - refuse to continue when tracked files have local changes
# - preserve config.yaml, auths/, and logs/

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_URL="${REPO_URL:-git@github.com:ZaZaLee/CLIProxyAPI.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-${DEFAULT_APP_DIR}}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
CLI_PROXY_IMAGE="${CLI_PROXY_IMAGE:-cli-proxy-api:local}"

# Set FORCE=1 to reset tracked source files to origin/BRANCH.
# Set CLEAN_UNTRACKED=1 together with FORCE=1 to remove untracked files, except
# for config.yaml, auths/, logs/, .env, and common local runtime directories.
FORCE="${FORCE:-0}"
CLEAN_UNTRACKED="${CLEAN_UNTRACKED:-0}"

# Set START_SERVICE=0 to build only.
START_SERVICE="${START_SERVICE:-1}"

# Set PULL_BASE_IMAGES=1 to refresh Docker base images during build when the
# installed Docker Compose supports the build --pull flag.
PULL_BASE_IMAGES="${PULL_BASE_IMAGES:-0}"

# Set PRUNE_OLD_IMAGES=1 to remove dangling images after a successful build.
PRUNE_OLD_IMAGES="${PRUNE_OLD_IMAGES:-0}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
    return
  fi
  die "Docker Compose is not available. Install the Docker Compose plugin or docker-compose."
}

prepare_repo() {
  if [[ ! -d "${APP_DIR}/.git" ]]; then
    die "APP_DIR is not an existing Git repository: ${APP_DIR}"
  fi

  log "Updating repository in ${APP_DIR}"
  git -C "${APP_DIR}" remote set-url origin "${REPO_URL}"
  git -C "${APP_DIR}" fetch --prune origin "${BRANCH}"

  if [[ "${FORCE}" == "1" ]]; then
    log "FORCE=1: resetting tracked files to origin/${BRANCH}"
    git -C "${APP_DIR}" checkout -B "${BRANCH}" "origin/${BRANCH}"
    git -C "${APP_DIR}" reset --hard "origin/${BRANCH}"
    if [[ "${CLEAN_UNTRACKED}" == "1" ]]; then
      log "CLEAN_UNTRACKED=1: removing untracked source files while preserving runtime files"
      git -C "${APP_DIR}" clean -fd \
        -e config.yaml \
        -e .env \
        -e auths/ \
        -e logs/ \
        -e .idea/ \
        -e .vscode/
    fi
    return
  fi

  if [[ -n "$(git -C "${APP_DIR}" status --porcelain)" ]]; then
    die "repository has local changes. Commit/stash them, or rerun with FORCE=1."
  fi

  if git -C "${APP_DIR}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    git -C "${APP_DIR}" checkout "${BRANCH}"
  else
    git -C "${APP_DIR}" checkout -B "${BRANCH}" "origin/${BRANCH}"
  fi
  git -C "${APP_DIR}" merge --ff-only "origin/${BRANCH}"
}

prepare_runtime_files() {
  cd "${APP_DIR}"

  if [[ ! -f config.yaml ]]; then
    if [[ -f config.example.yaml ]]; then
      log "config.yaml not found; creating it from config.example.yaml"
      cp config.example.yaml config.yaml
    else
      die "config.yaml not found and config.example.yaml is unavailable"
    fi
  fi

  mkdir -p auths logs
}

build_image() {
  cd "${APP_DIR}"

  local version commit build_date
  version="$(git describe --tags --always --dirty)"
  commit="$(git rev-parse --short HEAD)"
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  export CLI_PROXY_IMAGE
  export VERSION="${version}"
  export COMMIT="${commit}"
  export BUILD_DATE="${build_date}"

  log "Building Docker image"
  log "Image: ${CLI_PROXY_IMAGE}"
  log "Version: ${VERSION}, Commit: ${COMMIT}, BuildDate: ${BUILD_DATE}"

  local build_flags=()
  if [[ "${PULL_BASE_IMAGES}" == "1" ]]; then
    if "${COMPOSE[@]}" -f "${COMPOSE_FILE}" build --help 2>/dev/null | grep -q -- '--pull'; then
      build_flags+=(--pull)
    else
      log "Docker Compose build --pull is not supported; continuing without it"
    fi
  fi

  "${COMPOSE[@]}" -f "${COMPOSE_FILE}" build \
    "${build_flags[@]}" \
    --build-arg "VERSION=${VERSION}" \
    --build-arg "COMMIT=${COMMIT}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}"
}

start_service() {
  cd "${APP_DIR}"

  if [[ "${START_SERVICE}" != "1" ]]; then
    log "START_SERVICE=0: build completed; service was not restarted"
    return
  fi

  log "Starting service with Docker Compose"
  "${COMPOSE[@]}" -f "${COMPOSE_FILE}" up -d --remove-orphans --pull never
  log "Service is running. Use this command to follow logs:"
  log "cd ${APP_DIR} && ${COMPOSE[*]} -f ${COMPOSE_FILE} logs -f"
}

prune_images() {
  if [[ "${PRUNE_OLD_IMAGES}" != "1" ]]; then
    return
  fi
  log "Removing dangling Docker images"
  docker image prune -f
}

main() {
  need_cmd git
  need_cmd docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not available or current user cannot access it"
  detect_compose

  prepare_repo
  prepare_runtime_files
  build_image
  start_service
  prune_images

  log "Done"
}

main "$@"
