# ES - RabbitMQ - ES-writer stack

## Chọn chế độ triển khai

| Tổng đài (PBX/CCP) kết nối tới ES/RabbitMQ qua | Làm theo |
|---|---|
| **IP private** (chung hạ tầng / mạng nội bộ với tổng đài) | **Phần 0 → Phần 1** |
| **Internet** (IP public, khác hạ tầng) | **Phần 0 → Phần 2** |

| | Phần 1 – Local (IP private) | Phần 2 – Internet |
|---|---|---|
| Elasticsearch | `http://<PRIVATE_IP>:9200` | `https://<DOMAIN>:9200` |
| RabbitMQ AMQP | `amqp://<PRIVATE_IP>:5672` | `amqps://<DOMAIN>:5671` |
| RabbitMQ GUI (chỉ IP công ty) | `https://<IP public>:15672` | `https://<DOMAIN>:15672` |
| Domain + SSL Let's Encrypt | Không cần | Cần |
| File compose | `compose.private.yaml` | `compose.yaml` |

## 0. Chuẩn bị chung

### 0.1. Cài Docker

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git openssl
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 0.2. Lấy code

```bash
git clone <URL repo> /root/project/docker-services
cd /root/project/docker-services/es-rabbitmq-stack
docker network create proxy
```

Mọi lệnh bên dưới đều chạy trong thư mục `/root/project/docker-services/es-rabbitmq-stack`.

### 0.3. Tạo file `.env`

```bash
cp .env.example .env
sed -i "s/ELASTIC_PASSWORD=CHANGE_ME/ELASTIC_PASSWORD=$(openssl rand -hex 16)/" .env
sed -i "s/RABBITMQ_PASS=CHANGE_ME/RABBITMQ_PASS=$(openssl rand -hex 16)/" .env
chmod 600 .env
```

IP được vào RabbitMQ GUI (nhiều IP cách nhau dấu phẩy):

```ini
RABBITMQ_GUI_ALLOW_IPS=113.161.95.53/32
```

### 0.4. Tài khoản

Xem mật khẩu: `grep -E 'USER|PASS' .env`

- Elasticsearch: user `elastic`, password `ELASTIC_PASSWORD`
- RabbitMQ: user `RABBITMQ_USER` (mặc định `tel4vn`), password `RABBITMQ_PASS`

## 1. Triển khai LOCAL – kết nối qua IP private

### 1.1. Khai báo IP private

IP private của server này trong `.env`:

```ini
PRIVATE_IP=192.168.0.148
```

### 1.2. Security Group

Thêm 2 rule inbound vào Security Group của server:

| Protocol | Port | CIDR |
|---|---|---|
| TCP | 9200 | `192.168.0.0/24` |
| TCP | 5672 | `192.168.0.0/24` |

### 1.3. iptables

Chỉ cho dải `192.168.0.0/24` vào 9200 và 5672, tự áp lại mỗi khi Docker khởi động.

Tạo script (sửa 2 dòng đầu nếu IP/dải khác):

```bash
cat > /usr/local/sbin/es-rabbit-firewall.sh <<'EOF'
#!/bin/sh
PRIVATE_IP=192.168.0.148      # = PRIVATE_IP trong .env
ALLOW_CIDR=192.168.0.0/24     # dải IP private của tổng đài
for port in 9200 5672; do
  rule="-p tcp -m conntrack --ctorigdst $PRIVATE_IP --ctorigdstport $port --ctdir ORIGINAL ! -s $ALLOW_CIDR -j DROP"
  iptables -C DOCKER-USER $rule 2>/dev/null || iptables -I DOCKER-USER $rule
done
EOF
chmod +x /usr/local/sbin/es-rabbit-firewall.sh
```

Tạo service chạy script cùng Docker:

```bash
cat > /etc/systemd/system/es-rabbit-firewall.service <<'EOF'
[Unit]
Description=Firewall ES/RabbitMQ (DOCKER-USER)
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/es-rabbit-firewall.sh

[Install]
WantedBy=docker.service
EOF
systemctl daemon-reload
systemctl enable --now es-rabbit-firewall
iptables -S DOCKER-USER
```

Kết quả có 2 dòng `-A DOCKER-USER ! -s 192.168.0.0/24 ... --ctorigdstport 9200|5672 ... -j DROP`.

### 1.4. Deploy

```bash
docker compose -f compose.private.yaml up -d
```

Chờ 2–5 phút để service khởi động xong.

### 1.5. Kiểm tra

Từ server tổng đài (IP `192.168.0.x`):

```bash
curl -u elastic http://<PRIVATE_IP>:9200
nc -zv <PRIVATE_IP> 5672
```

Từ máy ngoài internet, 2 lệnh sau phải **timeout**:

```bash
telnet <IP public> 9200
telnet <IP public> 5672
```

RabbitMQ GUI: từ mạng công ty mở `https://<IP public>:15672` (cert tự ký, chọn Advanced → Proceed), đăng nhập user/pass RabbitMQ, check tab **Channels**.

