#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CODEX_ROOT="$HOME/.codex"
API_KEYS_FILE=""
SKIP_CENSUS_INIT=0
DRY_RUN=0
NON_INTERACTIVE=0
FAILURES=0

usage() {
  cat >&2 <<'EOF'
Usage: bash doctor-macos.sh [options]

  --api-keys-file PATH   Verify that the source key file is readable.
  --codex-root PATH      Codex home directory (default: $HOME/.codex).
  --skip-census-init     Skip live Docker/Census checks.
  --dry-run              Accepted for CLI parity; doctor is read-only.
  --non-interactive      Accepted for CLI parity; doctor never prompts.
  -h, --help             Show this help.
EOF
}

ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-keys-file)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      API_KEYS_FILE=$2
      shift 2
      ;;
    --codex-root)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      CODEX_ROOT=$2
      shift 2
      ;;
    --skip-census-init) SKIP_CENSUS_INIT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[ "$DRY_RUN" -eq 0 ] || :
[ "$NON_INTERACTIVE" -eq 0 ] || :

if [ "$(uname -s)" = 'Darwin' ]; then ok 'operating system is macOS'; else fail 'not running on macOS'; fi
for command_name in bash python3 git codex node npm npx uv uvx; do
  if command -v "$command_name" >/dev/null 2>&1; then ok "$command_name is available"; else fail "$command_name is unavailable"; fi
done
if command -v docker >/dev/null 2>&1; then
  ok 'docker is available'
elif [ "$SKIP_CENSUS_INIT" -eq 0 ]; then
  fail 'docker is unavailable'
else
  warn 'docker is unavailable; Census checks are skipped'
fi
if [ -n "$API_KEYS_FILE" ]; then
  if [ -r "$API_KEYS_FILE" ]; then ok 'API-key source file is readable (values hidden)'; else fail 'API-key source file is unreadable'; fi
fi

MANIFEST="$SCRIPT_DIR/manifests/mcps.lock.json"
if [ ! -f "$MANIFEST" ]; then
  fail 'manifest is missing'
elif python3 - "$MANIFEST" <<'PY' >/dev/null 2>&1
import json
import re
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
entries = data.get("mcps", data.get("servers", data.get("entries", [])))
ids = [entry.get("id", entry.get("name")) for entry in entries]
if len(ids) != 18 or len(set(ids)) != 18:
    raise SystemExit(1)
for entry in entries:
    source = entry.get("source", {})
    kind = source.get("type", source.get("kind"))
    if kind == "git":
        commit = source.get("commit", source.get("resolved_commit"))
        if not re.fullmatch(r"[0-9a-fA-F]{40}", str(commit or "")):
            raise SystemExit(1)
    elif kind == "npm":
        if not re.search(r"@\d", source.get("package_spec", "")):
            raise SystemExit(1)
    else:
        raise SystemExit(1)
PY
then
  ok 'manifest has 18 fully locked MCP entries'
else
  fail 'manifest lock metadata is invalid'
fi

SECRET_FILE="$CODEX_ROOT/secrets/econ-mcp.env"
SECRET_READY=0
if [ -f "$SECRET_FILE" ]; then
  mode=$(stat -f '%Lp' "$SECRET_FILE" 2>/dev/null || printf 'unknown')
  if [ "$mode" = '600' ]; then ok 'secret file has mode 600'; SECRET_READY=1; else fail "secret file mode is $mode, expected 600"; fi
else
  fail 'local secret file is missing'
fi

secret_present() {
  wanted=$1
  [ "$SECRET_READY" -eq 1 ] || return 1
  while IFS='=' read -r key value || [ -n "$key" ]; do
    if [ "$key" = "$wanted" ] && [ -n "$value" ]; then return 0; fi
  done < "$SECRET_FILE"
  return 1
}

for key_name in ALPHA_VANTAGE_API_KEY BEA_API_KEY CENSUS_API_KEY DC_API_KEY FRED_API_KEY SEC_EDGAR_USER_AGENT; do
  if secret_present "$key_name"; then ok "$key_name is present (value hidden)"; else fail "$key_name is missing"; fi
done
for key_name in BLS_API_KEY COMTRADE_SUBSCRIPTION_KEY FINANCIAL_DATASETS_API_KEY NASDAQ_DATA_LINK_API_KEY; do
  if secret_present "$key_name"; then ok "$key_name is present (value hidden)"; else warn "$key_name is absent"; fi
done

