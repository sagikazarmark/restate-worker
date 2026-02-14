#!/usr/bin/env bash
# dagger-cache — Companion tool for persisting Dagger cache to S3-compatible storage
# Works with ANY CI provider. Zero changes to Dagger engine.
#
# Usage:
#   ./dagger-cache.sh run call build --source .
#   ./dagger-cache.sh run call test --source .
#
# Environment variables:
#   DAGGER_CACHE_BUCKET      (required) S3 bucket name
#   DAGGER_CACHE_KEY          Cache key (default: dirname of pwd)
#   DAGGER_CACHE_FALLBACK_KEY Fallback cache key (default: none)
#   DAGGER_CACHE_ENDPOINT     Custom S3 endpoint (for MinIO, R2, etc.)
#   DAGGER_CACHE_REGION       S3 region (default: us-east-1)
#   DAGGER_CACHE_MAX_SIZE     Max cache size to sync (default: 20G)
#   DAGGER_CACHE_DIR          Local cache directory (default: /tmp/dagger-engine-cache)
#   DAGGER_VERSION            Engine version (default: auto-detect from CLI)
#   DAGGER_CACHE_PRUNE        Run GC before saving (default: true)
#   DAGGER_CACHE_VERBOSE      Enable verbose logging (default: false)
#   DAGGER_CACHE_SKIP_RESTORE Skip cache restore (default: false)
#   DAGGER_CACHE_SKIP_SAVE    Skip cache save (default: false)
#   DAGGER_CACHE_BACKEND      rclone backend type (default: s3)
#
# Requires: rclone, docker, dagger CLI
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────

CACHE_BUCKET="${DAGGER_CACHE_BUCKET:?Error: Set DAGGER_CACHE_BUCKET}"
CACHE_KEY="${DAGGER_CACHE_KEY:-$(basename "$(pwd)")}"
CACHE_FALLBACK_KEY="${DAGGER_CACHE_FALLBACK_KEY:-}"
CACHE_ENDPOINT="${DAGGER_CACHE_ENDPOINT:-}"
CACHE_REGION="${DAGGER_CACHE_REGION:-us-east-1}"
CACHE_MAX_SIZE="${DAGGER_CACHE_MAX_SIZE:-20G}"
CACHE_DIR="${DAGGER_CACHE_DIR:-/tmp/dagger-engine-cache}"
CACHE_PRUNE="${DAGGER_CACHE_PRUNE:-true}"
CACHE_VERBOSE="${DAGGER_CACHE_VERBOSE:-false}"
CACHE_SKIP_RESTORE="${DAGGER_CACHE_SKIP_RESTORE:-false}"
CACHE_SKIP_SAVE="${DAGGER_CACHE_SKIP_SAVE:-false}"
CACHE_BACKEND="${DAGGER_CACHE_BACKEND:-s3}"

ENGINE_NAME="dagger-engine-cached-$$"
ENGINE_READY_TIMEOUT=60

# Auto-detect Dagger version
if [[ -z "${DAGGER_VERSION:-}" ]]; then
    DAGGER_VERSION=$(dagger version 2>/dev/null | head -1 | awk '{print $2}' || echo "v0.19.11")
fi

# Ensure version has v prefix (engine image tags require it)
DAGGER_VERSION="v${DAGGER_VERSION#v}"

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

log() { echo "[dagger-cache] $*" >&2; }
log_verbose() { [[ "$CACHE_VERBOSE" == "true" ]] && log "$*" || true; }
die() { log "ERROR: $*"; exit 1; }

cleanup() {
    log "Cleaning up engine container..."
    docker rm -f "${ENGINE_NAME}" 2>/dev/null || true
    rm -f "${RCLONE_CONFIG_FILE}" 2>/dev/null || true
}

# Set up rclone config file to avoid inline config parsing issues
# (inline `:s3,...:bucket` breaks when endpoint URLs contain colons)
RCLONE_CONFIG_FILE=""
setup_rclone_config() {
    RCLONE_CONFIG_FILE=$(mktemp /tmp/rclone-dagger-XXXXXX.conf)

    case "${CACHE_BACKEND}" in
        s3)
            cat > "${RCLONE_CONFIG_FILE}" <<EOF
[cache]
type = s3
provider = Other
region = ${CACHE_REGION}
$([ -n "${CACHE_ENDPOINT}" ] && echo "endpoint = ${CACHE_ENDPOINT}")
EOF
            ;;
        gcs)
            cat > "${RCLONE_CONFIG_FILE}" <<EOF
[cache]
type = gcs
EOF
            ;;
        azureblob)
            cat > "${RCLONE_CONFIG_FILE}" <<EOF
[cache]
type = azureblob
EOF
            ;;
        r2)
            cat > "${RCLONE_CONFIG_FILE}" <<EOF
