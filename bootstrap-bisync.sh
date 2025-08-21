#!/usr/bin/env bash
set -euo pipefail

# ========= settings =========
UNIT_BASENAME="rclone-bisync"               # gera rclone-bisync@.service /.timer
ENV_DIR="/etc/rclone/bisync"
WORKDIR_BASE="/var/lib/rclone/bisync"
LOGDIR_BASE="/var/log/rclone"
RCLONE_BIN="$(command -v rclone || true)"
RCLONE_MIN="1.68.0"

# usuário padrão: se rodar com sudo usa o dono, senão logname/id -un
SYSTEM_USER_DEFAULT="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"

# ========= helpers =========
fail(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || fail "rode com sudo/root"; }
ver_ge(){ [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
sanitize_id(){ echo "$1" | tr ' /:@' '____' | sed -E 's/[^A-Za-z0-9_.+-]+/_/g'; }
ensure_base_dirs(){ mkdir -p "$ENV_DIR" "$WORKDIR_BASE" "$LOGDIR_BASE"; }

remote_type(){
  local remote="$1" user="$2"
  local cfg="/home/${user}/.config/rclone/rclone.conf"
  [ "$user" = "root" ] && cfg="/root/.config/rclone/rclone.conf"
  sudo -u "$user" env RCLONE_CONFIG="$cfg" "$RCLONE_BIN" config show "$remote" 2>/dev/null \
    | awk -F'=' '/^[[:space:]]*type[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2; exit}' || true
}

derive_s3_backup(){
  # De "remote:bucket/prefix..." -> "remote:bucket/_bisync_backups/<client>"
  local path="$1" client_id="$2"
  local remote="${path%%:*}"
  local after="${path#*:}"
  local bucket="${after%%/*}"
  echo "${remote}:${bucket}/_bisync_backups/${client_id}"
}

yn(){
  local prompt="$1" ans
  read -rp "$prompt [Y/n]: " ans || true
  ans="${ans:-Y}"; [[ "$ans" =~ ^[Yy]$ ]]
}

usage(){
cat <<'EOF'
Uso:
  sudo ./bootstrap-bisync.sh [--non-interactive]
      --path1 <remote1:path> \
      --path2 <remote2:path> \
      [--client <nome>] \
      [--bkp1 <remote1:_bisync_backups/<client>>] \
      [--bkp2 <remote2:_bisync_backups/<client>>] \
      [--user <usuario-systemd>] \
      [--interval 5min] \
      [--recreate] \
      [--purge-logs]

Padrões:
- client: último segmento de path1
- bkp1:  <remote1>:/_bisync_backups/<client>
- bkp2:  S3 -> <remote2>:<bucket>/_bisync_backups/<client>
          outros -> <remote2>:/_bisync_backups/<client>
EOF
}

# ========= parse args =========
CLIENT=""; PATH1=""; PATH2=""
BKP1=""; BKP2=""
SYSTEM_USER="$SYSTEM_USER_DEFAULT"
INTERVAL="5min"
NON_INTERACTIVE="0"
FORCE_RECREATE="0"
PURGE_LOGS="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --client)    CLIENT="$2"; shift 2;;
    --path1)     PATH1="$2"; shift 2;;
    --path2)     PATH2="$2"; shift 2;;
    --bkp1)      BKP1="$2"; shift 2;;
    --bkp2)      BKP2="$2"; shift 2;;
    --user)      SYSTEM_USER="$2"; shift 2;;
    --interval)  INTERVAL="$2"; shift 2;;
    --recreate)  FORCE_RECREATE="1"; shift;;
    --purge-logs) PURGE_LOGS="1"; shift;;
    --non-interactive) NON_INTERACTIVE="1"; shift;;
    -h|--help) usage; exit 0;;
    *) fail "flag desconhecida: $1";;
  esac
done

need_root
[ -n "$RCLONE_BIN" ] || fail "rclone não encontrado no PATH"
RCLONE_VER="$($RCLONE_BIN version | awk 'NR==1{print $2; exit}' | sed 's/^v//')"
ver_ge "$RCLONE_VER" "$RCLONE_MIN" || fail "rclone >= $RCLONE_MIN é necessário (encontrado v$RCLONE_VER)"
ensure_base_dirs

# ===== entrada interativa mínima =====
if [ "$NON_INTERACTIVE" = "0" ]; then
  echo "== Configuração interativa =="
  [ -n "$PATH1" ] || read -rp "Path1 (ex.: onedrive@geoia:/ClienteX): " PATH1
  [ -n "$PATH2" ] || read -rp "Path2 (ex.: s3@geoia-clients:bucket/ClienteX): " PATH2
