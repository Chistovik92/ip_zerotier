ZeroTier Exit Node Setup Script

https://zerotier.com/wp-content/uploads/2023/03/ZeroTier-Logo-FullColor-RGB.svg

A robust Bash script to configure a Linux server as a ZeroTier exit node/VPN gateway. This script automates the setup process for creating your own VPN server using ZeroTier.

🌟 Features

· Automatic Interface Detection - Discovers WAN and ZeroTier interfaces
· Dual Firewall Support - Configures both iptables and nftables
· Persistent Rules - Survives reboots with iptables-persistent
· Idempotent - Safe to run multiple times
· Colorful Output - Clear visual feedback during installation
· Error Handling - Comprehensive error checking and reporting

📋 Prerequisites

· Ubuntu 20.04+ or Debian 11+ (recommended)
· Root access
· ZeroTier installed and node joined to network
· Node authorized in ZeroTier Central

🚀 Quick Start

1. Install ZeroTier (if not already installed)

```bash
curl -s https://install.zerotier.com | sudo bash
```

2. Join ZeroTier Network

```bash
sudo zerotier-cli join <Your-Network-ID>
```

3. Download and Run Setup Script

```bash
# Download the script
wget https://raw.githubusercontent.com/Chistovik92/ip_ZeroTier/main/zt_exitnode.sh

# Make it executable
chmod +x zt_exitnode.sh

# Run as root
sudo ./zt_exitnode.sh
```

🔧 Manual Installation

```bash
git clone https://github.com/Chistovik92/ip_ZeroTier.git
cd ip_ZeroTier
chmod +x zt_exitnode.sh
sudo ./zt_exitnode.sh
```

📖 What the Script Does

1. Enables IPv4 Forwarding - Configures kernel parameter for routing
2. Detects Network Interfaces - Finds WAN and ZeroTier interfaces automatically
3. Configures Firewall Rules:
   · NAT masquerading for outbound traffic
   · Forwarding rules for established connections
   · Compatibility with both iptables and nftables
4. Makes Rules Persistent - Installs and saves iptables-persistent

🛠 Post-Setup Configuration

After running the script:

1. In ZeroTier Central:
   · Find your server's ZeroTier IP in "Managed IPs"
   · Add route: 0.0.0.0/0 via <Your-ZeroTier-IP>
2. On Client Devices:
   · Enable "Route all traffic through ZeroTier"
   · Test connection at 2ip.ru or similar service

🧪 Verification

Check if everything is working:

```bash
# Verify IP forwarding
cat /proc/sys/net/ipv4/ip_forward

# Check iptables rules
sudo iptables -t nat -L
sudo iptables -L FORWARD

# Check ZeroTier interface
ip addr show | grep zt
```

🐛 Troubleshooting

Common Issues

ZeroTier interface not found

· Ensure node is authorized in ZeroTier Central
· Check ZeroTier service: sudo systemctl status zerotier-one

No internet access through exit node

· Verify route is set in ZeroTier Central
· Check firewall rules: sudo iptables -L FORWARD -v

Rules don't persist after reboot

· Reinstall persistent package: sudo apt-get install --reinstall iptables-persistent

Debug Commands

```bash
# Check routing table
ip route

# Monitor traffic
sudo tcpdump -i zt*

# Check ZeroTier status
sudo zerotier-cli status
sudo zerotier-cli listnetworks
```

🔒 Security Notes

· This script enables IP forwarding which changes system security posture
· Ensure your server is properly secured with a firewall
· Regularly update your system and ZeroTier
· Monitor for unusual traffic patterns

📁 File Structure

```
ip_ZeroTier/
├── zt_exitnode.sh          # Main setup script
├── README.md              # This file
└── LICENSE               # License file
```

🤝 Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

⚠️ Disclaimer

This script is provided as-is without any warranties. Use at your own risk. Ensure you have proper authorization to run exit node services and comply with your hosting provider's terms of service.

📞 Support

· ZeroTier Documentation: https://docs.zerotier.com/
· ZeroTier Community: https://zerotier.com/community/

---

Note: Remember to authorize your node in ZeroTier Central before running the script!
