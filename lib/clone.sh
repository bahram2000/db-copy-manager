#!/usr/bin/env bash
# Core dump → restore pipeline.

_set_state_field() {
  local state_file="$1"
  local field="$2"
  local value="$3"
  local tmp="${state_file}.tmp"

  if grep -q "^${field}=" "${state_file}"; then
    awk -v f="${field}" -v v="${value}" '
      $0 ~ "^" f "=" { print f "=" v; next }
      { print }
    ' "${state_file}" > "${tmp}" && mv "${tmp}" "${state_file}"
  else
    printf '%s=%s\n' "${field}" "${value}" >> "${state_file}"
  fi
}

init_state_file() {
  local run_id="$1"
  local source_uri="$2"
  local dest_uri="$3"
  local source_type="${4:-live}"
  local state_file="${STATE_DIR}/${run_id}.env"
  mkdir -p "${STATE_DIR}"
  printf '%s' "${source_uri}" > "${STATE_DIR}/${run_id}.source.uri"
  printf '%s' "${dest_uri}" > "${STATE_DIR}/${run_id}.dest.uri"
  {
    printf 'RUN_ID=%s\n' "${run_id}"
    printf 'SOURCE_TYPE=%s\n' "${source_type}"
    printf 'STATUS=pending\n'
    printf 'SESSION_LOG=%s\n' "${LOG_DIR}/${run_id}.log"
    printf 'PID=\n'
    printf 'STARTED_AT=%s\n' "$(_log_ts)"
    printf 'FINISHED_AT=\n'
  } > "${state_file}"
}

resolve_source_type() {
  local source_uri="$1"
  local source_type="${2:-}"

  if [[ -n "${source_type}" ]]; then
    printf '%s' "${source_type}"
    return 0
  fi

  if is_backup_source_uri "${source_uri}"; then
    echo "backup"
  else
    echo "live"
  fi
}

load_run_state() {
  local run_id="$1"
  local state_file="${STATE_DIR}/${run_id}.env"
  if [[ ! -f "${state_file}" ]]; then
    log_error "State file missing for run: ${run_id}"
    return 1
  fi
  # shellcheck disable=SC1090
  source "${state_file}"
  SOURCE_URI="$(cat "${STATE_DIR}/${run_id}.source.uri")"
  DEST_URI="$(cat "${STATE_DIR}/${run_id}.dest.uri")"
  SOURCE_TYPE="$(resolve_source_type "${SOURCE_URI}" "${SOURCE_TYPE:-}")"
  export SOURCE_URI DEST_URI SOURCE_TYPE
}

update_state_status() {
  local run_id="$1"
  local status="$2"
  local state_file="${STATE_DIR}/${run_id}.env"
  [[ -f "${state_file}" ]] || return 0

  _set_state_field "${state_file}" "STATUS" "${status}"
  if [[ "${status}" == "completed" || "${status}" == "failed" ]]; then
    _set_state_field "${state_file}" "FINISHED_AT" "$(_log_ts)"
  fi
}

recreate_destination_database() {
  parse_pg_uri "${DEST_URI}"
  validate_db_name "${PG_URI_DB}" || return 1

  local db_name="${PG_URI_DB}"
  local err
  log_info "Preparing destination database '${db_name}'..."

  if destination_database_exists "${db_name}"; then
    log_warn "Database '${db_name}' exists on destination — dropping it."
    terminate_database_connections "${db_name}"

    apply_pg_admin_env
    err="$(dropdb --if-exists "${db_name}" 2>&1)" || {
      log_error "dropdb failed for '${db_name}'"
      [[ -n "${err}" ]] && log_error "  ${err}"
      clear_pg_env
      return 1
    }
    clear_pg_env
  fi

  apply_pg_admin_env
  err="$(createdb "${db_name}" 2>&1)" || {
    log_error "createdb failed for '${db_name}'"
    [[ -n "${err}" ]] && log_error "  ${err}"
    clear_pg_env
    return 1
  }
  clear_pg_env

  log_ok "Destination database '${db_name}' is ready."
  return 0
}

run_dump() {
  local dump_file="$1"
  parse_pg_uri "${SOURCE_URI}"
  apply_pg_env

  log_info "Dumping source (${PG_CONN_LABEL}) → ${dump_file}"
  pg_dump \
    --format=custom \
    --no-owner \
    --no-acl \
    --verbose \
    --file="${dump_file}" \
    "${PG_URI_DB}" 2>&1 | while IFS= read -r line; do log_info "[pg_dump] ${line}"; done

  local rc=${PIPESTATUS[0]}
  clear_pg_env

  if [[ ${rc} -ne 0 ]]; then
    log_error "pg_dump failed (exit ${rc})"
    return ${rc}
  fi

  log_ok "Dump complete: $(human_bytes "$(stat -f%z "${dump_file}" 2>/dev/null || stat -c%s "${dump_file}" 2>/dev/null)")"
  return 0
}

run_restore() {
  local dump_file="$1"
  parse_pg_uri "${DEST_URI}"
  apply_pg_env

  log_info "Restoring into destination (${PG_CONN_LABEL})"
  pg_restore \
    --no-owner \
    --no-acl \
    --verbose \
    --dbname="${PG_URI_DB}" \
    "${dump_file}" 2>&1 | while IFS= read -r line; do log_info "[pg_restore] ${line}"; done

  local rc=${PIPESTATUS[0]}
  clear_pg_env

  # pg_restore may exit 1 for benign warnings (e.g. missing roles)
  if [[ ${rc} -gt 1 ]]; then
    log_error "pg_restore failed (exit ${rc})"
    return ${rc}
  fi

  if [[ ${rc} -eq 1 ]]; then
    log_warn "pg_restore finished with warnings (exit 1) — review log above."
  else
    log_ok "Restore complete."
  fi
  return 0
}

run_clone_job() {
  local run_id="$1"
  local dump_file="${DUMP_DIR}/${run_id}.dump"

  load_run_state "${run_id}" || return 1
  mkdir -p "${DUMP_DIR}"
  init_session_log "${run_id}"
  update_state_status "${run_id}" "running"

  log_step "Clone job ${run_id}"
  if [[ "${SOURCE_TYPE}" == "backup" ]]; then
    log_info "Source:      backup $(mask_backup_url "${SOURCE_URI}")"
  else
    log_info "Source:      $(mask_uri "${SOURCE_URI}")"
  fi
  log_info "Destination: $(mask_uri "${DEST_URI}")"
  log_info "Log file:    ${SESSION_LOG}"

  if ! recreate_destination_database; then
    update_state_status "${run_id}" "failed"
    return 1
  fi

  if [[ "${SOURCE_TYPE}" == "backup" ]]; then
    if ! run_acquire_dump_from_backup "${SOURCE_URI}" "${dump_file}" "${run_id}"; then
      update_state_status "${run_id}" "failed"
      return 1
    fi
  elif ! run_dump "${dump_file}"; then
    update_state_status "${run_id}" "failed"
    return 1
  fi

  if ! run_restore "${dump_file}"; then
    update_state_status "${run_id}" "failed"
    return 1
  fi

  log_step "Cleanup"
  rm -f "${dump_file}"
  log_ok "Removed temporary dump file."

  update_state_status "${run_id}" "completed"
  log_ok "Clone job ${run_id} completed successfully."
  return 0
}
