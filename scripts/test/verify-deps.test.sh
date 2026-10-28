#!/usr/bin/env bash
# Tests verify_deps in scripts/verify.sh against a stub `npm` on PATH.
# Each case sets what the stub returns for the runtime audit (--omit=dev) and the full audit.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
stub="$(mktemp -d)"
trap 'rm -rf "$stub"' EXIT

cat >"$stub/npm" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" --omit=dev "* ]]; then
  printf '%s\n' "${PROD_OUT:-found 0 vulnerabilities}"; exit "${PROD_RC:-0}"
fi
printf '%s\n' "${ALL_OUT:-found 0 vulnerabilities}"; exit "${ALL_RC:-0}"
SH
chmod +x "$stub/npm"

fails=0
check() { # name, expected exit, expected text ('' = none), forbidden text ('' = none), then env assignments
  local name="$1" want_rc="$2" want="$3" forbid="$4"; shift 4
  local out rc
  out="$(env -u CI "$@" PATH="$stub:$PATH" bash -c "source '$here/../verify.sh'; verify_deps" 2>&1)"; rc=$?
  if [[ $rc -ne $want_rc ]] || { [[ -n "$want" ]] && ! grep -qF -- "$want" <<<"$out"; } \
     || { [[ -n "$forbid" ]] && grep -qF -- "$forbid" <<<"$out"; }; then
    echo "FAIL $name (exit $rc, want $want_rc)"; echo "$out" | sed 's/^/    /'; fails=$((fails + 1))
  else
    echo "ok   $name"
  fi
}

vuln="found 2 vulnerabilities (1 high, 1 critical)"
offline="npm error code ENOTFOUND"
check "all clean passes"            0 "" "WARNING"
check "dev advisory warns only"     0 "WARNING" "" ALL_RC=1 ALL_OUT="$vuln"
check "runtime advisory fails"      1 "vulnerability in runtime" "" PROD_RC=1 PROD_OUT="$vuln"
check "offline on the Mac skips"    0 "skipped" "" PROD_RC=1 PROD_OUT="$offline"
check "offline in CI fails"         1 "" "skipped" CI=true PROD_RC=1 PROD_OUT="$offline"
check "other npm error is not a vulnerability" 1 "npm audit failed" "vulnerability in runtime" \
  PROD_RC=1 PROD_OUT="npm error Cannot read properties of null (reading 'edgesOut')"
check "offline on the second call does not warn" 0 "" "WARNING" ALL_RC=1 ALL_OUT="$offline"

[[ $fails -eq 0 ]] && echo "verify-deps: all passed" || { echo "verify-deps: $fails failed"; exit 1; }
