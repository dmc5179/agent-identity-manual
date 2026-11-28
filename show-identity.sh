#!/usr/bin/env bash
# show-identity.sh - show one agent pod's identity, from inside the pod.
#
#   ./show-identity.sh [namespace/deployment]
#   ./show-identity.sh                 # first DEMO_AGENTS entry in demo.env, else agent-id-test/agent-a
#
# Runs `oc exec deploy/<name> -n <ns> -- python3 -I -c '<inline script>'` in the agent pod
# (image registry.access.redhat.com/ubi9/python-312, see manifests/12-example-agent.yaml) and prints:
#   - the projected service account token's claims: iss, sub, aud, iat, exp, and the remaining
#     lifetime in minutes. The token and its signature are never printed, only those claims.
#   - whether the SPIFFE workload API socket exists at the path in $SPIFFE_ENDPOINT_SOCKET
#     (unix:///spiffe-workload-api/spire-agent.sock in manifests/12-example-agent.yaml).
#   - the agent's SPIFFE ID: fetched with the py-spiffe module when the pod has it (pip installs
#     it to /tmp/pylib when it does not); when that is impossible (for example a disconnected
#     cluster), the expected ID spiffe://<trust-domain>/ns/<ns>/sa/<sa>, built from the namespace
#     and service account as manifests/03-agent-spiffe-ids.yaml defines, clearly labeled
#     "expected, not fetched".
#   - the pod name and its serviceAccountName (oc get pod ... -o jsonpath).
#
# The default target is the first entry of DEMO_AGENTS in demo.env (namespace/serviceaccount=Name),
# read with sed and never sourced; with no demo.env, agent-id-test/agent-a. TRUST_DOMAIN for the
# expected ID comes from the environment or vars.env, also read with sed.
# Needs a working oc login; the script changes nothing in the cluster. IDENTITY_TOKEN_PATH_OVERRIDE
# redirects the token path, for testing the decoder outside a pod (claims only, still never the token).
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,24p' "$0"; exit "${1:-0}"; }
[ $# -le 1 ] || usage 2
case "${1:-}" in -h|--help) usage 0 ;; esac

target="${1:-}"

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

# Default: the first entry of DEMO_AGENTS in demo.env (read with sed, never sourced),
# with the optional =Display Name suffix and quotes stripped.
if [ -z "$target" ] && [ -f demo.env ]; then
    target="$(sed -n 's/^DEMO_AGENTS=//p' demo.env | head -1 \
        | sed -e 's/[[:space:]]*#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" \
        | awk '{print $1}' | sed 's/=.*//')"
fi
[ -n "$target" ] || target="agent-id-test/agent-a"
case "$target" in */*) : ;; *)
    echo "Error: expected namespace/deployment, got: $target" >&2
    echo "Example: ./show-identity.sh agent-id-test/agent-a" >&2
    exit 2 ;;
esac
ns="${target%%/*}"
deploy="${target#*/}"; deploy="${deploy%%=*}"
[ -n "$ns" ] && [ -n "$deploy" ] || { echo "Error: expected namespace/deployment, got: $target" >&2; exit 2; }

if ! who_err="$(oc whoami 2>&1)"; then
  echo "oc cannot reach the cluster as context '$(oc config current-context 2>/dev/null)': $who_err" >&2
  echo "Log in again (oc login ...) or point KUBECONFIG at a working kubeconfig, then rerun." >&2
  exit 1
fi

if ! oc get deploy "$deploy" -n "$ns" >/dev/null 2>&1; then
  echo "Error: deployment '$deploy' not found in namespace '$ns'." >&2
  echo "Check the namespace and deployment name, or pass one: ./show-identity.sh <namespace>/<deployment>" >&2
  exit 1
fi

trust_domain="$(cfg_var TRUST_DOMAIN || true)"
if [ -z "$trust_domain" ]; then
  trust_domain="example.com"
  echo "Note: TRUST_DOMAIN is not set (environment or vars.env); the expected SPIFFE ID uses the placeholder ${trust_domain}." >&2
fi

# One pod of the deployment, through the deployment's own selector, and its service account.
selector="$(oc get deploy "$deploy" -n "$ns" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')"
selector="${selector%,}"
[ -n "$selector" ] || { echo "Error: deployment '$deploy' has an empty spec.selector.matchLabels" >&2; exit 1; }
pod="$(oc get pod -n "$ns" --selector="$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$pod" ] || { echo "Error: no pod for deployment '$deploy' in namespace '$ns'; is it running?" >&2; exit 1; }
sa="$(oc get pod "$pod" -n "$ns" -o jsonpath='{.spec.serviceAccountName}')"

echo "Namespace:       $ns"
echo "Deployment:      $deploy"
echo "Pod:             $pod"
echo "Service account: $sa"

