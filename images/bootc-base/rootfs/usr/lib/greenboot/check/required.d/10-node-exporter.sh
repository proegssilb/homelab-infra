#!/bin/bash
# greenboot baseline: after an update, the VM must still be observable. A failed
# required check makes greenboot boot back into the previous deployment.
# Per-VM checks (the app answers) arrive through cloud-init in
# /etc/greenboot/check/required.d/.
for _ in $(seq 1 30); do
  curl -sf -o /dev/null http://127.0.0.1:9100/metrics && exit 0
  sleep 2
done
echo "node_exporter did not answer on :9100 within 60s" >&2
exit 1
