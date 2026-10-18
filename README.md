# Guide setup dev/prod environment — RabbitMQ · ES-writer · Elasticsearch (v2)

Bản nâng cấp của "Guide setup dev/prod environment". Trình tự giữ như cũ; thay đổi chính:

| | Bản cũ | Bản mới |
|---|---|---|
| Truy cập ES | `http://IP:9200` public | `https://<ES_DOMAIN>` (Let's Encrypt, tự renew) |
| RabbitMQ GUI | `http://IP:15672` | `https://<RMQ_DOMAIN>` |
| AMQP từ ngoài | `5672` plaintext | `amqps://<RMQ_DOMAIN>:5671` (TLS 1.2+) |
| Port 9200/9300/5672/15672 | Public ra Internet | Không publish, chỉ trong network nội bộ |
| Tài khoản | Hardcode trong doc + compose, dùng `elastic` cho mọi thứ | `.env` (chmod 600, không commit), mỗi service 1 user quyền tối thiểu |
| Thêm consumer | Tạo folder mới + copy compose | Đổi `ES_WRITER_REPLICAS` |
| Tạo mapping | Publish tay qua RabbitMQ UI | `make bootstrap` (tự động, idempotent) |
| Lọc IP | Không | Allowlist theo CIDR cho ES / GUI / AMQPS |
| Data RabbitMQ | Không có volume (mất khi recreate) | Volume `rabbitmq-data` |

Version **giữ nguyên** như bản cũ: `elasticsearch:7.10.1`, `rabbitmq:3-management`, `es-writer:latest` (khai báo trong `.env`). Thành phần mới duy nhất là **Traefik v3.7** làm reverse proxy + cấp/renew SSL.

```
                 ┌──────────── host ─────────────────────────────────────────┐
 Internet ─80──► │ Traefik ─(ACME HTTP-01, redirect https)                   │
          ─443─► │ Traefik ─ Host(ES_DOMAIN)  ──http──► es:9200              │
          ─443─► │ Traefik ─ Host(RMQ_DOMAIN) ──http──► rabbitmq:15672       │
          ─5671► │ Traefik ─ SNI(RMQ_DOMAIN)  ──tcp───► rabbitmq:5672        │
                 │                           es-writer ─► rabbitmq, es       │
                 │   network "internal" (internal: true, không ra Internet)  │
                 └───────────────────────────────────────────────────────────┘
```

---

## 0. Chuẩn bị

- 1 VM Debian 12 / Ubuntu 22.04+, tối thiểu 4 vCPU / 8 GB RAM / 100 GB disk.
- 2 bản ghi DNS **A** trỏ về IP public của VM:
  - `es.<domain>` → Elasticsearch
  - `mq.<domain>` → RabbitMQ (dùng chung cho GUI và AMQPS)
- Security group / firewall cloud: mở **80, 443, 5671**. Đóng 9200, 9300, 5672, 15672.
  Port 80 bắt buộc nếu xin SSL kiểu HTTP-01 (mặc định). Không mở được 80 → dùng DNS-01 (mục 2.4).

## 1. Install Package Required

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg jq git make openssl iproute2
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Kernel param bắt buộc cho Elasticsearch (bản cũ thiếu, ES có thể không start):

```bash
echo -e "vm.max_map_count=262144\nvm.swappiness=1" | sudo tee /etc/sysctl.d/90-elasticsearch.conf
sudo sysctl --system
```

## 2. Deploy cụm RabbitMQ – ES-writer – Elasticsearch

### 2.1. Lấy code (thay cho bước tạo folder + `vim docker-compose.yml`)

```bash
sudo git clone git@github.com:<ORG>/es-rabbitmq-stack.git /opt/es-rabbitmq-stack
cd /opt/es-rabbitmq-stack
```

Không cần `docker volume create` / `docker network create` nữa — compose tự tạo.

### 2.2. Thông tin tài khoản & cấu hình

Tài khoản **không còn nằm trong compose hay tài liệu**. Mật khẩu được sinh ngẫu nhiên và ghi thẳng vào `.env`, không ai phải tự nghĩ hay gõ tay.

**Bước 1 — Sinh mật khẩu ngẫu nhiên vào `.env`** (1 lệnh):

```bash
make secrets
```

Lệnh này (`scripts/gen-secrets.sh`) làm 3 việc:

1. Chưa có `.env` thì copy từ `.env.example`.
2. Thay **mọi** giá trị `CHANGE_ME` bằng 1 chuỗi ngẫu nhiên 32 ký tự `A–Z a–z 0–9` (từ `openssl rand`). Chỉ dùng chữ và số để không phải escape khi nằm trong URL `amqp://user:pass@...`.
3. `chmod 600 .env` — chỉ root đọc được.

Kết quả trong `.env`:

```ini
ELASTIC_PASSWORD=<32 ký tự ngẫu nhiên>
ES_WRITER_PASS=<32 ký tự ngẫu nhiên khác>
...
```

Chạy lại `make secrets` **không** ghi đè mật khẩu đã sinh (chỉ thay những dòng còn `CHANGE_ME`). Muốn đổi 1 mật khẩu: sửa dòng đó thành `CHANGE_ME`, chạy `make secrets`, rồi làm theo mục 7 "Đổi mật khẩu".

Tương đương nếu muốn làm tay, không dùng make:

```bash
cp .env.example .env && chmod 600 .env
while grep -q '=CHANGE_ME' .env; do
  sed -i "0,/=CHANGE_ME/s//=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)/" .env
done
```

Xem mật khẩu để cấu hình CCP / lưu vào Vault:

```bash
grep -E '_PASS|PASSWORD' .env
```

**Bước 2 — Sửa domain và allowlist:**

```bash
vim .env
```

Bắt buộc sửa:

```ini
ES_DOMAIN=es.example.com
RMQ_DOMAIN=mq.example.com
ACME_EMAIL=devops@example.com          # nhận cảnh báo hết hạn từ Let's Encrypt
ES_ALLOWED_CIDRS=<IP PBX>/32,<IP CCP>/32,<VPN>/24
RMQ_MGMT_ALLOWED_CIDRS=<VPN>/24        # ai được mở RabbitMQ GUI
AMQP_ALLOWED_CIDRS=<IP PBX>/32,<IP CCP>/32
```

Danh sách tài khoản sau khi deploy (mật khẩu xem trong `.env`, lưu vào Vault/password manager):

**Elasticsearch** — `https://<ES_DOMAIN>` (port 443)

| User | Quyền | Dùng cho |
|---|---|---|
| `elastic` (`ELASTIC_PASSWORD`) | superuser | Chỉ admin / bootstrap. **Không** cấu hình vào app |
| `es_writer` | create index + write `pitel*` | Container es-writer |
| `ccp_app` | read + write document `pitel*` | CCP / API |
| `es_reader` | read-only `pitel*` | Báo cáo, Grafana |

**RabbitMQ** — GUI `https://<RMQ_DOMAIN>`, AMQPS `amqps://<RMQ_DOMAIN>:5671/pitel`

| User | Quyền | Dùng cho |
|---|---|---|
| `rmq_admin` | administrator | Đăng nhập GUI |
| `es_writer` | configure/write/read vhost `pitel` | Container es-writer |
| `pbx_publisher` | chỉ publish (write) vhost `pitel` | PBX / CCP gửi CDR |

User `guest` bị xoá. Vhost mặc định đổi từ `/` sang `pitel` (đổi bằng `RMQ_VHOST` nếu cần giữ `/`).

### 2.3. Kiểm tra trước khi deploy

```bash
make preflight
```

Kiểm tra: docker compose v2, `vm.max_map_count`, port 80/443/5671 trống, DNS 2 domain đã trỏ đúng, quyền `.env` = 600, cấu hình compose hợp lệ.

> Lần đầu nên xin cert **staging** để tránh bị Let's Encrypt rate-limit khi còn sai DNS/firewall:
> bỏ comment `ACME_CA_SERVER=...staging...` trong `.env`, deploy, kiểm tra OK thì comment lại và chạy
> `docker compose down && docker volume rm es-stack_traefik-acme && make deploy`.

### 2.4. SSL & auto renew

- Traefik tự xin cert Let's Encrypt cho `ES_DOMAIN` và `RMQ_DOMAIN` ngay lần truy cập đầu và **tự renew khi còn 30 ngày** — không cần cron/certbot.
- Cert lưu trong volume `traefik-acme` (`acme.json`, mode 600).
- Cùng một cert của `RMQ_DOMAIN` dùng cho cả GUI (443) và AMQPS (5671), nên renew 1 lần là đủ, không phải restart RabbitMQ.
- Không mở được port 80 (sau NAT, chặn inbound) → dùng **DNS-01**:

  ```bash
  # .env
  COMPOSE_FILE=compose.yaml:compose.acme-dns.yaml
  ACME_DNS_PROVIDER=cloudflare
  # token chỉ có quyền Zone:DNS:Edit cho đúng zone
  printf '%s' '<CF_API_TOKEN>' > secrets/acme_dns_token && chmod 600 secrets/acme_dns_token
  ```

  Provider khác: đổi `ACME_DNS_PROVIDER` và tên biến token trong `compose.acme-dns.yaml` theo danh sách provider của Traefik.

### 2.5. Run để deploy

```bash
make deploy
```

Thứ tự `make deploy` thực hiện:

1. `preflight`
2. Pull image theo version trong `.env`
3. Start Traefik + Elasticsearch + RabbitMQ, **đợi healthy** (thay cho "chờ 2–5 phút")
4. `bootstrap`: tạo vhost/user RabbitMQ, role/user ES, **tạo index mapping** (mục 4), đăng ký snapshot repo
5. Start es-writer (sau khi mapping đã có — đúng lưu ý "add mapping trước khi deploy service liên quan ES" của bản cũ)

## 3. Kiểm tra service đã work chưa

Chạy tự động (từ một máy nằm trong allowlist):

```bash
make smoke
```

Kiểm tra: cert hợp lệ trên 443 và 5671 + số ngày còn lại, ES trả 401 khi không auth và 200 khi có auth, HTTP → HTTPS redirect, số consumer của RabbitMQ ≥ `ES_WRITER_REPLICAS`.

Kiểm tra tay:

**Elasticsearch**

```bash
curl -u es_reader https://es.example.com          # curl sẽ hỏi password, không để lộ trên command line/history
```

Postman: `GET https://{{ES_DOMAIN}}`, Authorization = Basic Auth, user/password lấy từ biến môi trường của Postman (không lưu password trong collection chia sẻ).

**RabbitMQ**

Truy cập `https://<RMQ_DOMAIN>` → đăng nhập `rmq_admin` → tab **Channels**: có channel của user `es_writer`, state `idle` hoặc `running`.

**Trạng thái container / log**

```bash
make status
make logs S=es-writer          # log JSON, đưa thẳng vào Loki được
```

## 4. Muốn tạo thêm Consumer

Không tạo folder mới nữa. Sửa `.env`:

```ini
ES_WRITER_REPLICAS=2
```

```bash
docker compose up -d --wait es-writer
```

RabbitMQ GUI → Overview → **Consumers: 2** là được. Giảm thì đổi lại số và chạy lại lệnh.

## 5. Khi nào muốn add PBX – CCP vào ELK có sẵn

### Cách 1: Tự động (khuyến nghị)

Mapping các index đặt trong `elasticsearch/mappings/`, tên file = tên index:

| File | Index | Nguồn |
|---|---|---|
| `pitel.json` | `pitel` (CDR) | `fusionpbx-go-api@prod_cdr/fixtures/mapping.json` |
| `pitel_ttslog.json` | `pitel_ttslog` (TTS log) | `fusionpbx-go-api@prod_autocall_ccp/fixtures/mapping.json` |
| `pitel_crm_cdr.json` | `pitel_crm_cdr` | Cách 2 của bản cũ |

```bash
make bootstrap
```

- Index chưa có → tạo với mapping + `number_of_replicas=ES_REPLICAS` (mặc định 0 cho single-node; bản cũ để 1 nên index luôn **YELLOW**).
- Index đã có → bỏ qua, không đụng dữ liệu. Chạy lại bao nhiêu lần cũng được.
- Thêm index mới: thêm file `<index>.json` vào thư mục, commit, chạy lại `make bootstrap`.
- Các field nằm ngoài mapping vẫn được ES tự đưa vào (dynamic mapping) như cũ.

### Cách 2: Thủ công qua HTTPS

```bash
curl -u elastic -X PUT "https://es.example.com/pitel_crm_cdr" \
  -H 'Content-Type: application/json' \
  --data-binary @elasticsearch/mappings/pitel_crm_cdr.json
```

Cách publish JSON `{"http_method":"PUT","uri":"/pitel",...}` qua RabbitMQ GUI → Queues → es-writer của bản cũ vẫn dùng được (es-writer không đổi), nhưng không khuyến nghị: thao tác tay, không review được, dễ sai.

### Kiểm tra mapping đã lên chưa

```bash
curl -u es_reader "https://es.example.com/pitel/_mapping?pretty"
curl -u es_reader "https://es.example.com/_cat/indices/pitel*?v"     # health phải là green
```

## 6. Config CCP / PBX

Ở CCP cần sửa các server trong file config json (tham khảo Pitel04):

| Trước | Sau |
|---|---|
| `http://<IP>:9200`, user `elastic` | `https://<ES_DOMAIN>`, user `ccp_app` |
| `amqp://tel4vn:...@<IP>:5672/` | `amqps://pbx_publisher:<pass>@<RMQ_DOMAIN>:5671/pitel` |

Lưu ý:

- Phải dùng **domain**, không dùng IP — Traefik route theo SNI, kết nối bằng IP sẽ bị từ chối.
- Client Go `amqp091-go`: dùng `amqp.DialTLS(url, &tls.Config{MinVersion: tls.VersionTLS12})`.
- Giữ `sniff=false` khi kết nối ES qua proxy.
- IP của CCP/PBX phải nằm trong `ES_ALLOWED_CIDRS` / `AMQP_ALLOWED_CIDRS`, nếu không sẽ nhận `403` (HTTPS) hoặc bị đóng kết nối (AMQPS).
- Chạy local: chỉ cần đổi host trong config json như cũ.

## 7. Vận hành

| Việc | Lệnh |
|---|---|
| Đổi mật khẩu 1 user | Sửa `.env` → `make bootstrap` → `docker compose up -d` (để es-writer nhận pass mới) → cập nhật config CCP |
| Snapshot ES | `make snapshot` (giữ 7 bản, `KEEP=14 make snapshot`). Cron: `15 2 * * * cd /opt/es-rabbitmq-stack && make snapshot` |
| Đồng bộ backup off-site | Volume `es-stack_es-snapshots` → S3 / CMC Object Storage (restic/rclone) |
| Restore | `POST /_snapshot/local_fs/<snap>/_restore` bằng user `elastic` |
| Nâng version | Sửa version trong `.env.example` qua PR → CI scan → `make pull && make deploy` |
| Dừng stack (giữ data) | `make down` |
| Metrics | Traefik `:8082/metrics`, RabbitMQ `:15692/metrics` — chỉ trong network `internal`, gắn Prometheus vào network này để scrape |

## 8. Troubleshooting

| Triệu chứng | Nguyên nhân / xử lý |
|---|---|
| Trình duyệt báo cert `TRAEFIK DEFAULT CERT` | ACME chưa xin được cert: DNS chưa trỏ, port 80 bị chặn, hoặc bị rate-limit. `make logs S=traefik \| grep -i acme` |
| HTTPS trả `403 Forbidden` | IP client không nằm trong allowlist tương ứng |
| es-writer restart liên tục | `make logs S=es-writer`. Thường do chưa chạy `make bootstrap` hoặc sai pass sau khi đổi `.env` |
| Publisher lỗi `ACCESS_REFUSED ... configure` | Code PBX/CCP tự `QueueDeclare`/`ExchangeDeclare`. Nới `RMQ_PUBLISHER_PERMS` (vd `'^es-writer$ .* ^$'`) rồi `make bootstrap` |
| Index YELLOW | `number_of_replicas>0` trên single-node: `PUT /<index>/_settings {"index":{"number_of_replicas":0}}` |
| ES không start, log `max virtual memory areas` | Chưa set `vm.max_map_count` (mục 1) |
| Client AMQPS bị ngắt sau ~60s | Kiểm tra heartbeat của client > 0; entrypoint 5671 đã tắt readTimeout |

## 9. Ghi chú bảo mật (đọc 1 lần)

- **Mật khẩu trong tài liệu cũ đã lộ** (`tel4vnEs2021`, `tel4vn2020`, và header Basic `ZWxhc3Rp...` decode ra chính `elastic:tel4vnEs2021`). Coi như đã bị lộ: đổi ngay trên mọi môi trường đang dùng, và kiểm tra IP `113.164.246.25` còn mở 9200/15672 ra Internet hay không.
- **ES 7.10.1 và RabbitMQ 3.x đã hết hỗ trợ** (ES 7.x EOL 15/01/2026). Đã giảm rủi ro bằng cách: không publish port, network internal không ra Internet, bật `-Dlog4j2.formatMsgNoLookups=true` (Log4Shell CVE-2021-44228). Vẫn nên lên kế hoạch nâng lên ES 8.19 (còn hỗ trợ đến 07/2027, chạy được với client v7) — chỉ cần đổi `ES_VERSION` sau khi test es-writer.
- TLS kết thúc ở Traefik; đoạn Traefik → ES/RabbitMQ là HTTP/AMQP nội bộ trên cùng host, trong network `internal`. Đủ cho mô hình single-host; khi tách ES/RabbitMQ sang host khác thì bật TLS nội bộ.
- Image `luandnh1998/es-writer:latest` là image cá nhân, tag mutable → nên mirror về registry công ty và pin theo digest (`@sha256:...`).
- Docker publish port **bỏ qua UFW/iptables INPUT** — vì vậy chỉ Traefik publish port, việc lọc IP nằm ở `ipAllowList` của Traefik, cộng thêm security group trên cloud.

## Phụ lục A — Cấu trúc repo

```
compose.yaml                 # stack chính
compose.acme-http.yaml       # SSL qua HTTP-01 (mặc định)
compose.acme-dns.yaml        # SSL qua DNS-01
.env.example                 # mẫu cấu hình (không có secret)
traefik/dynamic/routes.yml   # router, allowlist, header bảo mật
traefik/dynamic/tls.yml      # TLS >= 1.2, cipher an toàn
rabbitmq/rabbitmq.conf       # log JSON, giới hạn memory/disk
elasticsearch/mappings/      # mapping index (tên file = tên index)
elasticsearch/roles/         # role ES quyền tối thiểu
scripts/                     # gen-secrets, preflight, es-init, rabbitmq-bootstrap, smoke-test, es-snapshot
ansible/                     # (tuỳ chọn) dựng host + deploy qua AWX
.github/workflows/security.yml  # CI: TruffleHog, Trivy config/fs/image, Semgrep, ShellCheck, SonarQube
```

## Phụ lục B — Deploy bằng Ansible / AWX (tuỳ chọn)

Thay mục 1 + 2 bằng 1 lệnh: cài Docker, set sysctl, hardening Docker daemon, UFW cho SSH, clone repo, render `.env` từ Vault, `make deploy`.

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
mkdir -p ansible/group_vars && cp ansible/group_vars.example.yml ansible/group_vars/es_stack.yml
ansible-vault create ansible/secrets.vault.yml   # elastic_password, es_writer_pass, ... (>=16 ký tự)
ansible-playbook -i ansible/inventory.ini ansible/site.yml -e @ansible/secrets.vault.yml --ask-vault-pass
```

Trên AWX: Project = repo này, Inventory = nhóm `es_stack`, secret đưa vào Custom Credential Type thay vì vault file.

## Phụ lục C — CI bảo mật

`.github/workflows/security.yml` chạy khi PR / push `main` / hằng tuần:

- **TruffleHog** — chặn commit lộ secret.
- **Trivy config** — misconfig trong compose / workflow / Ansible. **Trivy fs** — SCA + upload SARIF.
- **Trivy image** — báo cáo CVE của image đang pin (chỉ report, vì ES 7.10.1 / RMQ 3.x chắc chắn có CVE).
- **Semgrep** + **ShellCheck** + `docker compose config` + `ansible-lint`.
- **SonarQube** — chạy khi repo có biến `SONAR_HOST_URL` và secret `SONAR_TOKEN`.

Mọi action pin theo full commit SHA (sự cố trivy-action 03/2026, CVE-2026-33634), cập nhật qua Dependabot.
