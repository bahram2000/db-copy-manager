#!/usr/bin/env bash
# Detached execution so the clone survives SSH disconnect.

launch_detached_clone() {
  local run_id="$1"
  local source_uri="$2"
  local dest_uri="$3"
  local source_type="${4:-live}"
  local worker_log="${LOG_DIR}/${run_id}.worker.log"
  local pid_file="${STATE_DIR}/${run_id}.pid"

  mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${DUMP_DIR}"
  init_state_file "${run_id}" "${source_uri}" "${dest_uri}" "${source_type}"

  local worker_script="${RUN_DIR}/.worker-${run_id}.sh"
  cat > "${worker_script}" <<WORKER_EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="${SCRIPT_DIR}"
source "\${SCRIPT_DIR}/lib/config.sh"
source "\${SCRIPT_DIR}/lib/log.sh"
source "\${SCRIPT_DIR}/lib/conn.sh"
source "\${SCRIPT_DIR}/lib/prereq.sh"
source "\${SCRIPT_DIR}/lib/storage.sh"
source "\${SCRIPT_DIR}/lib/backup.sh"
source "\${SCRIPT_DIR}/lib/clone.sh"

run_clone_job '${run_id}'
WORKER_EOF
  chmod +x "${worker_script}"

  nohup bash "${worker_script}" >> "${worker_log}" 2>&1 &
  local pid=$!
  echo "${pid}" > "${pid_file}"
  _set_state_field "${STATE_DIR}/${run_id}.env" "PID" "${pid}"

  echo "${pid}"
}

print_detach_instructions() {
  local run_id="$1"
  local pid="$2"
  local session_log="${LOG_DIR}/${run_id}.log"
  local worker_log="${LOG_DIR}/${run_id}.worker.log"

  echo ""
  log_ok "Clone started in background (PID ${pid})."
  echo ""
  echo "  You can safely close SSH — the job will keep running."
  echo ""
  echo "  Monitor progress:"
  echo "    tail -f \"${session_log}\""
  echo "    tail -f \"${worker_log}\""
  echo ""
  echo "  Check status:"
  echo "    ${SCRIPT_DIR}/clone-db.sh --status ${run_id}"
  echo ""
}

list_runs() {
  local count=0
  echo ""
  echo "Recent clone runs:"
  echo ""

  if [[ ! -d "${STATE_DIR}" ]] || [[ -z "$(ls -A "${STATE_DIR}" 2>/dev/null)" ]]; then
    echo "  (no runs yet — start one with ./clone-db.sh)"
    echo ""
    return 0
  fi

  for state_file in "${STATE_DIR}"/*.env; do
    [[ -f "${state_file}" ]] || continue
    local run_id="${state_file##*/}"
    run_id="${run_id%.env}"
    # shellcheck disable=SC1090
    source "${state_file}"
    echo "  ${run_id}  status=${STATUS}  started=${STARTED_AT:-?}"
    count=$((count + 1))
  done

  echo ""
  echo "  Check one:  ./clone-db.sh --status <RUN_ID>"
  echo ""
}

show_run_status() {
  local run_id="$1"
  local state_file="${STATE_DIR}/${run_id}.env"

  if [[ ! -f "${state_file}" ]]; then
    log_error "No run found with id: ${run_id}"
    list_runs
    return 1
  fi

  # shellcheck disable=SC1090
  source "${state_file}"
  SOURCE_URI="$(cat "${STATE_DIR}/${run_id}.source.uri" 2>/dev/null || true)"
  DEST_URI="$(cat "${STATE_DIR}/${run_id}.dest.uri" 2>/dev/null || true)"
  SOURCE_TYPE="$(resolve_source_type "${SOURCE_URI}" "${SOURCE_TYPE:-}")"

  echo ""
  echo "Run ID:      ${RUN_ID}"
  echo "Status:      ${STATUS}"
  echo "PID:         ${PID:-n/a}"
  echo "Started:     ${STARTED_AT:-n/a}"
  echo "Finished:    ${FINISHED_AT:-n/a}"
  if [[ "${SOURCE_TYPE}" == "backup" ]]; then
    echo "Source:      backup $(mask_backup_url "${SOURCE_URI:-unknown}")"
  else
    echo "Source:      $(mask_uri "${SOURCE_URI:-unknown}")"
  fi
  echo "Destination: $(mask_uri "${DEST_URI:-unknown}")"
  echo "Log:         ${SESSION_LOG}"
  echo ""

  if [[ -n "${PID:-}" ]] && kill -0 "${PID}" 2>/dev/null; then
    echo "Process is still running."
  elif [[ "${STATUS}" == "running" ]]; then
    echo "Process is not running but status is still 'running' — check logs."
  fi
}
