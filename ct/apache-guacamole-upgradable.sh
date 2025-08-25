#!/usr/bin/env bash
# Copyright (c) 2025 community-scripts ORG
# Author: Mauricio Perez + ChatGPT
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://guacamole.apache.org/
# Base OS: Ubuntu Server 24.04 (LXC)
#
# What’s different:
# - Uses apt packages for: guacd (guacamole-server), mariadb-server, openjdk-21
# - Tomcat 9 is vendored (latest) to stay compatible with Guacamole WAR (javax.*)
# - Pulls latest Guacamole Client + JDBC dynamically at install time
# - Adds /usr/local/sbin/guacamole-update to refresh WAR/JDBC later (simple updater)
# - Leaves OS fully upgradable via `apt upgrade`

set -Eeuo pipefail

# Optional: source Proxmox Helper framework if available; otherwise use local fallbacks.
if [[ -n "${FUNCTIONS_FILE_PATH:-}" && -r "${FUNCTIONS_FILE_PATH}" ]]; then
  # shellcheck disable=SC1090
  source "${FUNCTIONS_FILE_PATH}"
elif [[ -r /etc/community-scripts/.bash_functions ]]; then
  # shellcheck disable=SC1091
  source /etc/community-scripts/.bash_functions
else
  # --------- Minimal local fallbacks so the script can run standalone ----------
  color() { :; }
  msg_info()  { echo -e "\e[34m[INFO]\e[0m  $*"; }
  msg_ok()    { echo -e "\e[32m[ OK ]\e[0m  $*"; }
  msg_warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
  msg_error() { echo -e "\e[31m[ERR]\e[0m   $*"; }
  die() { msg_error "$*"; exit 1; }

  # send tool output to screen; set to '>/dev/null 2>&1' to silence
  STD=""

  verb_ip6() { :; }
  catch_errors() { trap 'msg_error "Unexpected error (line $LINENO)"; exit 1' ERR; }
  setting_up_container() { :; }
  network_check() { :; }
  update_os() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get dist-upgrade -y
  }
  setup_mariadb() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y mariadb-server mariadb-client
    systemctl enable --now mariadb
  }
  motd_ssh() { :; }
  customize() { :; }
fi

# --- Community-Scripts integration ---
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# -----------------------------
# Helpers
# -----------------------------

_latest_guac_version() {
  # Scrape Apache downloads listing and return highest stable version (e.g. 1.6.0)
  curl -fsSL https://downloads.apache.org/guacamole/ \
  | grep -oE 'href="([0-9]+\.[0-9]+\.[0-9]+)/"' \
  | sed -E 's@href="([0-9]+\.[0-9]+\.[0-9]+)/"@\1@' \
  | sort -V | tail -n1
}

_latest_tomcat9_version() {
  curl -fsSL https://dlcdn.apache.org/tomcat/tomcat-9/ \
  | grep -oP '(?<=href=")v[^"/]+(?=/")' \
  | sed 's/^v//' \
  | sort -V | tail -n1
}

detect_java_home() {
  if command -v javac >/dev/null 2>&1; then
    local bin; bin="$(readlink -f "$(command -v javac)")"
    dirname "$(dirname "$bin")"
  else
    echo "/usr/lib/jvm/java-21-openjdk-amd64"
  fi
}

# -----------------------------
# Install base packages
# -----------------------------
msg_info "Installing base packages (MariaDB, guacd, Java, tools)"

# Pick the right guacd package name per distro
if apt-cache show guacd >/dev/null 2>&1; then
  PKG_GUACD="guacd"
else
  PKG_GUACD="guacamole-server"
fi

$STD apt-get install -y \
  ca-certificates curl jq \
  mariadb-server mariadb-client \
  "$PKG_GUACD" \
  openjdk-21-jdk-headless \
  libmariadb-java \
  unzip

# Make sure services are present/startable
systemctl enable --now mariadb guacd >/dev/null 2>&1 || true
msg_ok "Installed base packages"

# -----------------------------
# Secure MariaDB minimally + create DB
# -----------------------------
msg_info "Configuring database"
DB_NAME="guacamole_db"
DB_USER="guacamole_user"
DB_PASS="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c16)"

# Ensure MariaDB is running
systemctl enable --now mariadb

