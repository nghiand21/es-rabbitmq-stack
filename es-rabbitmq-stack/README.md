# Guide setup dev/prod environment

## Chọn chế độ triển khai trước

| Tổng đài (PBX/CCP) kết nối tới ES/RabbitMQ bằng... | Xem phần |
|---|---|
| **IP private** — ES/RabbitMQ chung hạ tầng vật lý / mạng nội bộ với tổng đài | **Phần 1** (không SSL/TLS cho ES và AMQP) |
| **Internet** — ES/RabbitMQ ở server/DC khác, đi qua IP public | **Phần 2** (SSL/TLS Let's Encrypt) |

Cả 2 chế độ đều phải làm **Phần 0** trước. RabbitMQ GUI ở cả 2 chế độ đều ra public qua HTTPS, **chỉ cho phép IP công ty** (`RABBITMQ_GUI_ALLOW_IPS`).

> Chỉ chọn Phần 1 khi tổng đài có IP private cùng mạng nội bộ riêng của mình với server này (cùng host / cùng VLAN / cùng mạng private trên cloud). Nếu "private" nhưng dùng chung với khách hàng khác hoặc đi qua link không mã hoá giữa 2 site → dùng Phần 2.

| | Phần 1 – Local (IP private) | Phần 2 – Internet |
|---|---|---|
| Elasticsearch | `http://<PRIVATE_IP>:9200` | `https://<DOMAIN>:9200` |
| RabbitMQ AMQP | `amqp://<PRIVATE_IP>:5672` | `amqps://<DOMAIN>:5671` |
| RabbitMQ GUI (chỉ IP công ty) | `https://<IP public>:15672` (cert tự ký) | `https://<DOMAIN>:15672` |
| Cần domain + DNS | Không | Có, bản ghi A trỏ về IP public server |
| File compose | `compose.private.yaml` | `compose.yaml` |
| Port mở ra internet | **15672** (chỉ IP công ty) | **80, 9200, 15672, 5671** |

Ở Phần 2, port 80 dùng để xin và tự gia hạn SSL Let's Encrypt, phải mở.

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

Sửa IP được vào RabbitMQ GUI trong `.env` (nhiều IP cách nhau dấu phẩy, VD `113.161.95.53/32, 1.2.3.4/32`):

```ini
RABBITMQ_GUI_ALLOW_IPS=113.161.95.53/32
```

`DOMAIN` và `ACME_EMAIL` chỉ dùng cho Phần 2, Phần 1 bỏ qua.

### 0.4. Thông tin tài khoản

Xem mật khẩu: `grep -E 'USER|PASS' .env`

- Elasticsearch: user `elastic`, password `ELASTIC_PASSWORD`
- RabbitMQ: user `RABBITMQ_USER` (mặc định `tel4vn`), password `RABBITMQ_PASS`

Sau đó làm **Phần 1** hoặc **Phần 2**, không làm cả hai.

## 1. Triển khai LOCAL — tổng đài kết nối qua IP private

ES và AMQP đi plaintext qua IP private (vẫn có user/pass). Không cần domain. RabbitMQ GUI đi qua Traefik với cert tự ký.

### 1.1. Khai báo IP private

Thêm IP private của server này (cùng mạng với tổng đài) vào `.env`:

```ini
PRIVATE_IP=192.168.0.148
```

Bắt buộc phải set: ES (9200) và AMQP (5672) chỉ bind vào IP này. Để trống thì compose sẽ báo lỗi và dừng.

### 1.2. Firewall / Security Group (BẮT BUỘC)

Chỉ bind `PRIVATE_IP` là **chưa đủ**. Trên cloud (CMC, ...) IP public được NAT 1:1 về IP private, nên truy cập `<IP public>:9200` từ internet vẫn tới được ES. Cũng không dùng được UFW vì port Docker publish đi vòng qua UFW. Phải chặn ở Security Group của cloud (stateful):

**Inbound** (ngoài các rule này là chặn hết):

| Port | Nguồn | Mục đích |
|---|---|---|
| 22/tcp | IP công ty / bastion | SSH — **thêm rule này trước** để không mất SSH |
| 15672/tcp | `113.161.95.53/32` | RabbitMQ GUI |
| 9200/tcp | dải private của tổng đài (VD `192.168.0.0/24`) | Elasticsearch |
| 5672/tcp | dải private của tổng đài | AMQP |

**Outbound:** cho phép tất cả (`0.0.0.0/0`, any) để còn `docker pull`, `apt`, DNS. Không có rule outbound nào thì server không tự kết nối ra ngoài được.

Kiểm tra VM **không còn gắn Security Group nào khác** mở các port trên (rule của nhiều SG được cộng dồn).

### 1.3. Deploy

```bash
docker compose -f compose.private.yaml up -d
```

Chờ 2–5 phút để service setup xong. Lúc đầu `es-writer` có thể restart vài lần do RabbitMQ chưa sẵn sàng, sau đó tự ổn.

### 1.4. Kiểm tra

Chạy từ server tổng đài:

```bash
curl -u elastic http://<PRIVATE_IP>:9200
nc -zv <PRIVATE_IP> 5672
```

Từ một máy ngoài internet, `telnet <IP public> 9200` và `telnet <IP public> 5672` phải bị **timeout**.

RabbitMQ GUI: từ mạng công ty truy cập `https://<IP public>:15672`. Trình duyệt sẽ cảnh báo cert (cert tự ký), chọn Advanced → Proceed. Đăng nhập bằng user/pass RabbitMQ, check tab **Channels**. Ngoài mạng công ty sẽ nhận `403 Forbidden` (hoặc timeout nếu Security Group đã chặn).

### 1.5. Config CCP

Trong file config json của CCP (tham khảo Pitel04):

- Elasticsearch: `http://<PRIVATE_IP>:9200`
- RabbitMQ: `amqp://<user>:<pass>@<PRIVATE_IP>:5672/`

Tiếp tục **Phần 3**, thay `<ES_URL>` bằng `http://<PRIVATE_IP>:9200`.

## 2. Triển khai INTERNET — tổng đài kết nối qua IP public

Toàn bộ ES, AMQP, GUI đi qua Traefik với SSL Let's Encrypt tự gia hạn.

### 2.1. Khai báo domain

Bản ghi DNS A của domain trỏ về IP public server. Sửa trong `.env`:

```ini
DOMAIN=es.example.com
ACME_EMAIL=devops@example.com
```

### 2.2. Deploy

```bash
docker compose up -d
```

Chờ 2–5 phút để service setup xong. SSL được xin tự động ở lần chạy đầu.

### 2.3. Kiểm tra

```bash
curl -u elastic https://<DOMAIN>:9200
```

Postman: `GET https://{{DOMAIN}}:9200`, Authorization = Basic Auth (user `elastic`).

RabbitMQ GUI: từ mạng công ty truy cập `https://<DOMAIN>:15672`, đăng nhập bằng user/pass RabbitMQ, check tab **Channels**. Ngoài mạng công ty sẽ nhận `403 Forbidden`.

### 2.4. Config CCP

Trong file config json của CCP (tham khảo Pitel04):

- Elasticsearch: `https://<DOMAIN>:9200`
- RabbitMQ: `amqps://<user>:<pass>@<DOMAIN>:5671/`

Phải dùng domain, không dùng IP (cert SSL cấp theo domain).

Tiếp tục **Phần 3**, thay `<ES_URL>` bằng `https://<DOMAIN>:9200`.

## 3. Vận hành (cả 2 chế độ)

Lệnh `docker compose` bên dưới: Phần 1 thêm `-f compose.private.yaml`, Phần 2 để nguyên.

### 3.1. Muốn tạo thêm Consumers thứ 2

- **Phần 1 (Local):** chỉ sửa `compose.private.yaml`, thêm vào dưới `services:`:

  ```yaml
    es-writer-2:
      extends: { file: compose.yaml, service: es-writer }
      container_name: es-writer-2
  ```

  Rồi chạy `docker compose -f compose.private.yaml up -d`.

- **Phần 2 (Internet):** chỉ sửa `compose.yaml`, thêm service `es-writer-2` (copy y hệt `es-writer`, đổi `container_name: es-writer-2`). Rồi chạy `docker compose up -d`.

Trên GUI có show **Consumers: 2** là được.

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
