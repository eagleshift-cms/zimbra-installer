#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Zimbra Open Source Edition (OSE) automated installer for Ubuntu 22.04
# -----------------------------------------------------------------------------
# This script performs the following actions:
#   1. Verifies root privileges and Ubuntu 22.04 environment
#   2. Sets the server hostname (and /etc/hosts) to zimbra.mge.co.id
#   3. Updates the system and installs required dependencies
#   4. Enables and configures UFW with the ports Zimbra needs
#   5. Downloads and extracts the Zimbra 9.0.0 OSE build for Ubuntu 22
#   6. Launches the interactive Zimbra installer (you will still answer prompts)
#   7. Obtains a Let’s Encrypt SSL certificate and deploys it to Zimbra
#   8. Prints post‑install reminders (admin URLs, DNS records, etc.)
#
# USAGE (once committed to GitHub):
#   curl -sSL https://raw.githubusercontent.com/<your‑github‑user>/<repo>/main/zimbra-ose-installer.sh | sudo bash
# -----------------------------------------------------------------------------
set -euo pipefail

# ------------------------- CONFIGURABLE VARIABLES ---------------------------
HOSTNAME="zimbra.mge.co.id"   # FQDN for this Zimbra server
DOMAIN="mge.co.id"           # Primary mail domain handled by Zimbra
ZIMBRA_TGZ="zcs-9.0.0_OSE_UBUNTU22_latest.tgz"
ZIMBRA_URL="https://download.zextras.com/${ZIMBRA_TGZ}"
INSTALL_DIR="/opt"            # where we download & extract the installer
FIREWALL_PORTS=(22 25 110 143 465 587 993 995 7071 80 443)  # UFW ports
CERTBOT_EMAIL="admin@${DOMAIN}"  # email for Let’s Encrypt registration
# -----------------------------------------------------------------------------

# -------------- HELPER FUNCTIONS ---------------
log()  { echo -e "\e[32m[+] $*\e[0m"; }
warn() { echo -e "\e[33m[!] $*\e[0m"; }
fail() { echo -e "\e[31m[✗] $*\e[0m" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || fail "Please run this script as root (use sudo)."
}

check_os() {
  grep -q "Ubuntu 22.04" /etc/os-release || \
    fail "Unsupported OS. Only Ubuntu 22.04 is supported."
}

set_hostname() {
  log "Setting hostname to $HOSTNAME"
  hostnamectl set-hostname "$HOSTNAME"
  local ip
  ip=$(hostname -I | awk '{print $1}')
  if ! grep -q "$HOSTNAME" /etc/hosts; then
    echo "$ip $HOSTNAME zimbra" >> /etc/hosts
  fi
}

system_update() {
  log "Updating system packages..."
  apt update && apt upgrade -y
}

install_deps() {
  log "Installing dependencies..."
  DEBIAN_FRONTEND=noninteractive apt install -y \
    net-tools curl sudo unzip libgmp10 libperl5.34 ufw certbot
}

setup_firewall() {
  log "Configuring UFW firewall..."
  ufw allow OpenSSH
  for port in "${FIREWALL_PORTS[@]}"; do
    ufw allow "${port}/tcp"
  done
  ufw --force enable
}

download_zimbra() {
  log "Downloading Zimbra OSE package..."
  cd "$INSTALL_DIR"
  if [[ ! -f "${ZIMBRA_TGZ}" ]]; then
    curl -L -o "${ZIMBRA_TGZ}" "${ZIMBRA_URL}"
  else
    warn "Package already exists, skipping download."
  fi
  tar xfz "${ZIMBRA_TGZ}"
}

run_installer() {
  log "Launching interactive Zimbra installer..."
  local dir
  dir=$(tar -tf "${INSTALL_DIR}/${ZIMBRA_TGZ}" | head -1 | cut -d'/' -f1)
  cd "${INSTALL_DIR}/${dir}"
  ./install.sh
  log "Zimbra installer finished (interactive phase)."
}

issue_cert() {
  log "Requesting Let’s Encrypt certificate for $HOSTNAME..."
  certbot certonly --standalone -d "$HOSTNAME" --non-interactive --agree-tos --email "$CERTBOT_EMAIL"

  log "Deploying certificate to Zimbra..."
  /opt/zimbra/bin/zmcertmgr deploycrt comm \
    /etc/letsencrypt/live/$HOSTNAME/privkey.pem \
    /etc/letsencrypt/live/$HOSTNAME/cert.pem \
    /etc/letsencrypt/live/$HOSTNAME/fullchain.pem

  su - zimbra -c 'zmcontrol restart'
  log "Certificate deployed and Zimbra restarted."
}

post_install_msg() {
  local ip
  ip=$(hostname -I | awk '{print $1}')
  cat <<EOF

====================================================================
 ZIMBRA OSE INSTALLATION COMPLETED
====================================================================
• Admin console : https://${HOSTNAME}:7071
• Webmail client: https://${HOSTNAME}
• Default admin : admin@${DOMAIN}

IMPORTANT NEXT STEPS:
 1) Add DNS A record:   ${HOSTNAME} → ${ip}
 2) (Optional) change MX record to point to ${HOSTNAME} once you migrate.
 3) Add SPF for this host:   v=spf1 mx a:${HOSTNAME} ~all
 4) Configure DKIM & DMARC inside the Zimbra Admin console.
 5) Schedule monthly cert renewal (crontab root):
      0 3 1 * * certbot renew --quiet && /opt/zimbra/bin/zmcontrol restart
====================================================================
EOF
}

main() {
  require_root
  check_os
  system_update
  set_hostname
  install_deps
  setup_firewall
  download_zimbra
  run_installer   # Interactive section – follow prompts!
  issue_cert      # Obtain & deploy Let’s Encrypt cert
  post_install_msg
}

main "$@"
