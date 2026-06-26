#!/usr/bin/env bash
# Parse PostgreSQL URIs and build connection environment variables.

# Globals set by parse_pg_uri: PG_URI_* and PG_CONN_LABEL
# PG_URI_SCHEME PG_URI_USER PG_URI_PASS PG_URI_HOST PG_URI_PORT PG_URI_DB PG_URI_QUERY

parse_pg_uri() {
  local uri="$1"
  local prefix

  if [[ ! "${uri}" =~ ^postgres(ql)?:// ]]; then
    log_error "Invalid PostgreSQL URI (expected postgresql://...): ${uri}"
    return 1
  fi

  uri="${uri#postgres://}"
  uri="${uri#postgresql://}"

  if [[ "${uri}" == *@* ]]; then
    prefix="${uri%%@*}"
    uri="${uri#*@}"
    if [[ "${prefix}" == *:* ]]; then
      PG_URI_USER="${prefix%%:*}"
      PG_URI_PASS="${prefix#*:}"
    else
      PG_URI_USER="${prefix}"
      PG_URI_PASS=""
    fi
  else
    PG_URI_USER="${PGUSER:-}"
    PG_URI_PASS="${PGPASSWORD:-}"
  fi

  if [[ "${uri}" == */* ]]; then
    PG_URI_HOST_PORT="${uri%%/*}"
    local rest="${uri#*/}"
    PG_URI_DB="${rest%%\?*}"
    if [[ "${rest}" == *\?* ]]; then
      PG_URI_QUERY="${rest#*\?}"
    else
      PG_URI_QUERY=""
    fi
  else
    log_error "URI missing database name: postgresql://.../dbname"
    return 1
  fi

  if [[ "${PG_URI_HOST_PORT}" == \[*\] ]]; then
    # IPv6: [host]:port
    PG_URI_HOST="${PG_URI_HOST_PORT%%]*}"
    PG_URI_HOST="${PG_URI_HOST#[}"
    local port_part="${PG_URI_HOST_PORT#*]}"
    if [[ "${port_part}" == :* ]]; then
      PG_URI_PORT="${port_part#:}"
    else
      PG_URI_PORT="${DEFAULT_PG_PORT}"
    fi
  elif [[ "${PG_URI_HOST_PORT}" == *:* ]]; then
    PG_URI_HOST="${PG_URI_HOST_PORT%%:*}"
    PG_URI_PORT="${PG_URI_HOST_PORT#*:}"
  else
    PG_URI_HOST="${PG_URI_HOST_PORT}"
    PG_URI_PORT="${DEFAULT_PG_PORT}"
  fi

  PG_CONN_LABEL="${PG_URI_USER}@${PG_URI_HOST}:${PG_URI_PORT}/${PG_URI_DB}"
  return 0
}

apply_pg_env() {
  export PGHOST="${PG_URI_HOST}"
  export PGPORT="${PG_URI_PORT}"
  export PGUSER="${PG_URI_USER}"
  export PGDATABASE="${PG_URI_DB}"
  if [[ -n "${PG_URI_PASS}" ]]; then
    export PGPASSWORD="${PG_URI_PASS}"
  fi
}

clear_pg_env() {
  unset PGHOST PGPORT PGUSER PGDATABASE PGPASSWORD
}

is_local_pg_host() {
  local host="$1"
  local canonical

  case "${host}" in
    ""|localhost|127.0.0.1|::1)
      return 0
      ;;
  esac

  canonical="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  if [[ -n "${canonical}" && "${host}" == "${canonical}" ]]; then
    return 0
  fi

  local short_name
  short_name="$(hostname -s 2>/dev/null || true)"
  if [[ -n "${short_name}" && "${host}" == "${short_name}" ]]; then
    return 0
  fi

  # Unix socket path or @/dbname style local socket
  if [[ "${host}" == /* ]]; then
    return 0
  fi

  return 1
}