fi
[ -n "$PATH1" ] || fail "--path1 obrigatório"
[ -n "$PATH2" ] || fail "--path2 obrigatório"

[ -n "$CLIENT" ] || CLIENT="$(basename "${PATH1#*:}")"
CLIENT_ID="$(sanitize_id "$CLIENT")"

REMOTE1="${PATH1%%:*}"
REMOTE2="${PATH2%%:*}"

# ===== user + intervalo (interativo) =====
if [ "$NON_INTERACTIVE" = "0" ]; then
  read -rp "Usuário systemd? [${SYSTEM_USER_DEFAULT}]: " _u || true
  SYSTEM_USER="${_u:-$SYSTEM_USER_DEFAULT}"
  read -rp "Intervalo entre execuções? [${INTERVAL}]: " _iv || true
  INTERVAL="${_iv:-$INTERVAL}"
fi

# ===== rclone.conf do usuário =====
RCLONE_CONFIG_PATH="/home/${SYSTEM_USER}/.config/rclone/rclone.conf"
[ "$SYSTEM_USER" = "root" ] && RCLONE_CONFIG_PATH="/root/.config/rclone/rclone.conf"
[ -f "$RCLONE_CONFIG_PATH" ] || fail "rclone.conf não encontrado: ${RCLONE_CONFIG_PATH} (rode 'rclone config' como ${SYSTEM_USER})"

TYPE1="$(remote_type "$REMOTE1" "$SYSTEM_USER")"
TYPE2="$(remote_type "$REMOTE2" "$SYSTEM_USER")"
[ -n "$TYPE1" ] || echo "Aviso: não consegui detectar type do remote '$REMOTE1' (seguindo)"
[ -n "$TYPE2" ] || echo "Aviso: não consegui detectar type do remote '$REMOTE2' (seguindo)"

# ===== backups padrão =====
[ -n "$BKP1" ] || BKP1="${REMOTE1}:/_bisync_backups/${CLIENT_ID}"
if [ -z "$BKP2" ]; then
  if [ "$TYPE2" = "s3" ]; then
    BKP2="$(derive_s3_backup "$PATH2" "$CLIENT_ID")"
  else
    BKP2="${REMOTE2}:/_bisync_backups/${CLIENT_ID}"
  fi
fi

# ===== resumo editável =====
if [ "$NON_INTERACTIVE" = "0" ]; then
  while true; do
    echo
    echo "===== Resumo (edite se quiser) ====="
    printf " Client:     %s\n" "$CLIENT"
    printf " InstanceID: %s\n" "$CLIENT_ID"
    printf " Path1:      %s   (type: %s)\n" "$PATH1" "${TYPE1:-?}"
    printf " Path2:      %s   (type: %s)\n" "$PATH2" "${TYPE2:-?}"
    printf " Backup1:    %s\n" "$BKP1"
    printf " Backup2:    %s\n" "$BKP2"
    printf " User:       %s\n" "$SYSTEM_USER"
    printf " Interval:   %s\n" "$INTERVAL"
    echo "===================================="
    read -rp "Confirmar? [Y]es / [E]dit / [A]bort: " ans || true
    ans="${ans:-Y}"
    case "$ans" in
      [Yy]) break;;
      [Aa]) echo "Abortado."; exit 1;;
      [Ee])
        read -rp "Client [${CLIENT}]: " x || true; CLIENT="${x:-$CLIENT}"
        CLIENT_ID="$(sanitize_id "$CLIENT")"
        read -rp "Path1  [${PATH1}]: " x || true; PATH1="${x:-$PATH1}"
        read -rp "Path2  [${PATH2}]: " x || true; PATH2="${x:-$PATH2}"
        read -rp "Bkp1   [${BKP1}]: " x || true; BKP1="${x:-$BKP1}"
        read -rp "Bkp2   [${BKP2}]: " x || true; BKP2="${x:-$BKP2}"
        read -rp "User   [${SYSTEM_USER}]: " x || true; SYSTEM_USER="${x:-$SYSTEM_USER}"
        read -rp "Intvl  [${INTERVAL}]: " x || true; INTERVAL="${x:-$INTERVAL}"
        ;;
      *) echo "Opção inválida."; continue;;
    esac
  done
fi

