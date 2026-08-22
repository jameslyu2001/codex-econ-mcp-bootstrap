#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST="$SCRIPT_DIR/manifests/mcps.lock.json"
API_KEYS_FILE=""
CODEX_ROOT="$HOME/.codex"
SKIP_CENSUS_INIT=0
DRY_RUN=0
NON_INTERACTIVE=0
WORK_DIR=""
SECRET_TMP=""
SECRET_VALUE=""

usage() {
  cat >&2 <<'EOF'
Usage: bash install-macos.sh [options]

  --api-keys-file PATH   Read KEY=VALUE or friendly "Label: value" records.
  --codex-root PATH      Codex home directory (default: $HOME/.codex).
  --skip-census-init     Skip the Docker build, migration, and slim seed.
  --dry-run              Validate and describe actions without persistent changes.
  --non-interactive      Never prompt for missing required values.
  -h, --help             Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

cleanup() {
  if [ -n "$SECRET_TMP" ] && [ -f "$SECRET_TMP" ]; then
    rm -f -- "$SECRET_TMP"
  fi
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-keys-file)
      [ "$#" -ge 2 ] || die '--api-keys-file requires a path'
      API_KEYS_FILE=$2
      shift 2
      ;;
    --codex-root)
      [ "$#" -ge 2 ] || die '--codex-root requires a path'
      CODEX_ROOT=$2
      shift 2
      ;;
    --skip-census-init)
      SKIP_CENSUS_INIT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown option: $1"
      ;;
  esac
done

