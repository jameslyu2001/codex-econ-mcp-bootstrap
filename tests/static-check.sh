#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALLER="$REPO_ROOT/install-macos.sh"
DOCTOR="$REPO_ROOT/doctor-macos.sh"
LAUNCHER="$REPO_ROOT/launchers/econ-mcp-launcher.sh"
STATIC_TEST="$REPO_ROOT/tests/static-check.sh"
PATCH_FILE="$REPO_ROOT/patches/census-api-key.patch"
MANIFEST="$REPO_ROOT/manifests/mcps.lock.json"

fail() {
  printf 'static-check: FAIL: %s\n' "$*" >&2
  exit 1
}

for file in "$INSTALLER" "$DOCTOR" "$LAUNCHER" "$STATIC_TEST"; do
  [ -f "$file" ] || fail "missing file: $file"
  bash -n "$file" || fail "Bash syntax error: $file"
done

python3 - "$INSTALLER" "$DOCTOR" "$LAUNCHER" "$STATIC_TEST" "$PATCH_FILE" "$MANIFEST" <<'PY'
import json
import re
import sys
from pathlib import Path

paths = [Path(value) for value in sys.argv[1:]]
texts = {path.name: path.read_text(encoding="utf-8") for path in paths}
for path in paths[:4]:
    data = path.read_bytes()
    if b"\r\n" in data:
        raise SystemExit("CRLF line endings are forbidden: %s" % path)
    if not data.startswith(b"#!/bin/bash\n"):
        raise SystemExit("missing Bash shebang: %s" % path)

installer = texts["install-macos.sh"]
doctor = texts["doctor-macos.sh"]
launcher = texts["econ-mcp-launcher.sh"]
patch_text = texts["census-api-key.patch"]
manifest = json.loads(texts["mcps.lock.json"])
for option in ("--api-keys-file", "--codex-root", "--skip-census-init", "--dry-run", "--non-interactive"):
    if option not in installer or option not in doctor:
        raise SystemExit("missing CLI option: %s" % option)

markers = (
    "python3 - \"$MANIFEST\"", "git clone", "checkout --quiet --detach",
    "rev-parse HEAD", "npm cache add", "chmod 600", "export CODEX_HOME",
    "codex mcp remove", "codex mcp add", "econ-mcp.env",
    "$CODEX_ROOT/backups/config/config.toml",
    "$CODEX_ROOT/launchers/econ-mcp-launcher.sh", "FINANCIAL_DATASETS_API_KEY",
    "NASDAQ_DATA_LINK_API_KEY", "SEED_MODE=slim",
    "npm run migrate:up && npm run seed", "git -C \"$project\" apply --check",
)
for marker in markers:
    if marker not in installer:
        raise SystemExit("installer marker missing: %s" % marker)
for marker in ("urlObj.searchParams.set('key', apiKey)", "safeUrl.searchParams.set('key', '***')"):
    if marker not in patch_text:
        raise SystemExit("Census patch marker missing: %s" % marker)

expected = {
    "econ_bls", "econ_ecb", "econ_eurostat", "econ_imf", "econ_oecd",
    "econ_world_bank", "econ_world_bank_data360", "econ_un_comtrade",
    "econ_alpha_vantage", "econ_bea", "econ_census", "econ_data_commons",
    "econ_financial_datasets", "econ_fred", "econ_nasdaq_data_link",
    "econ_sec_edgar", "econ_tam", "stata-mcp",
}
entries = manifest.get("mcps", [])
if len(entries) != 18 or {entry.get("id") for entry in entries} != expected:
    raise SystemExit("manifest does not contain the expected 18 MCP ids")
stata = next(entry for entry in entries if entry.get("id") == "stata-mcp")
if stata.get("source", {}).get("url") != "https://github.com/SepineTam/mcp-for-stata.git":
    raise SystemExit("stata-mcp source URL is unexpected")
if stata.get("source", {}).get("commit") != "e5b25dc90058001c942fb7ef851637c9f5728486":
    raise SystemExit("stata-mcp commit differs from the reviewed lock")
if stata.get("source", {}).get("upstream_version") != "1.22.0":
    raise SystemExit("stata-mcp upstream version is invalid")
for platform in ("windows", "macos"):
    if "--frozen" not in stata.get("runtime", {}).get(platform, {}).get("args", []):
        raise SystemExit("stata-mcp %s runtime is not frozen" % platform)
case_ids = set(re.findall(r"^  ((?:econ_[a-z0-9_]+)|stata-mcp)\)\s*$", launcher, re.M))
if case_ids != expected:
    raise SystemExit("launcher ids differ: missing=%s extra=%s" % (sorted(expected-case_ids), sorted(case_ids-expected)))
if len(re.findall(r"^\s+exec\s", launcher, re.M)) < 18:
    raise SystemExit("launcher lacks 18 exec paths")
if re.search(r"(^|\n)\s*set\s+[^\n]*x", installer + "\n" + launcher):
    raise SystemExit("shell xtrace must never be enabled")
if re.search(r"(^|\n)\s*(echo|printf)\b(?![^\n]*>&2)", launcher):
    raise SystemExit("launcher contains a possible stdout log")
if "source \"$SECRET_FILE\"" in launcher or ". \"$SECRET_FILE\"" in launcher:
    raise SystemExit("launcher must parse rather than source its secret file")
if "cat \"$SECRET_FILE\"" in doctor or "printenv" in doctor or "env |" in doctor:
    raise SystemExit("doctor contains a secret-display hazard")
if "No secret values were displayed" not in doctor:
    raise SystemExit("doctor lacks an explicit no-secret-output guarantee")
if "docker compose -p codex-econ-census" not in launcher:
    raise SystemExit("launcher lacks fixed Census Compose project naming")
for name, text in texts.items():
    if re.search(r"(?i)(api[_ -]?key|token|secret)\s*[:=]\s*['\"][A-Za-z0-9_-]{20,}", text):
        raise SystemExit("possible hard-coded secret in %s" % name)
PY

printf 'static-check: PASS (Bash syntax, 18 launch targets, secret safety, Census patching)\n'
