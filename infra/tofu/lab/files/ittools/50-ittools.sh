#!/bin/bash
# greenboot required check on ittools: after an update, the app must answer.
# Up to 10 min, so a slow start (network back late after a power cut) isn't
# mistaken for a broken update. Self-contained on purpose: a pushed check must not
# depend on a helper that an older deployment (a rollback target) doesn't have.
deadline=$((SECONDS + 600))
while [ $SECONDS -lt $deadline ]; do
  curl -sf -o /dev/null http://127.0.0.1:8080/ && exit 0
  sleep 5
done
echo "IT Tools did not answer on :8080 within 10 min" >&2
exit 1
