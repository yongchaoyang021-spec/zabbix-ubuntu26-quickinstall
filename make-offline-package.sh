#!/usr/bin/env bash
#===============================================================================
# make-offline-package.sh
#
# Build an offline installation bundle for Zabbix on Ubuntu 26.04.
#
# Run this script on an INTERNET-CONNECTED Ubuntu 26.04 machine with the SAME
# architecture (amd64/arm64) as the target intranet server. The resulting
# tar.gz contains every .deb needed to install the full Zabbix stack without
# any network access.
#
# Usage:
#   sudo bash make-offline-package.sh                          # defaults
#   sudo bash make-offline-package.sh --webserver nginx --agent
#   sudo bash make-offline-package.sh --output /tmp/mybundle
#
# Output:
#   zabbix-offline-<version>-ubuntu26.04-<arch>-<date>.tar.gz  + SHA256SUMS
#   Deploy: copy the tar.gz to the intranet server, then run:
#     sudo bash install-zabbix.sh --offline /path/to/bundle.tar.gz
#===============================================================================

set -Eeuo pipefail

C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_OFF='\033[0m'
info() { echo -e "${C_GREEN}[INFO ]${C_OFF} $*"; }
warn() { echo -e "${C_YELLOW}[WARN ]${C_OFF} $*"; }
err()  { echo -e "${C_RED}[ERROR]${C_OFF} $*" >&2; }
die()  { err "$*"; exit 1; }

ZABBIX_VERSION="8.0"
UBUNTU_VERSION="26.04"
WEBSERVER="apache"
AGENT_PKG="zabbix-agent2"
OUTPUT_DIR="$(pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  ZABBIX_VERSION="$2"; shift 2 ;;
        --webserver) WEBSERVER="$2"; shift 2 ;;
        --agent2)   AGENT_PKG="zabbix-agent2"; shift ;;
        --agent)    AGENT_PKG="zabbix-agent"; shift ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -f /etc/os-release ]] && {
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${VERSION_ID:-}" == "$UBUNTU_VERSION" ]] || \
        warn "This script is designed for Ubuntu ${UBUNTU_VERSION}; found ${PRETTY_NAME:-unknown}."
    warn "Packages must match the TARGET server's OS version and architecture."
}

command -v wget >/dev/null 2>&1 || apt-get update -y && apt-get install -y wget

WEB_PKG="zabbix-apache-conf"
[[ "$WEBSERVER" == "nginx" ]] && WEB_PKG="zabbix-nginx-conf"

WORK_DIR=$(mktemp -d /tmp/zabbix-offline.XXXXXX)
DEBS_DIR="${WORK_DIR}/debs"
mkdir -p "$DEBS_DIR/partial"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

#------------------------------------------------------------------------------
# 1. Add the official Zabbix repository (needed so apt can see Zabbix packages)
#------------------------------------------------------------------------------
info "Adding Zabbix ${ZABBIX_VERSION} repository..."
REPO_DEB_URL="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+ubuntu${UBUNTU_VERSION}_all.deb"
wget -qO "${WORK_DIR}/zabbix-release.deb" "$REPO_DEB_URL" || \
    die "Failed to download the Zabbix release package — check internet access."

dpkg -i "${WORK_DIR}/zabbix-release.deb"
apt-get update -y

#------------------------------------------------------------------------------
# 2. Download the full stack + all dependencies (no installation)
#------------------------------------------------------------------------------
info "Downloading Zabbix stack and all dependencies (this may take a while)..."
# --reinstall is critical: without it, apt skips packages that are already
# installed on this build machine and the bundle would miss core components
DEBIAN_FRONTEND=noninteractive apt-get install -y --download-only --reinstall \
    -o Dir::Cache::archives="${DEBS_DIR}" \
    -o Dir::Cache::archives/partial="${DEBS_DIR}/partial" \
    zabbix-server-mysql zabbix-frontend-php "${WEB_PKG}" zabbix-sql-scripts "${AGENT_PKG}" mysql-server

# The release package may be skipped by --download-only if already installed;
# we already downloaded it explicitly, so move it into the bundle.
cp "${WORK_DIR}/zabbix-release.deb" "${DEBS_DIR}/"

#------------------------------------------------------------------------------
# 3. Bundle metadata + checksums
#------------------------------------------------------------------------------
cat > "${WORK_DIR}/BUNDLE-INFO.txt" <<EOF
Zabbix offline installation bundle
  Created      : $(date '+%F %T')
  Zabbix       : ${ZABBIX_VERSION} (repo.zabbix.com)
  Target OS    : Ubuntu ${UBUNTU_VERSION}
  Architecture : $(dpkg --print-architecture)
  Web server   : ${WEBSERVER}
  Agent        : ${AGENT_PKG}
  Database     : MySQL 8 (server included)
  Usage        : sudo bash install-zabbix.sh --offline /path/to/this.tar.gz
EOF

find "$DEBS_DIR" -maxdepth 1 -name '*.deb' -exec sha256sum {} \; > "${WORK_DIR}/SHA256SUMS"

#------------------------------------------------------------------------------
# 4. Create the final tarball
#------------------------------------------------------------------------------
BUNDLE_NAME="zabbix-offline-${ZABBIX_VERSION}-ubuntu${UBUNTU_VERSION}-$(dpkg --print-architecture)-$(date +%Y%m%d)"
mkdir -p "$OUTPUT_DIR"

info "Creating ${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz ..."
tar -czf "${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz" -C "$WORK_DIR" \
    -C "$WORK_DIR" --transform "s,^,${BUNDLE_NAME}/," BUNDLE-INFO.txt SHA256SUMS debs

( cd "$OUTPUT_DIR" && sha256sum "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256" )

SIZE=$(du -h "${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz" | cut -f1)
cat <<DONE

==============================================================
  Offline bundle ready!
==============================================================
  File      : ${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz
  Size      : ${SIZE}
  Checksum  : ${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz.sha256

  Next steps:
    1. Copy the .tar.gz to the intranet server (USB / scp over LAN).
    2. Verify checksum:  sha256sum -c ${BUNDLE_NAME}.tar.gz.sha256
    3. Install:          sudo bash install-zabbix.sh --offline ${BUNDLE_NAME}.tar.gz
==============================================================
DONE
