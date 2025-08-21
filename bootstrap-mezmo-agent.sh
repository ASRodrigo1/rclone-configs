#!/usr/bin/env bash
set -euo pipefail

# bootstrap-mezmo-agent.sh
# - Configura logdna/Mezmo agent pedindo apenas a ingestion key
# - Cria YAML, drop-in do systemd e habilita o agente

SERVICE="logdna-agent"
BIN="/usr/bin/${SERVICE}"
CONFIG_DIR="/etc/logdna"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
OVRD_DIR="/etc/systemd/system/${SERVICE}.service.d"
OVRD_FILE="${OVRD_DIR}/override.conf"

# ===== helpers =====
fail(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || fail "rode com sudo/root"; }
have(){ command -v "$1" >/dev/null 2>&1; }

need_root

# ===== coleta da key (único prompt) =====
KEY="${MEZMO_KEY:-}"
if [ -z "${KEY}" ]; then
  read -rsp "Mezmo ingestion key: " KEY; echo
fi
[ -n "${KEY}" ] || fail "ingestion key vazia"

# ===== instala agente se não existir =====
if [ ! -x "${BIN}" ]; then
  echo "Agente não encontrado, tentando instalar..."
  if have apt-get; then
    apt-get update -y
    apt-get install -y logdna-agent || fail "instalação via apt falhou"
  elif have dnf; then
    dnf install -y logdna-agent || fail "instalação via dnf falhou"
  elif have yum; then
    yum install -y logdna-agent || fail "instalação via yum falhou"
  else
    fail "não sei instalar automaticamente neste sistema — instale o pacote 'logdna-agent' e rode de novo"
  fi
fi

# ===== prepara diretórios =====
install -d -m 755 "${CONFIG_DIR}"
install -d -m 755 /var/log/rclone

# Permite customizar tags sem novo prompt (opcional)
HOSTNAME_VAL="$(hostname -s 2>/dev/null || hostname)"
TAGS_VAL="${MEZMO_TAGS:-rclone,bisync}"

# ===== escreve config.yaml (idempotente) =====
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
echo "config escrito em ${CONFIG_FILE}"

# ===== drop-in do systemd =====
install -d -m 755 "${OVRD_DIR}"
cat >"${OVRD_FILE}" <<EOF
[Service]
# aponta explicitamente para o YAML que criamos
Environment="MZ_CONFIG_FILE=${CONFIG_FILE}"
Environment="LOGDNA_CONFIG_FILE=${CONFIG_FILE}"
# desliga tailer do journal também por env (além do YAML)
Environment="MZ_SYSTEMD_JOURNAL_TAILER=false"
# evita conflitos caso /etc/logdna.env defina diretórios/padrões
UnsetEnvironment=LOGDNA_LOG_DIRS LOGDNA_INCLUSION_RULES MZ_LOG_DIRS MZ_INCLUSION_RULES
EOF

# ===== aplica e sobe =====
systemctl daemon-reload
# limpa falhas antigas (se houver)
systemctl reset-failed "${SERVICE}" 2>/dev/null || true
systemctl enable --now "${SERVICE}"

# ===== verificação rápida =====
sleep 1
if systemctl is-active --quiet "${SERVICE}"; then
  echo "✅ ${SERVICE} ativo e habilitado no boot."
else
  echo "⚠️ ${SERVICE} não ficou ativo; últimos logs:"
  journalctl -u "${SERVICE}" -n 50 --no-pager || true
  exit 1
fi

echo
echo "Pronto! Logs de /var/log/rclone/*.log serão enviados."
echo "Comandos úteis:"
echo "  journalctl -u ${SERVICE} -n 200 --no-pager"
echo "  systemctl status ${SERVICE}"
