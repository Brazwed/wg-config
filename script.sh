#!/bin/bash
# Script de inicialização - Parte 1
# Ubuntu 24.04 LTS minimal (Oracle VPS)
# Objetivo: Atualização inicial + segurança + swap + firewall iptables + otimizações WireGuard/AdGuard/Unbound + ZERO logs

set -e
set -u

echo "=== Atualizando lista de pacotes ==="
sudo apt update -y
apt list --upgradable
sudo apt upgrade -y
sudo apt full-upgrade -y
sudo apt autoremove -y
sudo apt autoclean -y

echo "=== Otimizações de segurança básicas ==="
if ! dpkg -l | grep -q unattended-upgrades; then
    sudo apt install -y unattended-upgrades
    sudo dpkg-reconfigure --priority=low unattended-upgrades
fi

if ! dpkg -l | grep -q fail2ban; then
    sudo apt install -y fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
fi

echo "=== Configurando Swap de 2GB ==="
SWAPFILE="/swapfile"
if ! swapon --show | grep -q "$SWAPFILE"; then
    if [ ! -f "$SWAPFILE" ]; then
        sudo fallocate -l 2G $SWAPFILE
        sudo chmod 600 $SWAPFILE
        sudo mkswap $SWAPFILE
        echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab
    fi
    sudo swapon $SWAPFILE
fi
if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
    echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -w vm.swappiness=10
fi
if ! grep -q "vm.vfs_cache_pressure=50" /etc/sysctl.conf; then
    echo "vm.vfs_cache_pressure=50" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -w vm.vfs_cache_pressure=50
fi

echo "=== Configurando firewall com iptables ==="
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X

sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 853 -j ACCEPT

sudo apt install -y iptables-persistent
sudo netfilter-persistent save
sudo netfilter-persistent enable

echo "=== Tunings extras para WireGuard + AdGuard + Unbound ==="
# WireGuard: forwarding + performance
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf

# AdGuard: conexões simultâneas
echo "fs.file-max=100000" | sudo tee -a /etc/sysctl.conf
ulimit -n 65535

# Unbound: buffers e proteções
echo "net.core.rmem_max=2500000" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=2500000" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.conf.all.rp_filter=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.conf.all.accept_redirects=0" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.conf.all.accept_source_route=0" | sudo tee -a /etc/sysctl.conf

sudo sysctl -p

echo "=== Desativando completamente logs ==="
# rsyslog
sudo systemctl stop rsyslog || true
sudo systemctl disable rsyslog || true

# journald
JOURNAL_CONF="/etc/systemd/journald.conf"
sudo sed -i 's/^#\?Storage=.*/Storage=none/' $JOURNAL_CONF
sudo sed -i 's/^#\?ForwardToSyslog=.*/ForwardToSyslog=no/' $JOURNAL_CONF
sudo sed -i 's/^#\?ForwardToConsole=.*/ForwardToConsole=no/' $JOURNAL_CONF
sudo systemctl restart systemd-journald

# redirecionar todos os arquivos de log para /dev/null
for LOGFILE in /var/log/*.log /var/log/*/*.log; do
    if [ -f "$LOGFILE" ]; then
        sudo ln -sf /dev/null $LOGFILE
    fi
done

# kernel não imprime mensagens
echo "kernel.printk = 3 3 3 3" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

echo "=== Parte 1 concluída: VPS atualizada, protegida, otimizada para WireGuard+AdGuard+Unbound e sem geração de logs ==="
