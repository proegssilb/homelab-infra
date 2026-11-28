#!/bin/bash
# Boot a bootc-base disk image under KVM and check it over SSH.
#
#   boot-test.sh DISK.qcow2 [--expect-digest sha256:...] [--link-down SECONDS]
#                [--upgrade-to REF --upgrade-digest sha256:...]
#
# --link-down N: the NIC's link is down for the first N seconds (switch/gateway back
# late after a power cut); everything must still come up healthy once it's back.
#
# Runs inside the images/bootc-test container (CI and local alike):
#   podman build -t bootc-test -f images/bootc-test/Containerfile images/bootc-base
#   podman run --rm --device /dev/kvm -v "$PWD/out:/work:Z" bootc-test /work/qcow2/disk.qcow2
#
# The guest gets a NoCloud seed like the one Proxmox writes: hostname, an admin
# user with a throwaway key, a *static* address on QEMU's user-mode network, and
# dummy Alloy endpoints. Prints one PASS/FAIL line per check; exit 0 only if all pass.
set -uo pipefail

DISK=""; EXPECT_DIGEST=""; UPGRADE_TO=""; UPGRADE_DIGEST=""; LINK_DOWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-digest)  EXPECT_DIGEST=$2; shift 2 ;;
    --upgrade-to)     UPGRADE_TO=$2; shift 2 ;;
    --upgrade-digest) UPGRADE_DIGEST=$2; shift 2 ;;
    --link-down)      LINK_DOWN=$2; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *)  DISK=$1; shift ;;
  esac
done
[ -f "$DISK" ] || { echo "usage: boot-test.sh DISK.qcow2 [options]" >&2; exit 2; }
[ -e /dev/kvm ] || { echo "no /dev/kvm (run the container with --device /dev/kvm)" >&2; exit 2; }

W=$(mktemp -d)
QEMU_PID=""
cleanup() { [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

HOSTNAME_WANT=boottest
MAC=52:54:00:12:34:56
ADDR=10.0.2.15
SSH_PORT=2222
FAILS=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+: $2}"; FAILS=$((FAILS + 1)); }

# ── Seed ──────────────────────────────────────────────────────────────────────
ssh-keygen -q -t ed25519 -N '' -f "$W/key"
mkdir "$W/seed"
cat >"$W/seed/meta-data" <<EOF
instance-id: boottest-$(date +%s)
local-hostname: $HOSTNAME_WANT
EOF
cat >"$W/seed/user-data" <<EOF
#cloud-config
hostname: $HOSTNAME_WANT
users:
  - name: admin
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys: ["$(cat "$W/key.pub")"]
write_files:
  - path: /etc/alloy/endpoints.env
    content: "LOKI_URL=http://127.0.0.1:9\n"
EOF
cat >"$W/seed/network-config" <<EOF
version: 2
ethernets:
  lan:
    match: {macaddress: "$MAC"}
    addresses: [$ADDR/24]
    routes: [{to: default, via: 10.0.2.2}]
    nameservers: {addresses: [10.0.2.3]}
EOF
xorriso -as mkisofs -quiet -V cidata -J -r -o "$W/seed.iso" "$W/seed" 2>/dev/null

# ── Boot ──────────────────────────────────────────────────────────────────────
qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$DISK")" "$W/overlay.qcow2"
# Two data disks named like Proxmox's (drive id drive-scsiN, so the guest sees
# /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsiN): scsi2 blank, scsi3 with
# unknown data and no filesystem signature (random bytes), which must never be formatted.
truncate -s 1G "$W/scsi2.raw"
truncate -s 1G "$W/scsi3.raw"
head -c 1048576 /dev/urandom | dd of="$W/scsi3.raw" conv=notrunc status=none
SCSI3_SUM=$(head -c 1048576 "$W/scsi3.raw" | sha256sum)

boot() {
  qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
    -display none -serial "file:$W/console.log" \
    -drive "file=$W/overlay.qcow2,if=virtio" \
    -drive "file=$W/seed.iso,media=cdrom,readonly=on" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -device "virtio-net-pci,netdev=net0,mac=$MAC" \
    -device virtio-scsi-pci,id=scsi0 \
    -drive "file=$W/scsi2.raw,if=none,id=drive-scsi2,format=raw" -device scsi-hd,bus=scsi0.0,drive=drive-scsi2 \
    -drive "file=$W/scsi3.raw,if=none,id=drive-scsi3,format=raw" -device scsi-hd,bus=scsi0.0,drive=drive-scsi3 \
    -monitor "unix:$W/monitor.sock,server=on,wait=off" \
    -device virtio-serial-pci \
    -chardev "socket,path=$W/qga.sock,server=on,wait=off,id=qga0" \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -pidfile "$W/qemu.pid" -daemonize
  QEMU_PID=$(cat "$W/qemu.pid")
}

monitor() {  # one HMP command
  python3 - "$W/monitor.sock" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
time.sleep(0.3); s.recv(65536)
s.sendall(sys.argv[2].encode() + b"\n"); time.sleep(0.3)
PY
}

SSH=(ssh -q -i "$W/key" -p "$SSH_PORT" -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes admin@127.0.0.1)

wait_ssh() {  # up to $1 seconds, also waits for boot to settle
  local deadline=$((SECONDS + $1))
  while [ $SECONDS -lt $deadline ]; do
    if "${SSH[@]}" true 2>/dev/null; then
      "${SSH[@]}" "timeout 300 systemctl is-system-running --wait" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 5
  done
  return 1
}

booted_digest() {
  "${SSH[@]}" "sudo bootc status --json" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["booted"]["image"]["imageDigest"])' 2>/dev/null
}

