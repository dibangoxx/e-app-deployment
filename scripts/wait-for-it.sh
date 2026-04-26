#!/usr/bin/env bash
# wait-for-it.sh — waits for a host:port to be ready
# Usage: ./wait-for-it.sh postgres:5432 -- npm test

set -e
TIMEOUT=60
HOST=""
PORT=""
CMD=""

usage() {
  echo "Usage: $0 host:port [-t timeout] [-- command]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    *:* ) IFS=':' read -r HOST PORT <<< "$1"; shift ;;
    -t  ) TIMEOUT="$2"; shift 2 ;;
    --  ) shift; CMD="$@"; break ;;
    *   ) usage ;;
  esac
done

[[ -z "$HOST" || -z "$PORT" ]] && usage

echo "Waiting for $HOST:$PORT (timeout ${TIMEOUT}s)..."
start=$SECONDS

until nc -z "$HOST" "$PORT" 2>/dev/null; do
  if (( SECONDS - start >= TIMEOUT )); then
    echo "Timeout waiting for $HOST:$PORT"
    exit 1
  fi
  sleep 1
done

echo "$HOST:$PORT is ready (took $((SECONDS - start))s)"

if [[ -n "$CMD" ]]; then
  exec $CMD
fi
