#!/usr/bin/env bash
set -euo pipefail

# bootstrap-mezmo-agent.sh
# - Configures Mezmo (LogDNA) agent asking only for the ingestion key
# - Creates YAML, systemd drop-in, and enables the agent

SERVICE="logdna-agent"
BIN="/usr/bin/${SERVICE}"
CONFIG_DIR="/etc/logdna"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
OVRD_DIR="/etc/systemd/system/${SERVICE}.service.d"
OVRD_FILE="${OVRD_DIR}/override.conf"

# ===== helpers =====
fail(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || fail "run as sudo/root"; }
have(){ command -v "$1" >/dev/null 2>&1; }

need_root

# ===== get the key (only prompt) =====
KEY="${MEZMO_KEY:-}"
if [ -z "${KEY}" ]; then
  read -rsp "Mezmo ingestion key: " KEY; echo
fi
[ -n "${KEY}" ] || fail "empty ingestion key"

# ===== install agent if missing =====
if [ ! -x "${BIN}" ]; then
  echo "Agent not found, attempting to install..."
  if have apt-get; then
    apt-get update -y
    apt-get install -y logdna-agent || fail "installation via apt failed"
  elif have dnf; then
    dnf install -y logdna-agent || fail "installation via dnf failed"
  elif have yum; then
    yum install -y logdna-agent || fail "installation via yum failed"
  else
    fail "cannot install automatically on this system — install the 'logdna-agent' package and run again"
  fi
fi

# ===== prepare directories =====
install -d -m 755 "${CONFIG_DIR}"
install -d -m 755 /var/log/rclone

# Allow tags customization without another prompt (optional)
HOSTNAME_VAL="$(hostname -s 2>/dev/null || hostname)"
TAGS_VAL="${MEZMO_TAGS:-rclone,bisync}"

# ===== write config.yaml (idempotent) =====
umask 077
cat >"${CONFIG_FILE}" <<EOF
http:
  ingestion_key: ${KEY}
  host: logs.logdna.com
  endpoint: /logs/agent
  use_ssl: true
  use_compression: true
  gzip_level: 2
  timeout: 10000
  flush_duration: 5000
  body_size: 2097152
  params:
    hostname: ${HOSTNAME_VAL}
    tags: ${TAGS_VAL}

log:
  dirs:
    - /var/log/rclone
  include:
    glob:
      - '*.log'
    regex: []
  exclude:
    glob: []
    regex: []

journalctl:
  enabled: false

k8s:
  enabled: false
EOF
chmod 600 "${CONFIG_FILE}"
echo "config written to ${CONFIG_FILE}"

# ===== systemd drop-in =====
install -d -m 755 "${OVRD_DIR}"
cat >"${OVRD_FILE}" <<EOF
[Service]
# explicitly point to the YAML we created
Environment="MZ_CONFIG_FILE=${CONFIG_FILE}"
Environment="LOGDNA_CONFIG_FILE=${CONFIG_FILE}"
# disable journal tailer via env as well (in addition to YAML)
Environment="MZ_SYSTEMD_JOURNAL_TAILER=false"
# avoid conflicts if /etc/logdna.env sets dirs/patterns
UnsetEnvironment=LOGDNA_LOG_DIRS LOGDNA_INCLUSION_RULES MZ_LOG_DIRS MZ_INCLUSION_RULES
EOF

# ===== apply and start =====
systemctl daemon-reload
# clear any previous failures (if any)
systemctl reset-failed "${SERVICE}" 2>/dev/null || true
systemctl enable --now "${SERVICE}"

# ===== quick check =====
sleep 1
if systemctl is-active --quiet "${SERVICE}"; then
  echo "✅ ${SERVICE} is active and enabled on boot."
else
  echo "⚠️ ${SERVICE} is not active; recent logs:"
  journalctl -u "${SERVICE}" -n 50 --no-pager || true
  exit 1
fi

echo
echo "Done! Logs from /var/log/rclone/*.log will be shipped."
echo "Useful commands:"
echo "  journalctl -u ${SERVICE} -n 200 --no-pager"
echo "  systemctl status ${SERVICE}"
