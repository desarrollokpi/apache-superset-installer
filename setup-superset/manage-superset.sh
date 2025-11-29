#!/usr/bin/env bash
set -euo pipefail

# Unified manager for Superset environments (local/dev/prod).
# Usage:
#   ./manage-superset.sh <env> <action> [extra-args]
# Where:
#   <env>    : local | dev | prod
#   <action> : up | down

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
FILES_ROOT="${REPO_ROOT}/superset-files"

source "${SCRIPT_DIR}/scripts/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <env> <action> [options]

Environments:
  local    Superset without reverse proxy, bound to localhost.
  dev      Superset with Traefik reverse proxy for dev hostname.
  prod     Superset with Traefik reverse proxy for production hostname.

Actions:
  up       Prepare workspace and start the stack for the given environment.
  down     Stop the stack for the given environment (supports --with-volumes).

Examples:
  $(basename "$0") local up
  $(basename "$0") dev down --with-volumes
EOF
}

ensure_env_and_action() {
  if [[ $# -lt 2 ]]; then
    usage
    exit 1
  fi

  ENVIRONMENT="$1"
  ACTION="$2"
  shift 2

  case "$ENVIRONMENT" in
    local|dev|prod) ;;
    *)
      common::log ERROR "Unknown environment: ${ENVIRONMENT}"
      usage
      exit 1
      ;;
  esac

  case "$ACTION" in
    up|down) ;;
    *)
      common::log ERROR "Unknown action: ${ACTION}"
      usage
      exit 1
      ;;
  esac

  REMAINING_ARGS=("$@")
}

prepare_workspace() {
  local env="$1"

  local stack_name="superset-${env}"
  local state_dir="${FILES_ROOT}/${stack_name}"
  local artifacts_dir="${state_dir}/artifacts"
  local compose_name="docker-compose.superset.${env}.yaml"
  local compose_src="${SCRIPT_DIR}/${compose_name}"
  local compose_dst="${state_dir}/${compose_name}"

  common::ensure_dirs "$FILES_ROOT" "$state_dir" "$artifacts_dir"

  if [[ ! -f "$compose_src" ]]; then
    common::log ERROR "Compose file not found for env '${env}' at ${compose_src}"
    exit 1
  fi

  # Copy compose and Superset config into the workspace so docker compose runs in an isolated folder.
  common::copy_file "$compose_src" "$compose_dst"

  # Superset config specific to this repo lives under superset-config/.
  if [[ -f "${SCRIPT_DIR}/superset-config/superset_config.py" ]]; then
    common::copy_file "${SCRIPT_DIR}/superset-config/superset_config.py" "${state_dir}/superset_config.py"
  fi

  # init_superset.sh is the bootstrap script used by all environments.
  # Use the upstream-based script from superset-config/ and make it executable.
  if [[ -f "${SCRIPT_DIR}/superset-config/init_superset.sh" ]]; then
    common::copy_file "${SCRIPT_DIR}/superset-config/init_superset.sh" "${state_dir}/init_superset.sh" 755
  fi
  
  if [[ -f "${SCRIPT_DIR}/superset-config/requirements-local.txt" ]]; then
    common::copy_file "${SCRIPT_DIR}/superset-config/requirements-local.txt" "${state_dir}/requirements-local.txt" 755
  fi
  
  if [[ -f "${SCRIPT_DIR}/superset-config/.env.local" ]]; then
    common::copy_file "${SCRIPT_DIR}/superset-config/.env.local" "${state_dir}/.env.local" 755
  fi

  echo "$state_dir"
}