check() {  # name, remote command (pass = exit 0), optional diagnostic command run on failure
  if "${SSH[@]}" "$2" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1"
    [ -n "${3:-}" ] && "${SSH[@]}" "$3" 2>&1 | sed 's/^/    | /' | tail -n 25
  fi
}

boot
if [ "$LINK_DOWN" -gt 0 ]; then
  monitor "set_link net0 off"
  echo "link down for ${LINK_DOWN}s"
  sleep "$LINK_DOWN"
  monitor "set_link net0 on"
  echo "link up"
fi
if ! wait_ssh 420; then
  fail "boot: SSH reachable within 7 min"
  echo "--- last console lines ---"; tail -n 30 "$W/console.log"
  exit 1
fi
pass "boot: SSH reachable"

# ── Checks on the image under test ────────────────────────────────────────────
# In upgrade mode these run *after* the upgrade: the old disk predates whatever
# this image adds (that's the point), so before the switch only the basics count.
image_checks() {
  local p=$1  # label prefix
  [ "$("${SSH[@]}" hostname 2>/dev/null)" = "$HOSTNAME_WANT" ] && pass "${p}cloud-init: hostname" || fail "${p}cloud-init: hostname"
  check "${p}cloud-init: static address $ADDR/24" "ip -4 -o addr show | grep -q ' $ADDR/24 '"
  check "${p}cloud-init: no DHCP on the static NIC" "! nmcli -g ipv4.method connection show --active | grep -qx auto"
  check "${p}cloud-init: finished without errors" "sudo cloud-init status --wait | grep -q 'status: done'"
  check "${p}no failed systemd units" "test -z \"\$(systemctl --failed --no-legend --plain)\"" \
    "systemctl --failed --no-legend --plain"
  check "${p}greenboot health check passed" "test \"\$(systemctl show -p Result --value greenboot-healthcheck)\" = success" \
    "systemctl status greenboot-healthcheck --no-pager -l | tail -n 15"
  check "${p}updates only in the nightly window" "systemctl show -p TimersCalendar bootc-fetch-apply-updates.timer | grep -q '04:00:00'" \
    "systemctl cat bootc-fetch-apply-updates.timer"
  check "${p}sshd: password login off" "sudo sshd -T | grep -qix 'passwordauthentication no'" \
    "sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'"
  check "${p}qemu-guest-agent active" "systemctl is-active -q qemu-guest-agent"
  check "${p}host key published for the guest agent" "sudo cmp -s /etc/ssh/ssh_host_ed25519_key.pub /var/log/qemu-ga/ssh-host-key.pub" \
    "systemctl status ssh-host-key-publish.service --no-pager -l | tail -n 8; ls -lZ /var/log/qemu-ga/"
  if python3 - "$W/qga.sock" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-ping"}\n')
sys.exit(0 if b'"return"' in s.recv(4096) else 1)
PY
  then pass "${p}qemu-guest-agent answers the host"; else fail "${p}qemu-guest-agent answers the host"; fi
  check "${p}node_exporter answers on :9100" "curl -sf localhost:9100/metrics | grep -q '^node_boot_time_seconds'"
  check "${p}node_exporter: bootc image metric" "curl -sf localhost:9100/metrics | grep -q '^bootc_booted_image_info{'"
  check "${p}node_exporter: bootc update status metric" "curl -sf localhost:9100/metrics | grep -q '^bootc_update_available '" \
    "sudo /usr/libexec/bootc-image-metric; cat /var/lib/prometheus/node-exporter/bootc_image.prom; sudo bootc upgrade --check 2>&1 | tail -n 5"
  check "${p}alloy active with endpoints from cloud-init" "systemctl is-active -q alloy" \
    "systemctl status alloy --no-pager -l | head -n 12; sudo journalctl -u alloy -b --no-pager -n 15"
  check "${p}podman runs a container" "podman run --rm quay.io/fedora/fedora-minimal:45 true"

  # Data disks: format only a blank disk, never one with data.
  local d2=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2 d3=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
  check "${p}data disk: blank scsi2 gets a filesystem" \
    "sudo systemctl start homelab-prepare-disk@scsi2 && sudo blkid -p -o value -s TYPE $d2 | grep -qx ext4" \
    "sudo journalctl -u homelab-prepare-disk@scsi2 -b --no-pager | tail -n 8; ls -l /dev/disk/by-id/"
  check "${p}data disk: a formatted disk is left alone" \
    "u=\$(sudo blkid -p -o value -s UUID $d2) && sudo /usr/libexec/homelab-prepare-disk scsi2 | grep -q 'not touching' && test \"\$u\" = \"\$(sudo blkid -p -o value -s UUID $d2)\""
  check "${p}data disk: unknown data is refused" \
    "! sudo systemctl start homelab-prepare-disk@scsi3 && ! sudo blkid -p $d3"
  check "${p}data disk: refused disk unchanged" \
    "test \"\$(sudo head -c 1048576 $d3 | sha256sum)\" = '$SCSI3_SUM'"

  # Channel switch: an unreachable registry means retrying, not a failed unit.
  check "${p}channel switch retries while the registry is unreachable" \
    "sudo mkdir -p /etc/homelab && echo registry.invalid/none/bootc-base:stable | sudo tee /etc/homelab/channel >/dev/null && sudo systemctl start --no-block homelab-track-channel && sleep 20 && test \"\$(systemctl show -p SubState --value homelab-track-channel)\" = auto-restart" \
    "systemctl status homelab-track-channel --no-pager -l | tail -n 10"
  "${SSH[@]}" "sudo systemctl stop homelab-track-channel; sudo rm -f /etc/homelab/channel; sudo systemctl reset-failed" >/dev/null 2>&1 || true
}

