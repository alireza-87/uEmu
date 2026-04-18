#!/usr/bin/env bash
set -euo pipefail

MODE="all"
START_DOCKER=1

usage() {
    cat <<'EOF'
Usage: ./setup.sh [--docker-only | --vagrant-only] [--no-start-docker]

Installs the host-side tools needed to use this repository on:
  - Arch Linux
  - Ubuntu

By default it installs support for both workflows:
  - Docker: docker
  - Vagrant: vagrant + VirtualBox

Options:
  --docker-only      Install only Docker-related host dependencies
  --vagrant-only     Install only Vagrant/VirtualBox host dependencies
  --no-start-docker  Do not enable/start the docker service
  -h, --help         Show this help
EOF
}

log() {
    printf '[setup] %s\n' "$*"
}

warn() {
    printf '[setup] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[setup] ERROR: %s\n' "$*" >&2
    exit 1
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_sudo() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        return 0
    fi

    have_cmd sudo || die "sudo is required to install packages"
    sudo -v
}

run_sudo() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

apt_pkg_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

apt_pkg_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

apt_install_if_available() {
    local pkg
    local -a wanted=()
    local -a missing=()

    for pkg in "$@"; do
        [[ -n "$pkg" ]] || continue
        if apt_pkg_installed "$pkg"; then
            continue
        fi
        if apt_pkg_available "$pkg"; then
            wanted+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "APT packages not available on this system: ${missing[*]}"
    fi

    if [[ ${#wanted[@]} -gt 0 ]]; then
        log "Installing APT packages: ${wanted[*]}"
        run_sudo apt-get install -y "${wanted[@]}"
    fi
}

pacman_pkg_installed() {
    pacman -Q "$1" >/dev/null 2>&1
}

pacman_pkg_available() {
    pacman -Si "$1" >/dev/null 2>&1
}

pacman_install_if_available() {
    local pkg
    local -a wanted=()
    local -a missing=()

    for pkg in "$@"; do
        [[ -n "$pkg" ]] || continue
        if pacman_pkg_installed "$pkg"; then
            continue
        fi
        if pacman_pkg_available "$pkg"; then
            wanted+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Pacman packages not available on this system: ${missing[*]}"
    fi

    if [[ ${#wanted[@]} -gt 0 ]]; then
        log "Installing pacman packages: ${wanted[*]}"
        run_sudo pacman -Sy --needed --noconfirm "${wanted[@]}"
    fi
}

arch_header_pkg() {
    case "$(uname -r)" in
        *-lts*) echo "linux-lts-headers" ;;
        *-zen*) echo "linux-zen-headers" ;;
        *-hardened*) echo "linux-hardened-headers" ;;
        *) echo "linux-headers" ;;
    esac
}

install_ubuntu() {
    local kernel_headers="linux-headers-$(uname -r)"
    local -a common_pkgs=(
        bash
        ca-certificates
        curl
        git
        gnupg
        lsb-release
        software-properties-common
        wget
    )
    local -a docker_pkgs=()
    local -a vagrant_pkgs=()

    log "Detected Ubuntu/Debian-style system"
    run_sudo apt-get update

    if [[ "$MODE" != "vagrant" ]]; then
        docker_pkgs+=(docker.io)
    fi

    if [[ "$MODE" != "docker" ]]; then
        vagrant_pkgs+=(vagrant virtualbox virtualbox-dkms "$kernel_headers")
    fi

    apt_install_if_available "${common_pkgs[@]}" "${docker_pkgs[@]}" "${vagrant_pkgs[@]}"
}

install_arch() {
    local header_pkg
    local vbox_host_pkg="virtualbox-host-dkms"
    local -a common_pkgs=(
        base-devel
        bash
        ca-certificates
        curl
        git
        wget
    )
    local -a docker_pkgs=()
    local -a vagrant_pkgs=()

    log "Detected Arch-style system"

    if [[ "$MODE" != "vagrant" ]]; then
        docker_pkgs+=(docker)
    fi

    if [[ "$MODE" != "docker" ]]; then
        header_pkg="$(arch_header_pkg)"
        if [[ "$(uname -r)" == *-arch* ]] && pacman_pkg_available virtualbox-host-modules-arch; then
            vbox_host_pkg="virtualbox-host-modules-arch"
            vagrant_pkgs+=(vagrant virtualbox "$vbox_host_pkg")
        else
            vagrant_pkgs+=(vagrant virtualbox dkms "$vbox_host_pkg" "$header_pkg")
        fi
    fi

    pacman_install_if_available "${common_pkgs[@]}" "${docker_pkgs[@]}" "${vagrant_pkgs[@]}"
}

enable_post_install() {
    local target_user="${SUDO_USER:-${USER:-}}"

    if [[ "$MODE" != "vagrant" ]]; then
        if have_cmd systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1; then
            if [[ "$START_DOCKER" == "1" ]]; then
                log "Enabling and starting docker.service"
                run_sudo systemctl enable --now docker || warn "Could not enable/start docker.service"
            else
                log "Skipping docker.service start by request"
            fi
        fi

        if [[ -n "$target_user" ]] && getent group docker >/dev/null 2>&1; then
            log "Adding $target_user to docker group"
            run_sudo usermod -aG docker "$target_user" || warn "Could not add $target_user to docker group"
        fi
    fi

    if [[ "$MODE" != "docker" ]]; then
        if [[ -n "$target_user" ]] && getent group vboxusers >/dev/null 2>&1; then
            log "Adding $target_user to vboxusers group"
            run_sudo usermod -aG vboxusers "$target_user" || warn "Could not add $target_user to vboxusers"
        fi
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker-only)
            MODE="docker"
            shift
            ;;
        --vagrant-only)
            MODE="vagrant"
            shift
            ;;
        --no-start-docker)
            START_DOCKER=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $1"
            ;;
    esac
done

[[ -f /etc/os-release ]] || die "Cannot detect distribution: /etc/os-release not found"
# shellcheck disable=SC1091
source /etc/os-release

need_sudo

case "${ID:-}" in
    ubuntu|debian)
        install_ubuntu
        ;;
    arch|archarm)
        install_arch
        ;;
    *)
        if [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
            install_ubuntu
        elif [[ " ${ID_LIKE:-} " == *" arch "* ]]; then
            install_arch
        else
            die "Unsupported distribution: ${ID:-unknown}"
        fi
        ;;
esac

enable_post_install

cat <<EOF

[setup] Done.

Next steps:
  Docker build:   ./build.sh
  Docker run:     ./run.sh
  Vagrant build:  ./build-base-box.sh
  Vagrant worker: UEMU_ROLE=worker UEMU_VM_COUNT=21 UEMU_VM_CPUS=1 vagrant up

Notes:
  - If docker or vboxusers group membership changed, log out and back in.
  - If VirtualBox host modules were newly installed, a reboot may be required.
EOF
