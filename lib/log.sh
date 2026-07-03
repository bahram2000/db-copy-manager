#!/usr/bin/env bash
# Structured logging helpers.

_log_ts() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

init_session_log() {
  local run_id="$1"
  mkdir -p "${LOG_DIR}"
  SESSION_LOG="${LOG_DIR}/${run_id}.log"
  touch "${SESSION_LOG}"
}

log_write() {
  local level="$1"
  local message="$2"
  local line="[$(_log_ts)] [${level}] ${message}"
  echo "${line}" >&2
  if [[ -n "${SESSION_LOG:-}" ]]; then
    echo "${line}" >> "${SESSION_LOG}"
  fi
}

log_info()  { log_write "INFO"  "$1"; }
log_warn()  { log_write "WARN"  "$1"; }
log_error() { log_write "ERROR" "$1"; }
log_ok()    { log_write "OK"    "$1"; }

log_step() {
  echo "" >&2
  log_info "── $1 ──"
}
