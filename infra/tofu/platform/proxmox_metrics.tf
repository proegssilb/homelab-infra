# Proxmox metric servers: pvestatd on every node pushes node, guest and storage
# stats (the same data set for every server type).
#
# "otel" sends OTLP over HTTP straight into Prometheus's own OTLP receiver
# (--web.enable-otlp-receiver, roles/prometheus), so the data arrives labelled,
# with no exporter in between. Plain HTTP inside Lab, like the Graphite feed.
# Prometheus drops OTel unit suffixes (roles/prometheus, otlp.translation_strategy)
# because PVE's unit metadata is unreliable. Dashboard: roles/grafana/files/
# dashboards/proxmox.json.
#
# This replaced a hand-made Graphite server (obs01:2003), removed 2026-11-12.
# graphite_exporter stays for TrueNAS.

resource "proxmox_metrics_server" "otel" {
  name   = "otel"
  type   = "opentelemetry"
  server = var.metrics_otlp_host
  port   = 9090

  opentelemetry_proto = "http"
  opentelemetry_path  = "/api/v1/otlp/v1/metrics"
}
