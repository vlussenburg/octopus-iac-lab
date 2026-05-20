#!/usr/bin/env bash
# Smoke test: hit an HTTP endpoint N times, assert latency + success rate.
# Inputs are Octopus parameters, read via get_octopusvariable.

set -u

BASE=$(get_octopusvariable "BaseUrl")
URL_PATH=$(get_octopusvariable "Path")
ITER=$(get_octopusvariable "Iterations")
WANT=$(get_octopusvariable "ExpectedStatus")
MAX_MS=$(get_octopusvariable "MaxLatencyMs")
MIN_PCT=$(get_octopusvariable "MinSuccessPct")
WARMUP=$(get_octopusvariable "WarmupSeconds")
EXPECT=$(get_octopusvariable "ExpectBody")

[ -z "${URL_PATH:-}" ] && URL_PATH="/"
[ -z "${ITER:-}" ]     && ITER=20
[ -z "${WANT:-}" ]     && WANT=200
[ -z "${MAX_MS:-}" ]   && MAX_MS=500
[ -z "${MIN_PCT:-}" ]  && MIN_PCT=95
[ -z "${WARMUP:-}" ]   && WARMUP=5

if [ -z "${BASE:-}" ]; then
  echo "FAIL: BaseUrl parameter is empty"
  exit 1
fi

URL="${BASE%/}${URL_PATH}"

echo "Smoke test → $URL"
echo "Iterations=$ITER  expect=HTTP $WANT  max=${MAX_MS}ms  min_success=${MIN_PCT}%  warmup=${WARMUP}s"
[ -n "$EXPECT" ] && echo "Body must contain: \"$EXPECT\""
echo ""

if [ "$WARMUP" -gt 0 ]; then
  echo "Warming up (${WARMUP}s)…"
  sleep "$WARMUP"
fi

ok=0
fail=0
max_seen_ms=0
total_ms=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for i in $(seq 1 "$ITER"); do
  code_time=$(curl -sS -o "$tmp" -w "%{http_code} %{time_total}" --max-time 10 "$URL" || echo "000 0")
  code=$(echo "$code_time" | awk '{print $1}')
  t_sec=$(echo "$code_time" | awk '{print $2}')
  ms=$(awk -v t="$t_sec" 'BEGIN{printf "%d", t*1000}')

  total_ms=$((total_ms + ms))
  [ "$ms" -gt "$max_seen_ms" ] && max_seen_ms=$ms

  body_mark="-"
  if [ -n "$EXPECT" ]; then
    if grep -qF "$EXPECT" "$tmp"; then body_mark="+"; else body_mark="!"; fi
  fi

  ok_iter=true
  [ "$code" != "$WANT" ] && ok_iter=false
  [ "$ms" -gt "$MAX_MS" ] && ok_iter=false
  [ -n "$EXPECT" ] && [ "$body_mark" != "+" ] && ok_iter=false

  if $ok_iter; then
    ok=$((ok+1))
    printf "  [%2d/%d] %s %5dms body=%s\n" "$i" "$ITER" "$code" "$ms" "$body_mark"
  else
    fail=$((fail+1))
    printf "  [%2d/%d] %s %5dms body=%s  FAIL\n" "$i" "$ITER" "$code" "$ms" "$body_mark"
  fi
done

avg_ms=$((total_ms / ITER))
pct=$(awk -v o="$ok" -v n="$ITER" 'BEGIN{printf "%d", (o*100)/n}')

echo ""
echo "──── summary ────"
echo "  passing: $ok / $ITER  (${pct}%)"
echo "  latency: avg=${avg_ms}ms  max=${max_seen_ms}ms  threshold=${MAX_MS}ms"
echo ""

if [ "$pct" -lt "$MIN_PCT" ]; then
  echo "FAIL: success rate ${pct}% < threshold ${MIN_PCT}%"
  exit 1
fi

echo "PASS"
