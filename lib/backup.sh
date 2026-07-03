#!/usr/bin/env bash
# Download and extract pre-dumped PostgreSQL backups from HTTP(S) URLs.

is_backup_source_uri() {
  [[ "${1}" =~ ^https?:// ]]
}

mask_backup_url() {
  local url="$1"
  local max_len=80
  if [[ ${#url} -le ${max_len} ]]; then
    printf '%s' "${url}"
    return 0
  fi
  printf '%s...%s' "${url:0:40}" "${url: -30}"
}

require_backup_commands() {
  if ! command -v tar >/dev/null 2>&1; then
    log_error "Missing required command: tar"
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    return 0
  fi
  log_error "Missing required command: curl or wget (needed for backup URL download)."
  return 1
}

_get_http_download_cmd() {
  if command -v curl >/dev/null 2>&1; then
    echo "curl"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    echo "wget"
    return 0
  fi
  return 1
}

fetch_backup_url_size_bytes() {
  local url="$1"
  local cmd size

  cmd="$(_get_http_download_cmd)" || return 1

  if [[ "${cmd}" == "curl" ]]; then
    size="$(curl -fsI "${url}" 2>/dev/null | awk '
      BEGIN { IGNORECASE=1 }
      /^Content-Length:/ { gsub(/\r/, "", $2); if ($2 ~ /^[0-9]+$/) print $2; exit }
    ')" || true
    [[ -n "${size}" ]] && echo "${size}" && return 0
  else
    size="$(wget --spider -S "${url}" 2>&1 | awk '
      BEGIN { IGNORECASE=1 }
      /Content-Length:/ { gsub(/\r/, "", $2); if ($2 ~ /^[0-9]+$/) print $2; exit }
    ')" || true
    [[ -n "${size}" ]] && echo "${size}" && return 0
  fi

  return 1
}

test_backup_url_reachable() {
  local url="$1"
  local cmd http_code

  cmd="$(_get_http_download_cmd)" || return 1

  if [[ "${cmd}" == "curl" ]]; then
    http_code="$(curl -fsSIL -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo "000")"
  else
    http_code="$(wget --spider -S "${url}" 2>&1 | awk '
      /^  HTTP\// { code=$2 }
      END { print code+0 ? code : "000" }
    ')"
  fi

  if [[ "${http_code}" =~ ^[23] ]]; then
    log_ok "Backup URL reachable (HTTP ${http_code})"
    return 0
  fi

  log_error "Backup URL not reachable (HTTP ${http_code:-unknown})"
  log_error "  URL: $(mask_backup_url "${url}")"
  return 1
}

download_backup_archive() {
  local url="$1"
  local dest_path="$2"
  local cmd err

  cmd="$(_get_http_download_cmd)" || return 1
  log_info "Downloading backup archive → ${dest_path}"

  if [[ "${cmd}" == "curl" ]]; then
    err="$(curl -fL --progress-bar -o "${dest_path}" "${url}" 2>&1)" || {
      log_error "Download failed"
      [[ -n "${err}" ]] && log_error "  ${err}"
      rm -f "${dest_path}"
      return 1
    }
  else
    err="$(wget -O "${dest_path}" "${url}" 2>&1)" || {
      log_error "Download failed"
      [[ -n "${err}" ]] && log_error "  ${err}"
      rm -f "${dest_path}"
      return 1
    }
  fi

  log_ok "Download complete: $(human_bytes "$(file_size_bytes "${dest_path}")")"
  return 0
}

extract_backup_archive() {
  local archive_path="$1"
  local extract_dir="$2"
  local err

  mkdir -p "${extract_dir}"
  log_info "Extracting archive → ${extract_dir}"

  err="$(tar -xzf "${archive_path}" -C "${extract_dir}" 2>&1)" || {
    log_error "Archive extraction failed"
    [[ -n "${err}" ]] && log_error "  ${err}"
    return 1
  }

  log_ok "Archive extracted."
  return 0
}

file_size_bytes() {
  local path="$1"
  stat -f%z "${path}" 2>/dev/null || stat -c%s "${path}" 2>/dev/null || echo 0
}

validate_dump_file() {
  local dump_path="$1"
  pg_restore --list "${dump_path}" >/dev/null 2>&1
}

find_dump_file_in_dir() {
  local dir="$1"
  local candidate

  while IFS= read -r -d '' candidate; do
    if validate_dump_file "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done < <(find "${dir}" -type f \( -name '*.dump' -o -name '*.backup' -o -name '*.pgdump' \) -print0 2>/dev/null)

  while IFS= read -r -d '' candidate; do
    if validate_dump_file "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done < <(find "${dir}" -type f -print0 2>/dev/null)

  return 1
}

copy_dump_to_target() {
  local source_dump="$1"
  local target_dump="$2"

  if [[ "${source_dump}" == "${target_dump}" ]]; then
    return 0
  fi

  cp -f "${source_dump}" "${target_dump}"
}

prepare_dump_from_extracted_dir() {
  local extract_dir="$1"
  local target_dump="$2"
  local found_dump

  found_dump="$(find_dump_file_in_dir "${extract_dir}")" || {
    log_error "No pg_dump custom-format file found inside the archive."
    log_error "Expected a file restorable with pg_restore."
    return 1
  }

  log_info "Found dump file: ${found_dump}"
  copy_dump_to_target "${found_dump}" "${target_dump}" || {
    log_error "Could not copy dump file to ${target_dump}"
    return 1
  }

  log_ok "Dump ready: $(human_bytes "$(file_size_bytes "${target_dump}")")"
  return 0
}

cleanup_backup_artifacts() {
  local archive_path="$1"
  local extract_dir="$2"

  rm -f "${archive_path}"
  rm -rf "${extract_dir}"
}

run_acquire_dump_from_backup() {
  local backup_url="$1"
  local dump_file="$2"
  local run_id="$3"
  local archive_path="${DUMP_DIR}/${run_id}.archive.tar.gz"
  local extract_dir="${DUMP_DIR}/${run_id}.extract"

  log_info "Using pre-dumped backup: $(mask_backup_url "${backup_url}")"

  if ! download_backup_archive "${backup_url}" "${archive_path}"; then
    return 1
  fi

  if ! extract_backup_archive "${archive_path}" "${extract_dir}"; then
    cleanup_backup_artifacts "${archive_path}" "${extract_dir}"
    return 1
  fi

  if ! prepare_dump_from_extracted_dir "${extract_dir}" "${dump_file}"; then
    cleanup_backup_artifacts "${archive_path}" "${extract_dir}"
    return 1
  fi

  cleanup_backup_artifacts "${archive_path}" "${extract_dir}"
  return 0
}
