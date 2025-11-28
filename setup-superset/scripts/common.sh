#!/usr/bin/env bash

# Common helpers shared by Superset launcher scripts.

common::log() {
  local level="$1"
  shift
  local prefix="[superset]"
  if [[ -n "${STACK_LABEL:-}" ]]; then
    prefix="[${STACK_LABEL}]"
  fi
  printf '%s[%s] %s\n' "$prefix" "$level" "$*"
}

common::require_commands() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    printf 'Missing required commands: %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

common::load_env_files() {
  for env_file in "$@"; do
    if [[ -f "$env_file" ]]; then
      common::log INFO "Loading ${env_file}"
      # shellcheck disable=SC1090
      set -a
      source "$env_file"
      set +a
    fi
  done
}

common::ensure_dirs() {
  mkdir -p "$@"
}

common::copy_file() {
  local src="$1"
  local dst="$2"
  local mode="${3:-644}"
  install -Dm"${mode}" "$src" "$dst"
}

common::compose_up() {
  local compose_file="$1"
  local project_name="$2"
  shift 2
  docker compose -f "$compose_file" --project-name "$project_name" up -d --remove-orphans "$@"
}

common::compose_down() {
  local compose_file="$1"
  local project_name="$2"
  local with_volumes="${3:-false}"
  shift 3 || true
  local args=(-f "$compose_file" --project-name "$project_name" down "$@")
  if [[ "$with_volumes" == "true" ]]; then
    args+=(-v)
  fi
  docker compose "${args[@]}"
}
