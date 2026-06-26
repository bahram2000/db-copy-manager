#!/usr/bin/env bash
# Disk-space checks when the destination PostgreSQL instance is local.

get_pg_data_directory() {
  apply_pg_env
  local datadir
  datadir="$(psql -v ON_ERROR_STOP=1 -Atqc "SHOW data_directory" 2>/dev/null)" || {
    clear_pg_env
    return 1
  }
  clear_pg_env
  echo "${datadir}"
}

get_available_bytes_on_path() {
  local path="$1"
  df -Pk "${path}" 2>/dev/null | awk 'NR==2 { print $4 * 1024 }'
}

check_local_destination_storage() {
  local required_bytes="$1"
  local db_margin_bytes dump_margin_bytes
  db_margin_bytes="$(awk "BEGIN { printf \"%d\", ${required_bytes} * ${STORAGE_SAFETY_MARGIN} }")"
  # Custom-format dump is often smaller than live DB; reserve full size to be safe.
  dump_margin_bytes="${db_margin_bytes}"

  log_step "Local destination storage check"

  local data_dir data_avail_bytes dump_avail_bytes
  data_dir="$(get_pg_data_directory)" || {
    log_warn "Could not read data_directory from destination; skipping PG data disk check."
    data_dir=""
  }

  if [[ -n "${data_dir}" ]]; then
    data_avail_bytes="$(get_available_bytes_on_path "${data_dir}")"
    log_info "Destination data directory: ${data_dir}"
    log_info "Space needed for database:    $(human_bytes "${db_margin_bytes}")"
    if [[ -n "${data_avail_bytes}" && "${data_avail_bytes}" -gt 0 ]]; then
      log_info "Available on data volume:     $(human_bytes "${data_avail_bytes}")"
      if [[ "${data_avail_bytes}" -lt "${db_margin_bytes}" ]]; then
        log_error "Not enough disk space on the PostgreSQL data volume."
        return 1
      fi
    else
      log_warn "Could not measure free space for ${data_dir}."
    fi
  fi

  mkdir -p "${DUMP_DIR}"
  dump_avail_bytes="$(get_available_bytes_on_path "${DUMP_DIR}")"
  log_info "Temporary dump directory:     ${DUMP_DIR}"
  log_info "Space needed for dump file:   $(human_bytes "${dump_margin_bytes}")"
  if [[ -n "${dump_avail_bytes}" && "${dump_avail_bytes}" -gt 0 ]]; then
    log_info "Available on dump volume:     $(human_bytes "${dump_avail_bytes}")"
    if [[ "${dump_avail_bytes}" -lt "${dump_margin_bytes}" ]]; then
      log_error "Not enough disk space for the temporary dump file."
      return 1
    fi
  else
    log_warn "Could not measure free space for ${DUMP_DIR}."
  fi

  log_info "Source database size:         $(human_bytes "${required_bytes}")"
  log_ok "Local storage checks passed."
  return 0
}