[ "$(uname -s)" = 'Darwin' ] || die 'install-macos.sh must run on macOS'
case "$CODEX_ROOT" in
  /*) ;;
  *) die '--codex-root must be an absolute path' ;;
esac
export CODEX_HOME="$CODEX_ROOT"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
if [ -n "$API_KEYS_FILE" ] && [ ! -r "$API_KEYS_FILE" ]; then
  die "API keys file is not readable: $API_KEYS_FILE"
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for command_name in python3 git codex node npm npx uv uvx; do
  require_command "$command_name"
done
if [ "$SKIP_CENSUS_INIT" -eq 0 ]; then
  require_command docker
  docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 is required'
fi

BASH_MAJOR=${BASH_VERSION%%.*}
case "$BASH_MAJOR" in
  ''|*[!0-9]*) die 'unable to determine Bash version' ;;
  *) [ "$BASH_MAJOR" -ge 3 ] || die 'Bash 3.2 or newer is required' ;;
esac
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')
case "$NODE_MAJOR" in
  ''|*[!0-9]*) die 'unable to determine Node.js version' ;;
  *) [ "$NODE_MAJOR" -ge 18 ] || die 'Node.js 18 or newer is required' ;;
esac

umask 077
if [ "$DRY_RUN" -eq 1 ]; then
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-econ-mcp.XXXXXX")
else
  mkdir -p -- "$CODEX_ROOT/.staging" "$CODEX_ROOT/secrets" \
    "$CODEX_ROOT/mcp-servers/economic-data" "$CODEX_ROOT/backups/economic-data"
  chmod 700 -- "$CODEX_ROOT/secrets"
  WORK_DIR=$(mktemp -d "$CODEX_ROOT/.staging/econ-mcp.XXXXXX")
fi

NORMALIZED_MANIFEST="$WORK_DIR/mcps.tsv"
python3 - "$MANIFEST" "$NORMALIZED_MANIFEST" <<'PY'
import json
import re
import sys
from pathlib import Path

expected = {
    "econ_bls", "econ_ecb", "econ_eurostat", "econ_imf", "econ_oecd",
    "econ_world_bank", "econ_world_bank_data360", "econ_un_comtrade",
    "econ_alpha_vantage", "econ_bea", "econ_census", "econ_data_commons",
    "econ_financial_datasets", "econ_fred", "econ_nasdaq_data_link",
    "econ_sec_edgar", "econ_tam",
}
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
entries = data if isinstance(data, list) else data.get("mcps", data.get("servers", data.get("entries", [])))
if not isinstance(entries, list):
    raise SystemExit("manifest must contain an mcps/servers/entries list")

def text(value):
    return "" if value is None else str(value).strip()

rows = []
seen = set()
for entry in entries:
    if not isinstance(entry, dict):
        raise SystemExit("manifest entries must be objects")
    source = entry.get("source") if isinstance(entry.get("source"), dict) else {}
    service_id = text(entry.get("id", entry.get("name"))).lower()
    source_type = text(source.get("type", source.get("kind", "git"))).lower()
    source_url = text(source.get("url", entry.get("source_url")))
    commit = text(source.get("commit", source.get("resolved_commit", entry.get("commit")))).lower()
    directory = text(source.get("checkout_dir", source.get("local_directory", entry.get("local_directory"))))
    package_spec = text(source.get("package_spec", entry.get("package_spec")))
    if service_id not in expected or service_id in seen:
        raise SystemExit("unknown or duplicate MCP id: %s" % service_id)
    if not source_url.startswith("https://github.com/"):
        raise SystemExit("%s must use an HTTPS GitHub source" % service_id)
    if source_type == "git":
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise SystemExit("%s is not pinned to a full commit" % service_id)
        if not directory or directory in (".", "..") or "/" in directory or "\\" in directory:
            raise SystemExit("%s has an unsafe checkout directory" % service_id)
        package_spec = ""
    elif source_type == "npm":
        if not package_spec or package_spec.endswith("@latest") or not re.search(r"@\d", package_spec):
            raise SystemExit("%s must use an exact npm package version" % service_id)
        commit = ""
        directory = ""
    else:
        raise SystemExit("unsupported source type for %s: %s" % (service_id, source_type))
    values = (service_id, source_type, source_url, commit, directory, package_spec)
    if any("\t" in value or "\n" in value or "\r" in value for value in values):
        raise SystemExit("manifest fields cannot contain tabs or newlines")
    seen.add(service_id)
    rows.append((service_id, source_type, source_url, commit or "-", directory or "-", package_spec or "-"))

if seen != expected or len(rows) != 17:
    raise SystemExit("manifest must contain exactly the expected 17 MCP ids")
with Path(sys.argv[2]).open("w", encoding="utf-8", newline="\n") as handle:
    for row in rows:
        handle.write("\t".join(row) + "\n")
PY

SECRET_FILE="$CODEX_ROOT/secrets/econ-mcp.env"
MERGED_SECRETS="$WORK_DIR/econ-mcp.env"
python3 - "$SECRET_FILE" "$API_KEYS_FILE" "$MERGED_SECRETS" <<'PY'
import os
import re
import sys
from pathlib import Path

allowed = {
    "ALPHA_VANTAGE_API_KEY", "BEA_API_KEY", "BLS_API_KEY", "CENSUS_API_KEY",
    "COMTRADE_SUBSCRIPTION_KEY", "DC_API_KEY", "FINANCIAL_DATASETS_API_KEY",
    "FRED_API_KEY", "NASDAQ_DATA_LINK_API_KEY", "SEC_EDGAR_USER_AGENT",
}
aliases = {
    "ALPHA_VANTAGE": "ALPHA_VANTAGE_API_KEY",
    "BEA": "BEA_API_KEY",
    "BLS": "BLS_API_KEY",
    "CENSUS": "CENSUS_API_KEY",
    "OPEN_CENSUS_MCP_SERVER": "CENSUS_API_KEY",
    "COMTRADE": "COMTRADE_SUBSCRIPTION_KEY",
    "UN_COMTRADE": "COMTRADE_SUBSCRIPTION_KEY",
    "DATA_COMMONS": "DC_API_KEY",
    "FINANCIAL_DATASETS": "FINANCIAL_DATASETS_API_KEY",
    "FRED": "FRED_API_KEY",
    "NASDAQ_DATA_LINK": "NASDAQ_DATA_LINK_API_KEY",
    "SEC_EDGAR_USER_AGENT": "SEC_EDGAR_USER_AGENT",
}

def normalized(label):
    return re.sub(r"_+", "_", re.sub(r"[^A-Za-z0-9]+", "_", label)).strip("_").upper()

def resolve(label):
    key = normalized(label)
    if key in allowed:
        return key
    for alias in sorted(aliases, key=len, reverse=True):
        if alias in key:
            return aliases[alias]
    return None

def load(path, exact=False):
    values = {}
    if path is None or not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        separator = "=" if "=" in line else (":" if ":" in line else None)
        if separator is None:
            continue
        label, value = line.split(separator, 1)
        key = normalized(label) if exact else resolve(label)
        if key not in allowed:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        if value and all(character not in value for character in "\x00\r\n"):
            values[key] = value
    return values

existing = Path(sys.argv[1])
incoming = Path(sys.argv[2]) if sys.argv[2] else None
values = load(existing, exact=True)
values.update(load(incoming, exact=False))
fd = os.open(sys.argv[3], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
    for key in sorted(values):
        handle.write("%s=%s\n" % (key, values[key]))
PY
chmod 600 -- "$MERGED_SECRETS"

secret_get() {
  wanted=$1
  SECRET_VALUE=""
  while IFS='=' read -r key value || [ -n "$key" ]; do
    if [ "$key" = "$wanted" ]; then
      SECRET_VALUE=$value
      return 0
    fi
  done < "$MERGED_SECRETS"
  return 1
}

prompt_secret() {
  key=$1
  value=""
  printf 'Enter %s (input hidden): ' "$key" >&2
  IFS= read -r -s value
  printf '\n' >&2
  [ -n "$value" ] || return 1
  printf '%s=%s\n' "$key" "$value" >> "$MERGED_SECRETS"
  chmod 600 -- "$MERGED_SECRETS"
}

MISSING_REQUIRED=""
for required_key in ALPHA_VANTAGE_API_KEY BEA_API_KEY BLS_API_KEY CENSUS_API_KEY COMTRADE_SUBSCRIPTION_KEY DC_API_KEY FRED_API_KEY SEC_EDGAR_USER_AGENT; do
  if ! secret_get "$required_key"; then
    if [ "$DRY_RUN" -eq 0 ] && [ "$NON_INTERACTIVE" -eq 0 ] && [ -t 0 ] && prompt_secret "$required_key"; then
      :
    else
      MISSING_REQUIRED="$MISSING_REQUIRED $required_key"
    fi
  fi
done
if [ -n "$MISSING_REQUIRED" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    note "Dry run: missing required local values:$MISSING_REQUIRED"
  else
    die "missing required local values:$MISSING_REQUIRED"
  fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
  SECRET_TMP=$(mktemp "$CODEX_ROOT/secrets/.econ-mcp.env.XXXXXX")
  cp -- "$MERGED_SECRETS" "$SECRET_TMP"
  chmod 600 -- "$SECRET_TMP"
  mv -f -- "$SECRET_TMP" "$SECRET_FILE"
  SECRET_TMP=""
fi

node_build() {
  project=$1
  if [ -f "$project/package-lock.json" ] || [ -f "$project/npm-shrinkwrap.json" ]; then
    (cd "$project" && npm ci --no-audit --no-fund)
  else
    (cd "$project" && npm install --no-audit --no-fund)
  fi
  (cd "$project" && npm run build)
}

uv_sync() {
  project=$1
  if [ -f "$project/uv.lock" ]; then
    uv --directory "$project" sync --frozen
  else
    uv --directory "$project" sync
  fi
}

patch_census() {
  project=$1
  patch_file="$SCRIPT_DIR/patches/census-api-key.patch"
  [ -f "$patch_file" ] || die "Census patch not found: $patch_file"
  if git -C "$project" apply --check -- "$patch_file" >/dev/null 2>&1; then
    git -C "$project" apply -- "$patch_file"
  elif git -C "$project" apply --reverse --check -- "$patch_file" >/dev/null 2>&1; then
    :
  else
    die 'Census patch is neither applicable nor already applied'
  fi
}

build_service() {
  service_id=$1
  project=$2
  case "$service_id" in
    econ_bls|econ_ecb|econ_oecd|econ_bea|econ_fred|econ_tam)
      node_build "$project"
      ;;
    econ_data_commons)
      uv_sync "$project/packages/datacommons-mcp"
      ;;
    econ_eurostat|econ_imf|econ_world_bank|econ_world_bank_data360|econ_alpha_vantage|econ_financial_datasets|econ_nasdaq_data_link|econ_sec_edgar)
      uv_sync "$project"
      ;;
    econ_census)
      patch_census "$project"
      ;;
    *) die "no build recipe for $service_id" ;;
  esac
}

install_git_service() {
  service_id=$1
  source_url=$2
  commit=$3
  directory=$4
  target="$CODEX_ROOT/mcp-servers/economic-data/$directory"

  if [ "$DRY_RUN" -eq 1 ]; then
    note "Dry run: clone $service_id at $commit, build, and install to $target"
    return 0
  fi

  if [ -d "$target/.git" ]; then
    current_commit=$(git -C "$target" rev-parse HEAD 2>/dev/null || printf '')
    current_origin=$(git -C "$target" remote get-url origin 2>/dev/null || printf '')
    if [ "$current_commit" = "$commit" ] && [ "$current_origin" = "$source_url" ]; then
      note "Rebuilding pinned $service_id"
      build_service "$service_id" "$target"
      return 0
    fi
  fi

  stage="$WORK_DIR/$directory"
  note "Installing pinned $service_id ($commit)"
  git clone --quiet --filter=blob:none --no-checkout "$source_url" "$stage"
  git -C "$stage" fetch --quiet --depth 1 origin "$commit"
  git -C "$stage" checkout --quiet --detach "$commit"
  actual_commit=$(git -C "$stage" rev-parse HEAD)
  [ "$actual_commit" = "$commit" ] || die "$service_id checkout does not match its resolved commit"
  build_service "$service_id" "$stage"
  if [ -e "$target" ]; then
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    backup="$CODEX_ROOT/backups/economic-data/${directory}.${stamp}.$$"
    note "Preserving previous $service_id installation at $backup"
    mv -- "$target" "$backup"
  fi
  mv -- "$stage" "$target"
}

install_npm_service() {
  service_id=$1
  package_spec=$2
  if [ "$DRY_RUN" -eq 1 ]; then
    note "Dry run: cache fixed npm package $package_spec for $service_id"
  else
    note "Caching fixed npm package $package_spec for $service_id"
    npm cache add "$package_spec" >/dev/null
  fi
}

TAB=$(printf '\t')
CENSUS_DIR=""
while IFS="$TAB" read -r service_id source_type source_url commit directory package_spec || [ -n "$service_id" ]; do
  [ "$commit" = '-' ] && commit=""
  [ "$directory" = '-' ] && directory=""
  [ "$package_spec" = '-' ] && package_spec=""
  if [ "$source_type" = 'git' ]; then
    install_git_service "$service_id" "$source_url" "$commit" "$directory"
  else
    install_npm_service "$service_id" "$package_spec"
  fi
  if [ "$service_id" = 'econ_census' ]; then
    CENSUS_DIR="$CODEX_ROOT/mcp-servers/economic-data/$directory"
  fi
done < "$NORMALIZED_MANIFEST"

SEED_MARKER="$CODEX_ROOT/mcp-servers/economic-data/.census-slim-seeded"
if [ "$SKIP_CENSUS_INIT" -eq 0 ] && [ -f "$SEED_MARKER" ]; then
  note 'Census slim database is already initialized.'
elif [ "$SKIP_CENSUS_INIT" -eq 0 ]; then
  [ -n "$CENSUS_DIR" ] || die 'Census entry is missing'
  if [ "$DRY_RUN" -eq 1 ]; then
    note 'Dry run: build Census containers, migrate, slim-seed, and start services'
  else
    secret_get CENSUS_API_KEY || die 'CENSUS_API_KEY is required for Census initialization'
    CENSUS_KEY=$SECRET_VALUE
    note 'Initializing the Census MCP database with SEED_MODE=slim'
    (
      cd "$CENSUS_DIR"
      CENSUS_API_KEY="$CENSUS_KEY" SEED_MODE=slim docker compose -p codex-econ-census --profile prod build
      CENSUS_API_KEY="$CENSUS_KEY" SEED_MODE=slim docker compose -p codex-econ-census --profile prod run --rm \
        -e SEED_MODE=slim -e CENSUS_API_KEY census-mcp-db-init sh -c 'npm run migrate:up && npm run seed'
      CENSUS_API_KEY="$CENSUS_KEY" SEED_MODE=slim docker compose -p codex-econ-census --profile prod up -d
    )
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$SEED_MARKER"
    chmod 600 -- "$SEED_MARKER"
    unset CENSUS_KEY SECRET_VALUE
  fi
fi

SOURCE_LAUNCHER="$SCRIPT_DIR/launchers/econ-mcp-launcher.sh"
LAUNCHER="$CODEX_ROOT/launchers/econ-mcp-launcher.sh"
[ -f "$SOURCE_LAUNCHER" ] || die "launcher not found: $SOURCE_LAUNCHER"
if [ "$DRY_RUN" -eq 1 ]; then
  note "Dry run: install launcher at $LAUNCHER"
else
  mkdir -p -- "$CODEX_ROOT/launchers"
  LAUNCHER_TMP=$(mktemp "$CODEX_ROOT/launchers/.econ-mcp-launcher.sh.XXXXXX")
  cp -- "$SOURCE_LAUNCHER" "$LAUNCHER_TMP"
  chmod 755 -- "$LAUNCHER_TMP"
  mv -f -- "$LAUNCHER_TMP" "$LAUNCHER"
fi

register_service() {
  service_id=$1
  if [ "$DRY_RUN" -eq 1 ]; then
    note "Dry run: codex mcp remove/add $service_id"
    return 0
  fi
  codex mcp remove "$service_id" >/dev/null 2>&1 || true
  codex mcp add "$service_id" -- "$LAUNCHER" "$service_id" "$CODEX_ROOT" >/dev/null
  note "Registered $service_id"
}

backup_codex_config() {
  config="$CODEX_ROOT/config.toml"
  [ -f "$config" ] || return 0
  stamp=$(date -u '+%Y%m%d-%H%M%S')
  backup="$CODEX_ROOT/backups/config/config.toml.$stamp.$$.bak"
  if [ "$DRY_RUN" -eq 1 ]; then
    note "Dry run: back up existing Codex config to $backup"
    return 0
  fi
  mkdir -p -- "$CODEX_ROOT/backups/config"
  cp -p -- "$config" "$backup"
  chmod 600 -- "$backup"
  note "Backed up existing Codex config to $backup"
}

backup_codex_config

while IFS="$TAB" read -r service_id source_type source_url commit directory package_spec || [ -n "$service_id" ]; do
  case "$service_id" in
    econ_financial_datasets)
      if secret_get FINANCIAL_DATASETS_API_KEY; then
        register_service "$service_id"
      else
        if [ "$DRY_RUN" -eq 0 ]; then codex mcp remove "$service_id" >/dev/null 2>&1 || true; fi
        note 'Skipped econ_financial_datasets: FINANCIAL_DATASETS_API_KEY is absent'
      fi
      ;;
    econ_nasdaq_data_link)
      if secret_get NASDAQ_DATA_LINK_API_KEY; then
        register_service "$service_id"
      else
        if [ "$DRY_RUN" -eq 0 ]; then codex mcp remove "$service_id" >/dev/null 2>&1 || true; fi
        note 'Skipped econ_nasdaq_data_link: NASDAQ_DATA_LINK_API_KEY is absent'
      fi
      ;;
    *) register_service "$service_id" ;;
  esac
done < "$NORMALIZED_MANIFEST"

if [ "$DRY_RUN" -eq 1 ]; then
  note 'Dry run completed; no persistent state was changed.'
else
  mode=$(stat -f '%Lp' "$SECRET_FILE")
  [ "$mode" = '600' ] || die "secret file mode is $mode, expected 600"
  note 'macOS MCP installation completed.'
fi
