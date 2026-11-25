#!/usr/bin/env bash
#===============================================================================
# install-zabbix.sh
#
# Zabbix 8.0 LTS one-click installer for Ubuntu 26.04 (Resolute).
# Based on the official installation guide: https://www.zabbix.com/download
#
# Modes:
#   Online  (default): installs from repo.zabbix.com (server needs internet)
#   Offline          : --offline <dir> installs from a package tarball made by
#                      make-offline-package.sh (for intranet / air-gapped hosts)
#
# Usage examples:
#   sudo bash install-zabbix.sh
#   sudo bash install-zabbix.sh --db-password 'S3cret!' --timezone Asia/Shanghai
#   sudo bash install-zabbix.sh --webserver nginx --agent2
#   sudo bash install-zabbix.sh --offline /opt/zabbix-offline
#   sudo bash install-zabbix.sh --non-interactive --config /path/to/config.conf
#
# Exit codes: 0 ok / 1 general error / 2 unsupported OS / 3 wrong user
#===============================================================================

set -Eeuo pipefail

#------------------------------------------------------------------------------
# Defaults (override via CLI flags or config file)
#------------------------------------------------------------------------------
ZABBIX_VERSION="8.0"          # 8.0 (LTS) is recommended for production
UBUNTU_VERSION="26.04"
TIMEZONE="Asia/Shanghai"
WEBSERVER="apache"            # apache | nginx
AGENT_PKG="zabbix-agent2"     # zabbix-agent2 | zabbix-agent
DB_HOST="localhost"           # "localhost" = local socket; else remote MySQL host
DB_NAME="zabbix"
DB_USER="zabbix"
DB_PASSWORD=""                # auto-generated when empty
DB_ROOT_PASSWORD=""           # only needed when DB_HOST is remote
OPEN_FIREWALL="yes"
NON_INTERACTIVE="no"
OFFLINE_DIR=""
CONFIG_FILE=""
LOG_FILE="/var/log/zabbix-install.log"
CRED_FILE="/root/.zabbix-db-password"

ZABBIX_PKGS_BASE="zabbix-server-mysql zabbix-frontend-php zabbix-sql-scripts"
REPO_DEB_URL_FMT="https://repo.zabbix.com/zabbix/%s/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_%s+ubuntu%s_all.deb"

#------------------------------------------------------------------------------
# Pretty output helpers
#------------------------------------------------------------------------------
C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_OFF='\033[0m'
info()  { echo -e "${C_GREEN}[INFO ]${C_OFF} $*"; }
warn()  { echo -e "${C_YELLOW}[WARN ]${C_OFF} $*"; }
err()   { echo -e "${C_RED}[ERROR]${C_OFF} $*" >&2; }
step()  { echo -e "\n${C_BLUE}===== $* =====${C_OFF}"; }

die() { err "$*"; exit 1; }

on_error() {
    err "Command failed at line $1 (exit code $2). See full log: ${LOG_FILE}"
    err "Fix the problem and re-run the script — it is safe to retry."
    exit 1
}
trap 'on_error $LINENO $?' ERR

#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: sudo bash $0 [OPTIONS]

Options:
  --version <ver>          Zabbix major version (default: ${ZABBIX_VERSION})
  --db-password <pass>     Password for the 'zabbix' DB user (auto-generated if omitted)
  --db-host <host>         MySQL host (default: localhost = install/use local MySQL)
  --db-root-password <p>   MySQL root password (only required with --db-host <remote>)
  --webserver <ws>         Frontend web server: apache | nginx (default: ${WEBSERVER})
  --agent2                 Install zabbix-agent2 (default)
  --agent                  Install classic zabbix-agent instead of agent2
  --timezone <tz>          System/PHP timezone (default: ${TIMEZONE})
  --no-firewall            Do not touch firewall rules
  --offline <dir>          Offline install from a package directory/tarball
                           created by make-offline-package.sh
  --config <file>          Read options from a config file (see config.example.conf)
  --non-interactive        Never prompt; fail if a required option is missing
  -h, --help               Show this help

Example:
  sudo bash $0 --db-password 'MyS3cret!' --webserver nginx --timezone Asia/Shanghai
