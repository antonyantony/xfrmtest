#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# In Namespace 0 (at_ns0) using native tunnel
# Overlay IP: 172.16.1.100
# veth0 IP: 172.16.1.100, tunnel dev <type>00

# Out of Namespace get/get on lwtunnel
# Overlay IP: 172.16.1.200
# local 172.16.1.200 remote 172.16.1.100
# veth1 IP: 172.16.1.200, tunnel dev <type>11

function config_device {
	ip netns add at_ns0
	ip link add veth0 type veth peer name veth1
	ip link set veth0 netns at_ns0
	ip netns exec at_ns0 ip addr add 172.16.1.100/24 dev veth0
	ip netns exec at_ns0 ip link set dev veth0 up
	ip link set dev veth1 up mtu 1500
	ip addr add dev veth1 172.16.1.200/24
	# address & route inside the name space
	# ip netns exec at_ns0  ip route add 172.16.1.200 dev veth0 via 172.16.1.200 src 172.16.1.100
}

function test_iperf_server {
	ip netns exec at_ns0 iperf -s &
	serverpid=$!
}

function test_iperf { 
	outfile=$1
	iperf -c 172.16.1.100 | tee $outfile
	tp=$(grep bits $outfile)
	echo $tp
}

function setup_xfrm_tunnel {
	e=$1
	printf "Setup xfrm with ${e}\n"
	cbcauth=0x$(printf '1%.0s' {1..40})
	cbckey=0x$(printf '2%.0s' {1..32})
	spi_in_to_out=0x1
	spi_out_to_in=0x2
	aedkey='0x010203047aeaca3f87d060a12f4a4487d5a5c335'
	aeadivlen=96 #bits

	case "${e}" in
	gcm )
		enc="aead rfc4106(gcm(aes)) ${aedkey} ${aeadivlen}"
		;;

	cbc )
		enc="auth-trunc hmac(sha1) $cbcauth 96 enc cbc(aes) $cbckey"
		;;
	
	*)
		echo "unknow encrypter ${e}"
		exit 1
		;;
	esac


	ip netns exec at_ns0 \
		ip xfrm state add src 172.16.1.100 dst 172.16.1.200 proto esp \
			spi $spi_in_to_out reqid 1 mode tunnel ${enc}
	ip netns exec at_ns0 \
		ip xfrm policy add src 172.16.1.100/32 dst 172.16.1.200/32 dir out \
		tmpl src 172.16.1.100 dst 172.16.1.200 proto esp reqid 1 \
		mode tunnel
	# out -> in
	ip netns exec at_ns0 \
		ip xfrm state add src 172.16.1.200 dst 172.16.1.100 proto esp \
			spi $spi_out_to_in reqid 2 mode tunnel ${enc}
	ip netns exec at_ns0 \
		ip xfrm policy add src 172.16.1.200/32 dst 172.16.1.100/32 dir in \
		tmpl src 172.16.1.200 dst 172.16.1.100 proto esp reqid 2 \
		mode tunnel

	# out of namespace
	# in -> out
	ip xfrm state add src 172.16.1.100 dst 172.16.1.200 proto esp \
		spi $spi_in_to_out reqid 1 mode tunnel ${enc}
	ip xfrm policy add src 172.16.1.100/32 dst 172.16.1.200/32 dir in \
		tmpl src 172.16.1.100 dst 172.16.1.200 proto esp reqid 1 \
		mode tunnel
	# out -> in
	ip xfrm state add src 172.16.1.200 dst 172.16.1.100 proto esp \
		spi $spi_out_to_in reqid 2 mode tunnel ${enc}
	ip xfrm policy add src 172.16.1.200/32 dst 172.16.1.100/32 dir out \
		tmpl src 172.16.1.200 dst 172.16.1.100 proto esp reqid 2 \
		mode tunnel
}

function test_clear_baseline {
	config_device
	test_iperf_server 
	sleep 1
	echo "plain text base line"
	test_iperf "iperf-clear.txt"
	tpclear=$(grep bits "iperf-clear.txt")
}

function test_xfrm_tunnels {
	for e in "gcm" "cbc"
	do
		setup_xfrm_tunnel ${e}
		test_iperf "iperf-${e}.txt"
		ip xfrm s | grep seq
		ip netns exec at_ns0  ip xfrm s | grep seq
		cleanup_xfrm
	done
}

function cleanup_xfrm_ns {
		ip netns exec at_ns0 ip netns exec at_ns0 ip x s flush
		ip netns exec at_ns0 ip netns exec at_ns0 ip x p flush
}

function cleanup_xfrm {
	cleanup_xfrm_ns
	ip x s flush
	ip x p flush
}

function cleanup {
	set +eu
	pidof iperf && pkill iperf 2>&1 > /dev/null
	ip netns delete at_ns0
	cleanup_xfrm
	ip link del veth1
	if [ -n "${serverpid}" ]; then
		kill ${serverpid} 2>&1 > /dev/null
	fi
	rm -fr  iperf-*.txt
	set -eu
}
function gather_host_info {
	cpus=$(cat /proc/cpuinfo  | grep "processor" |wc -l)
	echo "CPUs $cpus"
 	model=$(cat /proc/cpuinfo  | grep "model name" | sort -u)
}
function summary {
	set +ex
	echo "CPUs $cpus ${model}"
	printf "Throughput clear\n$tpclear\n"
	for e in "gcm" "cbc"
	do
		tp=$(grep bits "iperf-${e}.txt")
		printf "Throughput encrypted ${e} \n${tp}\n"
	done
	set -eu
}

echo "Testing IPsec tunnel..."
cleanup 
gather_host_info
test_clear_baseline
test_xfrm_tunnels
summary
echo "*** PASS ***"
