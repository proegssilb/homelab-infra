#!/bin/bash
# greenboot required check on ittools: after an update, the app must answer.
for _ in $(seq 1 45); do
  curl -sf -o /dev/null http://127.0.0.1:8080/ && exit 0
  sleep 2
done
echo "IT Tools did not answer on :8080 within 90s" >&2
exit 1
