#!/usr/bin/env bash
# Optional package installation for missing backup tooling.

_has_http_download_client() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

_detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt-get"
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    echo "apt"
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    echo "yum"
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    echo "apk"
    return 0
  fi
  if command -v zypper >/dev/null 2>&1; then
    echo "zypper"
    return 0
  fi
  if command -v pacman >/dev/null 2>&1; then
    echo "pacman"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    echo "brew"
    return 0
  fi
  return 1
}

_build_pkg_install_cmd() {
  local pkg_manager="$1"
  local package="$2"

  case "${pkg_manager}" in
    apt-get)
      printf 'apt-get update -qq && apt-get install -y %s' "${package}"
      ;;
    apt)
      printf 'apt update -qq && apt install -y %s' "${package}"
      ;;
    dnf|yum)
      printf '%s install -y %s' "${pkg_manager}" "${package}"
      ;;
    apk)
      printf 'apk add --no-cache %s' "${package}"
      ;;
    zypper)
      printf 'zypper -n install %s' "${package}"
      ;;
    pacman)
      printf 'pacman -Sy --noconfirm %s' "${package}"
      ;;
    brew)
      printf 'brew install %s' "${package}"
      ;;
    *)
      return 1
      ;;
  esac
}

_run_pkg_install() {
  local install_cmd="$1"
  local err

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    err="$(bash -c "${install_cmd}" 2>&1)" || {
      log_error "Package install failed."
      [[ -n "${err}" ]] && log_error "  ${err}"
      return 1
    }
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    log_error "Need root or sudo to install packages automatically."
    return 1
  fi

  err="$(sudo bash -c "${install_cmd}" 2>&1)" || {
    log_error "Package install failed (sudo)."
    [[ -n "${err}" ]] && log_error "  ${err}"
    return 1
  }
  return 0
}

install_download_client_package() {
  local pkg_manager package install_cmd

  pkg_manager="$(_detect_pkg_manager)" || {
    log_error "Could not detect a supported package manager for auto-install."
    log_error "Install curl or wget manually, then retry."
    return 1
  }

  package="curl"
  install_cmd="$(_build_pkg_install_cmd "${pkg_manager}" "${package}")" || return 1

  log_info "Installing ${package} via ${pkg_manager}..."
  _run_pkg_install "${install_cmd}" || return 1

  if command -v curl >/dev/null 2>&1; then
    log_ok "Installed curl successfully."
    return 0
  fi

  log_warn "curl install did not succeed; trying wget..."
  package="wget"
  install_cmd="$(_build_pkg_install_cmd "${pkg_manager}" "${package}")" || return 1
  _run_pkg_install "${install_cmd}" || return 1

  if command -v wget >/dev/null 2>&1; then
    log_ok "Installed wget successfully."
    return 0
  fi

  log_error "Could not install curl or wget."
  return 1
}

ensure_download_client() {
  if _has_http_download_client; then
    return 0
  fi

  log_warn "Neither curl nor wget is installed."
  install_download_client_package || return 1
  _has_http_download_client
}
