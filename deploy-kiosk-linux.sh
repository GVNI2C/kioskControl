#!/usr/bin/env bash
# ============================================================================
# KIOSK DEPLOY - Linux (Debian/Ubuntu/Pop!_OS/Fedora/RHEL/Arch/openSUSE/Alpine)
# ============================================================================
# O que faz:
#   - Detecta a interface IPv4 ativa e o IP atual.
#   - Opcionalmente converte o IP atual DHCP -> FIXO.
#   - Define DNS 8.8.8.8 e 1.1.1.1 quando o modo fixo é escolhido.
#   - Detecta/instala Chrome, Chromium ou Firefox.
#   - Configura navegador em modo kiosk.
#   - Cria autostart para iniciar o kiosk após o login gráfico.
#   - Desativa recursos comuns de economia de energia na sessão gráfica.
#   - Salva backup da rede em /var/lib/kiosk-deploy/network-backup.env.
#
# Uso remoto:
#   curl -fsSL https://SEU_LINK/deploy-kiosk-linux.sh | sudo bash
#
# Uso local:
#   sudo bash deploy-kiosk-linux.sh
#
# Observacao: para uma configuracao de rede persistente, o script usa
# NetworkManager quando disponivel, depois systemd-networkd e, por ultimo,
# um fallback ip+systemd. A maioria das distribuicoes desktop modernas usa
# um desses mecanismos.
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="KioskDeploy"
STATE_DIR="/var/lib/kiosk-deploy"
STATE_FILE="$STATE_DIR/state.env"
NETWORK_BACKUP="$STATE_DIR/network-backup.env"
USER_SCRIPT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kiosk-deploy"
LAUNCHER="$USER_SCRIPT_DIR/kiosk-browser.sh"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/kiosk-browser.desktop"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SYSTEMD_USER_FILE="$SYSTEMD_USER_DIR/kiosk-browser.service"

DNS1="8.8.8.8"
DNS2="1.1.1.1"

TMP_REEXEC=""

cleanup() {
    if [[ -n "${TMP_REEXEC:-}" && -f "$TMP_REEXEC" ]]; then
        rm -f "$TMP_REEXEC" || true
    fi
}
trap cleanup EXIT

die() {
    echo
    echo "[ERRO] $*" >&2
    exit 1
}

ok() {
    echo "   [OK] $*"
}

step() {
    echo
    echo ">> $*"
}

pause_exit() {
    local code="${1:-1}"
    echo
    if [[ -t 0 ]]; then
        read -r -p "Pressione ENTER para fechar..." || true
    fi
    exit "$code"
}

banner() {
    clear 2>/dev/null || true
    echo "============================================================"
    echo "   KIOSK DEPLOY - Configurador automatico de TV (Linux)"
    echo "============================================================"
    echo
}

# ---------------------------------------------------------------------------
# Elevação: funciona tanto com arquivo local quanto com curl | bash.
# ---------------------------------------------------------------------------
ensure_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Execute como root. Exemplo: curl -fsSL https://SEU_LINK/deploy-kiosk-linux.sh | sudo bash"
    fi
}

# ---------------------------------------------------------------------------
# Ferramentas básicas
# ---------------------------------------------------------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Comando obrigatorio nao encontrado: $1"
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper"
    elif command -v apk >/dev/null 2>&1; then echo "apk"
    else echo "none"
    fi
}

install_packages() {
    local packages=("$@")
    local pm
    pm="$(detect_package_manager)"

    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y "${packages[@]}"
            ;;
        dnf) dnf install -y "${packages[@]}" ;;
        yum) yum install -y "${packages[@]}" ;;
        pacman) pacman -Sy --noconfirm "${packages[@]}" ;;
        zypper) zypper --non-interactive install "${packages[@]}" ;;
        apk) apk add --no-cache "${packages[@]}" ;;
        none) die "Nenhum gerenciador de pacotes suportado foi encontrado." ;;
    esac
}

# ---------------------------------------------------------------------------
# Sistema / sessão gráfica
# ---------------------------------------------------------------------------
detect_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${PRETTY_NAME:-Linux}"
    else
        echo "Linux"
    fi
}