[cache]
type = s3
provider = Cloudflare
endpoint = ${CACHE_ENDPOINT:?Set DAGGER_CACHE_ENDPOINT for R2}
EOF
            ;;
        *)
            die "Unsupported backend: ${CACHE_BACKEND}"
            ;;
    esac

    log_verbose "rclone config written to ${RCLONE_CONFIG_FILE}"
}

# Build rclone remote path
rclone_remote() {
    local key="$1"
    echo "cache:${CACHE_BUCKET}/${key}/"
}

# Common rclone flags (populated as a global array)
RCLONE_FLAGS=()
setup_rclone_flags() {
    RCLONE_FLAGS=(
        --config "${RCLONE_CONFIG_FILE}"
        --fast-list
        --transfers 16
        --checkers 32
        --stats-one-line
        --stats 10s
        --exclude 'executor/**'
        --exclude '*.tmp'
        --exclude '*.lock'
        --exclude 'runc-overlayfs/**'
    )

    if [[ "${CACHE_VERBOSE}" == "true" ]]; then
        RCLONE_FLAGS+=(--verbose)
    else
        RCLONE_FLAGS+=(--quiet)
    fi
}
setup_rclone_config
setup_rclone_flags

# ──────────────────────────────────────────────────────────────────────────────
# Phase 1: Restore cache
# ──────────────────────────────────────────────────────────────────────────────