# ===== proteção: backups fora da raiz =====
case "$BKP1" in
  "$PATH1"/*|"$PATH1") fail "Backup1 ($BKP1) não pode ficar DENTRO de Path1 ($PATH1)";;
esac
case "$BKP2" in
  "$PATH2"/*|"$PATH2") fail "Backup2 ($BKP2) não pode ficar DENTRO de Path2 ($PATH2)";;
esac

# ===== paths por instância =====
ENV_FILE="$ENV_DIR/${CLIENT_ID}.env"
WORKDIR="$WORKDIR_BASE/$CLIENT_ID"
LOGDIR="$LOGDIR_BASE/$CLIENT_ID"
INIT_MARK="$WORKDIR/.initialized"
LOG_INIT="$LOGDIR/bisync-init.log"
LOG_RUN="$LOGDIR/bisync.log"
SENTINEL=".healthcheck-${CLIENT_ID}"

# ===== flags extras por provider (usadas só no bisync!) =====
EXTRA_FLAGS=""
case "$TYPE1" in
  onedrive) EXTRA_FLAGS+=" --onedrive-delta";;
  s3)       EXTRA_FLAGS+=" --s3-no-check-bucket";;
esac
case "$TYPE2" in
  onedrive) EXTRA_FLAGS+=" --onedrive-delta";;
  s3)       EXTRA_FLAGS+=" --s3-no-check-bucket";;
esac
EXTRA_FLAGS="$(echo "$EXTRA_FLAGS" | xargs || true)"

# ===== recriação segura =====
INSTANCE="${UNIT_BASENAME}@${CLIENT_ID}"
if systemctl list-timers --all 2>/dev/null | grep -q "${INSTANCE}.timer" || [ -f "$ENV_FILE" ]; then
  if [ "$FORCE_RECREATE" = "1" ] || yn "Instância '${CLIENT_ID}' já existe. Recriar do zero?"; then
    systemctl stop "${INSTANCE}.timer"    2>/dev/null || true
    systemctl stop "${INSTANCE}.service"  2>/dev/null || true
    systemctl disable "${INSTANCE}.timer" 2>/dev/null || true
    systemctl reset-failed "${INSTANCE}.service" 2>/dev/null || true
    systemctl reset-failed "${INSTANCE}.timer"   2>/dev/null || true
    rm -f "$ENV_FILE"
    rm -rf "/etc/systemd/system/${UNIT_BASENAME}@${CLIENT_ID}.service.d"
    rm -rf "$WORKDIR"
    [ "$PURGE_LOGS" = "1" ] && rm -rf "$LOGDIR"
    systemctl daemon-reload
    echo "Instância '${CLIENT_ID}' removida."
  else
    echo "Mantendo instância existente. Nada a fazer."; exit 0
  fi
fi

# >>> cria diretórios locais AGORA (após limpeza) <<<
install -d -m 775 -o "$SYSTEM_USER" -g "$SYSTEM_USER" "$WORKDIR" "$LOGDIR"

# ===== ENV do cliente =====
cat >"$ENV_FILE"<<EOF
# Gerado por $0 em $(date -Is)
OD="$PATH1"
S3="$PATH2"
BOD="$BKP1"
BS3="$BKP2"

COMPARE_FLAGS="--compare size,modtime"
CONFLICT_FLAGS="--conflict-resolve newer --track-renames"
EXTRA_FLAGS="$EXTRA_FLAGS"
TRANS_FLAGS="--transfers 8 --checkers 32"
TIME_FLAGS="--timeout 10m --contimeout 15s"
LOG_FLAGS="--use-json-log --stats 30s --stats-log-level NOTICE --log-level INFO"

WORKDIR="$WORKDIR"
LOGDIR="$LOGDIR"
INIT_MARK="$INIT_MARK"
LOG_INIT="$LOG_INIT"
LOG_RUN="$LOG_RUN"
SENTINEL="$SENTINEL"
MAX_DELETE="10000"
EOF
echo "ENV criado: $ENV_FILE"

# ===== templates =====
SERVICE="/etc/systemd/system/${UNIT_BASENAME}@.service"
TIMER="/etc/systemd/system/${UNIT_BASENAME}@.timer"

cat >"$SERVICE"<<'EOF'
[Unit]
Description=Rclone bisync (%i) - generic providers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/rclone/bisync/%i.env

# Segurança: garante diretórios locais existentes (pode já existir, ok)
ExecStartPre=/bin/mkdir -p "${WORKDIR}" "${LOGDIR}"

# IMPORTANTE: usar /bin/bash -lc para que ${EXTRA_FLAGS} seja splitado corretamente.
# (systemd não faz word-splitting de variáveis em ExecStart*)

# Materializa sentinela e diretórios de backup (sem flags extras aqui)
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${OD}/${SENTINEL}\" || true"
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${S3}/${SENTINEL}\" || true"
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${BOD}/.keep\" || true"
ExecStartPre=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" touch \"${BS3}/.keep\" || true"

# Resync idempotente (somente se não inicializado)
ExecStartPre=/bin/bash -lc "\
  if [ ! -f \"${INIT_MARK}\" ]; then \
    __RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" bisync \"${OD}\" \"${S3}\" \
      --workdir \"${WORKDIR}\" \
      --check-access --check-filename \"${SENTINEL}\" \
      ${COMPARE_FLAGS} \
      --resync --resync-mode newer \
      ${CONFLICT_FLAGS} \
      --fix-case ${EXTRA_FLAGS} \
      --backup-dir1 \"${BOD}\" --backup-dir2 \"${BS3}\" \
      --max-delete ${MAX_DELETE} \
      --retries 5 --retries-sleep 30s --resilient --recover \
      ${TRANS_FLAGS} ${TIME_FLAGS} \
      ${LOG_FLAGS} \
      --log-file \"${LOG_INIT}\" ; \
    /bin/touch \"${INIT_MARK}\" ; \
  fi"

# Rodada incremental
ExecStart=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" bisync \"${OD}\" \"${S3}\" \
  --workdir \"${WORKDIR}\" \
  --check-access --check-filename \"${SENTINEL}\" \
  ${COMPARE_FLAGS} \
  ${CONFLICT_FLAGS} \
  --fix-case ${EXTRA_FLAGS} \
  --backup-dir1 \"${BOD}\" --backup-dir2 \"${BS3}\" \
  --max-delete ${MAX_DELETE} \
  --retries 5 --retries-sleep 30s --resilient --recover --max-lock 30m \
  ${TRANS_FLAGS} ${TIME_FLAGS} \
  ${LOG_FLAGS} \
  --log-file \"${LOG_RUN}\""

# Limpeza do sentinela
ExecStartPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${OD}/${SENTINEL}\" || true"
ExecStartPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${S3}/${SENTINEL}\" || true"
ExecStopPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${OD}/${SENTINEL}\" || true"
ExecStopPost=/bin/bash -lc "__RCLONE_BIN__ --config \"${RCLONE_CONFIG}\" deletefile \"${S3}/${SENTINEL}\" || true"

# Jobs longos (arquivos grandes)
TimeoutStartSec=0
EOF

cat >"$TIMER"<<'EOF'
[Unit]
Description=Run rclone bisync (%i) periodically

[Timer]
OnBootSec=2min
OnUnitInactiveSec=__INTERVAL__
AccuracySec=30s
RandomizedDelaySec=30s
Persistent=true
Unit=__UNIT__@%i.service

[Install]
WantedBy=timers.target
EOF

sed -i "s#__INTERVAL__#${INTERVAL}#g" "$TIMER"
sed -i "s#__UNIT__#${UNIT_BASENAME}#g" "$TIMER"
sed -i "s#__RCLONE_BIN__#${RCLONE_BIN}#g" "$SERVICE"

# ===== drop-in por instância: define usuário + RCLONE_CONFIG =====
DROPIN_DIR="/etc/systemd/system/${UNIT_BASENAME}@${CLIENT_ID}.service.d"
mkdir -p "$DROPIN_DIR"
HOME_DIR="/home/${SYSTEM_USER}"; [ "$SYSTEM_USER" = "root" ] && HOME_DIR="/root"

cat >"${DROPIN_DIR}/10-user.conf"<<EOF
[Service]
User=${SYSTEM_USER}
Group=${SYSTEM_USER}
Environment="HOME=${HOME_DIR}"
Environment="XDG_CONFIG_HOME=${HOME_DIR}/.config"
Environment="RCLONE_CONFIG=${RCLONE_CONFIG_PATH}"
EOF

# ===== systemd =====
systemctl daemon-reload
systemctl enable --now "${UNIT_BASENAME}@${CLIENT_ID}.timer"
# âncora o timer: dispara 1ª execução agora
systemctl start "${UNIT_BASENAME}@${CLIENT_ID}.service" || true

echo
echo "Pronto! Timer ligado para '${CLIENT_ID}'. Comandos úteis:"
echo "  systemctl status ${UNIT_BASENAME}@${CLIENT_ID}.timer"
echo "  systemctl status ${UNIT_BASENAME}@${CLIENT_ID}.service"
echo "  journalctl -u ${UNIT_BASENAME}@${CLIENT_ID}.service -n 200 --no-pager"
echo "  tail -f ${LOG_RUN}"
