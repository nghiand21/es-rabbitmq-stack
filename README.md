# Guide setup dev/prod environment

Dùng chung 1 domain, SSL Let's Encrypt tự gia hạn:

| Dịch vụ | Địa chỉ |
|---|---|
| Elasticsearch | `https://<DOMAIN>:9200` |
| RabbitMQ GUI | `https://<DOMAIN>:15672` |
| RabbitMQ AMQP (TLS) | `amqps://<DOMAIN>:5671` |

Yêu cầu: bản ghi DNS A của `<DOMAIN>` trỏ về IP server, firewall mở port **80, 9200, 15672, 5671**.
Port 80 dùng để xin và tự gia hạn SSL, phải mở.

## 1. Install Package Required

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

## 2. Deploy cụm RabbitMQ - ES-writer - Elasticsearch

### 2.1. Lấy code

```bash
git clone <URL repo> /root/project/docker-services
cd /root/project/docker-services
docker network create proxy
```

### 2.2. Tạo file `.env` và sinh mật khẩu ngẫu nhiên

```bash
cp .env.example .env
sed -i "s/ELASTIC_PASSWORD=CHANGE_ME/ELASTIC_PASSWORD=$(openssl rand -hex 16)/" .env
sed -i "s/RABBITMQ_PASS=CHANGE_ME/RABBITMQ_PASS=$(openssl rand -hex 16)/" .env
chmod 600 .env
```

Sửa domain và email trong `.env`:

```ini
DOMAIN=es.example.com
ACME_EMAIL=devops@example.com
```

### 2.3. Thông tin tài khoản

Xem mật khẩu: `grep -E 'USER|PASS' .env`

- Elasticsearch: user `elastic`, password `ELASTIC_PASSWORD`
- RabbitMQ: user `RABBITMQ_USER` (mặc định `tel4vn`), password `RABBITMQ_PASS`

### 2.4. Run docker compose để deploy

```bash
docker compose up -d
```

Sau khi deploy chờ từ 2-5p để các service setup hoàn tất. SSL được xin tự động ở lần chạy đầu.

## 3. Kiểm tra service đã work chưa

### Elasticsearch

```bash
curl -u elastic https://es.example.com:9200
```

Postman: `GET https://{{DOMAIN}}:9200`, Authorization = Basic Auth (user `elastic`).

### RabbitMQ

Truy cập `https://<DOMAIN>:15672`, đăng nhập bằng user/pass RabbitMQ, check tab **Channels**.

## 4. Muốn tạo thêm Consumers thứ 2

Thêm service `es-writer-2` vào `compose.yaml` (copy y hệt `es-writer`, đổi `container_name: es-writer-2`), rồi:

```bash
docker compose up -d
```

Trên giao diện có show **Consumers: 2** là được.

## 5. Khi nào muốn add PBX - CCP vào ELK có sẵn

### Cách 1: Tạo index CDR / TTS Log và khởi tạo mapping

Truy cập RabbitMQ GUI → Queues → es-writer → Publish message, copy nội dung file mapping vào mục Payload:

- CDR (index `pitel`): https://github.com/tel4vn-team/fusionpbx-go-api/blob/prod_cdr/fixtures/mapping.json
- TTS Log (index `pitel_ttslog`): https://github.com/tel4vn-team/fusionpbx-go-api/blob/prod_autocall_ccp/fixtures/mapping.json

Lưu ý:
- Cần add mapping trước khi deploy các service liên quan tới Elasticsearch.
- Các field nằm ngoài mapping sẽ được tự đưa vào, không cần bổ sung bằng tay nếu không cần thiết.

Kiểm tra lại mapping đã lên chưa:

```bash
curl -u elastic https://es.example.com:9200/pitel
```

### Cách 2: Tạo index `pitel_crm_cdr`

```bash
curl -u elastic -X PUT https://es.example.com:9200/pitel_crm_cdr \
  -H 'Content-Type: application/json' \
  --data-binary @mappings/pitel_crm_cdr.json
```

## 6. Config CCP

Ở CCP cần config các server ở file config json, có thể tham khảo Pitel04:

- Elasticsearch: `https://<DOMAIN>:9200`
- RabbitMQ: `amqps://<user>:<pass>@<DOMAIN>:5671/`

Phải dùng domain, không dùng IP (cert SSL cấp theo domain).

Đi local chủ yếu chỉnh lại host ở config json.
