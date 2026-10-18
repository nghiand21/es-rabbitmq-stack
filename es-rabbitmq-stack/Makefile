# Mọi target đều idempotent. Chạy trên host deploy, trong thư mục repo.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
.PHONY: help secrets preflight up bootstrap deploy status logs smoke snapshot down pull

help:            ## Liệt kê target
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

secrets:         ## Tạo .env (nếu chưa có) và sinh mật khẩu cho mọi CHANGE_ME
	./scripts/gen-secrets.sh

preflight:       ## Kiểm tra host: sysctl, port, DNS, compose config
	./scripts/preflight.sh

pull:            ## Pull image theo version pin trong .env
	docker compose pull

up:              ## Start traefik + es + rabbitmq (đợi healthy)
	docker compose up -d --wait traefik es rabbitmq

bootstrap:       ## Tạo user/role/vhost/index (idempotent, chạy lại = rotate password)
	./scripts/rabbitmq-bootstrap.sh
	./scripts/es-init.sh

deploy: preflight pull up bootstrap  ## Full deploy: preflight -> up -> bootstrap -> es-writer
	docker compose up -d --wait --remove-orphans
	@echo "Deploy xong. Chạy 'make smoke' từ máy trong allowlist."

status:          ## Trạng thái container
	docker compose ps

logs:            ## Tail log (S=service để lọc)
	docker compose logs -f --tail=200 $(S)

smoke:           ## Kiểm tra HTTPS/AMQPS/cert/consumer end-to-end
	./scripts/smoke-test.sh

snapshot:        ## Snapshot index ES (KEEP=7)
	./scripts/es-snapshot.sh

down:            ## Dừng stack (giữ volume/data)
	docker compose down
