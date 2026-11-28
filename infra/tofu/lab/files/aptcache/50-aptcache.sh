#!/bin/bash
# greenboot required check on aptcache01: after an update, the proxy must answer.
# Up to 10 min (slow start after a power cut isn't a broken update); self-contained.
deadline=$((SECONDS + 600))
while [ $SECONDS -lt $deadline ]; do
  curl -sf -o /dev/null http://127.0.0.1:3142/acng-report.html && exit 0
  sleep 5
done
echo "apt-cacher-ng did not answer on :3142 within 10 min" >&2
exit 1