SERVERS_ROOT="$CODEX_ROOT/mcp-servers/economic-data"
check_artifact() {
  service_id=$1
  relative_path=$2
  if [ -e "$SERVERS_ROOT/$relative_path" ]; then ok "$service_id artifact exists"; else fail "$service_id artifact is missing"; fi
}
check_artifact econ_bls 'mcp-bls/dist/index.js'
check_artifact econ_ecb 'ecb-mcp/dist/index.js'
check_artifact econ_eurostat 'eurostat-mcp/.venv'
check_artifact econ_imf 'imf-data-mcp/.venv'
check_artifact econ_oecd 'oecd-mcp/dist/index.js'
check_artifact econ_world_bank 'world_bank_mcp_server/.venv'
check_artifact econ_world_bank_data360 'data360-mcp/.venv'
check_artifact econ_alpha_vantage 'alpha_vantage_mcp/.git'
check_artifact econ_bea 'mcp-bea/dist/index.js'
check_artifact econ_census 'us-census-bureau-data-api-mcp/docker-compose.yml'
check_artifact econ_data_commons 'datacommons-agent-toolkit/packages/datacommons-mcp/.venv'
check_artifact econ_financial_datasets 'financial-datasets-mcp-server/.venv'
check_artifact econ_fred 'fred-mcp-server/build/index.js'
check_artifact econ_nasdaq_data_link 'nasdaq-data-link-mcp/.venv'
check_artifact econ_sec_edgar 'sec-edgar-mcp/.venv'
check_artifact econ_tam 'TAM-MCP-Server/dist/stdio-simple.js'
check_artifact stata-mcp 'mcp-for-stata/.venv'
if [ -d "$SERVERS_ROOT/mcp-for-stata/.venv" ] &&
  uv --directory "$SERVERS_ROOT/mcp-for-stata" run --frozen \
    stata-mcp doctor --check stata_cli --json >/dev/null 2>&1
then
  ok 'stata-mcp can locate Stata'
else
  fail 'stata-mcp cannot locate Stata; set STATA_CLI or ~/.statamcp/config.toml'
fi
if command -v npx >/dev/null 2>&1; then ok 'econ_un_comtrade fixed-package runtime is available'; else fail 'econ_un_comtrade requires npx'; fi
if [ -x "$CODEX_ROOT/launchers/econ-mcp-launcher.sh" ]; then ok 'installed launcher is executable'; else fail 'installed launcher is missing or not executable'; fi

registration_expected() {
  case "$1" in
    econ_financial_datasets) secret_present FINANCIAL_DATASETS_API_KEY ;;
    econ_nasdaq_data_link) secret_present NASDAQ_DATA_LINK_API_KEY ;;
    *) return 0 ;;
  esac
}
for service_id in \
  econ_bls econ_ecb econ_eurostat econ_imf econ_oecd econ_world_bank \
  econ_world_bank_data360 econ_un_comtrade econ_alpha_vantage econ_bea \
  econ_census econ_data_commons econ_financial_datasets econ_fred \
  econ_nasdaq_data_link econ_sec_edgar econ_tam stata-mcp
do
  if codex mcp get "$service_id" >/dev/null 2>&1; then
    if registration_expected "$service_id"; then ok "$service_id is registered"; else fail "$service_id is registered without its optional key"; fi
  else
    if registration_expected "$service_id"; then fail "$service_id is not registered"; else ok "$service_id is intentionally unregistered"; fi
  fi
done

if [ "$SKIP_CENSUS_INIT" -eq 0 ] && command -v docker >/dev/null 2>&1; then
  CENSUS_DIR="$SERVERS_ROOT/us-census-bureau-data-api-mcp"
  if ! docker info >/dev/null 2>&1; then
    fail 'Docker daemon is not running'
  elif [ -f "$CENSUS_DIR/docker-compose.yml" ] && \
       (cd "$CENSUS_DIR" && docker compose -p codex-econ-census --profile prod ps -q census-mcp-db 2>/dev/null | grep -q .); then
    ok 'Census PostgreSQL container exists'
    geography_count=$(cd "$CENSUS_DIR" && docker compose -p codex-econ-census --profile prod exec -T census-mcp-db \
      psql -U mcp_user -d mcp_db -tAc 'select count(*) from geographies' 2>/dev/null | tr -d '[:space:]' || printf '0')
    case "$geography_count" in ''|*[!0-9]*) geography_count=0 ;; esac
    if [ "$geography_count" -ge 3313 ]; then ok 'Census slim geography seed is complete'; else fail 'Census geography seed is incomplete'; fi
  else
    fail 'Census PostgreSQL container is unavailable'
  fi
  if docker exec mcp-server test -f /app/dist/index.js >/dev/null 2>&1; then ok 'Census MCP container is ready'; else fail 'Census MCP container is not ready'; fi
fi

if [ "$FAILURES" -gt 0 ]; then
  printf 'Doctor found %s problem(s). No secret values were displayed.\n' "$FAILURES" >&2
  exit 1
fi
printf 'Doctor passed. No secret values were displayed.\n'
