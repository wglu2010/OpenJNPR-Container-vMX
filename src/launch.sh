#!/bin/bash
# Copyright (c) 2018, Juniper Networks, Inc.
# All rights reserved.
#
echo "Juniper Networks vMX Docker Light Container"

VCPMEM="${VCPMEM:-1024}"  # default memory for VCP: 1024MB
VCPU="${VCPU:-1}"         # default # of cpus for VCP: 1

set -e # exit immediately if something goes wrong
/system_check.sh

echo "/u contains the following files:"
ls /u

# fix network interface order due to https://github.com/docker/compose/issues/4645
/fix_network_order.sh

if [ -z "$IMAGE" ]; then
  # no image given, check if we have one in /u
  IMAGE=$(cd /u && ls junos-*qcow2 | tail -1)
fi

if [ ! -f "/u/$IMAGE" ]; then
  echo "vMX file $IMAGE not found"
  exit 1
fi


if [[ "$IMAGE" =~ \.qcow2$ ]]; then
  echo "using qcow2 image $IMAGE"
  cp /u/$IMAGE /tmp/
  VCPIMAGE=$IMAGE
else
  echo "$IMAGE isn't a qcow2 image"
  exit 1
fi
RELEASE=$(echo "$VCPIMAGE" | cut -d- -f5| cut -d. -f1,2,3)

if [ -z "$LICENSE" ]; then
  LICENSE=$(cd /u && ls license*txt | tail -1)
fi

if [ ! -f "/u/$LICENSE" ]; then
  echo "Warning: No license file found ($LICENSE)"
fi
echo "LICENSE=$LICENSE"

until ip link show eth0; do
  echo "waiting for eth0 to be attached ..."
  sleep 5
done

rootpassword=$(pwgen 24 1)
hostname=$(docker ps --format '{{.Names}}' -f id=$HOSTNAME || echo $HOSTNAME)
myip=$(ip address show dev eth0|grep 'inet '|awk '{print $2}')
myipv6=$(ip addr show dev eth0 | awk '/inet6/ {print $2}' | head -1)
echo "Interface $eth IPv6 address $myipv6"
# bridge eth0 to fxp0 via br-ext, remove ip and change mac address of eth0
mymac=$(cat /sys/class/net/eth0/address)
echo "Bridging $eth ($myipmask/$mymac) with fxp0"
brctl addbr br-ext
ip link set up br-ext
ip tuntap add dev fxp0 mode tap
ip link set fxp0 up promisc on
macchanger -A eth0
brctl addif br-ext eth0
brctl addif br-ext fxp0

export rootpassword hostname myip myipv6

# augment junos config with apply group, which gets applied if no config provided
# (apply-group statement is assumed to be present in existing config, allowing a user
# to not apply it at all)
CONFIG="${CONFIG-config.txt}"
if [ -f /u/$CONFIG ]; then
  source=$CONFIG
  CONFIG=$(basename $CONFIG)
  cp /u/$source /tmp/$CONFIG
else
  echo "apply-groups openjnpr-container-vmx;" > /tmp/$CONFIG
fi
/create_apply_group.sh >> /tmp/$CONFIG

ip=$(echo "$myip" | cut -d/ -f1)
echo "-----------------------------------------------------------------------"
echo "vMX $hostname ($ip) $RELEASE root password $rootpassword"
echo "-----------------------------------------------------------------------"
echo ""

brctl addbr br-int
ip addr add 128.0.0.16/8 dev br-int
ip link set up br-int
ip tuntap add dev em1 mode tap
ip link set em1 up promisc on
brctl addif br-int em1
brctl show

CFGDRIVE=/tmp/configdrive.qcow2
echo "Creating config drive $CFGDRIVE"
/create_config_drive.sh $CFGDRIVE /tmp/$CONFIG /u/$LICENSE

HDDIMAGE="/tmp/vmxhdd.img"
echo "Creating empty $HDDIMAGE for VCP ..."
qemu-img create -f qcow2 $HDDIMAGE 4G >/dev/null

echo "Starting PFE ..."
sh /start_pfe.sh &

echo "Booting VCP ..."
cd /tmp/
qemu-system-x86_64 -M pc --enable-kvm -cpu host  -smp 1 -m $VCPMEM \
  -smbios type=0,vendor=Juniper \
  -smbios type=1,manufacturer=VMX,product=VM-vcp_vmx1-161-re-0,version=0.1.0 \
  -no-user-config \
  -no-shutdown \
  -drive if=ide,file=$VCPIMAGE -drive if=ide,file=$HDDIMAGE \
  -drive if=ide,file=$CFGDRIVE \
  -device cirrus-vga,id=video0,bus=pci.0,addr=0x2 \
  -netdev type=tap,id=tc0,ifname=fxp0,script=no,downscript=no \
  -device virtio-net-pci,netdev=tc0,mac=$mymac \
  -netdev type=tap,id=tc1,ifname=em1,script=no,downscript=no \
  -device virtio-net-pci,netdev=tc1 \
  -nographic || true
