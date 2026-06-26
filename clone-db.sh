#!/usr/bin/env bash
# PostgreSQL clone wizard — entry point.
#
# Usage:
#   ./clone-db.sh              Interactive wizard
#   ./clone-db.sh --status ID  Check a background run
#
# Requires: psql, pg_dump, pg_restore, createdb, dropdb (PostgreSQL client tools)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/conn.sh"
source "${SCRIPT_DIR}/lib/prereq.sh"
source "${SCRIPT_DIR}/lib/storage.sh"
source "${SCRIPT_DIR}/lib/clone.sh"
source "${SCRIPT_DIR}/lib/background.sh"
source "${SCRIPT_DIR}/lib/wizard.sh"

usage() {
  cat <<EOF
PostgreSQL DB Copy Manager

Usage:
  $(basename "$0")                 Run interactive clone wizard
  $(basename "$0") --status RUN_ID Check status of a background clone

Runs are stored under: ${RUN_DIR}/
EOF
}

main() {
  mkdir -p "${RUN_DIR}" "${LOG_DIR}" "${STATE_DIR}" "${DUMP_DIR}"

  case "${1:-}" in
    --status)
      [[ -n "${2:-}" ]] || { usage; exit 1; }
      show_run_status "${2}"
      ;;
    -h|--help)
      usage
      ;;
    "")
      run_wizard
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