EOF
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)            ZABBIX_VERSION="$2"; shift 2 ;;
        --db-password)        DB_PASSWORD="$2"; shift 2 ;;
        --db-host)            DB_HOST="$2"; shift 2 ;;
        --db-root-password)   DB_ROOT_PASSWORD="$2"; shift 2 ;;
        --webserver)          WEBSERVER="$2"; shift 2 ;;
        --agent2)             AGENT_PKG="zabbix-agent2"; shift ;;
        --agent)              AGENT_PKG="zabbix-agent"; shift ;;
        --timezone)           TIMEZONE="$2"; shift 2 ;;
        --no-firewall)        OPEN_FIREWALL="no"; shift ;;
        --offline)            OFFLINE_DIR="$2"; shift 2 ;;
        --config)             CONFIG_FILE="$2"; shift 2 ;;
        --non-interactive)    NON_INTERACTIVE="yes"; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

#------------------------------------------------------------------------------
# Optional config file (KEY=value lines, same names as shell variables)
#------------------------------------------------------------------------------
if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

#------------------------------------------------------------------------------
# Pre-flight checks
#------------------------------------------------------------------------------
check_preconditions() {
    step "Pre-flight checks"

    [[ $EUID -eq 0 ]] || die "Please run as root: sudo bash $0"

    # Log everything from now on
    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    if [[ ! -f /etc/os-release ]]; then
        die "/etc/os-release not found — this script is for Ubuntu ${UBUNTU_VERSION}."
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "${UBUNTU_VERSION}" ]]; then
        warn "This script targets Ubuntu ${UBUNTU_VERSION}; found ${PRETTY_NAME:-unknown}."
        if [[ "$NON_INTERACTIVE" == "yes" ]]; then
            die "Unsupported OS. Use --non-interactive only on Ubuntu ${UBUNTU_VERSION}."
        fi
        read -r -p "Continue anyway? [y/N] " ans
        [[ "${ans,,}" == "y" ]] || die "Aborted by user."
    fi

    local arch
    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64|arm64) info "Architecture: ${arch} (supported)" ;;
        *) warn "Architecture ${arch} is untested; official packages cover amd64/arm64." ;;
    esac

    case "$WEBSERVER" in apache|nginx) ;; *) die "Invalid --webserver value: $WEBSERVER (apache|nginx)" ;; esac

    command -v systemctl >/dev/null || die "systemd not detected — cannot manage services."

    info "Configuration:"
    info "  Zabbix version : ${ZABBIX_VERSION}"
    info "  Web server     : ${WEBSERVER}"
    info "  Agent package  : ${AGENT_PKG}"
    info "  DB host        : ${DB_HOST}"
    info "  Timezone       : ${TIMEZONE}"
    info "  Install mode   : $([[ -n "$OFFLINE_DIR" ]] && echo offline || echo online)"
    info "  Log file       : ${LOG_FILE}"
}

#------------------------------------------------------------------------------
# Generate a strong random password
#------------------------------------------------------------------------------
gen_password() {
    # NOTE: temporarily disable pipefail — `head -c` closes the pipe early and
    # SIGPIPEs `tr` (exit 141), which would otherwise abort under pipefail.
    set +o pipefail
    local pw
    pw=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    set -o pipefail
    printf '%s' "$pw"
}