handle_up() {
  local env="$1"

  common::require_commands docker
  if [[ "$env" == "dev" ]]; then
    common::require_commands openssl
  fi

  common::load_env_files "${REPO_ROOT}/.env" "${REPO_ROOT}/.env.${env}"

  local stack_name="superset-${env}"
  local project_name="superset_${env}"
  local state_dir
  state_dir="$(prepare_workspace "$env")"
  local compose_file="${state_dir}/docker-compose.superset.${env}.yaml"

  # Environment-specific validations.
  if [[ "$env" == "prod" ]]; then
    if [[ -z "${SUPERSET_VERSION:-}" ]]; then
      common::log ERROR "SUPERSET_VERSION must be set for prod (define it in .env.prod or export it)."
      exit 1
    fi
    if [[ -z "${SUPERSET_SECRET_KEY:-}" ]]; then
      common::log ERROR "SUPERSET_SECRET_KEY must be defined for prod."
      exit 1
    fi
  else
    SUPERSET_VERSION="${SUPERSET_VERSION:-5.0.0}"
  fi

  local superset_image_default="apache/superset"
  SUPERSET_IMAGE="${SUPERSET_IMAGE:-$superset_image_default}"
  export SUPERSET_VERSION SUPERSET_IMAGE

  common::log INFO "Preparing workspace at ${state_dir} for env '${env}' (project: ${project_name})"

  # Start the stack (Traefik is included in dev/prod compose, not in local).
  common::log INFO "Starting Docker Compose stack..."
  common::compose_up "$compose_file" "$project_name"

  common::log INFO "Stack is booting; follow logs with:"
  common::log INFO "docker compose --project-name ${project_name} -f ${compose_file} logs -f superset"

  local artifacts_dir="${state_dir}/artifacts"
  local password_artifact="${artifacts_dir}/generated_admin_password.txt"
  common::log INFO "Admin password artifact (if generated): ${password_artifact}"
}

handle_down() {
  local env="$1"
  shift || true

  local with_volumes=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-volumes)
        with_volumes=true
        shift
        ;;
      *)
        common::log ERROR "Unknown option for down: $1"
        usage
        exit 1
        ;;
    esac
  done

  common::require_commands docker
  common::load_env_files "${REPO_ROOT}/.env" "${REPO_ROOT}/.env.${env}"

  local stack_name="superset-${env}"
  local project_name="superset_${env}"
  local state_dir="${FILES_ROOT}/${stack_name}"
  local compose_file="${state_dir}/docker-compose.superset.${env}.yaml"

  if [[ ! -f "$compose_file" ]]; then
    common::log INFO "No compose file found at ${compose_file}; nothing to stop for env '${env}'."
    return
  fi

  # Provide sane defaults for teardown.
  SUPERSET_VERSION="${SUPERSET_VERSION:-5.0.0}"
  local superset_image_default="apache/superset"
  SUPERSET_IMAGE="${SUPERSET_IMAGE:-$superset_image_default}"
  export SUPERSET_VERSION SUPERSET_IMAGE

  common::log INFO "Stopping Superset stack for '${env}' (volumes removed: ${with_volumes})"
  common::compose_down "$compose_file" "$project_name" "$with_volumes"
  common::log INFO "Stack stopped."

  if [[ "$with_volumes" == "true" ]]; then
    # Best-effort cleanup of named volumes created by this compose file.
    # We ask Docker Compose which volumes belong to this stack instead of hardcoding names.
    local volumes_to_remove=()
    while IFS= read -r vol; do
      [[ -n "$vol" ]] && volumes_to_remove+=("$vol")
    done < <(docker compose -f "$compose_file" --project-name "$project_name" config --volumes 2>/dev/null || true)

    for vol in "${volumes_to_remove[@]}"; do
      if docker volume inspect "$vol" >/dev/null 2>&1; then
        common::log INFO "Removing Docker volume ${vol}"
        if ! docker volume rm "$vol" >/dev/null 2>&1; then
          common::log WARN "Failed to remove Docker volume ${vol}"
        fi
      fi
    done

    common::log INFO "Removing workspace at ${state_dir}"
    rm -rf "$state_dir"
  else
    common::log INFO "Workspace preserved at ${state_dir}. Use '--with-volumes' to wipe it."
  fi
}

main() {
  ensure_env_and_action "$@"

  case "$ACTION" in
    up)
      handle_up "$ENVIRONMENT"
      ;;
    down)
      handle_down "$ENVIRONMENT" "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
