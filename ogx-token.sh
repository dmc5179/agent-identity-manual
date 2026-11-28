#!/usr/bin/env bash
# ogx-token.sh - mint a Keycloak user token that OGX accepts (aud includes ogx-api).
#   ./ogx-token.sh <keycloak-user>            # prompts for the password, no echo
#   ./ogx-token.sh <keycloak-user> < pwfile   # or reads one line of stdin as the password
#   export DEMO_OGX_TOKEN="$(./ogx-token.sh alice)"
# Prints only the token, on stdout; every diagnostic goes to stderr.
#
# The token is requested with scope "openid ogx-api": ogx-api is an optional client
# scope on the cli client, and its mapper adds ogx-api to aud only when the token is
# asked for with that scope. A plain openid token gets 401 from an OGX with auth on.
# The script checks the audience of the returned token and fails with a clear message
# when ogx-api is missing (the scope is not defined on the realm or not added to the
# client; 00-keycloak-realm-clients.json defines it).
#
# Configuration, the environment first, then vars.env here (plain NAME=value lines,
# read with sed, never sourced, so no code in it runs):
#   KEYCLOAK_ISSUER       the realm issuer URL, equal to the token "iss" claim
#   KEYCLOAK_CLI_CLIENT   the public client the demo mints the token with
#   KEYCLOAK_CA           optional: a CA bundle. With it set, curl verifies the
#                         Keycloak certificate with --cacert "$KEYCLOAK_CA"; with it
#                         unset, curl runs with -k, which is acceptable only against
#                         a lab whose certificate you would trust anyway.
# The password is never a command line argument: the prompt reads it with read -rs
# (no echo), or stdin supplies it, and curl receives it as password@- on stdin, out
# of the process list.
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,24p' "$0"; exit "${1:-0}"; }
[ $# -eq 1 ] || usage 2
case "$1" in -h|--help) usage 0 ;; esac
user="$1"

# cfg_var NAME: print the variable's value, the environment first, then vars.env
# (an inline comment and optional quotes stripped). sed only, never a source.
cfg_var() {
    local name="$1"
    local v="${!name:-}"
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    [ -f vars.env ] || return 1
    v="$(sed -n "s/^${name}=//p" vars.env | tail -1 \
        | sed -e 's/[[:space:]]*#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

issuer="$(cfg_var KEYCLOAK_ISSUER)" \
    || { echo "Error: set KEYCLOAK_ISSUER in the environment or vars.env" >&2; exit 2; }
client="$(cfg_var KEYCLOAK_CLI_CLIENT)" \
    || { echo "Error: set KEYCLOAK_CLI_CLIENT in the environment or vars.env" >&2; exit 2; }
issuer="${issuer%/}"

if [ -t 0 ]; then
    printf 'Keycloak password for %s: ' "$user" >&2
    read -rs password || { printf '\n' >&2; echo "Error: no password entered" >&2; exit 2; }
    printf '\n' >&2
else
    # read returns non-zero at end of input without a newline, even when it read the password
    read -r password || [ -n "$password" ] || { echo "Error: stdin gave no password: expected one line" >&2; exit 2; }
fi
[ -n "$password" ] || { echo "Error: the password is empty" >&2; exit 2; }

# curl options: verify against KEYCLOAK_CA when set, -k when it is unset (see header).
if [ -n "${KEYCLOAK_CA:-}" ]; then
    tls=(--cacert "$KEYCLOAK_CA")
else
    tls=(-k)
fi

discovery="$(curl -sS "${tls[@]}" "${issuer}/.well-known/openid-configuration")" || {
    echo "Error: could not fetch ${issuer}/.well-known/openid-configuration (set KEYCLOAK_CA when the certificate is not public)" >&2
    exit 1
}
endpoint="$(printf '%s' "$discovery" | python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin).get("token_endpoint", ""))
except ValueError:
    sys.exit(3)')" || {
    echo "Error: no usable discovery document from ${issuer}" >&2
    exit 1
}
[ -n "$endpoint" ] || { echo "Error: ${issuer} publishes no token_endpoint" >&2; exit 1; }

# The password goes to curl on stdin (password@-), never on a command line where any
# user on the host could read it from the process list.
reply="$(printf '%s' "$password" | curl -sS "${tls[@]}" -X POST "$endpoint" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id="$client" \
    --data-urlencode username="$user" \
    --data-urlencode password@- \
    --data-urlencode scope='openid ogx-api')" || {
    echo "Error: the request to the token endpoint failed" >&2
    exit 1
}
token="$(printf '%s' "$reply" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("Error: the token endpoint did not answer with JSON\n")
    sys.exit(1)
if d.get("error"):
    m = "Error: the token endpoint refused the request: " + d["error"]
    if d.get("error_description"):
        m += " (" + d["error_description"] + ")"
    sys.stderr.write(m + "\n")
    sys.exit(1)
if not d.get("access_token"):
    sys.stderr.write("Error: the reply carries no access_token\n")
    sys.exit(1)
print(d["access_token"])')" || {
    echo "Error: no token for ${user} from ${endpoint}" >&2
    exit 1
}

# The audience is what OGX checks: decode the JWT payload and look for ogx-api.
aud="$(printf '%s' "$token" | python3 -I -c '
import base64, json, sys
payload = sys.stdin.read().strip().split(".")[1]
payload += "=" * (-len(payload) % 4)
aud = json.loads(base64.urlsafe_b64decode(payload)).get("aud", [])
if isinstance(aud, str):
    aud = [aud]
print("yes" if "ogx-api" in aud else "no")')" || {
    echo "Error: the access token is not a decodable JWT" >&2
    exit 1
}
if [ "$aud" != "yes" ]; then
    echo "Error: the token's aud does not include ogx-api, so OGX would refuse it: the" >&2
    echo "       ogx-api optional client scope is missing from the realm or not added" >&2
    echo "       to ${client} (00-keycloak-realm-clients.json defines it), or the scope" >&2
    echo "       was dropped from the request." >&2
    exit 1
fi

printf '%s\n' "$token"
