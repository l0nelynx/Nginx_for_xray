# All In One X-ray configuration with Nginx
--443-->Nginx-->[X-ray(TCP), Reality-fake, Panel, etc (HTTP)]
 - Reality fake site in sub.domain.com with selfsigned cert
 - Using multiple subdomains to forward TCP traffic to different sockets for X-ray
Quick start:
1. Add volume to your docker-compose.yml of x-ray node:
```yaml
    volumes:
      - ...
      - /dev/shm/:/dev/shm/
```
2. Run the script (it will install nginx in /opt/nginx )
```bash
bash <(curl -sSL https://raw.githubusercontent.com/l0nelynx/Nginx_for_xray/refs/heads/main/deploy_with_nginx.sh)
```
3. Xray.json inbound:
```json
{
      "tag": "VLESS_TCP_REALITY_NGINX",
      "listen": "/dev/shm/tcp_01.socket,0666", //Or tcp_XX.socket, where XX in 01 to SUB_COUNT
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "routeOnly": false,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "alpn": [
            "h3",
            "h2",
            "http/1.1"
          ],
          "show": false,
          "xver": 1,
          "target": "/dev/shm/reality.socket",
          "spiderX": "/",
          "shortIds": [
            ""
          ],
          "privateKey": "privateKey",
          "serverNames": [
            "sub.domain.com", //Or subXX.domain.com for tcp_XX.socket
            "node.domain.com" //For different nodes
          ]
        }
      }
```
4* /etc/sysctl.conf
```conf
...
net.core.wmem_max=16777216
net.core.rmem_max=16777216
net.ipv4.tcp_syncookies = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 2097152
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
```
```bash
sudo sysctl -p
```