# Create DB and user
$STD mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} DEFAULT CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

{
  echo "Guacamole-Credentials"
  echo "Database User: ${DB_USER}"
  echo "Database Password: ${DB_PASS}"
  echo "Database Name: ${DB_NAME}"
} >> ~/guacamole.creds
chmod 600 ~/guacamole.creds

msg_ok "Database ready: ${DB_NAME} / ${DB_USER}"

# -----------------------------
# Install Tomcat 9 (vendored)
# -----------------------------
msg_info "Installing Apache Tomcat 9 (latest)"
TOMCAT_VER="$(_latest_tomcat9_version)"
install -d -m 0755 /opt/apache-guacamole/tomcat9
curl -fsSL "https://dlcdn.apache.org/tomcat/tomcat-9/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz" \
  | tar -xz -C /opt/apache-guacamole/tomcat9 --strip-components=1

# Create dedicated user
id -u tomcat >/dev/null 2>&1 || useradd -r -d /opt/apache-guacamole/tomcat9 -s /bin/false tomcat
chown -R tomcat: /opt/apache-guacamole/tomcat9
chmod -R g+r /opt/apache-guacamole/tomcat9/conf
chmod g+x /opt/apache-guacamole/tomcat9/conf
msg_ok "Tomcat 9 installed (v${TOMCAT_VER})"

# -----------------------------
# Install Guacamole Client (WAR) + JDBC extension (latest)
# -----------------------------
msg_info "Installing Apache Guacamole (client + JDBC)"
GUAC_VER="$(_latest_guac_version)"
install -d -m 0755 /etc/guacamole/{extensions,lib}

# Use distro mariadb JDBC (keeps upgradable)
JDBC_JAR="/usr/share/java/mariadb-java-client.jar"
ln -sf "$JDBC_JAR" /etc/guacamole/lib/ 2>/dev/null || true

# Download WAR
curl -fsSL "https://downloads.apache.org/guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war" \
  -o "/opt/apache-guacamole/tomcat9/webapps/guacamole.war"

# Download JDBC auth extension (mysql) + schema
TMPD="$(mktemp -d)"
curl -fsSL "https://downloads.apache.org/guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz" \
  -o "${TMPD}/guacamole-auth-jdbc.tar.gz"
tar -xzf "${TMPD}/guacamole-auth-jdbc.tar.gz" -C "${TMPD}"
JDBC_DIR="$(find "${TMPD}" -maxdepth 1 -type d -name "guacamole-auth-jdbc-*")"

# Copy extension JAR
cp -f "${JDBC_DIR}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VER}.jar" /etc/guacamole/extensions/

