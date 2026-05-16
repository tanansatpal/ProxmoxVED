#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: YourNameHere
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://ui.docs.kafbat.io/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Bootstrap address is set by ct/kafka-ui.sh BEFORE the container is built,
# then propagated across the lxc-attach boundary.
KAFKA_BOOTSTRAP="${var_kafka_bootstrap:-}"
if [[ -z "$KAFKA_BOOTSTRAP" ]]; then
    msg_error "var_kafka_bootstrap is empty — was the ct script bypassed?"
    exit 1
fi

# ----------------------------------------------------------------------------
# Base dependencies
# ----------------------------------------------------------------------------
msg_info "Installing Dependencies"
$STD apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    netcat-openbsd \
    jq \
    openssl
msg_ok "Installed Dependencies"

# ----------------------------------------------------------------------------
# JDK 21 via Eclipse Temurin (Adoptium APT repo)
#
# Debian 12 only ships openjdk-17 in the default archive and bookworm-backports
# does not carry openjdk-21. Kafbat UI requires JDK 21, so we use Adoptium's
# repo — a well-maintained LTS Java distribution signed by Eclipse.
# ----------------------------------------------------------------------------
msg_info "Adding Adoptium APT repository"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
chmod 0644 /etc/apt/keyrings/adoptium.gpg

DEB_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{print $2}' /etc/os-release)
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${DEB_CODENAME} main" \
    >/etc/apt/sources.list.d/adoptium.list
$STD apt-get update
msg_ok "Added Adoptium APT repository"

msg_info "Installing Eclipse Temurin 21 (JRE, headless)"
$STD apt-get install -y temurin-21-jre
# Persist JAVA_HOME for systemd
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
echo "JAVA_HOME=${JAVA_HOME}" >/etc/environment
msg_ok "Installed Temurin 21 (${JAVA_HOME})"

# ----------------------------------------------------------------------------
# Service user
# ----------------------------------------------------------------------------
msg_info "Creating kafka-ui system user"
groupadd --system kafka-ui 2>/dev/null || true
useradd --system --gid kafka-ui --home-dir /opt/kafka-ui \
        --shell /usr/sbin/nologin kafka-ui 2>/dev/null || true
msg_ok "Created kafka-ui system user"

# ----------------------------------------------------------------------------
# Resolve and download latest Kafbat UI release
# ----------------------------------------------------------------------------
msg_info "Resolving latest Kafbat UI release"
API="https://api.github.com/repos/kafbat/kafka-ui/releases/latest"
UI_VERSION=$(curl -fsSL "$API" | jq -r '.tag_name')
UI_JAR_URL=$(curl -fsSL "$API" \
    | jq -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url' \
    | head -1)
if [[ -z "$UI_JAR_URL" || "$UI_JAR_URL" == "null" ]]; then
    msg_error "No JAR asset found in latest Kafbat UI release"
    exit 1
fi
msg_ok "Resolved Kafbat UI ${UI_VERSION}"

msg_info "Downloading Kafbat UI ${UI_VERSION}"
mkdir -p /opt/kafka-ui
curl -fsSL "$UI_JAR_URL" -o /opt/kafka-ui/kafka-ui.jar
echo "${UI_VERSION}" >/opt/kafka-ui/.version
chown -R kafka-ui:kafka-ui /opt/kafka-ui
msg_ok "Downloaded Kafbat UI"

# ----------------------------------------------------------------------------
# Generate admin credentials
# ----------------------------------------------------------------------------
msg_info "Generating admin credentials"
UI_USER="admin"
UI_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
msg_ok "Generated admin credentials"

# ----------------------------------------------------------------------------
# systemd unit
# ----------------------------------------------------------------------------
msg_info "Creating systemd service"
cat >/etc/systemd/system/kafka-ui.service <<EOF
[Unit]
Description=Kafka-UI (Kafbat fork)
Documentation=https://ui.docs.kafbat.io/
After=network.target
Wants=network.target

[Service]
Type=simple
User=kafka-ui
Group=kafka-ui
WorkingDirectory=/opt/kafka-ui
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="JAVA_OPTS=-Xms256M -Xmx512M -XX:+UseG1GC -Djava.awt.headless=true"
Environment="SERVER_PORT=8080"
Environment="KAFKA_CLUSTERS_0_NAME=local"
Environment="KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS=${KAFKA_BOOTSTRAP}"
Environment="AUTH_TYPE=LOGIN_FORM"
Environment="SPRING_SECURITY_USER_NAME=${UI_USER}"
Environment="SPRING_SECURITY_USER_PASSWORD=${UI_PASS}"
Environment="MANAGEMENT_HEALTH_LDAP_ENABLED=false"
ExecStart=${JAVA_HOME}/bin/java \$JAVA_OPTS -jar /opt/kafka-ui/kafka-ui.jar
Restart=on-failure
RestartSec=10
SuccessExitStatus=143
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
chmod 600 /etc/systemd/system/kafka-ui.service
systemctl daemon-reload
systemctl enable -q kafka-ui
msg_ok "Created systemd service"

# ----------------------------------------------------------------------------
# Credentials file
# ----------------------------------------------------------------------------
msg_info "Saving credentials"
HOST_IP=$(hostname -I | awk '{print $1}')
cat >/root/kafka-ui.creds <<EOF
Kafka-UI Version:    ${UI_VERSION}
Kafka-UI URL:        http://${HOST_IP}:8080
Cluster Name:        local
Bootstrap Server:    ${KAFKA_BOOTSTRAP}
Username:            ${UI_USER}
Password:            ${UI_PASS}
Auth Mode:           LOGIN_FORM (basic auth)
Java Runtime:        Eclipse Temurin 21 (${JAVA_HOME})
Service:             systemctl status kafka-ui
Logs:                journalctl -u kafka-ui -f
EOF
chmod 600 /root/kafka-ui.creds
msg_ok "Saved credentials to /root/kafka-ui.creds"

# ----------------------------------------------------------------------------
# Start and verify
#
# Spring Boot cold start on a 1-core, 1 GB LXC takes 25-50 seconds.
# Allow 90 seconds before declaring failure.
# ----------------------------------------------------------------------------
msg_info "Starting Kafka-UI (Spring Boot warm-up takes up to 90s)"
systemctl start kafka-ui

UI_READY=0
for _ in {1..90}; do
    if nc -z localhost 8080 2>/dev/null; then
        UI_READY=1
        break
    fi
    sleep 1
done
if [[ $UI_READY -eq 1 ]]; then
    msg_ok "Started Kafka-UI (listening on 8080)"
else
    msg_error "Kafka-UI did not bind 8080 within 90s — check 'journalctl -u kafka-ui'"
    exit 1
fi

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