#------------------------------------------------------------------------------
# Offline mode: unpack and install all .deb files
#------------------------------------------------------------------------------
install_offline_packages() {
    step "Installing packages from offline bundle: ${OFFLINE_DIR}"

    # Accept either a tarball or an extracted directory
    if [[ -f "$OFFLINE_DIR" && "$OFFLINE_DIR" == *.tar.gz ]]; then
        local extract_dir
        extract_dir=$(mktemp -d /opt/zabbix-offline.XXXXXX)
        info "Extracting $(basename "$OFFLINE_DIR") -> ${extract_dir}"
        tar -xzf "$OFFLINE_DIR" -C "$extract_dir"
        OFFLINE_DIR=$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1 || true)
        [[ -d "$OFFLINE_DIR" ]] || die "Could not locate extracted directory."
    fi
    [[ -d "$OFFLINE_DIR" ]] || die "Offline directory not found: $OFFLINE_DIR"

    local debs_dir="${OFFLINE_DIR}/debs"
    [[ -d "$debs_dir" ]] || die "'debs/' subfolder not found inside $OFFLINE_DIR"

    local deb_count
    deb_count=$(find "$debs_dir" -maxdepth 1 -name '*.deb' | wc -l)
    [[ "$deb_count" -gt 0 ]] || die "No .deb files found in $debs_dir"
    info "Found ${deb_count} .deb packages."

    info "Installing all packages with dpkg (this may take a few minutes)..."
    dpkg -i "$debs_dir"/*.deb || {
        warn "dpkg reported an issue, attempting 'apt-get -f install' with cached packages only..."
        apt-get install -f -y -o Acquire::http::Timeout=3 -o Acquire::Retries=0 || \
            die "Offline dependency resolution failed. The bundle may be incomplete."
    }

    info "Offline packages installed."
}

#------------------------------------------------------------------------------
# Online mode: add official Zabbix repository
#------------------------------------------------------------------------------
setup_online_repo() {
    step "Setting up official Zabbix ${ZABBIX_VERSION} repository"

    printf -v REPO_DEB_URL "$REPO_DEB_URL_FMT" "$ZABBIX_VERSION" "$ZABBIX_VERSION" "$UBUNTU_VERSION"
    local deb_file="/tmp/zabbix-release_latest_${ZABBIX_VERSION}+ubuntu${UBUNTU_VERSION}_all.deb"

    info "Downloading: $REPO_DEB_URL"
    wget -qO "$deb_file" "$REPO_DEB_URL" || die "Failed to download Zabbix release package. Check internet access / URL."
    dpkg -i "$deb_file"

    apt-get update -y
}

#------------------------------------------------------------------------------
# Install Zabbix packages
#------------------------------------------------------------------------------
install_zabbix_packages() {
    step "Installing Zabbix packages"

    local web_pkg=""
    if [[ "$WEBSERVER" == "apache" ]]; then
        web_pkg="zabbix-apache-conf"
    else
        web_pkg="zabbix-nginx-conf"
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ${ZABBIX_PKGS_BASE} ${web_pkg} ${AGENT_PKG}

    # Ensure MySQL server exists locally when DB is local.
    # NOTE: detect the SERVER package/binary, not the client — zabbix-server-mysql
    # pulls in mysql-client as a dependency, so `command -v mysql` is misleading.
    if [[ "$DB_HOST" == "localhost" ]]; then
        if ! dpkg -s mysql-server >/dev/null 2>&1 && ! command -v mysqld >/dev/null 2>&1; then
            info "Installing MySQL server..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
        fi
    fi
}

#------------------------------------------------------------------------------
# Database: create user/schema and import initial data
#------------------------------------------------------------------------------
setup_database() {
    step "Creating database and importing initial schema"

    # Reuse the existing DB password on re-runs (otherwise CREATE USER IF NOT
    # EXISTS keeps the OLD password and the new one never takes effect)
    if [[ -z "$DB_PASSWORD" && -f "$CRED_FILE" ]]; then
        DB_PASSWORD=$(sed -n 's/^DBPassword: //p' "$CRED_FILE")
        [[ -n "$DB_PASSWORD" ]] && info "Reusing DB password from ${CRED_FILE}"
    fi

    [[ -n "$DB_PASSWORD" ]] || DB_PASSWORD=$(gen_password)

    # Save credentials for the operator
    local cred_file="$CRED_FILE"
    umask 077
    {
        echo "Zabbix database credentials ($(date '+%F %T'))"
        echo "DBHost: ${DB_HOST}"
        echo "DBName: ${DB_NAME}"
        echo "DBUser: ${DB_USER}"
        echo "DBPassword: ${DB_PASSWORD}"
    } > "$cred_file"
    umask 022

    # mysql client call builder: local socket auth (Ubuntu default) or TCP+root pwd
    local mysql_root_args=(mysql -uroot)
    if [[ "$DB_HOST" != "localhost" ]]; then
        [[ -n "$DB_ROOT_PASSWORD" ]] || die "--db-root-password is required for a remote --db-host."
        mysql_root_args=(mysql -h "$DB_HOST" -uroot -p"$DB_ROOT_PASSWORD")
    fi

    info "Creating database '${DB_NAME}' and user '${DB_USER}'..."
    "${mysql_root_args[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';
SET GLOBAL log_bin_trust_function_creators = 1;
SQL

    info "Importing initial schema & data (several minutes, please wait)..."

    # Retry-safety: skip the import when the schema is already present
    local table_count
    table_count=$(MYSQL_PWD="$DB_PASSWORD" mysql --default-character-set=utf8mb4 \
        -uzabbix "${DB_NAME}" $([[ "$DB_HOST" != "localhost" ]] && echo "-h $DB_HOST") \
        -NBe "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null \
        | tr -d '[:space:]')
    if [[ "$table_count" =~ ^[0-9]+$ ]] && [[ "$table_count" -gt 5 ]]; then
        info "Schema already imported (${table_count} tables) — skipping."
        "${mysql_root_args[@]}" -e "SET GLOBAL log_bin_trust_function_creators = 0;" 2>/dev/null || true
        info "Database ready. Credentials saved to ${cred_file}"
        return 0
    fi

    if [[ "$DB_HOST" == "localhost" ]]; then
        zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
            | MYSQL_PWD="$DB_PASSWORD" mysql --default-character-set=utf8mb4 -uzabbix "${DB_NAME}"
    else
        zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
            | MYSQL_PWD="$DB_PASSWORD" mysql --default-character-set=utf8mb4 -h"$DB_HOST" -uzabbix "${DB_NAME}"
    fi

    "${mysql_root_args[@]}" -e "SET GLOBAL log_bin_trust_function_creators = 0;"
    info "Database ready. Credentials saved to ${cred_file}"
}

#------------------------------------------------------------------------------
# Configure zabbix_server.conf
#------------------------------------------------------------------------------
configure_zabbix_server() {
    step "Configuring /etc/zabbix/zabbix_server.conf"

    local conf="/etc/zabbix/zabbix_server.conf"
    set_conf() { # set_conf KEY VALUE FILE
        if grep -qE "^#?\s*${1}=.*" "$3"; then
            sed -i -E "s@^#?\s*(${1})=.*@\1=$2@" "$3"
        else
            echo "${1}=$2" >> "$3"
        fi
    }
    set_conf "DBHost" "$DB_HOST" "$conf"
    set_conf "DBName" "$DB_NAME" "$conf"
    set_conf "DBUser" "$DB_USER" "$conf"
    set_conf "DBPassword" "$DB_PASSWORD" "$conf"

    grep -qE "^DBPassword=" "$conf" || die "Failed to write DBPassword into $conf"
    info "zabbix_server.conf updated."
}

#------------------------------------------------------------------------------
# Timezone: system + PHP
#------------------------------------------------------------------------------
configure_timezone() {
    step "Configuring timezone: ${TIMEZONE}"

    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || warn "timedatectl failed; system timezone unchanged."

    if [[ "$WEBSERVER" == "apache" ]]; then
        local conf="/etc/zabbix/apache.conf"
        [[ -f "$conf" ]] && sed -i -E "s@^(\s*)#?\s*(php[_a-z]* value date\.timezone).*@\1php_value date.timezone ${TIMEZONE}@" "$conf"
    else
        local pool
        for pool in /etc/php/*/fpm/pool.d/zabbix.conf; do
            [[ -f "$pool" ]] && sed -i -E "s@^(\s*)#?\s*(php_admin_value\[date\.timezone\]).*@\1php_admin_value[date.timezone] = ${TIMEZONE}@" "$pool"
        done
    fi
    info "Timezone configured."
}

