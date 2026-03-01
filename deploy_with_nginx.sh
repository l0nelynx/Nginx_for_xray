#!/bin/bash

# Останавливаем выполнение при ошибках
set -e

# --- 1. Получение исходного кода ---
echo "--- 1. Синхронизация с GitHub ---"
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
git reset --hard origin/main # Жестко синхронизируем состояние с репозиторием

# --- 2. Ввод данных ---
echo "--- 2. Сбор параметров ---"
read -p "Введите основной домен (domain.com): " MAIN_DOMAIN
read -p "Введите маску субдоменов (sub): " SUB_MASK
read -p "Введите количество субдоменов (число): " SUB_COUNT

REALITY_DOMAIN="${SUB_MASK}.${MAIN_DOMAIN}"

# --- 3. Генерация конфигураций ---
echo "--- 3. Генерация конфигураций Nginx ---"

# 3.1 Обработка conf.d/default.conf
sed -i "s/{DOMAIN_REALITY}/$REALITY_DOMAIN/g" ./conf.d/default.conf
sed -i "s/{DOMAIN}/$MAIN_DOMAIN/g" ./conf.d/default.conf

# 3.2 Генерация секции STREAM для nginx.conf
# Генерируем карту (map)
MAP_CONTENT="    map \$ssl_preread_server_name \$backend_dispatcher {\n"
MAP_CONTENT+="        ${REALITY_DOMAIN}    tcp_to_xray_01;\n"

# Генерируем апстримы (upstreams)
UPSTREAMS="    upstream tcp_to_xray_01 {\n        server unix:/dev/shm/tcp_01.socket;\n    }\n"

for i in $(seq 1 $SUB_COUNT); do
    IDX=$(printf "%02d" $i)
    UP_IDX=$(printf "%02d" $((i + 1)))
    SUB_FULL="${SUB_MASK}${IDX}.${MAIN_DOMAIN}"
    
    MAP_CONTENT+="        ${SUB_FULL} tcp_to_xray_${UP_IDX};\n"
    UPSTREAMS+="    upstream tcp_to_xray_${UP_IDX} {\n        server unix:/dev/shm/tcp_${IDX}.socket;\n    }\n"
done

MAP_CONTENT+="        default nginx_internal_http;\n    }"

# Собираем nginx.conf целиком (используя Heredoc)
cat <<EOF > ./nginx.conf
user  nginx;
worker_processes  auto;
worker_rlimit_nofile 10000;
error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;

events {
    worker_connections  4096;
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
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        proxy_pass \$backend_dispatcher;
    }
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

    gzip on;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript;

    include /etc/nginx/conf.d/*.conf;
}
EOF

# --- 4. Cloudflare API ---
echo "--- 4. Настройка DNS Cloudflare ---"
read -p "Cloudflare API Token: " CF_TOKEN
read -p "Cloudflare Zone ID: " CF_ZONE_ID

CURRENT_IP=$(curl -s https://api.ipify.org)

create_record() {
    local name=$1
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":false}" > /dev/null
    echo "Запись $name создана."
}

create_record "$REALITY_DOMAIN"
for i in $(seq 1 $SUB_COUNT); do
    IDX=$(printf "%02d" $i)
    create_record "${SUB_MASK}${IDX}.${MAIN_DOMAIN}"
done

# --- 5. SSL и запуск ---
echo "--- 5. Генерация сертификата и запуск ---"
mkdir -p ./certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "./certs/private.key" \
    -out "./certs/fullchain.crt" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=$REALITY_DOMAIN"

docker compose down || true
docker compose up -d
docker compose logs -f