detect_user() {
    # Quando o script foi elevado via sudo, SUDO_USER identifica o usuário
    # que possui a sessão gráfica.
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "$SUDO_USER"
    elif [[ -n "${PKEXEC_UID:-}" ]]; then
        getent passwd "$PKEXEC_UID" | cut -d: -f1
    else
        echo "${USER:-root}"
    fi
}

USER_NAME="$(detect_user)"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 || true)"
[[ -n "$USER_HOME" ]] || USER_HOME="${HOME:-/root}"

run_as_user() {
    if [[ "$USER_NAME" == "root" ]]; then
        "$@"
    else
        sudo -u "$USER_NAME" -H env \
            HOME="$USER_HOME" \
            USER="$USER_NAME" \
            LOGNAME="$USER_NAME" \
            XDG_CONFIG_HOME="${USER_HOME}/.config" \
            "$@"
    fi
}

write_user_file() {
    local file="$1"
    local content="$2"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$content" > "$file"
    chown "$USER_NAME":"$(id -gn "$USER_NAME")" "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Rede
# ---------------------------------------------------------------------------
get_default_iface() {
    ip -4 route show default 2>/dev/null |
        awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_ipv4_info() {
    local iface="$1"
    ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
        awk 'NR==1 {print $4; exit}'
}

get_gateway() {
    local iface="$1"
    ip -4 route show default dev "$iface" 2>/dev/null |
        awk 'NR==1 {print $3; exit}'
}

get_dns() {
    local iface="$1"
    local dns=""

    if command -v resolvectl >/dev/null 2>&1; then
        dns="$(resolvectl dns "$iface" 2>/dev/null |
            sed -n 's/.*: //p' |
            tr ' ' '\n' |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            head -n 5 |
            paste -sd, - || true)"
    fi

    if [[ -z "$dns" && -r /etc/resolv.conf ]]; then
        dns="$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' /etc/resolv.conf |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
            head -n 5 |
            paste -sd, - || true)"
    fi

    echo "$dns"
}

has_networkmanager() {
    command -v nmcli >/dev/null 2>&1 &&
        systemctl is-active --quiet NetworkManager 2>/dev/null
}

save_network_backup() {
    local iface="$1" cid="$2" ip_cidr="$3" gateway="$4" dns="$5" backend="$6"

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    cat > "$NETWORK_BACKUP" <<EOF
BACKEND=$(printf '%q' "$backend")
INTERFACE=$(printf '%q' "$iface")
CONNECTION_ID=$(printf '%q' "$cid")
IP_CIDR=$(printf '%q' "$ip_cidr")
GATEWAY=$(printf '%q' "$gateway")
DNS=$(printf '%q' "$dns")
EOF
    chmod 600 "$NETWORK_BACKUP"
}