### 1.6. Config CCP

- Elasticsearch: `http://<PRIVATE_IP>:9200`
- RabbitMQ: `amqp://<user>:<pass>@<PRIVATE_IP>:5672/`

## 2. Triển khai INTERNET – kết nối qua IP public

### 2.1. Domain

Tạo bản ghi DNS A trỏ domain về IP public server, sửa `.env`:

```ini
DOMAIN=es.example.com
ACME_EMAIL=devops@example.com
```

Mở port **80, 9200, 15672, 5671**. Port 80 phải mở cho `0.0.0.0/0` (Let's Encrypt xác thực domain qua port này).

### 2.2. Deploy

```bash
docker compose up -d
```

Chờ 2–5 phút. SSL được xin tự động ở lần chạy đầu.

### 2.3. Kiểm tra

```bash
curl -u elastic https://<DOMAIN>:9200
```

RabbitMQ GUI: từ mạng công ty mở `https://<DOMAIN>:15672`, đăng nhập user/pass RabbitMQ, check tab **Channels**.

### 2.4. Config CCP

- Elasticsearch: `https://<DOMAIN>:9200`
- RabbitMQ: `amqps://<user>:<pass>@<DOMAIN>:5671/`

Dùng domain, không dùng IP.

### 2.5. SSL tự gia hạn

> ⚠️ Cert Let's Encrypt hết hạn sau 90 ngày. Cert hết hạn thì CCP **mất kết nối tới ES và RabbitMQ**.

Traefik tự kiểm tra mỗi ngày và gia hạn khi cert còn dưới 30 ngày. Gia hạn chỉ thành công khi đủ cả 4 điều kiện:

- Port 80 mở cho `0.0.0.0/0`.
- Server được phép kết nối ra internet (outbound 443 và DNS).
- Bản ghi DNS A của domain vẫn trỏ về IP public của server.
- Volume `letsencrypt` còn nguyên. **Không chạy `docker compose down -v`.**

Let's Encrypt không gửi email báo cert sắp hết hạn. Cần tự kiểm tra định kỳ, hoặc thêm cảnh báo hết hạn cert vào hệ thống monitor.

Xem ngày hết hạn:

```bash
echo | openssl s_client -connect <DOMAIN>:9200 -servername <DOMAIN> 2>/dev/null | openssl x509 -noout -enddate
```

Xem log gia hạn khi có lỗi:

```bash
docker logs traefik 2>&1 | grep -i acme | tail -20
```

## 3. Vận hành

Trong phần này, `<compose>` là:

- Phần 1: `docker compose -f compose.private.yaml`
- Phần 2: `docker compose`

`<ES_URL>` là `http://<PRIVATE_IP>:9200` (Phần 1) hoặc `https://<DOMAIN>:9200` (Phần 2).

### 3.1. Thêm consumer (không ảnh hưởng service đang chạy)

Thêm block sau vào dưới `services:` của file compose đang dùng (`compose.private.yaml` hoặc `compose.yaml`), mỗi consumer một tên mới:

```yaml
  es-writer-2:
    extends: { file: compose.yaml, service: es-writer }
    container_name: es-writer-2
```

Chỉ khởi động consumer mới:

```bash
<compose> up -d --no-deps es-writer-2
docker exec rabbitmq rabbitmqctl list_queues name consumers
```

Kết quả `es-writer  2` là được.

Bỏ consumer:

```bash
<compose> rm -sf es-writer-2
```

rồi xoá block `es-writer-2` khỏi file compose.

### 3.2. Cập nhật code

```bash
git stash
git pull
git stash pop
<compose> up -d
```

`git stash` giữ lại các consumer đã thêm ở mục 3.1.

### 3.3. Đổi IP được vào RabbitMQ GUI

Sửa `RABBITMQ_GUI_ALLOW_IPS` trong `.env`, rồi:

```bash
<compose> up -d --no-deps traefik
```

### 3.4. Tạo index và mapping

#### Index CDR / TTS Log

Truy cập RabbitMQ GUI → Queues → es-writer → Publish message, copy nội dung file mapping vào mục Payload:

- CDR (index `pitel`): https://github.com/tel4vn-team/fusionpbx-go-api/blob/prod_cdr/fixtures/mapping.json
- TTS Log (index `pitel_ttslog`): https://github.com/tel4vn-team/fusionpbx-go-api/blob/prod_autocall_ccp/fixtures/mapping.json

Add mapping trước khi deploy các service ghi vào Elasticsearch. Field ngoài mapping sẽ tự được thêm.

Kiểm tra:

```bash
curl -u elastic <ES_URL>/pitel
```

#### Index `pitel_crm_cdr`

```bash
curl -u elastic -X PUT <ES_URL>/pitel_crm_cdr \
  -H 'Content-Type: application/json' \
  --data-binary @mappings/pitel_crm_cdr.json
```