#------------------------------------------------------------------------------
# Web server: enable modules / config
#------------------------------------------------------------------------------
configure_webserver() {
    step "Configuring ${WEBSERVER} for the Zabbix frontend"

    if [[ "$WEBSERVER" == "apache" ]]; then
        a2enmod proxy proxy_fcgi >/dev/null
    else
        # zabbix-nginx-conf ships /etc/zabbix/nginx.conf
        [[ -f /etc/zabbix/nginx.conf ]] && {
            sed -i "s@^\s*#\?\s*listen\s.*@    listen 80;@" /etc/zabbix/nginx.conf
            sed -i "s@^\s*#\?\s*server_name.*@    server_name _;@" /etc/zabbix/nginx.conf
            [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
        }
    fi
    info "Web server configured."
}

#------------------------------------------------------------------------------
# Enable & start services
#------------------------------------------------------------------------------
start_services() {
    step "Starting and enabling services"

    local php_fpm=""
    local fpm_svc
    # awk must read ALL input (no `exit`) — an early-exit reader SIGPIPEs
    # systemctl and kills the script under pipefail
    fpm_svc=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '/^php[0-9.]+-fpm\.service/{print $1}' | sed -n '1p')
    [[ -n "$fpm_svc" ]] && php_fpm="$fpm_svc"

    local web_svc="$WEBSERVER"
    [[ "$WEBSERVER" == "apache" ]] && web_svc="apache2"
    local services=(zabbix-server "${AGENT_PKG}" "$web_svc")
    [[ -n "$php_fpm" ]] && services+=("$php_fpm")

    systemctl restart "${services[@]}"
    systemctl enable "${services[@]}" >/dev/null 2>&1
    info "Started: ${services[*]}"
}