set_network_static() {
    local iface="$1" ip_cidr="$2" gateway="$3"

    step "Configurando IP fixo e DNS..."
    mkdir -p "$STATE_DIR"

    if has_networkmanager; then
        local cid
        cid="$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null | head -n1 || true)"
        [[ -n "$cid" && "$cid" != "--" ]] || die "A interface '$iface' nao possui uma conexao do NetworkManager."

        save_network_backup "$iface" "$cid" "$ip_cidr" "$gateway" "$(get_dns "$iface")" "networkmanager"

        local args=(con mod "$cid"
            ipv4.method manual
            ipv4.addresses "$ip_cidr"
            ipv4.dns "$DNS1,$DNS2"
            ipv4.never-default no)

        if [[ -n "$gateway" ]]; then
            args+=(ipv4.gateway "$gateway")
        else
            args+=(ipv4.gateway "")
        fi

        nmcli "${args[@]}"
        nmcli con up "$cid" >/dev/null || true

        # NetworkManager pode levar alguns segundos para reaplicar a conexao.
        for _ in {1..30}; do
            if ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
                awk '{print $4}' | grep -Fxq "$ip_cidr"; then
                ok "IP fixo aplicado: $ip_cidr"
                break
            fi
            sleep 2
        done
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        # systemd-networkd: cria uma unidade .network especifica para a
        # interface. O arquivo e persistente e pode ser removido no revert.
        local netfile="/etc/systemd/network/10-kiosk-${iface}.network"
        save_network_backup "$iface" "" "$ip_cidr" "$gateway" "$(get_dns "$iface")" "systemd-networkd"

        mkdir -p /etc/systemd/network
        {
            echo "[Match]"
            echo "Name=$iface"
            echo
            echo "[Network]"
            echo "DHCP=no"
            echo "Address=$ip_cidr"
            [[ -n "$gateway" ]] && echo "Gateway=$gateway"
            echo "DNS=$DNS1"
            echo "DNS=$DNS2"
        } > "$netfile"
        chmod 600 "$netfile"
        systemctl restart systemd-networkd
        sleep 3
        ok "IP fixo aplicado via systemd-networkd: $ip_cidr"
    else
        # Fallback universal de runtime. Para persistencia, grava um servico
        # systemd que reaplica a configuracao no boot.
        save_network_backup "$iface" "" "$ip_cidr" "$gateway" "$(get_dns "$iface")" "ip-fallback"

        cat > /usr/local/sbin/kiosk-network.sh <<EOF
#!/usr/bin/env bash
set -e
ip link set dev "$iface" up
ip -4 addr flush dev "$iface" scope global
ip -4 addr add "$ip_cidr" dev "$iface"
ip -4 route replace default via "$gateway" dev "$iface"
if command -v resolvectl >/dev/null 2>&1; then
  resolvectl dns "$iface" "$DNS1" "$DNS2" || true
  resolvectl domain "$iface" "~." || true
fi
EOF
        chmod 700 /usr/local/sbin/kiosk-network.sh

        cat > /etc/systemd/system/kiosk-network.service <<'EOF'
[Unit]
Description=KioskDeploy static network
After=network-pre.target
Before=network.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kiosk-network.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now kiosk-network.service
        ok "IP fixo aplicado via fallback ip/systemd: $ip_cidr"
    fi

    # DNS extra: quando resolvectl existe, tenta aplicar imediatamente.
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns "$iface" "$DNS1" "$DNS2" 2>/dev/null || true
        resolvectl domain "$iface" "~." 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Navegador
# ---------------------------------------------------------------------------
browser_path() {
    case "$1" in
        chrome)
            for p in \
                /usr/bin/google-chrome \
                /usr/bin/google-chrome-stable \
                /opt/google/chrome/google-chrome \
                "$USER_HOME/.local/bin/google-chrome"; do
                [[ -x "$p" ]] && { echo "$p"; return 0; }
            done
            ;;
        chromium)
            for p in \
                /usr/bin/chromium \
                /usr/bin/chromium-browser \
                /snap/bin/chromium \
                "$USER_HOME/.local/bin/chromium"; do
                [[ -x "$p" ]] && { echo "$p"; return 0; }
            done
            ;;
        firefox)
            for p in /usr/bin/firefox /usr/bin/firefox-esr "$USER_HOME/.local/bin/firefox"; do
                [[ -x "$p" ]] && { echo "$p"; return 0; }
            done
            ;;
    esac
    return 1
}

install_browser() {
    local browser="$1"
    local pm
    pm="$(detect_package_manager)"

    step "Instalando/verificando o navegador..."

    if browser_path "$browser" >/dev/null 2>&1; then
        ok "Navegador ja instalado: $browser"
        return
    fi

    case "$browser:$pm" in
        chromium:apt) install_packages chromium-browser 2>/dev/null || install_packages chromium ;;
        chromium:dnf|chromium:yum) install_packages chromium ;;
        chromium:pacman) install_packages chromium ;;
        chromium:zypper) install_packages chromium ;;
        chromium:apk) install_packages chromium ;;
        firefox:apt) install_packages firefox ;;
        firefox:dnf|firefox:yum) install_packages firefox ;;
        firefox:pacman) install_packages firefox ;;
        firefox:zypper) install_packages MozillaFirefox ;;
        firefox:apk) install_packages firefox ;;
        chrome:apt)
            # Chrome nao faz parte dos repositorios padrao de todas as distros.
            # Tenta o pacote google-chrome-stable se um repo ja estiver configurado.
            install_packages google-chrome-stable || true
            ;;
        chrome:dnf|chrome:yum) install_packages google-chrome-stable || true ;;
        *) true ;;
    esac

    browser_path "$browser" >/dev/null 2>&1 ||
        die "Nao foi possivel instalar/encontrar '$browser'. Em uma distro sem pacote correspondente, instale o navegador manualmente e rode o deploy novamente."

    ok "Navegador instalado: $browser"
}