restore_cache() {
    if [[ "${CACHE_SKIP_RESTORE}" == "true" ]]; then
        log "Skipping cache restore (DAGGER_CACHE_SKIP_RESTORE=true)"
        return 0
    fi

    mkdir -p "${CACHE_DIR}"

    local remote
    remote=$(rclone_remote "${CACHE_KEY}")

    log "Restoring cache from ${CACHE_BACKEND}://${CACHE_BUCKET}/${CACHE_KEY}/..."
    local start_time=$SECONDS

    # Try primary key
    if rclone sync "${RCLONE_FLAGS[@]}" "${remote}" "${CACHE_DIR}/" 2>&1; then
        local size
        size=$(du -sh "${CACHE_DIR}" 2>/dev/null | awk '{print $1}' || echo "unknown")
        local elapsed=$(( SECONDS - start_time ))
        log "Cache restored: ${size} in ${elapsed}s"
        return 0
    fi

    # Try fallback key
    if [[ -n "${CACHE_FALLBACK_KEY}" ]]; then
        log "Primary cache miss, trying fallback: ${CACHE_FALLBACK_KEY}"
        remote=$(rclone_remote "${CACHE_FALLBACK_KEY}")

        if rclone sync "${RCLONE_FLAGS[@]}" "${remote}" "${CACHE_DIR}/" 2>&1; then
            local size
            size=$(du -sh "${CACHE_DIR}" 2>/dev/null | awk '{print $1}' || echo "unknown")
            local elapsed=$(( SECONDS - start_time ))
            log "Fallback cache restored: ${size} in ${elapsed}s"
            return 0
        fi
    fi

    log "No existing cache found, starting fresh"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 2: Start engine
# ──────────────────────────────────────────────────────────────────────────────

start_engine() {
    log "Starting Dagger engine ${DAGGER_VERSION} with cached state..."

    # Stop any existing auto-provisioned engine
    docker rm -f "$(docker ps -q --filter 'name=dagger-engine')" 2>/dev/null || true

    # Start engine with cache volume
    docker run -d --privileged \
        --name "${ENGINE_NAME}" \
        -v "${CACHE_DIR}:/var/lib/dagger" \
        "registry.dagger.io/engine:${DAGGER_VERSION}" \
        || die "Failed to start Dagger engine"

    # Wait for engine to be ready
    log "Waiting for engine to be ready..."
    local i=0
    while [[ $i -lt $ENGINE_READY_TIMEOUT ]]; do
        if docker exec "${ENGINE_NAME}" buildctl debug workers >/dev/null 2>&1; then
            log "Engine ready"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    die "Engine failed to start within ${ENGINE_READY_TIMEOUT}s"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 3: Run dagger command
# ──────────────────────────────────────────────────────────────────────────────

run_dagger() {
    export _EXPERIMENTAL_DAGGER_RUNNER_HOST="container://${ENGINE_NAME}"

    log "Running: dagger $*"
    log "Engine: ${ENGINE_NAME} (${_EXPERIMENTAL_DAGGER_RUNNER_HOST})"

    # Pass through to dagger CLI
    dagger "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 4: Save cache
# ──────────────────────────────────────────────────────────────────────────────

save_cache() {
    if [[ "${CACHE_SKIP_SAVE}" == "true" ]]; then
        log "Skipping cache save (DAGGER_CACHE_SKIP_SAVE=true)"
        return 0
    fi

    # Stop engine cleanly (important for BoltDB consistency)
    log "Stopping engine for clean shutdown..."
    docker stop "${ENGINE_NAME}" --timeout 30 2>/dev/null || true

    # Fix ownership of cache files (engine runs as root inside Docker)
    log "Fixing cache file permissions..."
    sudo chown -R "$(id -u):$(id -g)" "${CACHE_DIR}" 2>/dev/null || true

    local remote
    remote=$(rclone_remote "${CACHE_KEY}")

    log "Saving cache to ${CACHE_BACKEND}://${CACHE_BUCKET}/${CACHE_KEY}/..."
    local start_time=$SECONDS

    # Check cache size
    local size
    size=$(du -sh "${CACHE_DIR}" 2>/dev/null | awk '{print $1}' || echo "unknown")
    log "Cache size: ${size}"

    if rclone sync "${RCLONE_FLAGS[@]}" "${CACHE_DIR}/" "${remote}" 2>&1; then
        local elapsed=$(( SECONDS - start_time ))
        log "Cache saved in ${elapsed}s"
    else
        log "WARNING: Cache save failed (non-fatal)"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Subcommands
# ──────────────────────────────────────────────────────────────────────────────

cmd_run() {
    # Full lifecycle: restore → start → run → save → cleanup
    trap cleanup EXIT

    restore_cache
    start_engine

    local exit_code=0
    run_dagger "$@" || exit_code=$?

    save_cache
    cleanup

    exit ${exit_code}
}

cmd_restore() {
    # Just restore cache (for use in CI steps)
    restore_cache
    log "Cache restored to ${CACHE_DIR}"
    log "Start engine with: docker run -d --privileged -v ${CACHE_DIR}:/var/lib/dagger --name dagger-engine registry.dagger.io/engine:${DAGGER_VERSION}"
    log "Then set: export _EXPERIMENTAL_DAGGER_RUNNER_HOST=container://dagger-engine"
}

cmd_save() {
    # Just save cache (for use in CI steps)
    save_cache
}

cmd_info() {
    echo "dagger-cache configuration:"
    echo "  Backend:      ${CACHE_BACKEND}"
    echo "  Bucket:       ${CACHE_BUCKET}"
    echo "  Key:          ${CACHE_KEY}"
    echo "  Fallback:     ${CACHE_FALLBACK_KEY:-none}"
    echo "  Endpoint:     ${CACHE_ENDPOINT:-default}"
    echo "  Region:       ${CACHE_REGION}"
    echo "  Cache Dir:    ${CACHE_DIR}"
    echo "  Engine Ver:   ${DAGGER_VERSION}"
    echo "  Max Size:     ${CACHE_MAX_SIZE}"
    echo ""

    if [[ -d "${CACHE_DIR}" ]]; then
        echo "Local cache:"
        echo "  Size: $(du -sh "${CACHE_DIR}" 2>/dev/null | awk '{print $1}' || echo 'empty')"
        echo "  Files: $(find "${CACHE_DIR}" -type f 2>/dev/null | wc -l || echo '0')"
    else
        echo "No local cache present"
    fi
}

cmd_clean() {
    local remote
    remote=$(rclone_remote "${CACHE_KEY}")
    log "Deleting remote cache: ${CACHE_BACKEND}://${CACHE_BUCKET}/${CACHE_KEY}/"
    rclone purge "${remote}" 2>&1 || log "Nothing to delete"

    if [[ -d "${CACHE_DIR}" ]]; then
        log "Deleting local cache: ${CACHE_DIR}"
        rm -rf "${CACHE_DIR}"
    fi

    log "Cache cleaned"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
dagger-cache — Persist Dagger cache to S3-compatible storage

Usage:
  dagger-cache run [dagger args...]    Full lifecycle: restore → run → save
  dagger-cache restore                 Just restore cache from S3
  dagger-cache save                    Just save cache to S3
  dagger-cache info                    Show configuration and cache status
  dagger-cache clean                   Delete remote and local cache

Examples:
  dagger-cache run call build --source .
  dagger-cache run check

Environment:
  DAGGER_CACHE_BUCKET        S3 bucket name (required)
  DAGGER_CACHE_KEY           Cache key (default: dirname)
  DAGGER_CACHE_FALLBACK_KEY  Fallback key for cache miss
  DAGGER_CACHE_BACKEND       s3, gcs, azureblob, r2 (default: s3)
  DAGGER_CACHE_ENDPOINT      Custom S3 endpoint
  DAGGER_CACHE_REGION        S3 region (default: us-east-1)
  AWS_ACCESS_KEY_ID          AWS credentials (for S3)
  AWS_SECRET_ACCESS_KEY      AWS credentials (for S3)
EOF
}

# Check prerequisites
for cmd in rclone docker dagger; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required tool not found: $cmd"
done

case "${1:-}" in
    run)
        shift
        cmd_run "$@"
        ;;
    restore)
        cmd_restore
        ;;
    save)
        cmd_save
        ;;
    info)
        cmd_info
        ;;
    clean)
        cmd_clean
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        # Default: treat as "run" with all args passed to dagger
        cmd_run "$@"
        ;;
esac
