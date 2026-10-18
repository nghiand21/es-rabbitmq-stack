#!/usr/bin/env bash
# Replace every `KEY=CHANGE_ME` in .env with a random 32-char alphanumeric secret.
# Alphanumeric only -> safe inside AMQP URLs and basic-auth without escaping.
source "$(dirname "$0")/lib.sh"
require openssl
[[ -f .env ]] || { cp .env.example .env; info "created .env from .env.example"; }
chmod 600 .env
count=0
while grep -qE '^[A-Z_]+=CHANGE_ME' .env; do
  secret="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  sed -i -E "0,/^([A-Z_]+)=CHANGE_ME/s//\1=${secret}/" .env
  count=$((count + 1))
done
info "generated ${count} secrets in .env (mode 600). Store them in Vault/AWX credential, not in git."