select_browser() {
    echo
    echo "Qual navegador usar no kiosk?"
    echo "  [1] Chromium (recomendado para Linux)"
    echo "  [2] Google Chrome"
    echo "  [3] Firefox"
    echo
    local choice
    while true; do
        read -r -p "Digite o numero da opcao [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) echo "chromium"; return ;;
            2) echo "chrome"; return ;;
            3) echo "firefox"; return ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# URL / kiosk launcher
# ---------------------------------------------------------------------------
get_kiosk_url() {
    step "Configuracao da URL"
    echo "   Cole a URL que o kiosk deve abrir."
    echo "   Exemplo: https://servidor.exemplo/kiosk.html?id=kiosk-01"
    local url
    while true; do
        read -r -p "URL: " url
        [[ "$url" =~ ^https?:// ]] && { echo "$url"; return; }
        echo "   URL invalida. Use http:// ou https://."
    done
}

browser_args() {
    local browser="$1" url="$2"
    case "$browser" in
        firefox)
            printf '%s' "--kiosk \"$url\""
            ;;
        *)
            printf '%s' "--kiosk \"$url\" --no-first-run --no-default-browser-check --disable-translate --disable-pinch --overscroll-history-navigation=0 --disable-session-crashed-bubble"
            ;;
    esac
}

configure_power() {
    step "Desativando suspensao/protetor de tela..."
    local user_uid
    user_uid="$(id -u "$USER_NAME")"

    if command -v xset >/dev/null 2>&1; then
        run_as_user env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-$USER_HOME/.Xauthority}" \
            bash -c 'xset s off 2>/dev/null || true; xset -dpms 2>/dev/null || true; xset s noblank 2>/dev/null || true' || true
    fi

    # GNOME/MATE/Cinnamon e derivados
    if command -v gsettings >/dev/null 2>&1; then
        run_as_user gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
        run_as_user gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
        run_as_user gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
    fi

    # KDE
    if command -v qdbus >/dev/null 2>&1; then
        run_as_user qdbus org.freedesktop.ScreenSaver /ScreenSaver SetActive false 2>/dev/null || true
    fi

    ok "Politicas de economia de energia ajustadas para a sessao grafica."
}

configure_kiosk_startup() {
    local browser="$1" url="$2" path="$3"
    local args
    args="$(browser_args "$browser" "$url")"

    step "Configurando inicializacao automatica do kiosk..."

    run_as_user mkdir -p "$USER_SCRIPT_DIR" "$AUTOSTART_DIR"

    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -u
BROWSER="$path"
URL="$url"

# Aguarda a sessao grafica estar pronta.
sleep 3

# Tenta evitar tela em branco por economia de energia.
command -v xset >/dev/null 2>&1 && {
  xset s off 2>/dev/null || true
  xset -dpms 2>/dev/null || true
  xset s noblank 2>/dev/null || true
}

while true; do
  "\$BROWSER" $args
  sleep 2
done
EOF
    chmod 755 "$LAUNCHER"
    chown "$USER_NAME":"$(id -gn "$USER_NAME")" "$LAUNCHER" 2>/dev/null || true

    cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Kiosk Browser
Comment=KioskDeploy
Exec=$LAUNCHER
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF
    chmod 644 "$AUTOSTART_FILE"
    chown "$USER_NAME":"$(id -gn "$USER_NAME")" "$AUTOSTART_FILE" 2>/dev/null || true

    ok "Autostart criado para o usuario '$USER_NAME'."
    ok "O navegador sera reaberto automaticamente se for encerrado."
}

save_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
USER_NAME=$(printf '%q' "$USER_NAME")
USER_HOME=$(printf '%q' "$USER_HOME")
INTERFACE=$(printf '%q' "$1")
IP_CIDR=$(printf '%q' "$2")
GATEWAY=$(printf '%q' "$3")
BROWSER=$(printf '%q' "$4")
BROWSER_PATH=$(printf '%q' "$5")
KIOSK_URL=$(printf '%q' "$6")
EOF
    chmod 600 "$STATE_FILE"
}