#------------------------------------------------------------------------------
# Firewall
#------------------------------------------------------------------------------
configure_firewall() {
    [[ "$OPEN_FIREWALL" == "yes" ]] || { info "Firewall handling skipped (--no-firewall)."; return 0; }
    step "Configuring firewall"

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow 80/tcp  comment 'Zabbix frontend HTTP'
        ufw allow 443/tcp comment 'Zabbix frontend HTTPS'
        ufw allow 10051/tcp comment 'Zabbix trapper (agents report here)'
        ufw allow 10050/tcp comment 'Zabbix agent (passive checks)'
        info "ufw rules added for 80/443/10050/10051."
    else
        warn "ufw is not active. Ensure ports 80/443 (web) and 10051 (trapper) are reachable."
        warn "On public cloud hosts, also open these ports in the provider security group."
    fi
}

#------------------------------------------------------------------------------
# Verify installation
#------------------------------------------------------------------------------
verify_installation() {
    step "Verifying installation"

    local failed=0
    local svc
    local web_svc="$WEBSERVER"
    [[ "$WEBSERVER" == "apache" ]] && web_svc="apache2"
    for svc in zabbix-server "$AGENT_PKG" "$web_svc"; do
        if systemctl is-active --quiet "$svc"; then
            info "Service OK : $svc"
        else
            warn "Service FAILED: $svc  (check: journalctl -u $svc -e)"
            failed=1
        fi
    done

    if systemctl is-active --quiet zabbix-server; then
        if grep -qE "server #[0-9]+ started|server startup" /var/log/zabbix/zabbix_server.log 2>/dev/null; then
            info "zabbix_server.log shows successful startup."
        else
            warn "Server process is up but DB migration may still be running; tail the log to confirm:"
            warn "  tail -f /var/log/zabbix/zabbix_server.log"
        fi
    fi

    return $failed
}

#------------------------------------------------------------------------------
# Final summary
#------------------------------------------------------------------------------
print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    cat <<SUMMARY

==============================================================
  Zabbix ${ZABBIX_VERSION} LTS installation finished
==============================================================
  Frontend URL   : http://${ip:-<server-ip>}/zabbix
  Default login  : Admin / zabbix   <-- CHANGE THIS PASSWORD NOW!
  DB credentials : /root/.zabbix-db-password
  Server log     : /var/log/zabbix/zabbix_server.log
  Install log    : ${LOG_FILE}

  Recommended next steps (production):
    1. Log in and change the default Admin password immediately.
    2. Enable HTTPS (certbot or corporate certificate).
    3. Restrict access: only 80/443 public; keep 10051 for agents;
       10050 only inside your monitoring network.
    4. Tune MySQL: innodb_buffer_pool_size = 50-70% of RAM.
    5. Schedule daily backups of the 'zabbix' database and /etc/zabbix/.
==============================================================
SUMMARY
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    check_preconditions

    if [[ -n "$OFFLINE_DIR" ]]; then
        install_offline_packages
    else
        setup_online_repo
        install_zabbix_packages
    fi

    if [[ "$DB_HOST" == "localhost" ]]; then
        step "Preparing local MySQL"
        systemctl enable --now mysql 2>/dev/null || systemctl enable --now mysqld 2>/dev/null \
            || die "Failed to start the MySQL service. Check: journalctl -u mysql -e"

        # Wait until mysqld actually accepts connections (fresh first boot
        # initialization can take a while)
        info "Waiting for MySQL to accept connections..."
        for i in $(seq 1 60); do
            if mysqladmin --silent ping >/dev/null 2>&1; then
                info "MySQL is ready."
                break
            fi
            [[ $i -eq 60 ]] && die "MySQL did not become ready within 60s. Check: journalctl -u mysql -e"
            sleep 1
        done
    fi

    setup_database
    configure_zabbix_server
    configure_timezone
    configure_webserver
    start_services
    configure_firewall

    if verify_installation; then
        print_summary
    else
        warn "Some services are not running — review the log above before using Zabbix."
        exit 1
    fi
}

main "$@"
