#!/usr/bin/env bash
# Interactive prompts and pre-flight validation.

prompt_uri() {
  local label="$1"
  local uri=""
  echo ""
  echo "${label}"
  echo "  Format: postgresql://USER:PASSWORD@HOST:PORT/DATABASE"
  echo "  URL-encode special characters in USER/PASSWORD (e.g. @ → %40)."
  echo "  Example: postgresql://admin:secret@db.example.com:5432/myapp"
  while [[ -z "${uri}" ]]; do
    read -r -p "  URI: " uri
    uri="$(echo "${uri}" | xargs)"
    if [[ -z "${uri}" ]]; then
      echo "  URI cannot be empty."
    fi
  done
  echo "${uri}"
}

confirm_yes_no() {
  local question="$1"
  local default="${2:-n}"
  local prompt_suffix="[y/N]"
  [[ "${default}" == "y" ]] && prompt_suffix="[Y/n]"

  local answer=""
  read -r -p "${question} ${prompt_suffix}: " answer
  answer="$(echo "${answer}" | tr '[:upper:]' '[:lower:]')"
  answer="${answer:-${default}}"

  [[ "${answer}" == "y" || "${answer}" == "yes" ]]
}

run_preflight() {
  local source_uri="$1"
  local dest_uri="$2"

  log_step "Pre-flight checks"

  SOURCE_URI="${source_uri}"
  DEST_URI="${dest_uri}"

  if ! require_commands; then
    return 1
  fi

  parse_pg_uri "${source_uri}" || return 1
  test_pg_connection "Source" || return 1

  local src_size src_ver
  src_size="$(get_source_db_size_bytes)" || {
    log_error "Could not read source database size."
    return 1
  }
  src_ver="$(get_server_version)" || true
  log_info "Source database size: $(human_bytes "${src_size}")"
  [[ -n "${src_ver}" ]] && log_info "Source PostgreSQL version: ${src_ver}"

  parse_pg_uri "${dest_uri}" || return 1
  test_pg_connection "Destination" || return 1

  local dest_ver
  dest_ver="$(get_server_version)" || true
  [[ -n "${dest_ver}" ]] && log_info "Destination PostgreSQL version: ${dest_ver}"

  if is_local_pg_host "${PG_URI_HOST}"; then
    check_local_destination_storage "${src_size}" || return 1
  else
    log_info "Destination host '${PG_URI_HOST}' is remote — skipping local disk check."
    log_warn "Ensure the remote server has enough storage for ~$(human_bytes "${src_size}") (+ margin)."
  fi

  if destination_db_exists; then
    log_warn "Destination database already exists — it will be dropped and recreated."
  fi

  log_ok "All pre-flight checks passed."
  echo "${src_size}"
}

print_banner() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           PostgreSQL DB Copy Manager                     ║"
  echo "║   Clone a database from source → destination             ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
}

run_wizard() {
  print_banner

  local source_uri dest_uri run_id pid

  source_uri="$(prompt_uri "SOURCE database connection")"
  dest_uri="$(prompt_uri "DESTINATION database connection")"

  if [[ "${source_uri}" == "${dest_uri}" ]]; then
    log_error "Source and destination URIs are identical."
    return 1
  fi

  run_preflight "${source_uri}" "${dest_uri}" >/dev/null || return 1

  echo ""
  log_info "Summary"
  log_info "  Source:      ${source_uri}"
  log_info "  Destination: ${dest_uri}"
  echo ""

  if ! confirm_yes_no "Start clone in background?" "y"; then
    log_info "Aborted."
    return 0
  fi

  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $$)"
  pid="$(launch_detached_clone "${run_id}" "${source_uri}" "${dest_uri}")"
  print_detach_instructions "${run_id}" "${pid}"
}
