#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: YourNameHere
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://ui.docs.kafbat.io/

APP="Kafka-UI"
var_tags="${var_tags:-messaging;ui;kafka}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-5}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources

    if [[ ! -d /opt/kafka-ui ]]; then
        msg_error "No ${APP} Installation Found!"
        exit 1
    fi

    API="https://api.github.com/repos/kafbat/kafka-ui/releases/latest"
    RELEASE=$(curl -fsSL "$API" | jq -r '.tag_name')
    CURRENT=$(cat /opt/kafka-ui/.version 2>/dev/null || echo "v0.0.0")

    if [[ "$RELEASE" == "$CURRENT" ]]; then
        msg_ok "${APP} is already at ${CURRENT}."
        exit 0
    fi

    JAR_URL=$(curl -fsSL "$API" \
        | jq -r '.assets[] | select(.name | endswith(".jar")) | .browser_download_url' \
        | head -1)
    if [[ -z "$JAR_URL" || "$JAR_URL" == "null" ]]; then
        msg_error "No JAR asset found in ${RELEASE}"
        exit 1
    fi

    msg_info "Stopping ${APP}"
    systemctl stop kafka-ui
    msg_ok "Stopped ${APP}"

    msg_info "Updating ${APP} to ${RELEASE}"
    curl -fsSL "$JAR_URL" -o /opt/kafka-ui/kafka-ui.jar
    echo "${RELEASE}" >/opt/kafka-ui/.version
    chown -R kafka-ui:kafka-ui /opt/kafka-ui
    msg_ok "Updated ${APP} to ${RELEASE}"

    msg_info "Starting ${APP}"
    systemctl start kafka-ui
    msg_ok "Started ${APP}"

    msg_ok "Update Complete"
    exit 0
}

start

# ----------------------------------------------------------------------------
# Prompt: which Kafka broker to connect to?
#
# Runs on the Proxmox host where whiptail has a real TTY. The answer is
# exported so the install script (running inside the container via
# lxc-attach) can read it.
#
# Non-interactive override:
#   var_kafka_bootstrap="192.168.1.142:9092" bash -c "$(curl -fsSL .../ct/kafka-ui.sh)"
# ----------------------------------------------------------------------------
if [[ -z "${var_kafka_bootstrap:-}" ]]; then
    # Try to suggest a sensible default from the host's primary subnet
    HOST_NETBASE=$(ip -4 addr show 2>/dev/null \
        | awk '/inet / && $2 !~ /^127\./ {print $2}' \
        | head -1 \
        | cut -d/ -f1 \
        | awk -F. '{print $1"."$2"."$3}')
    DEFAULT_BOOTSTRAP="${HOST_NETBASE:-192.168.1}.X:9092"

    var_kafka_bootstrap=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Kafka Broker Address" \
        --inputbox "\nEnter the bootstrap address of your existing Kafka broker.

This is the IP:port that the Kafka LXC advertises (advertised.listeners).
Find it in /root/kafka.creds inside your Kafka container.

Format: <ip>:<port>  (e.g. 192.168.1.142:9092)" \
        15 70 "${DEFAULT_BOOTSTRAP}" \
        3>&1 1>&2 2>&3) || {
        msg_error "Cancelled — bootstrap address required."
        exit 1
    }
fi

# Sanity-check the format (ip-or-host : port)
if [[ ! "$var_kafka_bootstrap" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]]; then
    msg_error "Invalid bootstrap address: '${var_kafka_bootstrap}' (expected host:port)"
    exit 1
fi
export var_kafka_bootstrap

build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Web UI:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW} Connected to Kafka broker:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}${var_kafka_bootstrap}${CL}"
echo -e "${INFO}${YW} Login credentials are in:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}/root/kafka-ui.creds${CL}"
