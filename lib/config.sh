#!/usr/bin/env bash
# Shared paths and defaults for db-copy-manager.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
RUN_DIR="${SCRIPT_DIR}/.runs"
LOG_DIR="${RUN_DIR}/logs"
STATE_DIR="${RUN_DIR}/state"

# Extra headroom on top of measured source DB size (20%).
STORAGE_SAFETY_MARGIN=1.20

# Temporary dump file lives here during clone.
DUMP_DIR="${RUN_DIR}/dumps"

DEFAULT_PG_PORT=5432
