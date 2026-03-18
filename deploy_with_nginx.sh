#!/bin/bash
set -e
echo "--- 1. Repo Sync ---"
TARGET_DIR="/opt/nginx"
REPO_URL="https://github.com/l0nelynx/Nginx_for_xray.git"
mkdir -p "$TARGET_DIR"
touch "$TARGET_DIR/.env"
cd "$TARGET_DIR"
if [ ! -d ".git" ]; then
    git init
    git remote add origin "$REPO_URL"
fi
git fetch origin
git reset --hard origin/main
echo "--- 2. Collecting parameters ---"
read -p "Enter your primary domain (domain.com): " MAIN_DOMAIN
read -p "Enter subdomain mask (for example, sub): " SUB_MASK
read -p "Number of subdomains - SUB_COUNT (for example, 3): " SUB_COUNT
REALITY_DOMAIN="${SUB_MASK}.${MAIN_DOMAIN}"

# Спрашиваем proxy_protocol для каждого субдомена
echo ""
echo "--- Proxy Protocol configuration ---"
declare -A PP_ENABLED

# Для reality (первый, индекс 01)
read -p "Enable proxy_protocol for ${REALITY_DOMAIN} (tcp_01)? [y/N]: " pp_ans
if [[ "$pp_ans" =~ ^[Yy]$ ]]; then
    PP_ENABLED["01"]=true
else
    PP_ENABLED["01"]=false
fi

for i in $(seq 1 $SUB_COUNT); do
    SUB_IDX=$(printf "%02d" $i)
    TARGET_IDX=$(printf "%02d" $((i + 1)))
    SUB_FULL="${SUB_MASK}${SUB_IDX}.${MAIN_DOMAIN}"
    read -p "Enable proxy_protocol for ${SUB_FULL} (tcp_${TARGET_IDX})? [y/N]: " pp_ans
    if [[ "$pp_ans" =~ ^[Yy]$ ]]; then
        PP_ENABLED["$TARGET_IDX"]=true
    else
        PP_ENABLED["$TARGET_IDX"]=false
    fi
done

echo "--- 3. nginx.conf & default.conf assembly ---"
sed -i "s/{DOMAIN_REALITY}/$REALITY_DOMAIN/g" ./conf.d/default.conf
sed -i "s/{DOMAIN}/$MAIN_DOMAIN/g" ./conf.d/default.conf

# STREAM
# MAP — теперь ссылается на 127.0.0.1:1000X
MAP_CONTENT="    map \$ssl_preread_server_name \$backend_dispatcher {\n"
MAP_CONTENT+="        ${REALITY_DOMAIN}    127.0.0.1:10001;\n"

# UPSTREAMS
UPSTREAMS="    upstream tcp_to_xray_01 {\n        server unix:/dev/shm/tcp_01.socket;\n    }\n"

# Промежуточные server-блоки
build_intermediate_server() {
    local port=$1
    local upstream=$2
    local pp=${3:-false}

    local pp_line=""
    if [ "$pp" = true ]; then
        pp_line="        proxy_protocol on;\n"
    fi

    echo -e "    server {\n        listen 127.0.0.1:${port} proxy_protocol;\n        set_real_ip_from 127.0.0.1;\n${pp_line}        proxy_pass ${upstream};\n    }"
}

INTERMEDIATE_SERVERS=""
INTERMEDIATE_SERVERS+=$(build_intermediate_server "10001" "tcp_to_xray_01" "${PP_ENABLED["01"]}")
INTERMEDIATE_SERVERS+="\n"

for i in $(seq 1 $SUB_COUNT); do
    SUB_IDX=$(printf "%02d" $i)
    TARGET_IDX=$(printf "%02d" $((i + 1)))
    PORT=$((10000 + i + 1))
    SUB_FULL="${SUB_MASK}${SUB_IDX}.${MAIN_DOMAIN}"

    MAP_CONTENT+="        ${SUB_FULL} 127.0.0.1:${PORT};\n"
    UPSTREAMS+="    upstream tcp_to_xray_${TARGET_IDX} {\n        server unix:/dev/shm/tcp_${TARGET_IDX}.socket;\n    }\n"
    INTERMEDIATE_SERVERS+=$(build_intermediate_server "$PORT" "tcp_to_xray_${TARGET_IDX}" "${PP_ENABLED["$TARGET_IDX"]}")
    INTERMEDIATE_SERVERS+="\n"
done

MAP_CONTENT+="        default nginx_internal_http;\n    }"

# Write nginx.conf
cat <<EOF > ./nginx.conf
user  nginx;
worker_processes  auto;
worker_rlimit_nofile 1048576;
error_log  /var/log/nginx/error.log error;
pid        /run/nginx.pid;
events {
    worker_connections  16384;
    use epoll;
    multi_accept on;
}
stream {
    tcp_nodelay on;
$(echo -e "$MAP_CONTENT")
$(echo -e "$UPSTREAMS")
    upstream nginx_internal_http {
        server 127.0.0.1:8443;
    }
    server {
        listen 443 fastopen=256;
        ssl_preread on;
        proxy_protocol on;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_pass \$backend_dispatcher;
    }
$(echo -e "$INTERMEDIATE_SERVERS")
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    include /etc/nginx/conf.d/*.conf;
}
EOF

# --- 4. Cloudflare DNS ---
echo "--- 4. Setting up Cloudflare ---"
read -p "Cloudflare API Token: " CF_TOKEN
read -p "Cloudflare Zone ID: " CF_ZONE_ID
CURRENT_IP=$(curl -s https://api.ipify.org)
create_dns() {
    local name=$1
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}" > /dev/null
    echo "Создана запись: $name"
}
create_dns "$REALITY_DOMAIN"
for i in $(seq 1 $SUB_COUNT); do
    SUB_IDX=$(printf "%02d" $i)
    create_dns "${SUB_MASK}${SUB_IDX}.${MAIN_DOMAIN}"
done

# --- 5. SSL & start ---
echo "--- 5. SSL & start Docker Compose ---"
mkdir -p ./certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "./certs/private.key" \
    -out "./certs/fullchain.crt" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=$REALITY_DOMAIN"
docker compose down --remove-orphans || true
docker compose up -d
docker compose logs -f
