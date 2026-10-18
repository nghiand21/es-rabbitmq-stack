#!/usr/bin/env bash
# Idempotent ES bootstrap: roles, users, index mappings.
# Talks to ES from INSIDE the es container (no published port needed).
# Secrets travel via `docker exec -e VAR` (env), never via argv.
source "$(dirname "$0")/lib.sh"
require docker jq
load_env

ES_AUTH="$(printf 'elastic:%s' "$ELASTIC_PASSWORD" | base64 -w0)"; export ES_AUTH

# es_api METHOD PATH [BODY_FILE|-]  -> prints body, returns 0 on 2xx, 1 otherwise
es_api() {
  local method="$1" path="$2" body="${3:-}" out code
  # shellcheck disable=SC2016  # expanded inside the container on purpose
  local args=(exec -T -e ES_AUTH es sh -c
    'curl -sS -o /dev/stdout -w "\n%{http_code}" -X "$0" -H "Authorization: Basic $ES_AUTH" -H "Content-Type: application/json" ${1:+--data-binary @-} "http://localhost:9200$2"'
    "$method" "${body:+1}" "$path")
  if [[ -n "$body" ]]; then out="$(dc "${args[@]}" < "$body")"; else out="$(dc "${args[@]}" </dev/null)"; fi
  code="${out##*$'\n'}"; printf '%s\n' "${out%$'\n'*}"
  [[ "$code" =~ ^2 ]]
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

info "waiting for ES health (yellow)"
for _ in $(seq 1 60); do es_api GET '/_cluster/health?wait_for_status=yellow&timeout=5s' >/dev/null 2>&1 && break; sleep 5; done
es_api GET '/_cluster/health' >/dev/null || die "ES not healthy"

# ---- Roles (least privilege) ----------------------------------------------
patterns_json="$(jq -cn --arg p "$ES_INDEX_PATTERNS" '$p|split(",")|map(gsub("^\\s+|\\s+$";""))')"
for role in es_writer es_app es_reader; do
  jq --argjson p "$patterns_json" '.indices[].names = $p' "elasticsearch/roles/${role}.json" > "$tmp/role.json"
  es_api PUT "/_security/role/${role}" "$tmp/role.json" >/dev/null || die "role ${role} failed"
  info "role ${role} applied (indices: ${ES_INDEX_PATTERNS})"
done

# ---- Users (create or reset password -> idempotent & rotatable) ------------
ensure_user() {
  local user="$1" pass="$2" role="$3"
  jq -n --arg pw "$pass" --arg r "$role" '{password:$pw, roles:[$r]}' > "$tmp/user.json"
  es_api PUT "/_security/user/${user}" "$tmp/user.json" >/dev/null || die "user ${user} failed"
  info "user ${user} -> role ${role}"
}
ensure_user "$ES_WRITER_USER" "$ES_WRITER_PASS" es_writer
ensure_user "$ES_APP_USER"    "$ES_APP_PASS"    es_app
ensure_user "$ES_READER_USER" "$ES_READER_PASS" es_reader
rm -f "$tmp/user.json"

# ---- Indices: create only if missing (mapping of existing index untouched) --
for f in elasticsearch/mappings/*.json; do
  idx="$(basename "$f" .json)"
  if es_api GET "/${idx}" >/dev/null 2>&1; then
    info "index ${idx} exists — skip (use PUT /${idx}/_mapping for additive changes)"
    continue
  fi
  jq --argjson r "${ES_REPLICAS:-0}" '.settings.index.number_of_replicas = $r' "$f" > "$tmp/idx.json"
  es_api PUT "/${idx}" "$tmp/idx.json" >/dev/null || die "create index ${idx} failed"
  info "index ${idx} created (replicas=${ES_REPLICAS:-0})"
done

# ---- Snapshot repository (fs) ----------------------------------------------
echo '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/snapshots","compress":true}}' > "$tmp/repo.json"
es_api PUT /_snapshot/local_fs "$tmp/repo.json" >/dev/null && info "snapshot repo local_fs registered"

info "ES bootstrap done"
