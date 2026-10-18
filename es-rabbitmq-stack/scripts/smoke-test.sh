#!/usr/bin/env bash
# End-to-end checks from the host through the public TLS endpoints.
# shellcheck disable=SC2015  # ok() always returns 0
source "$(dirname "$0")/lib.sh"
require curl openssl jq
load_env
fail=0
ok()  { info "PASS $*"; }
bad() { log error "FAIL $*"; fail=1; }

cert_check() {   # host port
  local end days
  end="$(echo | openssl s_client -connect "$1:$2" -servername "$1" -verify_return_error 2>/dev/null \
         | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)" || true
  [[ -n "$end" ]] || { bad "TLS $1:$2 — no valid certificate (staging CA? DNS? allowlist?)"; return; }
  days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  (( days > 14 )) && ok "TLS $1:$2 valid, expires in ${days}d" || bad "TLS $1:$2 expires in ${days}d (renew broken?)"
}
cert_check "$ES_DOMAIN" 443
cert_check "$RMQ_DOMAIN" 443
cert_check "$RMQ_DOMAIN" 5671

# netrc via process substitution: creds never appear in argv
code="$(curl -sS -o /dev/null -w '%{http_code}' --netrc-file <(printf 'machine %s login %s password %s\n' "$ES_DOMAIN" "$ES_READER_USER" "$ES_READER_PASS") "https://$ES_DOMAIN/_cluster/health")"
[[ "$code" == 200 ]] && ok "ES auth via https://$ES_DOMAIN (es_reader)" || bad "ES https returned $code"

code="$(curl -sS -o /dev/null -w '%{http_code}' "https://$ES_DOMAIN/")"
[[ "$code" == 401 ]] && ok "ES rejects anonymous (401)" || bad "ES anonymous returned $code (expected 401)"

code="$(curl -sS -o /dev/null -w '%{http_code}' "http://$ES_DOMAIN/")"
[[ "$code" =~ ^30[178]$ ]] && ok "HTTP -> HTTPS redirect" || bad "HTTP redirect returned $code"

q="$(curl -fsS --netrc-file <(printf 'machine %s login %s password %s\n' "$RMQ_DOMAIN" "$RMQ_ADMIN_USER" "$RMQ_ADMIN_PASS") \
      "https://$RMQ_DOMAIN/api/queues/$(jq -rn --arg v "$RMQ_VHOST" '$v|@uri')" || echo '[]')"
consumers="$(jq '[.[].consumers] | add // 0' <<<"$q")"
(( consumers >= ES_WRITER_REPLICAS )) && ok "RabbitMQ consumers=$consumers (expected >= $ES_WRITER_REPLICAS)" \
  || bad "RabbitMQ consumers=$consumers (expected >= $ES_WRITER_REPLICAS) — check: docker compose logs es-writer"

exit "$fail"
