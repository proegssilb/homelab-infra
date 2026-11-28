#!/bin/bash
# greenboot required check on upsmon01: after an update, the exporter must answer.
# Deliberately not "the UPS answers": a USB glitch or an unplugged UPS isn't a broken
# image, and must not roll an update back (the UPS rules alert on that instead).
# Up to 10 min; self-contained.
deadline=$((SECONDS + 600))
while [ $SECONDS -lt $deadline ]; do
  curl -sf -o /dev/null http://127.0.0.1:9199/metrics && exit 0
  sleep 5
done
echo "nut_exporter did not answer on :9199 within 10 min" >&2
exit 1
