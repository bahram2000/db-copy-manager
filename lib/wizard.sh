#!/usr/bin/env bash
# Interactive prompts and pre-flight validation.

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

prompt_source() {
  local uri=""

  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  STEP 1/2 — SOURCE (copy FROM)" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  Live database:" >&2
  echo "    postgresql://USER:PASSWORD@HOST:PORT/DATABASE" >&2
  echo "  Pre-dumped backup (tar.gz with pg_dump inside):" >&2
  echo "    https://host/path/to/backup.tar.gz" >&2
  echo "  URL-encode special characters in PASSWORD (e.g. @ → %40)." >&2
  echo "" >&2

  while [[ -z "${uri}" ]]; do
    read -r -p "  Paste SOURCE URI or backup URL: " uri </dev/tty
    uri="$(trim_ws "${uri}")"
    if [[ -z "${uri}" ]]; then
      echo "  ✗ Source cannot be empty." >&2
    elif [[ ! "${uri}" =~ ^postgres(ql)?:// ]] && [[ ! "${uri}" =~ ^https?:// ]]; then
      echo "  ✗ Must be a postgresql:// URI or an http(s):// backup URL." >&2
      uri=""
    fi
  done

  if is_backup_source_uri "${uri}"; then
    echo "  ✓ Accepted backup URL: $(mask_backup_url "${uri}")" >&2
  else
    echo "  ✓ Accepted: $(mask_uri "${uri}")" >&2
  fi
  printf '%s' "${uri}"
}

detect_source_type() {
  local source_uri="$1"
  if is_backup_source_uri "${source_uri}"; then
    echo "backup"
  else
    echo "live"
  fi
}

format_source_label() {
  local source_uri="$1"
  local source_type="$2"
  if [[ "${source_type}" == "backup" ]]; then
    printf 'backup %s' "$(mask_backup_url "${source_uri}")"
  else
    mask_uri "${source_uri}"
  fi
}

run_preflight_live_source() {
  local source_uri="$1"
  local src_size src_ver

  parse_pg_uri "${source_uri}" || return 1
  test_pg_connection "Source" || return 1

  src_size="$(get_source_db_size_bytes)" || {
    log_error "Could not read source database size."
    return 1
  }
  src_ver="$(get_server_version)" || true
  log_info "Source database size: $(human_bytes "${src_size}")"
  [[ -n "${src_ver}" ]] && log_info "Source PostgreSQL version: ${src_ver}"

  PREFLIGHT_REQUIRED_BYTES="${src_size}"
  return 0
}

run_preflight_backup_source() {
  local backup_url="$1"
  local archive_size estimated_size

  if ! require_backup_commands; then
    return 1
  fi

  test_backup_url_reachable "${backup_url}" || return 1

  archive_size="$(fetch_backup_url_size_bytes "${backup_url}" 2>/dev/null || true)"
  if [[ -n "${archive_size}" && "${archive_size}" -gt 0 ]]; then
    log_info "Backup archive size: $(human_bytes "${archive_size}")"
    estimated_size="$(awk "BEGIN { printf \"%d\", ${archive_size} * 2 }")"
    log_info "Estimated space for download + extract: $(human_bytes "${estimated_size}")"
    PREFLIGHT_REQUIRED_BYTES="${estimated_size}"
    return 0
  fi

  log_warn "Could not determine backup archive size from HTTP headers."
  log_warn "Local disk checks will use a conservative estimate."
  PREFLIGHT_REQUIRED_BYTES="1073741824"
  return 0
}

run_preflight() {
  local source_uri="$1"
  local dest_uri="$2"
  local source_type required_bytes

  log_step "Pre-flight checks"

  SOURCE_URI="${source_uri}"
  DEST_URI="${dest_uri}"
  source_type="$(detect_source_type "${source_uri}")"

  if ! require_commands; then
    return 1
  fi

  if [[ "${source_type}" == "backup" ]]; then
    run_preflight_backup_source "${source_uri}" || return 1
  else
    run_preflight_live_source "${source_uri}" || return 1
  fi
  required_bytes="${PREFLIGHT_REQUIRED_BYTES}"

  parse_pg_uri "${dest_uri}" || return 1
  test_pg_connection "Destination" || return 1

  local dest_ver
  dest_ver="$(get_server_version)" || true
  [[ -n "${dest_ver}" ]] && log_info "Destination PostgreSQL version: ${dest_ver}"

  if is_local_pg_host "${PG_URI_HOST}"; then
    check_local_destination_storage "${required_bytes}" "${source_type}" || return 1
  else
    log_info "Destination host '${PG_URI_HOST}' is remote — skipping local disk check."
    log_warn "Ensure the remote server has enough storage for ~$(human_bytes "${required_bytes}") (+ margin)."
  fi

  if destination_database_exists "${PG_URI_DB}"; then
    log_warn "Destination database '${PG_URI_DB}' already exists — it will be dropped and recreated."
    log_warn "Active connections to that database will be terminated during the clone."
  fi

  log_ok "All pre-flight checks passed."
  return 0
}

confirm_yes_no() {
  local question="$1"
  local default="${2:-n}"
  local prompt_suffix="[y/N]"
  [[ "${default}" == "y" ]] && prompt_suffix="[Y/n]"

  local answer=""
  read -r -p "${question} ${prompt_suffix}: " answer </dev/tty
  answer="$(echo "${answer}" | tr '[:upper:]' '[:lower:]')"
  answer="${answer:-${default}}"

  [[ "${answer}" == "y" || "${answer}" == "yes" ]]
}

print_banner() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║           PostgreSQL DB Copy Manager                     ║"
  echo "║   Clone a database:  SOURCE  ──►  DESTINATION          ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  echo "  You will be asked for a source and a destination, in order:"
  echo "    1. SOURCE      — live postgresql:// URI or https:// backup URL"
  echo "    2. DESTINATION — postgresql:// URI (will be replaced)"
  echo ""
}

prompt_uri() {
  local step="$1"
  local label="$2"
  local uri=""

  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  STEP ${step} — ${label}" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  Format: postgresql://USER:PASSWORD@HOST:PORT/DATABASE" >&2
  echo "  URL-encode special characters in PASSWORD (e.g. @ → %40)." >&2
  echo "" >&2

  while [[ -z "${uri}" ]]; do
    read -r -p "  Paste ${label} URI: " uri </dev/tty
    uri="$(trim_ws "${uri}")"
    if [[ -z "${uri}" ]]; then
      echo "  ✗ URI cannot be empty." >&2
    elif [[ ! "${uri}" =~ ^postgres(ql)?:// ]]; then
      echo "  ✗ Must start with postgresql:// or postgres://" >&2
      uri=""
    fi
  done

  echo "  ✓ Accepted: $(mask_uri "${uri}")" >&2
  printf '%s' "${uri}"
}

run_wizard() {
  print_banner

  local source_uri dest_uri source_type run_id pid

  source_uri="$(prompt_source)"
  dest_uri="$(prompt_uri "2/2" "DESTINATION (copy TO)")"
  source_type="$(detect_source_type "${source_uri}")"

  if [[ "${source_uri}" == "${dest_uri}" ]]; then
    log_error "Source and destination URIs are identical."
    return 1
  fi

  if ! run_preflight "${source_uri}" "${dest_uri}"; then
    log_error "Pre-flight checks failed — clone NOT started."
    return 1
  fi

  echo ""
  log_step "Confirm"
  log_info "  Source (FROM):  $(format_source_label "${source_uri}" "${source_type}")"
  log_info "  Dest   (TO):    $(mask_uri "${dest_uri}")"
  echo ""

  if ! confirm_yes_no "Start clone in background?" "y"; then
    log_info "Aborted by user — nothing was changed."
    return 0
  fi

  run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo $$)"
  pid="$(launch_detached_clone "${run_id}" "${source_uri}" "${dest_uri}" "${source_type}")"
  print_detach_instructions "${run_id}" "${pid}"
}
