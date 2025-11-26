#!/bin/bash
# Script de inicialização - Parte 2
# Configuração de Docker + WireGuard + AdGuard + Unbound separado
# Idempotente: verifica estado antes de aplicar

set -e
set -u

check_command() { command -v "$1" >/dev/null 2>&1; }

# === Instalar Docker ===
if check_command docker; then
  echo "[INFO] Docker já está instalado."
else
  echo "[INFO] Instalando Docker..."
  curl -sSL https://get.docker.com/ | CHANNEL=stable bash
  systemctl enable docker
  systemctl start docker
fi

# === Instalar Docker Compose plugin ===
if check_command docker && docker compose version >/dev/null 2>&1; then
  echo "[INFO] Docker Compose já está disponível."
else
  echo "[INFO] Instalando Docker Compose plugin..."
  apt-get update && apt-get install -y docker-compose-plugin
fi

# === Instalar Git ===
if check_command git; then
  echo "[INFO] Git já está instalado."
else
  echo "[INFO] Instalando Git..."
  apt-get update && apt-get install -y git
fi

# === Liberar porta 53 ===
if systemctl is-active --quiet systemd-resolved; then
  echo "[INFO] Desativando systemd-resolved..."
  systemctl stop systemd-resolved
  systemctl disable systemd-resolved
  rm -f /etc/resolv.conf
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
fi

# === Variáveis ===
WG_HOST="137.131.239.109"
WG_PASSWORD="teste"
BASE_DIR="$HOME/wg-adguard"

# === Diretórios ===
mkdir -p "$BASE_DIR/adguard/work"
mkdir -p "$BASE_DIR/adguard/conf"
mkdir -p "$BASE_DIR/.wg-easy"
mkdir -p "$BASE_DIR/unbound"

# === Configuração Unbound customizada ===
UNBOUND_CONF="$BASE_DIR/unbound/unbound.conf"
if [ ! -f "$UNBOUND_CONF" ]; then
cat > "$UNBOUND_CONF" <<EOF
server:
    interface: 0.0.0.0
    port: 53
    do-ip4: yes
    do-udp: yes
    do-tcp: yes

    # Privacidade
    qname-minimisation: yes
    hide-identity: yes
    hide-version: yes

    # Endurecimento
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes

    # Performance/robustez
    edns-buffer-size: 1232
    prefetch: yes

    # Acesso (somente rede interna e localhost)
    access-control: 10.8.1.0/24 allow
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 deny
EOF
fi

# === docker-compose.yml ===
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
cat > "$COMPOSE_FILE" <<EOF
version: "3"

services:
  wg-easy:
    environment:
      - WG_HOST=${WG_HOST}
      - PASSWORD=${WG_PASSWORD}
      - WG_DEFAULT_DNS=10.8.1.4
    image: weejewel/wg-easy
    volumes:
      - "$BASE_DIR/.wg-easy:/etc/wireguard"
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    networks:
      wg-easy:
        ipv4_address: 10.8.1.2

  adguard:
    image: adguard/adguardhome
    container_name: adguard
    volumes:
      - "$BASE_DIR/adguard/work:/opt/adguardhome/work"
      - "$BASE_DIR/adguard/conf:/opt/adguardhome/conf"
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
      - "80:80/tcp"
    restart: unless-stopped
    networks:
      wg-easy:
        ipv4_address: 10.8.1.3

  unbound:
    image: klutchell/unbound
    container_name: unbound
    volumes:
      - "$BASE_DIR/unbound/unbound.conf:/etc/unbound/unbound.conf:ro"
    ports:
      - "5053:53/tcp"
      - "5053:53/udp"
    restart: unless-stopped
    networks:
      wg-easy:
        ipv4_address: 10.8.1.4

networks:
  wg-easy:
    ipam:
      config:
        - subnet: 10.8.1.0/24
EOF
else
  echo "[INFO] docker-compose.yml já existe, pulando criação..."
fi

# === Firewall ===
PORTAS=( "udp:51820" "tcp:51821" "tcp:53" "udp:53" "tcp:3000" "tcp:80" "tcp:5053" "udp:5053" )
for P in "${PORTAS[@]}"; do
  PROTO="${P%%:*}"
  PORT="${P##*:}"
  if ! iptables -C INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT
  fi
done
iptables-save > /etc/iptables.rules

if [ ! -f /etc/systemd/system/iptables-restore.service ]; then
cat > /etc/systemd/system/iptables-restore.service <<EOF
[Unit]
Description=Restore iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable iptables-restore.service
fi

# === IP Forwarding ===
if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
  sysctl -w net.ipv4.ip_forward=1
  grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# === Git init ===
cd "$BASE_DIR"
if [ ! -d ".git" ]; then
  git init
  git add docker-compose.yml
  git commit -m "Initial commit: WireGuard + AdGuard + Unbound setup"
else
  echo "[INFO] Repositório Git já existe."
fi

# === Subir containers ===
echo "[INFO] Subindo containers..."
docker compose up -d

echo "[INFO] Parte 2 concluída: Docker + WireGuard + AdGuard + Unbound configurados com segurança reforçada!"
