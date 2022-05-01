#!/bin/bash

TOKEN=$(openssl rand -hex 64)

TMP_DIR=$(mktemp -d -t k3os-XXXX)

echo 'Temp Dir:' $TMP_DIR/

mkdir -p $TMP_DIR/iso/boot/grub

curl -L -o $TMP_DIR/k3os-amd64.iso https://github.com/rancher/k3os/releases/download/v0.21.5-k3s2r1/k3os-amd64.iso
7z x -o$TMP_DIR/iso -- $TMP_DIR/k3os-amd64.iso k3os

SERVER_CREATE='  - "--cluster-init"'
SERVER_JOIN='server_url: https://172.16.20.16:6443'

cat >$TMP_DIR/iso/boot/grub/grub.cfg <<EOF
set default=0
set timeout=10

set gfxmode=auto
set gfxpayload=keep
insmod all_video
insmod gfxterm

menuentry "k3OS Installer" {
  search.fs_label K3OS root
  set sqfile=/k3os/system/kernel/current/kernel.squashfs
  loopback loop0 /$sqfile
  set root=($root)
  linux (loop0)/vmlinuz printk.devkmsg=on k3os.mode=install k3os.install.device=/dev/sdc k3os.install.config_url=/k3osconfig.yaml console=ttyS0 console=tty1
  initrd /k3os/system/kernel/current/initrd
}
EOF

declare -A server_op

server_op=([crit1]="$SERVER_CREATE" [crit2]="$SERVER_JOIN" [crit3]="$SERVER_JOIN")
server_ips=([crit1]="172.16.20.16" [crit2]="172.16.20.17" [crit3]="172.16.20.18")
server_macs=([crit1]="0c:c4:7a:b7:25:b6" [crit2]="0c:c4:7a:b7:24:0c" [crit3]="0c:c4:7a:b7:25:00")

for HOST in "${!server_op[@]}"; do
    SERVER_FLIP_LINE=${server_op[$HOST]}

    cat >$TMP_DIR/iso/k3osconfig.yaml <<EOF
#cloud-config

ssh_authorized_keys:
  - gh:proegssilb
hostname: ${HOST}
write_files:
  - path: /var/lib/connman/default.config
    encoding: ""
    content: |-
      [service_eth0]
      MAC=${server_macs[$HOST]}
      Type=ethernet
      IPv4.method=manual
      IPv4.netmask_prefixlen=24
      IPv4.local_address=${server_ips[$HOST]}
      IPv4.gateway=172.16.20.1
      IPv6=off
      Domain=m.xenrelay.com
      SearchDomains=m.xenrelay.com,i.xenrelay.com,xenrelay.com
      Timeservers=0.us.pool.ntp.org,1.us.pool.ntp.org
      Nameservers=172.16.20.16,172.16.0.1,1.1.1.1
k3os:
  dns_nameservers:
    - 127.0.0.1
    - 1.1.1.1
  token: ${TOKEN}
  k3s_args:
    - server
  ${SERVER_FLIP_LINE}
EOF

    grub-mkrescue -o k3os-new-$HOST.iso $TMP_DIR/iso/ -- -volid K3OS
done
