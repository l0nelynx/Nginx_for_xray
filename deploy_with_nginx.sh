#!/bin/bash

# Останавливаем выполнение при ошибках
set -e

echo "--- 1. Получение исходного кода из GitHub ---"
REPO_URL="https://github.com/l0nelynx/Nginx_for_xray.git"
TARGET_DIR="/opt/nginx"

if [ ! -d "$TARGET_DIR" ]; then
    mkdir -p "$TARGET_DIR"
    touch "$TARGET_DIR/.env"
fi

cd "$TARGET_DIR"
if [ ! -d ".git" ]; then
    git init
    git remote add origin "$REPO_URL"
fi
git pull origin main

echo "--- 2. Определение доменов и субдоменов ---"
read -p "Введите основной домен (например, domain.com): " MAIN_DOMAIN
read -p "Введите маску субдомена (например, sub): " SUB_MASK
read -p "Введите количество субдоменов (число): " SUB_COUNT

# Генерация списка субдоменов
REALITY_DOMAIN="${SUB_MASK}.${MAIN_DOMAIN}"
declare -a SUBDOMAINS
for i in $(seq -f "%02g" 1 $SUB_COUNT); do
    SUBDOMAINS+=("${SUB_MASK}${i}.${MAIN_DOMAIN}")
done

echo "--- 3. Редактирование конфигов Nginx ---"

# 3.2 Редактирование conf.d/default.conf
# Заменяем {DOMAIN_REALITY} и {DOMAIN}
sed -i "s/{DOMAIN_REALITY}/$REALITY_DOMAIN/g" ./conf.d/default.conf
sed -i "s/{DOMAIN}/$MAIN_DOMAIN/g" ./conf.d/default.conf

# 3.1 & 3.3 Редактирование nginx.conf
# Сначала заменяем базовые переменные
sed -i "s/{DOMAIN_REALITY}/$REALITY_DOMAIN/g" ./nginx.conf
sed -i "s/{DOMAIN_SUB01}/${SUBDOMAINS[0]}/g" ./nginx.conf

# Подготовка блоков для вставки в map и новых upstream
MAP_ENTRIES=""
UPSTREAM_BLOCKS=""

# Начинаем с 2-го субдомена (индекс 1), так как первый уже прописан в шаблоне как {DOMAIN_SUB01}
# Но так как в ТЗ "nginx.conf стало" требует tcp_to_xray_03 для sub02, пройдем циклом:
for i in $(seq 2 $SUB_COUNT); do
    IDX_STR=$(printf "%02d" $i)
    XRAY_IDX=$(printf "%02d" $((i + 1)))
    SUB_NAME="${SUB_MASK}${IDX_STR}.${MAIN_DOMAIN}"
    
    MAP_ENTRIES+="\t\t${SUB_NAME} tcp_to_xray_${XRAY_IDX};\n"
    UPSTREAM_BLOCKS+="\tupstream tcp_to_xray_${XRAY_IDX} {\n\t\tserver unix:/dev/shm/tcp_${IDX_STR}.socket;\n\t}\n"
done

# Вставка дополнительных записей в секцию map (после строки с tcp_to_xray_02)
sed -i "/tcp_to_xray_02;/a ${MAP_ENTRIES}" ./nginx.conf

# Добавление новых upstream блоков в конец секции stream (перед закрывающей скобкой http или в конец)
# Для надежности вставим перед блоком "upstream nginx_internal_http"
sed -i "/upstream nginx_internal_http/i ${UPSTREAM_BLOCKS}" ./nginx.conf


echo "--- 4. Автоматизация DNS Cloudflare ---"
read -p "Введите Cloudflare API Token: " CF_TOKEN
read -p "Введите Cloudflare Zone ID: " CF_ZONE_ID

SERVER_IP=$(curl -s https://api.ipify.org)
echo "Текущий IP сервера: $SERVER_IP"

# Функция для создания A-записи
create_dns_record() {
    local name=$1
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$SERVER_IP\",\"ttl\":120,\"proxied\":false}" | jq -r '.success'
}

echo "Создание записи для Reality: $REALITY_DOMAIN"
create_dns_record "$REALITY_DOMAIN"

for sub in "${SUBDOMAINS[@]}"; do
    echo "Создание записи для субдомена: $sub"
    create_dns_record "$sub"
done

echo "--- 5. Генерация самоподписанного сертификата ---"
mkdir -p ./certs
touch ./certs/private.key && touch ./certs/fullchain.crt

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "./certs/private.key" \
    -out "./certs/fullchain.crt" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=$REALITY_DOMAIN"

echo "--- 6. Запуск Docker ---"
docker compose down || true
docker compose up -d
docker compose logs -f
