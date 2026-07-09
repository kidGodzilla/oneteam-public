#!/usr/bin/env bash
set -euo pipefail

#####################################################################################
# OneTeam — host bootstrap.
# Takes a fresh Ubuntu box (LTS) to a hardened, Docker-ready state. Run ONCE as root.
# Adapted from a proven Dokku host-bootstrap; swaps Dokku for Docker + compose and
# our ops-baseline choices. `install.sh` runs after this to bring up the stack.
#
# IMPORTANT: this disables SSH password login. Add your SSH key BEFORE running or it
# will refuse to proceed (keys-present safety check) rather than lock you out.
#
# Idempotent: every step checks-before-doing, so re-running converges.
#####################################################################################

NOFILE_LIMIT=1048576
LIMITS_FILE="/etc/security/limits.conf"
PAM_FILE="/etc/pam.d/common-session"

# --- helpers (from the Dokku script — good idempotent primitives) -------------------
append_if_missing() { grep -qxF "$1" "$2" 2>/dev/null || echo "$1" >>"$2"; }
upsert_line() { # key= value file  — update existing key or append
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}" "$file" 2>/dev/null; then
    sed -i "s|^${key}.*|${key}${value}|" "$file"
  else
    echo "${key}${value}" >>"$file"
  fi
}
reload_ssh() { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true; }

# --- 0. privilege ------------------------------------------------------------------
check_root() { [ "$EUID" -eq 0 ] || { echo "❌ Must run as root (sudo)"; exit 1; }; }

# --- 1. core packages + auto security updates --------------------------------------
install_core_packages() {
  apt-get update
  apt-get install -y curl wget git ca-certificates gnupg
}

automatic_updates() {
  apt-get install -y --no-install-recommends unattended-upgrades apt-listchanges
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure --priority=low unattended-upgrades
  # Reboot for kernel/security updates, but inside a window (not blindly mid-day).
  upsert_line 'Unattended-Upgrade::Automatic-Reboot ' '"true";' /etc/apt/apt.conf.d/50unattended-upgrades
  upsert_line 'Unattended-Upgrade::Automatic-Reboot-Time ' '"04:00";' /etc/apt/apt.conf.d/50unattended-upgrades
}

# --- 2. SSH hardening (with lock-out safety) ---------------------------------------
check_ssh_keys_present() {
  local found=0 f
  for f in /root/.ssh/authorized_keys ${SUDO_USER:+/home/$SUDO_USER/.ssh/authorized_keys}; do
    [ -s "$f" ] && found=1
  done
  [ "$found" -eq 1 ] || {
    echo "❌ No SSH keys found in /root or \$SUDO_USER. Add your key before hardening —"
    echo "   disabling password auth without a key would lock you out."
    exit 1
  }
}

harden_ssh() {
  check_ssh_keys_present
  # Ubuntu 24.04 cloud images set PasswordAuthentication via a drop-in that OVERRIDES
  # /etc/ssh/sshd_config — so sed-ing the main file alone silently does nothing. Write
  # our own high-priority drop-in instead; it wins.
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-oneteam.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  reload_ssh
}

# --- 3. firewall + intrusion prevention --------------------------------------------
install_firewall() {
  apt-get install -y ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow http
  ufw allow https
  ufw --force enable
}

install_fail2ban() {
  # Simple, proven SSH brute-force protection. For web-facing services later, layer
  # CrowdSec on top (behavioral, community blocklist).
  apt-get install -y fail2ban
  ln -sf /etc/fail2ban/jail.d/defaults-debian.conf /etc/fail2ban/jail.d/sshd.local
  systemctl restart fail2ban
}

# --- 4. Docker (official apt repo — not curl|bash) ---------------------------------
install_docker() {
  command -v docker &>/dev/null && return
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

configure_docker_daemon() {
  # Default json-file logs grow UNBOUNDED — a classic appliance disk-fill. Cap them.
  install -d -m 0755 /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker 2>/dev/null || true
}

docker_prune_cron() {
  # SAFE prune: images + build cache only. Deliberately NO `system prune --volumes` —
  # that deletes named volumes not attached to a running container, which would nuke
  # our data if the stack is ever down during the cron. (This is the footgun in the
  # original Dokku script's daily `system prune -a --volumes`.)
  cat >/etc/cron.d/docker-prune <<'EOF'
@daily root docker image prune -af >/dev/null 2>&1
EOF
}

# --- 5. host housekeeping ----------------------------------------------------------
persist_journald() {
  upsert_line 'Storage=' 'persistent' /etc/systemd/journald.conf
  systemctl restart systemd-journald
}

raise_ulimits() {
  upsert_line "fs.file-max = " "$NOFILE_LIMIT" /etc/sysctl.conf
  upsert_line "fs.nr_open = " "$NOFILE_LIMIT" /etc/sysctl.conf
  append_if_missing "session required pam_limits.so" "$PAM_FILE"
  append_if_missing "* soft nofile $NOFILE_LIMIT" "$LIMITS_FILE"
  append_if_missing "* hard nofile $NOFILE_LIMIT" "$LIMITS_FILE"
  append_if_missing "root soft nofile $NOFILE_LIMIT" "$LIMITS_FILE"
  append_if_missing "root hard nofile $NOFILE_LIMIT" "$LIMITS_FILE"
}

create_swap_if_needed() {
  local mem_total; mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  (( mem_total < 8000000 )) || return 0
  swapon --show | grep -q '/swapfile' && { echo "✓ swap active"; return 0; }
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  append_if_missing '/swapfile none swap sw 0 0' /etc/fstab
}

install_chrony() { apt-get install -y chrony; systemctl enable --now chrony; }

set_hostname() {
  local current; current=$(hostname)
  if [[ "$current" == "localhost" || "$current" == ip-* ]]; then
    hostnamectl set-hostname "oneteam-$(hostname -I | awk '{print $1}' | tr . -)"
  fi
}

# TODO: install a lightweight monitoring agent (e.g. Beszel) here once its hub URL/token is known.

# --- main --------------------------------------------------------------------------
main() {
  check_root
  install_core_packages

  harden_ssh
  install_firewall
  install_fail2ban

  install_docker
  configure_docker_daemon
  docker_prune_cron

  persist_journald
  raise_ulimits
  create_swap_if_needed
  install_chrony
  set_hostname
  automatic_updates

  echo "✅ Host bootstrap complete. Next: ./install.sh   (reboot recommended)"
}

main "$@"
