#!/usr/bin/env bash
# =============================================================================
#  zt_exitnode.sh — превращает Linux-сервер в «модем» ZeroTier:
#    * ставит и настраивает ZeroTier;
#    * (по API-токену) сам создаёт/настраивает сеть, авторизует сервер,
#      включает broadcast для игр по локалке и маршрут 0.0.0.0/0 для VPN;
#    * без токена — даёт пошаговые инструкции и проверяет, что всё сделано;
#    * настраивает NAT/forwarding только для трафика ZeroTier в собственных
#      цепочках (ZTMODEM-*), не трогая Docker/ufw/firewalld и прочие правила;
#    * вешает всё на systemd-сервис zt-modem, который переживает перезагрузку.
#
#  Использование:  sudo ./zt_exitnode.sh [install|status|members|uninstall] [опции]
#  Подробности:    sudo ./zt_exitnode.sh --help
# =============================================================================
set -Eeuo pipefail

readonly VERSION="2.0.0"
readonly REPO_RAW="https://raw.githubusercontent.com/Chistovik92/ip_zerotier/main"
ZT_API="${ZT_API:-https://api.zerotier.com/api/v1}"

readonly CONF_DIR="/etc/zt-modem"
readonly CONF="$CONF_DIR/zt-modem.conf"
readonly TOKEN_FILE="$CONF_DIR/api-token"
readonly INFO="$CONF_DIR/info.txt"
readonly FW="/usr/local/sbin/zt-modem-fw"
readonly SELF="/usr/local/sbin/zt-modem"
readonly UNIT="/etc/systemd/system/zt-modem.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-zt-modem.conf"

# ---------- вывод -------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=; GREEN=; YELLOW=; BLUE=; BOLD=; NC=
fi
STEP=0
step() { STEP=$((STEP + 1)); echo; echo "${GREEN}${BOLD}[$STEP]${NC} ${BOLD}$*${NC}"; }
info() { echo "    $*"; }
ok()   { echo "    ${GREEN}✔${NC} $*"; }
warn() { echo "    ${YELLOW}⚠${NC} $*" >&2; }
die()  { echo; echo "${RED}✘ $*${NC}" >&2; exit 1; }
trap 'echo "${RED}✘ Ошибка в строке $LINENO: $BASH_COMMAND${NC}" >&2' ERR

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
API_BODY="$TMP/body.json"
API_HDR="$TMP/auth.hdr"

# ---------- параметры ---------------------------------------------------------
CMD="install"
TOKEN="${ZT_TOKEN:-}"
NWID="${ZT_NETWORK:-}"
SUBNET=""
NET_NAME="zt-modem"
DEFAULT_ROUTE=1
BLOCK_PRIVATE=1
ASSUME_YES=0
SAVE_TOKEN=""
PURGE=0

usage() {
    cat <<EOF
${BOLD}zt_exitnode.sh v$VERSION${NC} — сервер как «модем» ZeroTier (LAN для игр + VPN)

Команды:
  install      (по умолчанию) установить и настроить всё
  status       показать состояние
  members      показать участников сети и авторизовать новых (нужен API-токен)
  uninstall    убрать правила/сервис (ZeroTier остаётся; --purge удалит и его)

Опции:
  -t, --token TOKEN     API-токен ZeroTier (my.zerotier.com → Account → API Access Tokens).
                        Лучше передавать через переменную: ZT_TOKEN=... sudo -E ./zt_exitnode.sh
  -n, --network ID      ID существующей сети (16 hex-символов). Без него с токеном
                        будет предложено выбрать или создать сеть.
  -s, --subnet CIDR     подсеть для новой сети, например 10.147.20.0/24 (по умолчанию случайная)
      --name NAME       имя новой сети (по умолчанию: $NET_NAME)
      --no-vpn          только локальная сеть для игр, без выхода в интернет через сервер
      --allow-private   разрешить клиентам ходить в приватные сети за сервером (по умолчанию закрыто)
      --save-token      сохранить токен в $TOKEN_FILE (для команды members)
  -y, --yes             не задавать вопросов (для автоматизации)
      --purge           (для uninstall) также выйти из сети и удалить ZeroTier
  -h, --help            эта справка

Примеры:
  sudo ./zt_exitnode.sh                                   # интерактивно
  ZT_TOKEN=xxxx sudo -E ./zt_exitnode.sh -y               # полностью автоматически
  sudo ./zt_exitnode.sh -n 8056c2e21c000001               # без токена, в свою сеть
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            install|status|members|uninstall) CMD="$1" ;;
            -t|--token)      TOKEN="${2:?нужно значение для $1}"; shift ;;
            -n|--network)    NWID="${2:?нужно значение для $1}"; shift ;;
            -s|--subnet)     SUBNET="${2:?нужно значение для $1}"; shift ;;
            --name)          NET_NAME="${2:?нужно значение для $1}"; shift ;;
            --no-vpn)        DEFAULT_ROUTE=0 ;;
            --allow-private) BLOCK_PRIVATE=0 ;;
            --save-token)    SAVE_TOKEN=1 ;;
            -y|--yes)        ASSUME_YES=1 ;;
            --purge)         PURGE=1 ;;
            -h|--help)       usage; exit 0 ;;
            *) die "Неизвестный аргумент: $1 (см. --help)" ;;
        esac
        shift
    done
    NWID="${NWID,,}"
    [[ -z "$NWID" || "$NWID" =~ ^[0-9a-f]{16}$ ]] || die "Неверный Network ID: '$NWID' (нужно 16 hex-символов)"
}

# ---------- ввод (работает и при curl ... | sudo bash) -------------------------
has_tty() { [[ $ASSUME_YES -eq 0 ]] && { : </dev/tty; } 2>/dev/null; }
ask() {  # ask "вопрос" "по умолчанию" -> $REPLY
    local def="${2-}" ans=""
    if has_tty; then read -r -p "    $1" ans </dev/tty || ans=""; fi
    REPLY="${ans:-$def}"
}
ask_secret() {
    local ans=""
    if has_tty; then read -r -s -p "    $1" ans </dev/tty || ans=""; echo; fi
    REPLY="$ans"
}
confirm() {  # confirm "вопрос" [y|n по умолчанию]
    local def="${2:-y}"
    [[ $ASSUME_YES -eq 1 ]] && [[ $def == y ]] && return 0
    [[ $ASSUME_YES -eq 1 ]] && return 1
    ask "$1 [$( [[ $def == y ]] && echo 'Y/n' || echo 'y/N')]: " "$def"
    [[ ${REPLY,,} == y* ]]
}

