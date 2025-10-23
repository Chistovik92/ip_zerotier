#!/usr/bin/env bash
set -euo pipefail

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color
readonly SCRIPT_NAME="ZeroTier Exit Node Setup"

# Error handler
trap 'echo -e "${RED}Error in line $LINENO${NC}"; exit 1' ERR

show_header() {
    echo -e "${GREEN}"
    cat << "EOF"
    __  __                         ____        _   _                  
   |  \/  | ___  ___ ___  _ __   / ___|  ___ | |_| |_ ___ _ __ ___   
   | |\/| |/ _ \/ __/ _ \| '_ \  \___ \ / _ \| __| __/ _ \ '_ ` _ \  
   | |  | |  __/ (_| (_) | | | |  ___) | (_) | |_| ||  __/ | | | | | 
   |_|  |_|\___|\___\___/|_| |_| |____/ \___/ \__|\__\___|_| |_| |_| 
                                                                     
EOF
    echo -e "${NC}"
}

check_root() {
    [[ $EUID -eq 0 ]] || { 
        echo -e "${RED}Please run as root${NC}" >&2
        exit 1
    }
}

setup_ipv4_forwarding() {
    echo -e "${GREEN}[1]${NC} Enabling IPv4 forwarding..."
    local config_file="/etc/sysctl.d/99-zt-forward.conf"
    
    if [[ ! -f "$config_file" ]] || ! grep -q "net.ipv4.ip_forward = 1" "$config_file"; then
        echo 'net.ipv4.ip_forward = 1' > "$config_file"
        sysctl -q -p "$config_file"
    else
        echo "IPv4 forwarding already configured"
    fi
}

detect_interfaces() {
    echo -e "${GREEN}[2]${NC} Detecting network interfaces..."
    
    WAN_IF=$(ip route | awk '/default/ {print $5; exit}')
    [[ -n "$WAN_IF" ]] || {
        echo -e "${RED}Failed to detect WAN interface${NC}" >&2
        exit 1
    }

    ZT_IF=$(ip -o link show | awk -F': ' '/ zt/ {print $2; exit}' || true)
    [[ -n "$ZT_IF" ]] || {
        echo -e "${RED}ZeroTier interface not found${NC}" >&2
        echo "Please authorize this node in your ZeroTier network and rerun the script"
        exit 1
    }

    echo "Detected:"
    echo "  WAN Interface: $WAN_IF"
    echo "  ZeroTier Interface: $ZT_IF"
}

configure_iptables() {
    echo -e "${GREEN}[3]${NC} Configuring iptables rules..."
    
    # NAT rules
    iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

    # Forwarding rules
    local forward_rules=(
        "-i $WAN_IF -o $ZT_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        "-i $ZT_IF -o $WAN_IF -j ACCEPT"
    )

    for rule in "${forward_rules[@]}"; do
        iptables -C FORWARD $rule 2>/dev/null || iptables -A FORWARD $rule
    done
}

configure_nftables() {
    if command -v nft &>/dev/null && nft list ruleset | grep -q "hook postrouting"; then
        echo -e "${GREEN}[4]${NC} Configuring nftables (compatibility layer)..."
        
        nft add table ip myzt 2>/dev/null || true
        nft add chain ip myzt nat '{ type nat hook postrouting priority 100; }' 2>/dev/null || true
        
        if ! nft list chain ip myzt nat | grep -q "oif \"$WAN_IF\" masquerade"; then
            nft add rule ip myzt nat oif "$WAN_IF" masquerade
        fi
    fi
}

install_persistent_rules() {
    echo -e "${GREEN}[5]${NC} Installing persistent rules..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    # Configure debconf selections
    {
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true
    } | debconf-set-selections

    # Update and install
    apt-get -qq update
    apt-get -qq install -y iptables-persistent
    
    # Save rules
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save -qq
    fi
}

show_success_message() {
    local zt_ip
    zt_ip=$(ip -o -4 addr show dev "$ZT_IF" | awk '{print $4}' | cut -d'/' -f1 | head -1) || true
    
    cat << EOF

✅ ${GREEN}Setup Complete!${NC}

Next steps:
  1) In ZeroTier Central, copy this server's ZeroTier IP (from "Managed IPs" column)
  2) Add a route: 0.0.0.0/0 via <ZT-IP>
  3) On client devices, enable "Route all traffic through ZeroTier"
  4) Test at 2ip.ru - IP should match your VPS IP

Detected ZeroTier IP: ${BLUE}${zt_ip:-"Run 'ip addr show dev $ZT_IF' to find"}${NC}

EOF
}

main() {
    show_header
    echo -e "${BLUE}$SCRIPT_NAME${NC}\n"
    
    check_root
    setup_ipv4_forwarding
    detect_interfaces
    configure_iptables
    configure_nftables
    install_persistent_rules
    show_success_message
}

main "$@"