DIGEST=$(booted_digest)
if [ -n "$DIGEST" ]; then pass "bootc status readable"; else fail "bootc status readable"; fi

if [ -z "$UPGRADE_TO" ]; then
  if [ "$LINK_DOWN" -gt 0 ]; then
    # It waited for the network instead of giving up; that the boot then completed
    # (greenboot, units after network-online.target) is checked below.
    check "network patience: waited for the link instead of giving up" \
      "sudo journalctl -u homelab-wait-network -b --no-pager | grep -qE 'network ready after ([6-9][0-9]|[1-9][0-9]{2,})s'" \
      "sudo journalctl -u homelab-wait-network -b --no-pager | tail -n 5"
  fi
  image_checks ""
  if [ -n "$EXPECT_DIGEST" ]; then
    [ "$DIGEST" = "$EXPECT_DIGEST" ] && pass "booted the expected image" || fail "booted the expected image" "got $DIGEST"
  fi
else
  # ── Upgrade: old disk -> image under test ──────────────────────────────────
  if "${SSH[@]}" "sudo bootc switch --quiet '$UPGRADE_TO'" >/dev/null 2>&1; then
    pass "upgrade: bootc switch staged"
    "${SSH[@]}" "sudo systemctl reboot" >/dev/null 2>&1 || true
    sleep 15
    if wait_ssh 420; then
      pass "upgrade: back after reboot"
      NEW=$(booted_digest)
      if [ -n "$UPGRADE_DIGEST" ]; then
        [ "$NEW" = "$UPGRADE_DIGEST" ] && pass "upgrade: booted the new image" || fail "upgrade: booted the new image" "got $NEW"
      else
        [ -n "$NEW" ] && [ "$NEW" != "$DIGEST" ] && pass "upgrade: booted a different image" || fail "upgrade: booted a different image"
      fi
      image_checks "upgraded: "
    else
      fail "upgrade: back after reboot"
    fi
  else
    fail "upgrade: bootc switch staged"
  fi
fi

if [ "$FAILS" -gt 0 ]; then
  echo "--- failed units / last console lines ---"
  "${SSH[@]}" "systemctl --failed --no-legend --plain" 2>/dev/null
  tail -n 20 "$W/console.log"
  echo "RESULT: $FAILS check(s) failed"
  exit 1
fi
echo "RESULT: all checks passed"