# ---------- сеть: утилиты ------------------------------------------------------
ip2int() { local IFS=.; local -a o; read -r -a o <<<"$1"; echo $(( (10#${o[0]}<<24) | (10#${o[1]}<<16) | (10#${o[2]}<<8) | 10#${o[3]} )); }
int2ip() { local n=$1; echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"; }
valid_ip() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local i; for i in 1 2 3 4; do (( 10#${BASH_REMATCH[i]} <= 255 )) || return 1; done
}
# cidr_parse 10.1.2.3/24 -> CIDR_NET CIDR_BCAST (int) CIDR_PFX CIDR_STR (нормализованная)
cidr_parse() {
    local ip="${1%/*}" pfx="${1#*/}"
    [[ "$1" == */* ]] && valid_ip "$ip" && [[ $pfx =~ ^[0-9]{1,2}$ ]] && (( 10#$pfx <= 32 )) || return 1
    pfx=$(( 10#$pfx ))
    local mask=$(( (0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF ))
    CIDR_NET=$(( $(ip2int "$ip") & mask ))
    CIDR_BCAST=$(( CIDR_NET | (~mask & 0xFFFFFFFF) ))
    CIDR_PFX=$pfx
    CIDR_STR="$(int2ip "$CIDR_NET")/$pfx"
}
in_cidr() { cidr_parse "$2" || return 1; local n; n=$(ip2int "$1"); (( n >= CIDR_NET && n <= CIDR_BCAST )); }
is_private_cidr() {
    cidr_parse "$1" || return 1
    local n=$CIDR_NET
    (( (n & 0xFF000000) == 0x0A000000 || (n & 0xFFF00000) == 0xAC100000 || (n & 0xFFFF0000) == 0xC0A80000 ))
}
subnet_in_use() {  # пересекается ли подсеть с уже существующими маршрутами/адресами сервера
    local r; cidr_parse "$1" || return 0
    local a=$CIDR_NET b=$CIDR_BCAST
    while read -r r; do
        [[ $r == */* ]] || r="$r/32"
        cidr_parse "$r" 2>/dev/null || continue
        (( CIDR_NET <= b && a <= CIDR_BCAST )) && return 0
    done < <(ip -4 route show table all 2>/dev/null | awk '$1 ~ /^[0-9]/ && $0 !~ / dev zt/ {print $1}'
             ip -4 -o addr 2>/dev/null | awk '$2 !~ /^zt/ {print $4}')
    return 1
}
random_subnet() {
    local i s
    for i in $(seq 1 50); do
        s="10.147.$(( RANDOM % 230 + 20 )).0/24"
        subnet_in_use "$s" || { echo "$s"; return; }
    done
    echo "10.$(( RANDOM % 200 + 30 )).$(( RANDOM % 250 )).0/24"
}
wan_if() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
public_ip() { curl -4 -fsS -m 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS -m 6 https://ifconfig.me 2>/dev/null || echo "?"; }

# ---------- проверки и пакеты -------------------------------------------------
PKG=""
check_system() {
    [[ $EUID -eq 0 ]] || die "Запустите от root: sudo $0 $*"
    [[ "$(uname -s)" == Linux ]] || die "Нужен Linux-сервер."
    [[ -d /run/systemd/system ]] || die "Нужен systemd (обычный VPS на Ubuntu/Debian/CentOS/Alma/Rocky/Fedora)."
    if command -v apt-get >/dev/null; then PKG=apt
    elif command -v dnf >/dev/null; then PKG=dnf
    elif command -v yum >/dev/null; then PKG=yum
    elif command -v pacman >/dev/null; then PKG=pacman
    elif command -v zypper >/dev/null; then PKG=zypper
    fi
}
APT_UPDATED=0
pkg_install() {
    info "Устанавливаю пакеты: $*"
    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            if [[ $APT_UPDATED -eq 0 ]]; then apt-get update -qq >/dev/null || true; APT_UPDATED=1; fi
            apt-get install -y -qq "$@" >/dev/null ;;
        dnf)    dnf install -y -q "$@" >/dev/null ;;
        yum)    yum install -y -q "$@" >/dev/null ;;
        pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
        zypper) zypper -n -q install "$@" >/dev/null ;;
        *) die "Не знаю, как установить $* на этой системе — поставьте вручную и запустите снова." ;;
    esac
}
ensure_deps() {
    local need=()
    command -v curl >/dev/null || need+=(curl)
    command -v jq   >/dev/null || need+=(jq)
    command -v ip   >/dev/null || need+=(iproute2)
    if ! command -v iptables >/dev/null && ! command -v nft >/dev/null; then
        if [[ $PKG == apt ]]; then need+=(iptables); else need+=(nftables); fi
    fi
    if ((${#need[@]})); then
        if [[ $PKG == yum || $PKG == dnf ]] && [[ " ${need[*]} " == *" jq "* ]]; then
            pkg_install epel-release 2>/dev/null || true
        fi
        pkg_install "${need[@]}" || die "Не удалось установить: ${need[*]}"
    fi
    ok "Зависимости на месте (curl, jq, ip, $(command -v iptables >/dev/null && echo iptables || echo nft))"
}
check_tun() {
    if [[ ! -c /dev/net/tun ]]; then
        modprobe tun 2>/dev/null || true
        [[ -c /dev/net/tun ]] || die "Нет /dev/net/tun. На OpenVZ/LXC-VPS включите TUN/TAP в панели хостера и перезапустите скрипт."
    fi
}

# ---------- ZeroTier ----------------------------------------------------------
NODE_ID=""
install_zerotier() {
    if command -v zerotier-cli >/dev/null; then
        ok "ZeroTier уже установлен ($(zerotier-cli -v 2>/dev/null || echo '?'))"
    else
        info "Устанавливаю ZeroTier с официального сайта..."
        curl -fsSL https://install.zerotier.com -o "$TMP/zt-install.sh" \
            || die "Не удалось скачать https://install.zerotier.com (проверьте интернет/DNS на сервере)."
        bash "$TMP/zt-install.sh" >"$TMP/zt-install.log" 2>&1 \
            || { tail -20 "$TMP/zt-install.log" >&2; die "Установщик ZeroTier завершился с ошибкой."; }
        command -v zerotier-cli >/dev/null || die "ZeroTier не установился (см. вывод выше)."
        ok "ZeroTier установлен ($(zerotier-cli -v 2>/dev/null))"
    fi
    systemctl enable --now zerotier-one >/dev/null 2>&1 || systemctl restart zerotier-one
    local i
    for i in $(seq 1 30); do zerotier-cli info >/dev/null 2>&1 && break; sleep 1; done
    NODE_ID="$(zerotier-cli info 2>/dev/null | awk '{print $3}')"
    [[ $NODE_ID =~ ^[0-9a-f]{10}$ ]] || die "Служба zerotier-one не отвечает: systemctl status zerotier-one"
    ok "Node ID сервера: ${BOLD}$NODE_ID${NC}"
}
net_json() { zerotier-cli -j listnetworks 2>/dev/null | jq -c --arg n "$NWID" '.[] | select(.nwid == $n)' 2>/dev/null || true; }

# ---------- API ZeroTier Central ---------------------------------------------
api() {  # api METHOD PATH [JSON] -> печатает HTTP-код, тело в $API_BODY
    local code args=(-sS -m 30 -o "$API_BODY" -w '%{http_code}' -X "$1" -H "@$API_HDR" -H 'Content-Type: application/json')
    [[ -n "${3-}" ]] && args+=(--data "$3")
    : >"$API_BODY"
    code="$(curl "${args[@]}" "$ZT_API$2" 2>/dev/null)" || true
    echo "${code:-000}"
}
is2xx() { [[ $1 == 2* ]]; }
api_err() { jq -r '.message // .error // empty' "$API_BODY" 2>/dev/null | head -c 300; }

setup_token() {
    if [[ -z $TOKEN && -r $TOKEN_FILE ]]; then TOKEN="$(<"$TOKEN_FILE")"; fi
    if [[ -z $TOKEN ]] && has_tty; then
        cat <<EOF
    Для полной автоматической настройки нужен API-токен ZeroTier (бесплатно):
      my.zerotier.com → Account → API Access Tokens → New Token
    (на «новом» Central бесплатного тарифа API нет — тогда просто нажмите Enter,
     скрипт даст пошаговую инструкцию и проверит, что всё сделано верно)
EOF
        ask_secret "API-токен (Enter — без токена): "
        TOKEN="${REPLY//[[:space:]]/}"
    fi
    [[ -n $TOKEN ]] || return 0
    (umask 077; printf 'Authorization: token %s\n' "$TOKEN" >"$API_HDR")
    local code; code="$(api GET /network)"
    if is2xx "$code"; then
        ok "Токен принят (ZeroTier Central API)"
    else
        warn "Токен не подошёл (HTTP $code${code/#000/: нет связи с $ZT_API}). $(api_err)"
        warn "Продолжаю в ручном режиме."
        TOKEN=""
    fi
}

choose_network_api() {
    local code list count i id
    code="$(api GET /network)"; is2xx "$code" || die "Не удалось получить список сетей (HTTP $code). $(api_err)"
    list="$(jq -r '.[] | [.id, (.config.name // "-"), ((.totalMemberCount // 0)|tostring)] | @tsv' "$API_BODY")"
    if [[ -n $NWID ]]; then
        if grep -q "^$NWID" <<<"$list"; then ok "Сеть $NWID найдена в аккаунте"; return; fi
        warn "Сеть $NWID не принадлежит этому аккаунту — настроить её через API не получится."
        TOKEN=""; return
    fi
    count=$(grep -c . <<<"$list" || true)
    if (( count > 0 )); then
        info "Сети в аккаунте:"
        i=0; while IFS=$'\t' read -r id name members; do
            i=$((i + 1)); printf '      %d) %s  %-20s участников: %s\n' "$i" "$id" "$name" "$members"
        done <<<"$list"
        info "  0) создать новую сеть «$NET_NAME»"
        local def=0
        id="$(awk -F'\t' -v n="$NET_NAME" '$2 == n {print NR; exit}' <<<"$list")"
        [[ -n $id ]] && def=$id
        ask "Выберите сеть [$def]: " "$def"
        if [[ $REPLY =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= count )); then
            NWID="$(sed -n "${REPLY}p" <<<"$list" | cut -f1)"
            ok "Выбрана сеть $NWID"; return
        fi
    fi
    create_network_api
}

create_network_api() {
    local code body
    body="$(jq -nc --arg n "$NET_NAME" '{config: {name: $n, private: true}}')"
    code="$(api POST /network "$body")"
    is2xx "$code" || die "Не удалось создать сеть (HTTP $code). $(api_err)
    Создайте сеть вручную в my.zerotier.com и запустите: sudo $0 -n <Network ID>"
    NWID="$(jq -r '.id' "$API_BODY")"
    [[ $NWID =~ ^[0-9a-f]{16}$ ]] || die "API вернул странный ответ при создании сети."
    ok "Создана сеть «$NET_NAME»: ${BOLD}$NWID${NC}"
}

SERVER_IP=""
configure_network_api() {
    local code cfg existing pools used mine start end pool_json new_cfg member
    code="$(api GET "/network/$NWID")"; is2xx "$code" || die "Не удалось прочитать сеть (HTTP $code). $(api_err)"
    cfg="$(jq -c '.config' "$API_BODY")"

    existing="$(jq -r '[.routes[]? | select(.via == null and (.target | test("^[0-9.]+/[0-9]+$")) and .target != "0.0.0.0/0") | .target][0] // empty' <<<"$cfg")"
    if [[ -n $SUBNET ]]; then
        cidr_parse "$SUBNET" && (( CIDR_PFX >= 8 && CIDR_PFX <= 30 )) && is_private_cidr "$SUBNET" || die "Подсеть '$SUBNET' должна быть приватной (10.x, 172.16-31.x, 192.168.x) с маской /8../30."
        SUBNET="$CIDR_STR"
    elif [[ -n $existing ]]; then
        SUBNET="$existing"
    else
        SUBNET="$(random_subnet)"
    fi
    cidr_parse "$SUBNET"; SUBNET="$CIDR_STR"
    subnet_in_use "$SUBNET" && warn "Подсеть $SUBNET пересекается с сетями сервера — лучше указать другую через --subnet."
    ok "Подсеть ZeroTier: $SUBNET"

    # IP сервера: уже назначенный в этой подсети, иначе первый свободный (.1)
    code="$(api GET "/network/$NWID/member")"
    used=""; mine=""
    if is2xx "$code"; then
        used="$(jq -r --arg me "$NODE_ID" '.[] | select(.nodeId != $me) | .config.ipAssignments[]?' "$API_BODY")"
        mine="$(jq -r --arg me "$NODE_ID" '.[] | select(.nodeId == $me) | .config.ipAssignments[]?' "$API_BODY")"
    fi
    local ip
    for ip in $mine; do in_cidr "$ip" "$SUBNET" && { SERVER_IP="$ip"; break; }; done
    if [[ -z $SERVER_IP ]]; then
        cidr_parse "$SUBNET"
        local n
        for (( n = CIDR_NET + 1; n < CIDR_BCAST; n++ )); do
            ip="$(int2ip "$n")"
            grep -qxF "$ip" <<<"$used" || { SERVER_IP="$ip"; break; }
        done
    fi
    [[ -n $SERVER_IP ]] || die "В подсети $SUBNET нет свободных адресов."

    # пул автоназначения: оставляем существующий, если он в нашей подсети
    pool_json="$(jq -c --arg s "$SUBNET" '[.ipAssignmentPools[]?]' <<<"$cfg")"
    local pool_ok=0 ps
    for ps in $(jq -r '.[].ipRangeStart' <<<"$pool_json"); do in_cidr "$ps" "$SUBNET" && pool_ok=1; done
    if (( pool_ok == 0 )); then
        cidr_parse "$SUBNET"
        if (( CIDR_BCAST - CIDR_NET > 32 )); then start=$(( CIDR_NET + 10 )); else start=$(( CIDR_NET + 2 )); fi
        end=$(( CIDR_BCAST - 1 ))
        pool_json="$(jq -nc --arg a "$(int2ip "$start")" --arg b "$(int2ip "$end")" '[{ipRangeStart: $a, ipRangeEnd: $b}]')"
    fi

    if (( DEFAULT_ROUTE )) && jq -e --arg ip "$SERVER_IP" '[.routes[]? | select(.target == "0.0.0.0/0" and .via != $ip)] | length > 0' <<<"$cfg" >/dev/null; then
        warn "В сети уже был маршрут 0.0.0.0/0 через другой узел — заменяю на этот сервер."
    fi

    new_cfg="$(jq -c --arg sub "$SUBNET" --arg sip "$SERVER_IP" --argjson def "$DEFAULT_ROUTE" --argjson pools "$pool_json" '
        [ .routes[]? | select(.target != $sub and (.target != "0.0.0.0/0" or ($def == 0 and .via != $sip))) ] as $keep
        | { config: {
              routes: ([{target: $sub, via: null}] + $keep
                       + (if $def == 1 then [{target: "0.0.0.0/0", via: $sip}] else [] end)),
              ipAssignmentPools: $pools,
              v4AssignMode: ((.v4AssignMode // {}) + {zt: true}),
              enableBroadcast: true,
              multicastLimit: ([(.multicastLimit // 32), 32] | max)
          } }' <<<"$cfg")"
    code="$(api POST "/network/$NWID" "$new_cfg")"
    is2xx "$code" || die "Не удалось обновить настройки сети (HTTP $code). $(api_err)"
    ok "Сеть настроена: авто-IP, broadcast для игр$( (( DEFAULT_ROUTE )) && echo ", маршрут 0.0.0.0/0 → $SERVER_IP (VPN)")"

    member="$(jq -nc --arg ip "$SERVER_IP" --arg name "zt-modem-$(hostname -s 2>/dev/null || echo server)" \
        '{name: $name, description: "ZeroTier exit node (zt_exitnode.sh)",
          config: {authorized: true, ipAssignments: [$ip], noAutoAssignIps: true}}')"
    local i
    for i in $(seq 1 20); do
        code="$(api POST "/network/$NWID/member/$NODE_ID" "$member")"
        is2xx "$code" && break
        sleep 3
    done
    is2xx "$code" || die "Не удалось авторизовать сервер в сети (HTTP $code). $(api_err)"
    ok "Сервер авторизован в сети, IP: ${BOLD}$SERVER_IP${NC}"
}

# ---------- ручной режим -----------------------------------------------------
ask_network_manual() {
    [[ -n $NWID ]] && return
    has_tty || die "Без токена нужен ID сети: sudo $0 -n <Network ID>"
    cat <<EOF
    Создайте сеть (если её ещё нет):
      1. Откройте https://my.zerotier.com (или central.zerotier.com) и войдите.
      2. Нажмите «Create A Network» и скопируйте Network ID (16 символов).
EOF
    while :; do
        ask "Network ID: " ""
        NWID="${REPLY,,}"; NWID="${NWID//[[:space:]]/}"
        [[ $NWID =~ ^[0-9a-f]{16}$ ]] && break
        warn "Нужно ровно 16 hex-символов, например 8056c2e21c000001"
    done
}

manual_auth_help() {
    cat <<EOF

    ${BOLD}Что сделать в веб-панели ZeroTier (сеть $NWID):${NC}
      1. Members → найдите узел ${BOLD}$NODE_ID${NC} → поставьте галочку ${BOLD}Auth/Authorized${NC}.
         (если узла нет в списке — нажмите «Manually Add Member» и введите $NODE_ID)
      2. Settings → IPv4 Auto-Assign: включите и выберите любой диапазон
         (например 10.147.17.*). Маршрут этой подсети добавится сам.
      3. Settings → Multicast → включите ${BOLD}Enable Broadcast${NC} (нужно для игр по LAN).
EOF
}

wait_ready() {  # wait_ready TIMEOUT_SEC -> ZT_IF, SERVER_IP
    local timeout=$1 t=0 j status last="" addr
    while (( t < timeout )); do
        j="$(net_json)"; [[ -n $j ]] || j='{}'
        status="$(jq -r '.status // "?"' <<<"$j")"
        addr="$(jq -r '[.assignedAddresses[]? | select(test("^[0-9.]+/"))][0] // empty' <<<"$j")"
        if [[ $status == OK && -n $addr ]]; then
            ZT_IF="$(jq -r '.portDeviceName' <<<"$j")"
            SERVER_IP="${addr%/*}"
            return 0
        fi
        if [[ $status != "$last" ]]; then
            case "$status" in
                ACCESS_DENIED)  info "Статус: ACCESS_DENIED — ждём авторизации сервера в сети..." ;;
                REQUESTING_CONFIGURATION) info "Статус: запрашиваю конфигурацию сети..." ;;
                NOT_FOUND)      info "Статус: NOT_FOUND — сети с таким ID не существует?" ;;
                OK)             info "Статус: OK, жду назначения IP (проверьте IPv4 Auto-Assign)..." ;;
                *)              info "Статус: $status" ;;
            esac
            last="$status"
        fi
        sleep 3; t=$((t + 3))
    done
    return 1
}

# ---------- локальная настройка ---------------------------------------------
join_network() {
    if [[ -n "$(net_json)" ]]; then
        ok "Сервер уже в сети $NWID"
    else
        zerotier-cli join "$NWID" >/dev/null || die "zerotier-cli join $NWID не удался"
        ok "Сервер подключается к сети $NWID"
    fi
    sleep 1
    # сервер — шлюз, сам он не должен заворачивать свой трафик в ZeroTier
    zerotier-cli set "$NWID" allowManaged=1 >/dev/null 2>&1 || true
    zerotier-cli set "$NWID" allowGlobal=0  >/dev/null 2>&1 || true
    zerotier-cli set "$NWID" allowDefault=0 >/dev/null 2>&1 || true
    zerotier-cli set "$NWID" allowDNS=0     >/dev/null 2>&1 || true
}

cleanup_legacy() {
    # Остатки старой версии скрипта (MASQUERADE на весь трафик, iptables-persistent, nft table myzt)
    [[ -f /etc/sysctl.d/99-zt-forward.conf ]] || return 0
    info "Нашёл настройки старой версии скрипта — убираю их (они маскировали весь трафик сервера)."
    local wan z; wan="$(wan_if)"
    rm -f /etc/sysctl.d/99-zt-forward.conf
    command -v nft >/dev/null && nft delete table ip myzt 2>/dev/null || true
    if command -v iptables >/dev/null && [[ -n $wan ]]; then
        while iptables -w -t nat -D POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null; do :; done
        for z in $(ip -o link show | awk -F': ' '$2 ~ /^zt/ {print $2}' | cut -d@ -f1); do
            while iptables -w -D FORWARD -i "$wan" -o "$z" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
            while iptables -w -D FORWARD -i "$z" -o "$wan" -j ACCEPT 2>/dev/null; do :; done
        done
    fi
    if [[ -f /etc/iptables/rules.v4 ]]; then
        cp -a /etc/iptables/rules.v4 "/etc/iptables/rules.v4.bak-zt-modem"
        sed -i -E "/^-A POSTROUTING -o ${wan:-__none__} -j MASQUERADE\$/d;
                   /^-A FORWARD -i ${wan:-__none__} -o zt[^ ]+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\$/d;
                   /^-A FORWARD -i zt[^ ]+ -o ${wan:-__none__} -j ACCEPT\$/d" /etc/iptables/rules.v4
        info "Старые правила удалены из /etc/iptables/rules.v4 (бэкап: rules.v4.bak-zt-modem)."
        info "Пакет iptables-persistent больше не нужен для ZeroTier; удалять его или нет — решать вам."
    fi
}

write_config() {
    mkdir -p "$CONF_DIR"; chmod 755 "$CONF_DIR"
    {
        echo "# zt-modem: сгенерировано zt_exitnode.sh v$VERSION $(date -Is)"
        echo "NWID=$NWID"
        echo "BLOCK_PRIVATE=$BLOCK_PRIVATE"
        echo "# Интерфейс в интернет; пусто = определять автоматически по маршруту по умолчанию"
        echo "WAN_IF="
    } >"$CONF"
    echo 'net.ipv4.ip_forward = 1' >"$SYSCTL_FILE"
    sysctl -q -w net.ipv4.ip_forward=1
    if [[ $SAVE_TOKEN == 1 && -n $TOKEN ]]; then
        (umask 077; printf '%s\n' "$TOKEN" >"$TOKEN_FILE")
        ok "Токен сохранён в $TOKEN_FILE (только для root)"
    fi
}

install_fw_helper() {
    cat >"$FW" <<'FWEOF'
#!/usr/bin/env bash
# zt-modem-fw — NAT/forwarding для сети ZeroTier. Создано zt_exitnode.sh.
# Работает только с собственными цепочками ZTMODEM-* / таблицей ztmodem,
# чужие правила (Docker, ufw, firewalld, fail2ban...) не трогает.
#   zt-modem-fw apply [--wait SEC] | remove [--all] | status
set -uo pipefail
CONF=/etc/zt-modem/zt-modem.conf
FWD_STATE=/etc/zt-modem/firewalld.state
PRIVATE_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16"
NWID=""; BLOCK_PRIVATE=1; WAN_IF=""
[[ -r $CONF ]] && . "$CONF"
log() { echo "zt-modem-fw: $*"; }
[[ -n $NWID ]] || { log "NWID не задан в $CONF"; exit 1; }

zt_if()   { zerotier-cli -j listnetworks 2>/dev/null | jq -r --arg n "$NWID" '.[] | select(.nwid == $n) | .portDeviceName // empty' 2>/dev/null; }
zt_nets() { ip -4 route show dev "$1" proto kernel scope link 2>/dev/null | awk '{print $1}'; }
wan_if()  { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

wait_iface() {
    local t=${1:-0} i=0
    while :; do
        ZT_IF="$(zt_if)"
        if [[ -n $ZT_IF ]] && ip link show "$ZT_IF" >/dev/null 2>&1; then
            mapfile -t ZT_NETS < <(zt_nets "$ZT_IF")
            ((${#ZT_NETS[@]})) && return 0
        fi
        (( i >= t )) && return 1
        sleep 2; i=$((i + 2))
    done
}

backend() {
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then echo firewalld
    elif command -v iptables >/dev/null && iptables -w -L -n >/dev/null 2>&1; then echo iptables
    elif command -v nft >/dev/null; then echo nft
    else echo none; fi
}

# ----- iptables -----
ipt_unhook() {
    local t=$1 parent=$2 ch=$3
    while iptables -w -t "$t" -D "$parent" -j "$ch" 2>/dev/null; do :; done
    iptables -w -t "$t" -F "$ch" 2>/dev/null; iptables -w -t "$t" -X "$ch" 2>/dev/null; true
}
ipt_remove() {
    command -v iptables >/dev/null || return 0
    ipt_unhook filter FORWARD     ZTMODEM-FWD
    ipt_unhook filter INPUT       ZTMODEM-IN
    ipt_unhook nat    POSTROUTING ZTMODEM-NAT
    ipt_unhook mangle FORWARD     ZTMODEM-MSS
}
ipt_mss() {
    iptables -w -t mangle -N ZTMODEM-MSS 2>/dev/null || iptables -w -t mangle -F ZTMODEM-MSS
    if iptables -w -t mangle -A ZTMODEM-MSS -i "$ZT_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
       && iptables -w -t mangle -A ZTMODEM-MSS -o "$ZT_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -w -t mangle -I FORWARD 1 -j ZTMODEM-MSS
    else
        log "TCPMSS недоступен в ядре — пропускаю MSS clamping"
        iptables -w -t mangle -X ZTMODEM-MSS 2>/dev/null
    fi
}
ipt_apply() {
    local net d wan wan_ip
    ipt_remove
    # FORWARD: клиенты ZeroTier -> интернет, ответы обратно, клиент <-> клиент
    iptables -w -N ZTMODEM-FWD
    iptables -w -A ZTMODEM-FWD -i "$ZT_IF" -o "$ZT_IF" -j ACCEPT
    if [[ $BLOCK_PRIVATE == 1 ]]; then
        for d in $PRIVATE_NETS; do
            iptables -w -A ZTMODEM-FWD -i "$ZT_IF" -d "$d" -j REJECT --reject-with icmp-net-prohibited
        done
    fi
    iptables -w -A ZTMODEM-FWD -i "$ZT_IF" -j ACCEPT
    iptables -w -A ZTMODEM-FWD -o "$ZT_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -w -I FORWARD 1 -j ZTMODEM-FWD
    # INPUT: порт ZeroTier (прямые P2P-соединения вместо медленных релеев) и ping из сети
    iptables -w -N ZTMODEM-IN
    iptables -w -A ZTMODEM-IN -p udp --dport 9993 -j ACCEPT
    iptables -w -A ZTMODEM-IN -i "$ZT_IF" -p icmp -j ACCEPT
    iptables -w -I INPUT 1 -j ZTMODEM-IN
    # NAT: только трафик из подсети ZeroTier
    iptables -w -t nat -N ZTMODEM-NAT
    for net in "${ZT_NETS[@]}"; do
        if ! iptables -w -t nat -A ZTMODEM-NAT -s "$net" ! -o "$ZT_IF" -j MASQUERADE 2>/dev/null; then
            wan="${WAN_IF:-$(wan_if)}"
            wan_ip="$(ip -4 -o addr show dev "$wan" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
            iptables -w -t nat -A ZTMODEM-NAT -s "$net" -o "$wan" -j SNAT --to-source "$wan_ip" \
                || { log "не удалось добавить NAT"; return 1; }
        fi
    done
    iptables -w -t nat -I POSTROUTING 1 -j ZTMODEM-NAT
    ipt_mss
}

# ----- nftables (если нет iptables) -----
nft_remove() { command -v nft >/dev/null && nft delete table ip ztmodem 2>/dev/null; true; }
nft_apply() {  # nft_apply [mss-only]
    local nets priv="" fwd="" nat="" input=""
    nets="$(IFS=,; echo "${ZT_NETS[*]}")"
    [[ $BLOCK_PRIVATE == 1 ]] && priv="iifname \"$ZT_IF\" ip daddr { ${PRIVATE_NETS// /, } } reject"
    if [[ ${1-} != mss-only ]]; then
        fwd="chain forward { type filter hook forward priority -1; policy accept;
                iifname \"$ZT_IF\" oifname \"$ZT_IF\" accept
                $priv
                iifname \"$ZT_IF\" accept
                oifname \"$ZT_IF\" ct state established,related accept }"
        input="chain input { type filter hook input priority -1; policy accept;
                udp dport 9993 accept
                iifname \"$ZT_IF\" ip protocol icmp accept }"
        nat="chain postrouting { type nat hook postrouting priority 100; policy accept;
                ip saddr { $nets } oifname != \"$ZT_IF\" masquerade }"
    fi
    nft_remove
    nft -f - <<EOF
table ip ztmodem {
    chain mss { type filter hook forward priority -150; policy accept;
        iifname "$ZT_IF" tcp flags & (syn|rst) == syn tcp option maxseg size set rt mtu
        oifname "$ZT_IF" tcp flags & (syn|rst) == syn tcp option maxseg size set rt mtu }
    $fwd
    $input
    $nat
}
EOF
}

# ----- firewalld -----
fwd() { firewall-cmd "$@" >/dev/null 2>&1; }
fwd_apply() {
    local changed=0 wz oz wan
    wan="${WAN_IF:-$(wan_if)}"
    touch "$FWD_STATE"
    if ! firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx ztmodem; then
        fwd --permanent --new-zone=ztmodem; changed=1
    fi
    [[ "$(firewall-cmd --permanent --zone=ztmodem --get-target 2>/dev/null)" == ACCEPT ]] \
        || { fwd --permanent --zone=ztmodem --set-target=ACCEPT; changed=1; }
    if ! fwd --permanent --zone=ztmodem --query-interface="$ZT_IF"; then
        oz="$(firewall-cmd --permanent --get-zone-of-interface="$ZT_IF" 2>/dev/null)" && fwd --permanent --zone="$oz" --remove-interface="$ZT_IF"
        fwd --permanent --zone=ztmodem --add-interface="$ZT_IF"; changed=1
    fi
    wz="$(firewall-cmd --get-zone-of-interface="$wan" 2>/dev/null || firewall-cmd --get-default-zone)"
    if ! fwd --permanent --zone="$wz" --query-masquerade; then
        fwd --permanent --zone="$wz" --add-masquerade; echo "MASQ_ZONE=$wz" >>"$FWD_STATE"; changed=1
    fi
    if ! fwd --permanent --zone="$wz" --query-port=9993/udp; then
        fwd --permanent --zone="$wz" --add-port=9993/udp; echo "PORT_ZONE=$wz" >>"$FWD_STATE"; changed=1
    fi
    (( changed )) && fwd --reload
    command -v nft >/dev/null && nft_apply mss-only 2>/dev/null
    true
}
fwd_remove_all() {
    [[ -f $FWD_STATE ]] || return 0
    local MASQ_ZONE="" PORT_ZONE=""
    . "$FWD_STATE"
    if command -v firewall-cmd >/dev/null; then
        fwd --permanent --delete-zone=ztmodem
        [[ -n $MASQ_ZONE ]] && fwd --permanent --zone="$MASQ_ZONE" --remove-masquerade
        [[ -n $PORT_ZONE ]] && fwd --permanent --zone="$PORT_ZONE" --remove-port=9993/udp
        systemctl is-active --quiet firewalld && fwd --reload
    fi
    rm -f "$FWD_STATE"
}

apply() {
    local wait=0
    [[ ${1-} == --wait ]] && wait=${2:-0}
    if ! wait_iface "$wait"; then
        log "интерфейс сети $NWID не готов (сервер не авторизован или нет IP) — повторю позже"
        return 1
    fi
    sysctl -q -w net.ipv4.ip_forward=1
    local be; be="$(backend)"
    case "$be" in
        iptables)  ipt_apply || return 1 ;;
        nft)       nft_apply || return 1 ;;
        firewalld) fwd_apply ;;
        *) log "нет iptables/nft/firewalld"; return 1 ;;
    esac
    log "правила применены ($be): $ZT_IF, сети ${ZT_NETS[*]}"
}

remove() {
    ipt_remove
    nft_remove
    [[ ${1-} == --all ]] && fwd_remove_all
    log "правила удалены"
}

status() {
    echo "backend: $(backend)   ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
    if wait_iface 0; then echo "ZeroTier: $ZT_IF  сети: ${ZT_NETS[*]}"; else echo "ZeroTier: интерфейс сети $NWID не готов"; fi
    if command -v iptables >/dev/null; then
        iptables -w -S ZTMODEM-FWD 2>/dev/null
        iptables -w -t nat -S ZTMODEM-NAT 2>/dev/null
    fi
    command -v nft >/dev/null && nft list table ip ztmodem 2>/dev/null
    [[ -f $FWD_STATE ]] && firewall-cmd --zone=ztmodem --list-all 2>/dev/null
    true
}

case "${1-}" in
    apply)  shift; apply "$@" ;;
    remove) shift; remove "$@" ;;
    status) status ;;
    *) echo "usage: $0 apply [--wait SEC] | remove [--all] | status"; exit 2 ;;
esac
FWEOF
    chmod 755 "$FW"

    cat >"$UNIT" <<EOF
[Unit]
Description=ZeroTier modem: NAT/forwarding for ZeroTier network $NWID
Documentation=https://github.com/Chistovik92/ip_zerotier
Wants=network-online.target zerotier-one.service
After=network-online.target zerotier-one.service docker.service firewalld.service ufw.service nftables.service netfilter-persistent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$FW apply --wait 180
ExecStop=$FW remove
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable zt-modem.service >/dev/null 2>&1
    ok "Установлен сервис zt-modem (правила восстанавливаются после перезагрузки)"
}

install_self() {  # ставим скрипт как команду zt-modem (для status/members/uninstall)
    local src="${BASH_SOURCE[0]:-}"
    if [[ -f $src ]] && grep -q 'zt-modem-fw' "$src" 2>/dev/null; then
        [[ "$(readlink -f "$src")" == "$SELF" ]] || install -m 755 "$src" "$SELF"
    elif curl -fsSL -m 20 "$REPO_RAW/zt_exitnode.sh" -o "$TMP/self.sh" 2>/dev/null && grep -q 'zt-modem-fw' "$TMP/self.sh"; then
        install -m 755 "$TMP/self.sh" "$SELF"
    else
        warn "Не удалось установить команду $SELF (не критично)."
        return 0
    fi
    ok "Команда управления: ${BOLD}sudo zt-modem status | members | uninstall${NC}"
}

start_service() {
    if systemctl restart zt-modem.service; then
        ok "Правила NAT/forwarding применены ($(journalctl -u zt-modem -n 1 -o cat 2>/dev/null | sed 's/^zt-modem-fw: //'))"
    else
        warn "Сервис zt-modem пока не смог применить правила: $(journalctl -u zt-modem -n 1 -o cat 2>/dev/null)"
        warn "Он будет повторять попытки каждые 30 секунд."
    fi
}

# ---------- проверка итоговой конфигурации (видна с сервера) ------------------
verify_network() {
    local j bc hasdef hasnet interactive=$1 printed=0 waited=0 good
    while :; do
        j="$(net_json)"; [[ -n $j ]] || j='{}'
        bc="$(jq -r '.broadcastEnabled // false' <<<"$j")"
        hasdef="$(jq -r --arg ip "$SERVER_IP" '[.routes[]? | select(.target == "0.0.0.0/0" and .via == $ip)] | length' <<<"$j")"
        hasnet="$(jq -r '[.routes[]? | select(.via == null and .target != "0.0.0.0/0")] | length' <<<"$j")"
        good=1
        [[ $bc == true ]] || good=0
        (( hasnet > 0 )) || good=0
        (( DEFAULT_ROUTE == 0 || hasdef > 0 )) || good=0
        (( good )) && break
        if [[ $interactive != 1 ]]; then
            # с токеном: даём контроллеру до 30 с, чтобы разослать новую конфигурацию
            (( waited >= 30 )) && break
            sleep 3; waited=$((waited + 3)); continue
        fi
        if (( printed == 0 )); then
            echo
            info "${BOLD}Осталось поправить настройки сети в веб-панели (сеть $NWID → Settings):${NC}"
            [[ $bc == true ]] || info "  • Multicast → включите ${BOLD}Enable Broadcast${NC}"
            (( hasnet > 0 )) || info "  • Managed Routes: добавьте подсеть ZeroTier (обычно добавляется сама при Auto-Assign)"
            (( DEFAULT_ROUTE == 0 || hasdef > 0 )) || \
                info "  • Advanced → Managed Routes → Add Route: Destination ${BOLD}0.0.0.0/0${NC}  Via ${BOLD}$SERVER_IP${NC}"
            info "Жду изменений (проверка каждые 5 с). Enter — пропустить."
            printed=1
        fi
        if read -r -t 5 _ </dev/tty 2>/dev/null; then break; fi
        sleep 0.2
    done
    ROUTE_OK=$(( DEFAULT_ROUTE == 0 || hasdef > 0 ))
    [[ $bc == true ]] && ok "Broadcast включён — игры по LAN будут видеть друг друга" \
                      || warn "Broadcast выключен — многие игры не найдут LAN-сервер. Включите Enable Broadcast."
    if (( DEFAULT_ROUTE )); then
        (( hasdef > 0 )) && ok "Маршрут 0.0.0.0/0 → $SERVER_IP настроен — сервер работает как VPN" \
                         || warn "Нет маршрута 0.0.0.0/0 via $SERVER_IP — VPN не заработает, пока его не добавить."
    fi
}

# ---------- итог ---------------------------------------------------------------
client_help() {
    cat <<EOF
Network ID:        $NWID
Сервер (Node ID):  $NODE_ID
IP сервера в сети: $SERVER_IP ($ZT_IF)
Внешний IP:        $PUB_IP

КАК ПОДКЛЮЧИТЬ ДРУЗЕЙ / СВОИ УСТРОЙСТВА
  Windows (автоматически, PowerShell от администратора):
    irm $REPO_RAW/client/zt-client-windows.ps1 -OutFile zt-client.ps1
    powershell -ExecutionPolicy Bypass -File .\\zt-client.ps1 -NetworkId $NWID -Vpn on
    (-Vpn off — только LAN для игр, интернет идёт напрямую)
  Windows / macOS вручную:
    установите ZeroTier с https://www.zerotier.com/download/ → значок в трее →
    Join New Network → $NWID. Для VPN: в меню сети отметьте «Allow Default Route Override».
  Android / iOS: приложение ZeroTier One → «+» → $NWID →
    включите «Route all traffic through ZeroTier» (Default Route) для VPN.
  Linux:
    sudo zerotier-cli join $NWID
    sudo zerotier-cli set $NWID allowDefault=1     # VPN (0 — только LAN)

  После подключения каждое новое устройство нужно авторизовать:
    веб-панель → Members → галочка Auth, либо на сервере: sudo zt-modem members
  Бесплатный тариф ZeroTier ограничен числом устройств (сервер тоже считается).

ПРОВЕРКА
  VPN: откройте https://2ip.ru — должен показаться IP $PUB_IP.
  LAN: ping $SERVER_IP и IP друзей (видны в Members). В игре — «Сетевая игра / LAN».
  Если друзья не видят игру: на Windows сеть ZeroTier должна быть «Частной»
  (клиентский скрипт делает это сам) и игру надо разрешить в брандмауэре.
EOF
}

print_summary() {
    PUB_IP="$(public_ip)"
    mkdir -p "$CONF_DIR"
    client_help >"$INFO"
    echo
    echo "${GREEN}${BOLD}════════════════════ ГОТОВО ════════════════════${NC}"
    client_help
    echo
    echo "Эта информация сохранена в $INFO"
    echo "Состояние: sudo zt-modem status     Участники: sudo zt-modem members     Удаление: sudo zt-modem uninstall"
}

# ---------- команды ------------------------------------------------------------
cmd_install() {
    echo "${BLUE}${BOLD}ZeroTier modem / exit node — v$VERSION${NC}"

    step "Проверка системы"
    check_system
    check_tun
    ensure_deps

    step "ZeroTier"
    install_zerotier

    step "Учётная запись ZeroTier"
    setup_token
    if [[ -n $TOKEN ]]; then choose_network_api; fi
    if [[ -z $TOKEN ]]; then ask_network_manual; fi

    step "Подключение к сети $NWID"
    join_network

    if [[ -n $TOKEN ]]; then
        step "Настройка сети через API"
        configure_network_api
        info "Жду, пока сервер получит конфигурацию..."
        wait_ready 90 || die "Сервер не получил IP за 90 с. Проверьте в веб-панели, что узел $NODE_ID авторизован."
    else
        step "Авторизация сервера (вручную)"
        if wait_ready 6; then
            ok "Сервер уже авторизован"
        else
            manual_auth_help
            echo
            info "Жду авторизации (до 15 минут). Ctrl+C — прервать; затем просто запустите скрипт снова."
            wait_ready $(( ASSUME_YES ? 60 : 900 )) \
                || die "Сервер так и не получил IP. Выполните шаги выше и запустите скрипт ещё раз."
        fi
    fi
    ok "Интерфейс $ZT_IF, IP сервера ${BOLD}$SERVER_IP${NC}"

    step "Маршрутизация и NAT (только для трафика ZeroTier)"
    cleanup_legacy
    write_config
    install_fw_helper
    start_service

    step "Проверка настроек сети"
    local interactive=0
    [[ -z $TOKEN ]] && has_tty && interactive=1
    verify_network "$interactive"
    install_self

    print_summary
}

cmd_status() {
    [[ $EUID -eq 0 ]] || die "Запустите от root."
    [[ -r $CONF ]] && . "$CONF"
    echo "${BOLD}zerotier-one:${NC} $(systemctl is-active zerotier-one 2>/dev/null)   ${BOLD}zt-modem:${NC} $(systemctl is-active zt-modem 2>/dev/null)"
    command -v zerotier-cli >/dev/null && { zerotier-cli info; zerotier-cli listnetworks; }
    if [[ -x $FW ]]; then "$FW" status; fi
    if [[ -r $INFO ]]; then echo; cat "$INFO"; fi
}

cmd_members() {
    [[ $EUID -eq 0 ]] || die "Запустите от root."
    check_system; ensure_deps
    [[ -r $CONF ]] && . "$CONF"
    [[ -n $NWID ]] || die "Сеть не настроена — сначала: sudo $0 install"
    setup_token
    [[ -n $TOKEN ]] || die "Для этой команды нужен API-токен (-t или ZT_TOKEN, либо --save-token при установке)."
    local code; code="$(api GET "/network/$NWID/member")"
    is2xx "$code" || die "Не удалось получить участников (HTTP $code). $(api_err)"
    echo
    jq -r '.[] | [ .nodeId, (if .config.authorized then "✔" else "✘ ждёт" end),
                   ((.config.ipAssignments // []) | join(",")), (.name // ""),
                   (if .lastSeen then ((now*1000 - .lastSeen)/60000 | floor | tostring) + " мин назад" else "-" end) ] | @tsv' \
        "$API_BODY" | { if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi; } | sed 's/^/    /'
    local pending id
    pending="$(jq -r '.[] | select(.config.authorized | not) | .nodeId' "$API_BODY")"
    [[ -n $pending ]] || { echo; ok "Неавторизованных устройств нет."; return; }
    echo
    for id in $pending; do
        if confirm "Авторизовать $id?" y; then
            code="$(api POST "/network/$NWID/member/$id" '{"config":{"authorized":true}}')"
            is2xx "$code" && ok "$id авторизован" || warn "$id: ошибка HTTP $code"
        fi
    done
}

cmd_uninstall() {
    [[ $EUID -eq 0 ]] || die "Запустите от root."
    [[ -r $CONF ]] && . "$CONF"
    step "Удаление zt-modem"
    systemctl disable --now zt-modem.service >/dev/null 2>&1 || true
    [[ -x $FW ]] && "$FW" remove --all || true
    rm -f "$UNIT" "$FW" "$SYSCTL_FILE" "$SELF"
    systemctl daemon-reload
    ok "Сервис и правила NAT удалены (ip_forward оставлен как есть до перезагрузки — на него могут полагаться Docker и др.)"
    if (( PURGE )); then
        [[ -n ${NWID:-} ]] && command -v zerotier-cli >/dev/null && zerotier-cli leave "$NWID" >/dev/null 2>&1 || true
        check_system
        case "$PKG" in
            apt) apt-get remove -y -qq zerotier-one >/dev/null || true ;;
            dnf|yum) $PKG remove -y -q zerotier-one >/dev/null || true ;;
            *) warn "Удалите пакет zerotier-one вручную." ;;
        esac
        rm -rf "$CONF_DIR"
        ok "ZeroTier удалён"
    fi
    if [[ -n ${NWID:-} ]]; then info "Не забудьте удалить маршрут 0.0.0.0/0 и узел сервера в веб-панели сети $NWID."; fi
}

main() {
    parse_args "$@"
    case "$CMD" in
        install)   cmd_install ;;
        status)    cmd_status ;;
        members)   cmd_members ;;
        uninstall) cmd_uninstall ;;
    esac
}

main "$@"
