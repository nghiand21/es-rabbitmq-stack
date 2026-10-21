# Guide setup dev/prod environment

## Chọn chế độ triển khai trước

| Tổng đài (PBX/CCP) kết nối tới ES/RabbitMQ bằng... | Xem phần |
|---|---|
| **IP private** — ES/RabbitMQ chung hạ tầng vật lý / mạng nội bộ với tổng đài | **Phần 1** (không SSL/TLS cho ES và AMQP) |
| **Internet** — ES/RabbitMQ ở server/DC khác, đi qua IP public | **Phần 2** (SSL/TLS Let's Encrypt) |

Cả 2 chế độ đều phải làm **Phần 0** trước. RabbitMQ GUI ở cả 2 chế độ đều ra public qua `https://<DOMAIN>:15672`, **chỉ cho phép IP công ty** (`RABBITMQ_GUI_ALLOW_IPS`).

> Chỉ chọn Phần 1 khi mạng private là mạng nội bộ riêng của mình (cùng host / cùng VLAN). Nếu "private" nhưng dùng chung với khách hàng khác hoặc đi qua link không mã hoá giữa 2 site → dùng Phần 2.

| Dịch vụ | Phần 1 – Local (IP private) | Phần 2 – Internet |
|---|---|---|
| Elasticsearch | `http://<PRIVATE_IP>:9200` | `https://<DOMAIN>:9200` |
| RabbitMQ AMQP | `amqp://<PRIVATE_IP>:5672` | `amqps://<DOMAIN>:5671` |
| RabbitMQ GUI | `https://<DOMAIN>:15672` (chỉ IP công ty) | `https://<DOMAIN>:15672` (chỉ IP công ty) |
| File compose | `compose.private.yaml` | `compose.yaml` |
| Port firewall mở public | **80, 15672** | **80, 9200, 15672, 5671** |

Port 80 dùng để xin và tự gia hạn SSL cho GUI (và ES/AMQPS ở Phần 2), phải mở. Bản ghi DNS A của `<DOMAIN>` trỏ về IP public server.

## 0. Chuẩn bị chung (cả 2 chế độ)

### 0.1. Install Package Required

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
cd /root/project/docker-services
docker network create proxy
```

### 0.3. Tạo file `.env` và sinh mật khẩu ngẫu nhiên

```bash
cp .env.example .env
sed -i "s/ELASTIC_PASSWORD=CHANGE_ME/ELASTIC_PASSWORD=$(openssl rand -hex 16)/" .env
sed -i "s/RABBITMQ_PASS=CHANGE_ME/RABBITMQ_PASS=$(openssl rand -hex 16)/" .env
chmod 600 .env
```

Sửa domain, email và IP được vào GUI trong `.env`:

```ini
DOMAIN=es.example.com
ACME_EMAIL=devops@example.com
# Nhiều IP cách nhau dấu phẩy, VD: 113.161.95.53/32, 1.2.3.4/32
RABBITMQ_GUI_ALLOW_IPS=113.161.95.53/32
```

### 0.4. Thông tin tài khoản

Xem mật khẩu: `grep -E 'USER|PASS' .env`

- Elasticsearch: user `elastic`, password `ELASTIC_PASSWORD`
- RabbitMQ: user `RABBITMQ_USER` (mặc định `tel4vn`), password `RABBITMQ_PASS`

Sau đó làm **Phần 1** hoặc **Phần 2**, không làm cả hai.

## 1. Triển khai LOCAL — tổng đài kết nối qua IP private

ES và AMQP đi plaintext qua IP private (vẫn có user/pass). Chỉ RabbitMQ GUI đi qua Traefik + SSL.

### 1.1. Khai báo IP private

Thêm IP private của server này (cùng mạng với tổng đài) vào `.env`:

```ini
PRIVATE_IP=10.0.0.10
```

Bắt buộc phải set: ES (9200) và AMQP (5672) chỉ bind vào IP này. Không bind `0.0.0.0` vì port Docker publish **đi vòng qua UFW/iptables**, firewall không chặn được. Để trống thì compose sẽ báo lỗi và dừng.

### 1.2. Deploy

```bash
docker compose -f compose.private.yaml up -d
```

Chờ 2–5 phút để service setup xong. Lúc đầu `es-writer` có thể restart vài lần do RabbitMQ chưa sẵn sàng, sau đó tự ổn.

### 1.3. Kiểm tra

Chạy từ server tổng đài:

```bash
curl -u elastic http://<PRIVATE_IP>:9200
nc -zv <PRIVATE_IP> 5672
```

Từ ngoài internet `<IP public>:9200` và `:5672` phải **không** vào được.

RabbitMQ GUI: từ mạng công ty truy cập `https://<DOMAIN>:15672`, đăng nhập bằng user/pass RabbitMQ, check tab **Channels**. Ngoài mạng công ty sẽ nhận `403 Forbidden`.

### 1.4. Config CCP

Trong file config json của CCP (tham khảo Pitel04):

- Elasticsearch: `http://<PRIVATE_IP>:9200`
- RabbitMQ: `amqp://<user>:<pass>@<PRIVATE_IP>:5672/`

Tiếp tục **Phần 3**, thay `<ES_URL>` bằng `http://<PRIVATE_IP>:9200`.

## 2. Triển khai INTERNET — tổng đài kết nối qua IP public

Toàn bộ ES, AMQP, GUI đi qua Traefik với SSL Let's Encrypt tự gia hạn.

### 2.1. Deploy

```bash
docker compose up -d
```

Chờ 2–5 phút để service setup xong. SSL được xin tự động ở lần chạy đầu.

### 2.2. Kiểm tra

```bash
curl -u elastic https://<DOMAIN>:9200
```

Postman: `GET https://{{DOMAIN}}:9200`, Authorization = Basic Auth (user `elastic`).

RabbitMQ GUI: từ mạng công ty truy cập `https://<DOMAIN>:15672`, đăng nhập bằng user/pass RabbitMQ, check tab **Channels**. Ngoài mạng công ty sẽ nhận `403 Forbidden`.

### 2.3. Config CCP

Trong file config json của CCP (tham khảo Pitel04):

- Elasticsearch: `https://<DOMAIN>:9200`
- RabbitMQ: `amqps://<user>:<pass>@<DOMAIN>:5671/`

Phải dùng domain, không dùng IP (cert SSL cấp theo domain).

Tiếp tục **Phần 3**, thay `<ES_URL>` bằng `https://<DOMAIN>:9200`.

## 3. Vận hành (cả 2 chế độ)

Lệnh `docker compose` bên dưới: Phần 1 thêm `-f compose.private.yaml`, Phần 2 để nguyên.

### 3.1. Muốn tạo thêm Consumers thứ 2

Thêm service `es-writer-2` vào `compose.yaml` (copy y hệt `es-writer`, đổi `container_name: es-writer-2`). Nếu đang chạy Phần 1, thêm vào `compose.private.yaml`:

```yaml
  es-writer-2:
    extends: { file: compose.yaml, service: es-writer-2 }
```

Rồi chạy lại `docker compose up -d`. Trên GUI có show **Consumers: 2** là được.

### 3.2. Add PBX - CCP vào ELK có sẵn

#### Cách 1: Tạo index CDR / TTS Log và khởi tạo mapping

Truy cập RabbitMQ GUI → Queues → es-writer → Publish message, copy nội dung file mapping vào mục Payload:

- CDR (index `pitel`): https://github.com/tel4vn-team/fusionpbx-go-api/blob/prod_cdr/fixtures/mapping.json
- TTS Log (index `pitel_ttslog`): https://github.com/tel4vn-team/fusionpbx-go-api/blob/prod_autocall_ccp/fixtures/mapping.json

Lưu ý:
- Cần add mapping trước khi deploy các service liên quan tới Elasticsearch.
- Các field nằm ngoài mapping sẽ được tự đưa vào, không cần bổ sung bằng tay nếu không cần thiết.

Kiểm tra lại mapping đã lên chưa:

```bash
curl -u elastic <ES_URL>/pitel
```

#### Cách 2: Tạo index `pitel_crm_cdr`

```bash
curl -u elastic -X PUT <ES_URL>/pitel_crm_cdr \
  -H 'Content-Type: application/json' \
  --data-binary @mappings/pitel_crm_cdr.json
```

### 3.3. Đổi danh sách IP được vào RabbitMQ GUI

Sửa `RABBITMQ_GUI_ALLOW_IPS` trong `.env`, rồi chạy lại `docker compose up -d traefik`.
