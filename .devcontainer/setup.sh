#!/usr/bin/env bash
# Dev container start-up (postCreateCommand): start BC on Linux, then give every AL project
# in the workspace a launch.json that points F5 at it.
#   BC_SETUP_ONLY_LAUNCH=1   write the launch.json files only (used for testing)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORKSPACE="${CODESPACE_VSCODE_FOLDER:-$PWD}"

write_launch() {
  local dir="$1" f="$1/.vscode/launch.json"
  if [ -e "$f" ]; then echo "[setup] $f exists, left as it is"; return; fi
  mkdir -p "$dir/.vscode"
  cat > "$f" <<'JSON'
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "BC on Linux",
            "type": "al",
            "request": "launch",
            "server": "http://localhost",
            "serverInstance": "BC",
            "port": 7049,
            "authentication": "UserPassword",
            "breakOnError": "All",
            "launchBrowser": false,
            "schemaUpdateMode": "ForceSync"
        }
    ]
}
JSON
  echo "[setup] wrote $f (sign in as BCRUNNER / Admin123!)"
}

# AL projects: the workspace folder itself or a folder up to two levels down that has an app.json.
while IFS= read -r app; do
  write_launch "$(dirname "$app")"
done < <(find "$WORKSPACE" -maxdepth 2 -name app.json -not -path '*/node_modules/*' -not -path '*/.alpackages/*' 2>/dev/null)

[ "${BC_SETUP_ONLY_LAUNCH:-}" = 1 ] && exit 0

# In a Codespace the browser reaches the web client through a forwarded https address, and the
# proxy rewrites Host and Origin: see docs/WEBCLIENT-POC.md. Outside a Codespace both stay empty.
export BC_WEBCLIENT_TRUST_FORWARDED_HEADERS=1
export BC_WEBCLIENT_PUBLIC_URL="${CODESPACE_NAME:+https://${CODESPACE_NAME}-8080.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}/}"
# BC installs its test framework (Test Runner, Library Assert, Library Variable Storage,
# Permissions Mock, Any, the test libraries) on a clean start only. Recreating just the BC
# container against an existing database loses them (the republish is refused as a duplicate),
# so start from nothing: a no-op in a new Codespace, and it makes running this script again safe.
docker compose down
docker compose up -d --wait
