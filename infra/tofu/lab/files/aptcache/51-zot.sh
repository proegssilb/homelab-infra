#!/bin/bash
# greenboot required check on aptcache01: after an update, the registry cache must
# answer (the OCI API root). Up to 10 min; self-contained.
deadline=$((SECONDS + 600))
while [ $SECONDS -lt $deadline ]; do
  curl -sf -o /dev/null http://127.0.0.1:5000/v2/ && exit 0
  sleep 5
done
echo "zot did not answer on :5000 within 10 min" >&2
exit 1
