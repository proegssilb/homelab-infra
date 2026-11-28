#!/bin/bash
# greenboot required check on garage-apps: after an update, Garage must report
# itself healthy (admin API /health, loopback, no token). Up to 10 min; self-contained.
deadline=$((SECONDS + 600))
while [ $SECONDS -lt $deadline ]; do
  curl -sf -o /dev/null http://127.0.0.1:3903/health && exit 0
  sleep 5
done
echo "garage not healthy on :3903 within 10 min" >&2
exit 1
