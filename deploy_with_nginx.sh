#!/bin/bash

# Остановка скрипта при ошибках
set -e

# --- 1. Получение основного кода ---
echo "===> Клонирование репозитория..."
mkdir -p /opt/nginx/
cd /opt/nginx/ || exit

# Инициализация и получение кода согласно ТЗ
git init
# Используем корректный синтаксис добавления remote
git remote add origin https://github.com/l0nelynx/Nginx_for_xray.git 2>/dev/null || echo "Remote origin уже существует"
git pull origin main || git pull origin master

# --- 2. Интерактивный запрос ---
echo "===> Настройка доменов..."
read -p "Введите основной домен (пример: domain.com): " DOMAIN
read -p "Введите маску субдомена (пример: sub): " MASK
read -p "Введите число субдоменов (пример: 3): " COUNT

# Cloudflare API данные (необходимо для пункта 4)
echo "===> Настройка Cloudflare API..."
read -p "Введите Cloudflare Zone ID: " CF_ZONE_ID
read -p "Введите Cloudflare API Token: " CF_API_TOKEN

# Генерация домена Reality (без номера)
DOMAIN_REALITY="${MASK}.${DOMAIN}"

# --- 3. Редактирование конфигов nginx ---
echo "===> Настройка конфигурации Nginx..."
NGINX_CONF="./nginx.conf"
DEFAULT_CONF="./conf.d/default.conf"

# 3.2 Замена доменов в default.conf
sed -i "s/{DOMAIN_REALITY}/${DOMAIN_REALITY}/g" "$DEFAULT_CONF"
sed -i "s/{DOMAIN}/${DOMAIN}/g" "$DEFAULT_CONF"

# 3.1 и 3.3 Генерация секций для nginx.conf
MAP_ENTRIES=""
UPSTREAM_ENTRIES=""
SUBDOMAINS=()

for (( i=1; i<=COUNT; i++ )); do
    NUM=$(printf "%02d" $i)
    SUB="${MASK}${NUM}.${DOMAIN}"
    SUBDOMAINS+=("$SUB")
    
    # TCP сокеты для субдоменов начинаются с 02 (01 занят sub.domain.com)
    UPSTREAM_NUM=$(printf "%02d" $((i+1)))
    
    # Формируем строки для вставки
    MAP_ENTRIES+="\t\t${SUB} tcp_to_xray_${UPSTREAM_NUM};\n"
    
    UPSTREAM_ENTRIES+="\tupstream tcp_to_xray_${UPSTREAM_NUM} {\n"
    UPSTREAM_ENTRIES+="\t\tserver unix:/dev/shm/tcp_${UPSTREAM_NUM}.socket;\n"
    UPSTREAM_ENTRIES+="\t}\n"
done

# Замена {DOMAIN_REALITY} в nginx.conf
sed -i "s/{DOMAIN_REALITY}/${DOMAIN_REALITY}/g" "$NGINX_CONF"

# Удаляем строку-шаблон {DOMAIN_SUB01} и вставляем сгенерированные субдомены
sed -i "/{DOMAIN_SUB01}.*/c\\${MAP_ENTRIES}" "$NGINX_CONF"

# Вставляем новые upstream блоки после tcp_to_xray_01
# Ищем конец блока tcp_to_xray_01 (строка "    }") и добавляем сгенерированные блоки
sed -i "/upstream tcp_to_xray_01 {/,/}/a\\${UPSTREAM_ENTRIES}" "$NGINX_CONF"


# --- 4. Автоматизация внесения А записей DNS в Cloudflare ---
echo "===> Обновление DNS записей в Cloudflare..."
CURRENT_IP=$(curl -s http://ipv4.icanhazip.com)
echo "Текущий IP сервера: $CURRENT_IP"

# Добавляем домен без номера в массив для создания записи
SUBDOMAINS+=("$DOMAIN_REALITY")

for SUB in "${SUBDOMAINS[@]}"; do
    echo "Создание/обновление A-записи для $SUB..."
    
    # Запрос к API Cloudflare
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data '{"type":"A","name":"'${SUB}'","content":"'${CURRENT_IP}'","ttl":120,"proxied":false}' | jq '.success, .errors'
done


# --- 5. Генерация самоподписного сертификата для Reality ---
echo "===> Генерация сертификатов..."
mkdir -p ./certs
touch ./certs/private.key && touch ./certs/fullchain.crt

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "./certs/private.key" \
    -out "./certs/fullchain.crt" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=${DOMAIN_REALITY}"


# --- 6. Запуск ---
echo "===> Перезапуск контейнеров Docker..."
cd /opt/nginx/ && docker compose down && docker compose up -d && docker compose logs -f