final_summary() {
    local iface="$1" ip_cidr="$2" gateway="$3" browser="$4" url="$5"
    echo
    echo "============================================================"
    echo "   Configuracao concluida com sucesso!"
    echo "============================================================"
    echo "   Sistema:       $(detect_distro)"
    echo "   Usuario kiosk: $USER_NAME"
    echo "   Navegador:     $browser"
    echo "   URL:           $url"
    echo
    echo "   ========================================================"
    echo "   INTERFACE:     $iface"
    echo "   IP DEFINIDO:   $ip_cidr"
    echo "   GATEWAY:       ${gateway:-nao definido}"
    echo "   DNS:           $DNS1, $DNS2"
    echo "   ========================================================"
    echo
    echo "   Backup da rede: $NETWORK_BACKUP"
    echo "   Autostart:      $AUTOSTART_FILE"
    echo
    echo "   Para desfazer: execute revert-kiosk-linux.sh"
    echo
}

main() {
    ensure_root "$@"
    banner

    need_cmd ip
    need_cmd awk
    need_cmd sed

    echo "Sistema detectado: $(detect_distro)"
    echo "Usuario da sessao grafica: $USER_NAME"
    echo

    local iface ip_cidr ip_address prefix gateway
    iface="$(get_default_iface)"
    [[ -n "$iface" ]] || die "Nao foi encontrada uma interface com rota padrao IPv4."

    ip_cidr="$(get_ipv4_info "$iface")"
    [[ -n "$ip_cidr" ]] || die "Nao foi encontrado um IPv4 valido na interface '$iface'."

    ip_address="${ip_cidr%/*}"
    prefix="${ip_cidr#*/}"
    gateway="$(get_gateway "$iface")"

    echo "Interface: $iface"
    echo "IP atual:  $ip_cidr"
    echo "Gateway:   ${gateway:-nao detectado}"
    echo "DNS atual:  $(get_dns "$iface" || true)"
    echo

    echo "Configuracao de rede"
    echo "  [1] Definir o IP atual como fixo"
    echo "  [2] Manter a configuracao atual"
    local net_choice
    while true; do
        read -r -p "Digite o numero da opcao [1]: " net_choice
        net_choice="${net_choice:-1}"
        [[ "$net_choice" == "1" || "$net_choice" == "2" ]] && break
    done

    local browser url browser_path
    browser="$(select_browser)"
    install_browser "$browser"
    browser_path="$(browser_path "$browser")"
    url="$(get_kiosk_url)"

    if [[ "$net_choice" == "1" ]]; then
        [[ -n "$gateway" ]] || die "Nao foi possivel detectar o gateway. Defina a rede manualmente antes de usar o modo IP fixo."
        set_network_static "$iface" "$ip_cidr" "$gateway"
    else
        echo
        ok "Configuracao de rede mantida sem alteracoes."
    fi

    configure_power
    configure_kiosk_startup "$browser" "$url" "$browser_path"
    save_state "$iface" "$ip_cidr" "$gateway" "$browser" "$browser_path" "$url"

    if [[ "$net_choice" == "1" ]]; then
        final_summary "$iface" "$ip_cidr" "$gateway" "$browser" "$url"
    else
        echo
        echo "============================================================"
        echo "   Configuracao concluida com sucesso!"
        echo "============================================================"
        echo "   Rede:          NAO ALTERADA"
        echo "   IP atual:      $(get_ipv4_info "$iface" || true)"
        echo "   Interface:     $iface"
        echo "   Navegador:     $browser"
        echo "   URL:           $url"
        echo "   DNS fixo:      nao aplicado (rede mantida)"
        echo
        echo "   Para desfazer: execute revert-kiosk-linux.sh"
        echo
    fi

    if [[ -t 0 ]]; then
        local reboot
        read -r -p "Deseja reiniciar o computador agora? (S/N) [N]: " reboot
        if [[ "$reboot" =~ ^[Ss]$ ]]; then
            echo "Reiniciando em 5 segundos..."
            sleep 5
            systemctl reboot
        else
            echo "Ok, nao reiniciado agora. O autostart sera usado no proximo login grafico."
        fi
    fi
}

main "$@"
