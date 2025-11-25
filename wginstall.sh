#!/bin/bash
# Script de inicialização - Parte 1
# Ubuntu 24.04 LTS minimal (Oracle VPS)
# Objetivo: Atualização + segurança + swap + firewall iptables + otimizações WireGuard/AdGuard/Unbound + ZERO logs
# Idempotente: verifica estado antes de aplicar

set -e
set -u

echo "=== Atualizando pacotes ==="
sudo apt update -y
if apt list --upgradable 2>/dev/null | grep -q upgradable; then
    sudo apt upgrade -y
    sudo apt full-upgrade -y
    sudo apt autoremove -y
    sudo apt autoclean -y
else
    echo "[INFO] Nenhuma atualização pendente."
fi

echo "=== Segurança básica ==="
if ! dpkg -l | grep -qw unattended-upgrades; then
    sudo apt install -y unattended-upgrades
    sudo dpkg-reconfigure --priority=low unattended-upgrades
fi

if ! dpkg -l | grep -qw fail2ban; then
    sudo apt install -y fail2ban
fi
if ! systemctl is-active --quiet fail2ban; then
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
fi

echo "=== Swap de 2GB ==="
SWAPFILE="/swapfile"
if ! swapon --show | grep -q "$SWAPFILE"; then
    if [ ! -f "$SWAPFILE" ]; then
        sudo fallocate -l 2G $SWAPFILE
        sudo chmod 600 $SWAPFILE
        sudo mkswap $SWAPFILE
        echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab
    fi
    sudo swapon $SWAPFILE
else
    echo "[INFO] Swap já está ativo."
fi

echo "=== Tunings de memória ==="
if [ "$(sysctl -n vm.swappiness)" != "10" ]; then
    echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -w vm.swappiness=10
fi
if [ "$(sysctl -n vm.vfs_cache_pressure)" != "50" ]; then
    echo "vm.vfs_cache_pressure=50" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -w vm.vfs_cache_pressure=50
fi

echo "=== Firewall iptables ==="
REGRAS=(
    "-A INPUT -i lo -j ACCEPT"
    "-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
    "-A INPUT -p tcp --dport 22 -j ACCEPT"
    "-A INPUT -p udp --dport 51820 -j ACCEPT"
    "-A INPUT -p udp --dport 53 -j ACCEPT"
    "-A INPUT -p tcp --dport 53 -j ACCEPT"
    "-A INPUT -p tcp --dport 853 -j ACCEPT"
)

sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

for REGRA in "${REGRAS[@]}"; do
    if ! sudo iptables -C ${REGRA:3} 2>/dev/null; then
        sudo iptables $REGRA
    fi
done

if ! dpkg -l | grep -qw iptables-persistent; then
    sudo apt install -y iptables-persistent
    sudo netfilter-persistent save
    sudo netfilter-persistent enable
else
    sudo netfilter-persistent save
fi

echo "=== Tunings WireGuard + AdGuard + Unbound ==="
declare -A SYSCTL_VALORES=(
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv6.conf.all.forwarding"]="1"
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"
    ["fs.file-max"]="100000"
    ["net.core.rmem_max"]="2500000"
    ["net.core.wmem_max"]="2500000"
    ["net.ipv4.conf.all.rp_filter"]="1"
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.all.accept_source_route"]="0"
    ["kernel.printk"]="3 3 3 3"
)

for PARAM in "${!SYSCTL_VALORES[@]}"; do
    VALOR="${SYSCTL_VALORES[$PARAM]}"
    if [ "$(sysctl -n $PARAM 2>/dev/null || echo '')" != "$VALOR" ]; then
        echo "$PARAM=$VALOR" | sudo tee -a /etc/sysctl.conf
        sudo sysctl -w "$PARAM=$VALOR"
    fi
done

ulimit -n 65535

echo "=== Desativando logs ==="
sudo systemctl stop rsyslog || true
sudo systemctl disable rsyslog || true

JOURNAL_CONF="/etc/systemd/journald.conf"
sudo sed -i 's/^#\?Storage=.*/Storage=none/' $JOURNAL_CONF
sudo sed -i 's/^#\?ForwardToSyslog=.*/ForwardToSyslog=no/' $JOURNAL_CONF
sudo sed -i 's/^#\?ForwardToConsole=.*/ForwardToConsole=no/' $JOURNAL_CONF
sudo systemctl restart systemd-journald

for LOGFILE in /var/log/*.log /var/log/*/*.log; do
    if [ -f "$LOGFILE" ] && [ ! -L "$LOGFILE" ]; then
        sudo ln -sf /dev/null "$LOGFILE"
    fi
done

echo "=== Instalando nano ==="
if ! dpkg -l | grep -qw nano; then
    sudo apt install -y nano
else
    echo "[INFO] Nano já está instalado."
fi

echo "=== Parte 1 concluída: VPS otimizada, com nano instalado e sem geração de logs ==="

# === Iniciando Script Parte 2 ===
SCRIPT2="$HOME/wginstall.sh"
if [ -f "$SCRIPT2" ]; then
    echo "[INFO] Executando Script Parte 2..."
    bash "$SCRIPT2"
else
    echo "[WARN] Script Parte 2 não encontrado em $SCRIPT2. Pulei execução."
fi
