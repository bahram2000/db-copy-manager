#!/usr/bin/env bash
# Tooling checks and live connection validation.

require_commands() {
  local missing=()
  local cmd
  for cmd in psql pg_dump pg_restore createdb dropdb; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required commands: ${missing[*]}"
    log_error "Install PostgreSQL client tools on this machine and retry."
    return 1
  fi
  log_ok "PostgreSQL client tools found."
  return 0
}

test_pg_connection() {
  local role="$1"
  local err
  apply_pg_env

  if psql -v ON_ERROR_STOP=1 -Atqc "SELECT 1" >/dev/null 2>&1; then
    log_ok "${role} connection OK (${PG_CONN_LABEL})"
    clear_pg_env
    return 0
  fi

  err="$(psql -v ON_ERROR_STOP=1 -Atqc "SELECT 1" 2>&1 >/dev/null || true)"
  log_error "${role} connection FAILED (${PG_CONN_LABEL})"
  [[ -n "${err}" ]] && log_error "  psql says: ${err}"
  clear_pg_env
  return 1
}

get_source_db_size_bytes() {
  apply_pg_env
  local size
  size="$(psql -v ON_ERROR_STOP=1 -Atqc "SELECT pg_database_size(current_database())" 2>/dev/null)" || {
    clear_pg_env
    return 1
  }
  clear_pg_env
  echo "${size}"
}

get_server_version() {
  apply_pg_env
  local ver
  ver="$(psql -v ON_ERROR_STOP=1 -Atqc "SHOW server_version_num" 2>/dev/null)" || {
    clear_pg_env
    return 1
  }
  clear_pg_env
  echo "${ver}"
}

destination_db_exists() {
  apply_pg_env
  local exists
  exists="$(psql -v ON_ERROR_STOP=1 -Atqc \
    "SELECT 1 FROM pg_database WHERE datname = current_database()" 2>/dev/null)" || {
    clear_pg_env
    return 1
  }
  clear_pg_env
  [[ "${exists}" == "1" ]]
}

human_bytes() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "${bytes}" 2>/dev/null || echo "${bytes} B"
  else
    echo "${bytes} bytes"
  fi
}