# Load schema into DB (only if DB is empty)
TABLES=$(mariadb -N -B -u root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
if [[ "${TABLES}" -eq 0 ]]; then
  msg_info "Populating database schema"
  cat "${JDBC_DIR}/mysql/schema/"*.sql | $STD mariadb -u root "${DB_NAME}"
  msg_ok "Database schema installed"
else
  msg_ok "Database already has tables; skipping schema import"
fi

rm -rf "${TMPD}"

# -----------------------------
# guacamole.properties
# -----------------------------
msg_info "Writing /etc/guacamole/guacamole.properties"
cat >/etc/guacamole/guacamole.properties <<EOF
# --- Guacamole core ---
guacd-hostname: 127.0.0.1
guacd-port: 4822

# --- MySQL/MariaDB auth ---
mysql-hostname: 127.0.0.1
mysql-port: 3306
mysql-database: ${DB_NAME}
mysql-username: ${DB_USER}
mysql-password: ${DB_PASS}
# Avoid SSL mismatch unless explicitly configured on server:
mysql-ssl-mode: disabled
EOF
chown -R tomcat: /etc/guacamole
msg_ok "guacamole.properties ready"

# -----------------------------
# Systemd: guacd (apt) + Tomcat (vendored)
# -----------------------------
msg_info "Configuring services"

# guacd (from apt) already has a systemd unit; ensure started
systemctl enable --now guacd

JAVA_HOME="$(detect_java_home)"
cat >/etc/systemd/system/tomcat9.service <<EOF
[Unit]
Description=Apache Tomcat 9 (Guacamole)
After=network.target
Wants=guacd.service

[Service]
Type=forking
Environment=JAVA_HOME=${JAVA_HOME}
Environment=CATALINA_PID=/opt/apache-guacamole/tomcat9/temp/tomcat.pid
Environment=CATALINA_HOME=/opt/apache-guacamole/tomcat9
Environment=CATALINA_BASE=/opt/apache-guacamole/tomcat9
Environment=CATALINA_OPTS=-Xms512M -Xmx1024M -server -XX:+UseParallelGC
Environment=JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom
ExecStart=/opt/apache-guacamole/tomcat9/bin/startup.sh
ExecStop=/opt/apache-guacamole/tomcat9/bin/shutdown.sh
User=tomcat
Group=tomcat
UMask=0007
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tomcat9

msg_ok "Services configured (guacd + tomcat9)"

# -----------------------------
# Simple Updater
# -----------------------------
msg_info "Installing simple updater: /usr/local/sbin/guacamole-update"
cat >/usr/local/sbin/guacamole-update <<'EOSH'
#!/usr/bin/env bash
set -Eeuo pipefail
GUAC_HOME="/etc/guacamole"
WEBAPPS="/opt/apache-guacamole/tomcat9/webapps"
EXT="${GUAC_HOME}/extensions"
TMPD="$(mktemp -d)"

die(){ echo "ERROR: $*" >&2; exit 1; }

latest_ver() {
  curl -fsSL https://downloads.apache.org/guacamole/ \
  | grep -oE 'href="([0-9]+\.[0-9]+\.[0-9]+)/"' \
  | sed -E 's@href="([0-9]+\.[0-9]+\.[0-9]+)/"@\1@' \
  | sort -V | tail -n1
}

need_root() { [[ $EUID -eq 0 ]] || die "Run as root"; }

need_root

NEW="$(latest_ver)"
echo "Latest Guacamole version: ${NEW}"

systemctl stop tomcat9 || true

# Download WAR
curl -fsSL "https://downloads.apache.org/guacamole/${NEW}/binary/guacamole-${NEW}.war" \
  -o "${TMPD}/guacamole.war"
install -m 0644 "${TMPD}/guacamole.war" "${WEBAPPS}/guacamole.war"

# Download JDBC and replace extension
curl -fsSL "https://downloads.apache.org/guacamole/${NEW}/binary/guacamole-auth-jdbc-${NEW}.tar.gz" \
  -o "${TMPD}/jdbc.tgz"
tar -xzf "${TMPD}/jdbc.tgz" -C "${TMPD}"
JDBC_DIR="$(find "${TMPD}" -maxdepth 1 -type d -name "guacamole-auth-jdbc-*")"

# Remove existing mysql extension jars
rm -f ${EXT}/guacamole-auth-jdbc-mysql-*.jar 2>/dev/null || true
install -m 0644 "${JDBC_DIR}/mysql/guacamole-auth-jdbc-mysql-${NEW}.jar" "${EXT}/"

echo "Updated WAR and JDBC to ${NEW}."
echo "NOTE: If this is a major upgrade that changes DB schema, apply upgrade SQLs:"
echo "  tar -xzf jdbc.tgz; cd guacamole-auth-jdbc-${NEW}/mysql/upgrade"
echo "  cat *.sql | mariadb -u root guacamole_db"
echo "Restarting tomcat9 ..."
systemctl start tomcat9
rm -rf "${TMPD}"
EOSH
chmod +x /usr/local/sbin/guacamole-update
msg_ok "Updater installed"

# -----------------------------
# Final touch
# -----------------------------
motd_ssh
customize

IP=$(hostname -I | awk '{print $1}')
msg_ok "Apache Guacamole ${GUAC_VER} is ready!"
echo -e "  URL:    http://${IP}:8080/guacamole"
echo -e "  DB Credentials saved at: ~/guacamole.creds"
echo -e "  Update later with: sudo guacamole-update"

# -------------------------------------
# Point Tomcat’s ROOT to guacamole.war
# -------------------------------------
# inside the container
sudo systemctl stop tomcat9
cd /opt/apache-guacamole/tomcat9/webapps

# remove the default ROOT app
sudo rm -rf ROOT ROOT.war

# make ROOT be Guacamole (symlink so your updater keeps working)
sudo ln -s guacamole.war ROOT.war

sudo systemctl start tomcat9
