#!/usr/bin/env bash
# ============================================================================
# KIOSK DEPLOY - Revert Linux
# ============================================================================
# Desfaz o que o deploy-kiosk-linux.sh fez:
#   - remove o autostart do navegador kiosk;
#   - remove o launcher;
#   - restaura a rede DHCP/DNS quando existe backup;
#   - remove o servico de rede fallback quando usado.
#
# Uso:
#   sudo bash revert-kiosk-linux.sh
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

STATE_DIR="/var/lib/kiosk-deploy"
NETWORK_BACKUP="$STATE_DIR/network-backup.env"
STATE_FILE="$STATE_DIR/state.env"
FALLBACK_SERVICE="/etc/systemd/system/kiosk-network.service"
FALLBACK_SCRIPT="/usr/local/sbin/kiosk-network.sh"

die() {
    echo "[ERRO] $*" >&2
    exit 1
}
ok() { echo "   [OK] $*"; }

[[ "${EUID}" -eq 0 ]] || die "Execute como root: sudo bash revert-kiosk-linux.sh"
[[ -f "$STATE_FILE" ]] || die "Estado do deploy nao encontrado em $STATE_FILE."

# shellcheck disable=SC1090
source "$STATE_FILE"

USER_NAME="${USER_NAME:-}"
USER_HOME="${USER_HOME:-}"
INTERFACE="${INTERFACE:-}"

if [[ -z "$USER_NAME" || -z "$INTERFACE" ]]; then
    die "Arquivo de estado incompleto."
fi

USER_GROUP="$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")"
XDG_CONFIG="${USER_HOME}/.config"
AUTOSTART_FILE="${XDG_CONFIG}/autostart/kiosk-browser.desktop"
LAUNCHER="${XDG_CONFIG}/kiosk-deploy/kiosk-browser.sh"

echo "============================================================"
echo "   KIOSK DEPLOY - Revert Linux"
echo "============================================================"
echo
echo "Usuario:   $USER_NAME"
echo "Interface: $INTERFACE"
echo

rm -f "$AUTOSTART_FILE" "$LAUNCHER"
ok "Autostart e launcher removidos."

# Remove unidade systemd user, caso uma versão futura a utilize.
if command -v systemctl >/dev/null 2>&1; then
    if [[ -n "${USER_NAME}" ]]; then
        systemctl stop "kiosk-browser.service" 2>/dev/null || true
        systemctl disable "kiosk-browser.service" 2>/dev/null || true
    fi
fi

restore_networkmanager() {
    [[ -f "$NETWORK_BACKUP" ]] || return 1
    # shellcheck disable=SC1090
    source "$NETWORK_BACKUP"
    [[ "${BACKEND:-}" == "networkmanager" ]] || return 1
    command -v nmcli >/dev/null 2>&1 || die "nmcli nao encontrado para restaurar a rede."

    local cid="${CONNECTION_ID:-}"
    [[ -n "$cid" ]] || die "Conexao NetworkManager original nao registrada."

    echo "Restaurando DHCP/DNS automatico no NetworkManager..."
    nmcli con mod "$cid" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns "" ipv4.never-default no
    nmcli con up "$cid" >/dev/null || true
    ok "DHCP e DNS automatico restaurados."
    return 0
}

restore_networkd() {
    [[ -f "$NETWORK_BACKUP" ]] || return 1
    # shellcheck disable=SC1090
    source "$NETWORK_BACKUP"
    [[ "${BACKEND:-}" == "systemd-networkd" ]] || return 1

    local netfile="/etc/systemd/network/10-kiosk-${INTERFACE}.network"
    rm -f "$netfile"
    systemctl restart systemd-networkd
    ok "Configuracao temporaria do systemd-networkd removida."
    return 0
}

restore_fallback() {
    [[ -f "$NETWORK_BACKUP" ]] || return 1
    # shellcheck disable=SC1090
    source "$NETWORK_BACKUP"
    [[ "${BACKEND:-}" == "ip-fallback" ]] || return 1

    systemctl disable --now kiosk-network.service 2>/dev/null || true
    rm -f "$FALLBACK_SERVICE" "$FALLBACK_SCRIPT"
    systemctl daemon-reload
    ok "Servico fallback removido."
    echo "   A interface voltara a ser gerenciada pelo gerenciador de rede da distro."
    return 0
}

if [[ -f "$NETWORK_BACKUP" ]]; then
    restored=0
    restore_networkmanager && restored=1 || true
    if [[ "$restored" -eq 0 ]]; then restore_networkd && restored=1 || true; fi
    if [[ "$restored" -eq 0 ]]; then restore_fallback && restored=1 || true; fi

    if [[ "$restored" -eq 0 ]]; then
        echo "   [AVISO] Nao foi possivel identificar o backend de rede do backup."
    fi
else
    echo "   [AVISO] Nenhum backup de rede encontrado; a rede nao foi alterada."
fi

echo
echo "Aguardando a rede..."
for _ in {1..30}; do
    ip_now="$(ip -4 -o addr show dev "$INTERFACE" scope global 2>/dev/null | awk 'NR==1{print $4;exit}' || true)"
    if [[ -n "$ip_now" ]]; then
        break
    fi
    sleep 2
done

echo
echo "============================================================"
echo "   Reversao concluida"
echo "============================================================"
echo "   Interface: $INTERFACE"
echo "   IP atual:  ${ip_now:-nao obtido}"
echo "   DHCP:      restaurado (quando o backend foi identificado)"
echo "============================================================"
echo

read -r -p "Deseja reiniciar o computador agora? (S/N) [N]: " reboot_choice
if [[ "$reboot_choice" =~ ^[Ss]$ ]]; then
    echo "Reiniciando em 5 segundos..."
    sleep 5
    systemctl reboot
fi
