#!/usr/bin/env bash
#
# Update CLIProxyAPI from Git, build a container image on a k3s host, push it
# to Harbor, and optionally roll the Kubernetes deployment.

set -Eeuo pipefail

if [ ! -x "$0" ]; then
  chmod +x "$0"
  exec "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REPO_URL="${REPO_URL:-git@github.com:ZaZaLee/CLIProxyAPI.git}"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-${DEFAULT_APP_DIR}}"

HARBOR_REGISTRY="${HARBOR_REGISTRY:-sig-harbor.vancygame.com}"
HARBOR_URL="${HARBOR_URL:-https://sig-harbor.vancygame.com}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-tG8dS1mP6yA0tB9x}"
HARBOR_PROJECT="${HARBOR_PROJECT:-ai}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-cli-proxy-api}"
TAG="${TAG:-ai-sig}"

CONTAINERD_SOCK="${CONTAINERD_SOCK:-unix:///run/k3s/containerd/containerd.sock}"
CONTAINERD_NAMESPACE="${CONTAINERD_NAMESPACE:-k8s.io}"

# Set FORCE=1 to reset tracked source files to origin/BRANCH.
# Set CLEAN_UNTRACKED=1 together with FORCE=1 to remove untracked files, except
# for config.yaml, auths/, logs/, .env, and common local runtime directories.
FORCE="${FORCE:-0}"
CLEAN_UNTRACKED="${CLEAN_UNTRACKED:-0}"

PULL_BASE_IMAGES="${PULL_BASE_IMAGES:-0}"
PUSH_IMAGE="${PUSH_IMAGE:-1}"
UPDATE_K8S="${UPDATE_K8S:-1}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-ai}"
KUBE_DEPLOYMENT="${KUBE_DEPLOYMENT:-cli-proxy-api}"
KUBE_CONTAINER="${KUBE_CONTAINER:-cli-proxy-api}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
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

detect_container_tool() {
  if command -v nerdctl >/dev/null 2>&1; then
    CONTAINER_CMD=(nerdctl --address "${CONTAINERD_SOCK}" --namespace "${CONTAINERD_NAMESPACE}" --insecure-registry)
    CONTAINER_TYPE="nerdctl"
    log "Using container tool: nerdctl (${CONTAINERD_NAMESPACE}, ${CONTAINERD_SOCK})"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD=(docker)
    CONTAINER_TYPE="docker"
    log "Using container tool: docker"
    return
  fi

  die "neither nerdctl nor docker is available"
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
        -e home/ \
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

  if [[ ! -f config.yaml && -f config.example.yaml ]]; then
    log "config.yaml not found; creating it from config.example.yaml"
    cp config.example.yaml config.yaml
  fi

  mkdir -p auths home logs
}

login_harbor() {
  if [[ "${PUSH_IMAGE}" != "1" ]]; then
    return
  fi

  [[ -n "${HARBOR_USERNAME}" ]] || die "HARBOR_USERNAME is empty"
  [[ -n "${HARBOR_PASSWORD}" ]] || die "HARBOR_PASSWORD is empty"

  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  log "Logging in to Harbor: ${HARBOR_URL}"
  "${CONTAINER_CMD[@]}" login -u "${HARBOR_USERNAME}" -p "${HARBOR_PASSWORD}" "${HARBOR_REGISTRY}"
}

build_image() {
  cd "${APP_DIR}"

  local version commit build_date
  version="$(git describe --tags --always --dirty)"
  commit="$(git rev-parse --short HEAD)"
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  FULL_IMAGE_NAME="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_REPOSITORY}:${TAG}"

  log "Building container image"
  log "Image: ${FULL_IMAGE_NAME}"
  log "Version: ${version}, Commit: ${commit}, BuildDate: ${build_date}"

  local build_flags=(-t "${FULL_IMAGE_NAME}")
  if [[ "${PULL_BASE_IMAGES}" == "1" ]]; then
    build_flags+=(--pull)
  fi

  "${CONTAINER_CMD[@]}" build \
    "${build_flags[@]}" \
    --build-arg "VERSION=${version}" \
    --build-arg "COMMIT=${commit}" \
    --build-arg "BUILD_DATE=${build_date}" \
    .
}

push_image() {
  if [[ "${PUSH_IMAGE}" != "1" ]]; then
    log "PUSH_IMAGE=0: skipped Harbor push"
    return
  fi

  log "Pushing image: ${FULL_IMAGE_NAME}"
  if ! "${CONTAINER_CMD[@]}" push "${FULL_IMAGE_NAME}"; then
    log "Push failed; retrying after Harbor login"
    "${CONTAINER_CMD[@]}" login -u "${HARBOR_USERNAME}" -p "${HARBOR_PASSWORD}" "${HARBOR_REGISTRY}"
    "${CONTAINER_CMD[@]}" push "${FULL_IMAGE_NAME}"
  fi

  "${CONTAINER_CMD[@]}" logout "${HARBOR_REGISTRY}" >/dev/null 2>&1 || true
}

update_k8s() {
  if [[ "${UPDATE_K8S}" != "1" ]]; then
    log "UPDATE_K8S=0: skipped Kubernetes rollout"
    return
  fi

  need_cmd kubectl
  log "Updating Kubernetes deployment ${KUBE_NAMESPACE}/${KUBE_DEPLOYMENT}"
  kubectl -n "${KUBE_NAMESPACE}" set image \
    "deployment/${KUBE_DEPLOYMENT}" \
    "${KUBE_CONTAINER}=${FULL_IMAGE_NAME}"
  kubectl -n "${KUBE_NAMESPACE}" rollout restart "deployment/${KUBE_DEPLOYMENT}"
  kubectl -n "${KUBE_NAMESPACE}" rollout status \
    "deployment/${KUBE_DEPLOYMENT}" \
    --timeout="${ROLLOUT_TIMEOUT}"
}

prune_images() {
  if [[ "${PRUNE_OLD_IMAGES}" != "1" ]]; then
    return
  fi

  log "Removing dangling container images"
  "${CONTAINER_CMD[@]}" image prune -f
}

main() {
  need_cmd git
  detect_container_tool
  "${CONTAINER_CMD[@]}" version >/dev/null 2>&1 || die "${CONTAINER_TYPE} is not available"

  prepare_repo
  prepare_runtime_files
  login_harbor
  build_image
  push_image
  update_k8s
  prune_images

  log "Done: ${FULL_IMAGE_NAME}"
}

main "$@"