# The inline script the pod runs: claims only, never the token or its signature.
PY="$(cat <<'PYEOF'
import base64
import json
import os
import subprocess
import sys
import time

ns, sa, trust_domain = sys.argv[1], sys.argv[2], sys.argv[3]
token_path = os.environ.get("IDENTITY_TOKEN_PATH_OVERRIDE",
                            "/var/run/secrets/kubernetes.io/serviceaccount/token")

# 1. Claims of the projected service account token, decoded with base64 in Python.
print()
print("Projected service account token claims ({}):".format(token_path))
print("  the token itself and its signature are not printed")
try:
    with open(token_path, encoding="utf-8") as f:
        parts = f.read().strip().split(".")
    if len(parts) != 3:
        raise ValueError("expected 3 JWT parts, found {}".format(len(parts)))
    claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
    exp = int(claims.get("exp", 0))
    for key in ("iss", "sub", "aud", "iat", "exp"):
        value = claims.get(key, "<missing>")
        if key == "aud" and isinstance(value, list):
            value = " ".join(str(item) for item in value)
        print("  {}: {}".format(key, value))
    now = int(time.time())
    if exp:
        print("  stated expiry in: {:.1f} min".format((exp - now) / 60.0))
    # Kubernetes extends the stated expiry of the default token for older clients; warnafter is
    # when the kubelet really replaces it (about an hour after it was issued).
    warn = (claims.get("kubernetes.io") or {}).get("warnafter")
    if warn:
        print("  replaced by the kubelet in: {:.1f} min (kubernetes.io.warnafter; the long exp is a".format((int(warn) - now) / 60.0))
        print("    compatibility extension for older clients)")
except Exception as exc:
    print("  could not decode the token claims: {}: {}".format(type(exc).__name__, exc))

# 2. The SPIFFE workload API socket, at the path in $SPIFFE_ENDPOINT_SOCKET.
print()
socket_uri = os.environ.get("SPIFFE_ENDPOINT_SOCKET",
                            "unix:///spiffe-workload-api/spire-agent.sock")
socket_path = socket_uri[len("unix://"):] if socket_uri.startswith("unix://") else socket_uri
if os.path.exists(socket_path):
    print("SPIFFE workload API socket: present at {}".format(socket_path))
else:
    print("SPIFFE workload API socket: NOT present at {}".format(socket_path))
    print("  (SPIFFE_ENDPOINT_SOCKET={})".format(socket_uri))

# 3. The SPIFFE ID: fetched with py-spiffe when possible, otherwise the expected one.
import importlib
sys.path.insert(0, "/tmp/pylib")

def fetch_spiffe_id():
    try:
        from spiffe import WorkloadApiClient
    except ImportError:
        try:
            subprocess.run(
                [sys.executable, "-I", "-m", "pip", "install", "--quiet",
                 "--target", "/tmp/pylib", "spiffe"],
                check=True, capture_output=True, timeout=180)
        except Exception:
            return None, ("py-spiffe is not installed and pip could not install it"
                          " (for example on a disconnected cluster)")
        importlib.invalidate_caches()
        try:
            from spiffe import WorkloadApiClient
        except ImportError:
            return None, "py-spiffe is still not importable after the pip install"
    try:
        with WorkloadApiClient() as client:
            svid = client.fetch_x509_svid()
            jwt = None
            try:
                # A JWT-SVID for a made-up audience: only its claims are shown, never the token.
                j = client.fetch_jwt_svid(audience={"show-identity"})
                jwt = (j.expiry, sorted(j.audience))
            except Exception:
                pass
        return (str(svid.spiffe_id), jwt), "fetched from the workload API with py-spiffe"
    except Exception:
        return None, "the workload API call failed (is the SPIRE agent socket mounted and SPIRE ready?)"

fetched, how = fetch_spiffe_id()
spiffe_id, jwt = fetched if fetched else (None, None)
print()
if spiffe_id:
    print("SPIFFE ID: {} ({})".format(spiffe_id, how))
    if jwt:
        print("  JWT-SVID (the short-lived credential for outbound calls): expires in {:.1f} min, audience {}".format(
            (int(jwt[0]) - int(time.time())) / 60.0, " ".join(jwt[1])))
else:
    print("SPIFFE ID: spiffe://{}/ns/{}/sa/{} (expected, not fetched)".format(trust_domain, ns, sa))
    print("  {}".format(how))
    print("  the ID is derived from the namespace and service account,")
    print("  as the ClusterSPIFFEID in manifests/03-agent-spiffe-ids.yaml defines it")
PYEOF
)"

oc exec "deploy/${deploy}" -n "$ns" -- python3 -I -c "$PY" "$ns" "$sa" "$trust_domain"
