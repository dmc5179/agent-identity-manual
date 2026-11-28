#!/usr/bin/env bash
# render.sh - fill a YAML file from vars.env and hand it to oc.
#   ./render.sh manifests/01-ztwim.yaml            print the rendered YAML
#   ./render.sh manifests/01-ztwim.yaml --check    server-side dry run (changes nothing)
#   ./render.sh manifests/01-ztwim.yaml --apply    apply
# Only variables defined in vars.env are replaced; other ${...} text is left as is.
set -euo pipefail
cd "$(dirname "$0")"
[ -f vars.env ] || { echo "copy vars.env.example to vars.env and fill it in" >&2; exit 1; }
f="${1:?usage: render.sh FILE [--check|--apply]}"; mode="${2:-}"
# The numbered manifests live in manifests/; a bare name such as 01-ztwim.yaml also works.
[ -f "$f" ] || { [ -f "manifests/$f" ] && f="manifests/$f"; }
[ -f "$f" ] || { echo "no such file: $f (the numbered files are in manifests/)" >&2; exit 1; }
set -a; . ./vars.env; set +a
vars="$(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/${\1}/p' vars.env | tr '\n' ' ')"
out="$(envsubst "$vars" < "$f")"
ph="$(grep -v '^[[:space:]]*#' <<<"$out" | grep -o '<[a-z-]*>' | sort -u | tr '\n' ' ' || true)"
[ -n "$ph" ] && echo "note: $f still has <placeholders> to edit: $ph" >&2
case "$mode" in
  "")       printf '%s\n' "$out" ;;
  --check)  printf '%s\n' "$out" | oc apply --dry-run=server -f - ;;
  --apply)  printf '%s\n' "$out" | oc apply -f - ;;
  *)        echo "unknown option $mode" >&2; exit 2 ;;
esac
