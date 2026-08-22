#!/bin/bash

set -euo pipefail

error() {
  printf 'econ-mcp-launcher: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 2 ] || error 'expected SERVICE_ID and CODEX_ROOT'
SERVICE_ID=$1
CODEX_ROOT=$2
case "$CODEX_ROOT" in
  /*) ;;
  *) error 'CODEX_ROOT must be an absolute path' ;;
esac

SECRET_FILE="$CODEX_ROOT/secrets/econ-mcp.env"
SERVERS_ROOT="$CODEX_ROOT/mcp-servers/economic-data"
[ -r "$SECRET_FILE" ] || error 'local secret file is missing or unreadable'

# Parse only known KEY=VALUE records. Sourcing a credential file would execute it.
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in
    ALPHA_VANTAGE_API_KEY|BEA_API_KEY|BLS_API_KEY|CENSUS_API_KEY|COMTRADE_SUBSCRIPTION_KEY|DC_API_KEY|FINANCIAL_DATASETS_API_KEY|FRED_API_KEY|NASDAQ_DATA_LINK_API_KEY|SEC_EDGAR_USER_AGENT)
      export "${key}=${value}"
      ;;
  esac
done < "$SECRET_FILE"

export DATA360_API_BASE_URL="${DATA360_API_BASE_URL:-https://data360api.worldbank.org}"
export DATA360_CODELIST_API_BASE_URL="${DATA360_CODELIST_API_BASE_URL:-https://data360api.worldbank.org}"
export MCP_LOG_LEVEL="${MCP_LOG_LEVEL:-error}"
export MCP_TRANSPORT_TYPE=stdio

case "$SERVICE_ID" in
  econ_bls)
    exec node "$SERVERS_ROOT/mcp-bls/dist/index.js"
    ;;
  econ_ecb)
    exec node "$SERVERS_ROOT/ecb-mcp/dist/index.js"
    ;;
  econ_eurostat)
    exec uv --directory "$SERVERS_ROOT/eurostat-mcp" run --frozen server.py
    ;;
  econ_imf)
    exec uv --directory "$SERVERS_ROOT/imf-data-mcp" run --frozen imf-data-mcp
    ;;
  econ_oecd)
    exec node "$SERVERS_ROOT/oecd-mcp/dist/index.js"
    ;;
  econ_world_bank)
    exec uv --directory "$SERVERS_ROOT/world_bank_mcp_server" run --frozen world_bank_mcp_server
    ;;
  econ_world_bank_data360)
    exec uv --directory "$SERVERS_ROOT/data360-mcp" run --frozen fastmcp run \
      src/data360/server.py --transport stdio
    ;;
  econ_un_comtrade)
    exec npx -y '@cyanheads/un-comtrade-mcp-server@0.1.5'
    ;;
  econ_alpha_vantage)
    : "${ALPHA_VANTAGE_API_KEY:?ALPHA_VANTAGE_API_KEY is required}"
    exec uv --directory "$SERVERS_ROOT/alpha_vantage_mcp/mcp" run --frozen \
      marketdata-mcp-server "$ALPHA_VANTAGE_API_KEY"
    ;;
  econ_bea)
    : "${BEA_API_KEY:?BEA_API_KEY is required}"
    exec node "$SERVERS_ROOT/mcp-bea/dist/index.js"
    ;;
  econ_census)
    : "${CENSUS_API_KEY:?CENSUS_API_KEY is required}"
    CENSUS_DIR="$SERVERS_ROOT/us-census-bureau-data-api-mcp"
    (cd "$CENSUS_DIR" && CENSUS_API_KEY="$CENSUS_API_KEY" SEED_MODE=slim \
      docker compose -p codex-econ-census --profile prod up -d >/dev/null 2>&1)
    attempt=0
    while [ "$attempt" -lt 30 ]; do
      if docker exec mcp-server test -f /app/dist/index.js >/dev/null 2>&1; then
        exec docker exec -i -e CENSUS_API_KEY="$CENSUS_API_KEY" mcp-server node dist/index.js
      fi
      attempt=$((attempt + 1))
      sleep 1
    done
    error 'Census MCP container did not become ready'
    ;;
  econ_data_commons)
    : "${DC_API_KEY:?DC_API_KEY is required}"
    exec uv --directory "$SERVERS_ROOT/datacommons-agent-toolkit/packages/datacommons-mcp" \
      run --frozen datacommons-mcp serve stdio
    ;;
  econ_financial_datasets)
    : "${FINANCIAL_DATASETS_API_KEY:?FINANCIAL_DATASETS_API_KEY is required}"
    exec uv --directory "$SERVERS_ROOT/financial-datasets-mcp-server" run --frozen server.py
    ;;
  econ_fred)
    : "${FRED_API_KEY:?FRED_API_KEY is required}"
    exec node "$SERVERS_ROOT/fred-mcp-server/build/index.js"
    ;;
  econ_nasdaq_data_link)
    : "${NASDAQ_DATA_LINK_API_KEY:?NASDAQ_DATA_LINK_API_KEY is required}"
    export PYTHONPATH="$SERVERS_ROOT/nasdaq-data-link-mcp"
    exec uv --directory "$SERVERS_ROOT/nasdaq-data-link-mcp" run --frozen \
      python nasdaq_data_link_mcp_os/server.py
    ;;
  econ_sec_edgar)
    : "${SEC_EDGAR_USER_AGENT:?SEC_EDGAR_USER_AGENT is required}"
    exec uv --directory "$SERVERS_ROOT/sec-edgar-mcp" run --frozen sec-edgar-mcp
    ;;
  econ_tam)
    exec node "$SERVERS_ROOT/TAM-MCP-Server/dist/stdio-simple.js"
    ;;
  stata-mcp)
    exec uv --directory "$SERVERS_ROOT/mcp-for-stata" run --frozen stata-mcp
    ;;
  *)
    error "unknown service: $SERVICE_ID"
    ;;
esac
