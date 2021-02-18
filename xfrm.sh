set -eu
SRC=${SRC-'192.168.1.1'}
DST=${DST-'192.168.1.2'}
OFFLOAD=${OFFLOAD-''}

OFFLOAD_O=''
OFFLOAD_I=''
if [[ -n ${OFFLOAD} ]]; then
	OFFLOAD_O="offload dev ${OFFLOAD} dir out"
	OFFLOAD_I="offload dev ${OFFLOAD} dir in"
fi


O=1
I=2
aedkey_i='0x1111111111111111111111111111111111111111'
aedkey_o='0x2222222222222222222222222222222222222222'

HOST=$(hostname)
if [ "$HOST" = "perf2" ] ; then
	SWAP=${SRC}
	SRC=${DST}
	DST=${SWAP}

	SWAP=${O}
	O=${I}
	I=${SWAP}

	SWAP=${aedkey_i}
	aedkey_i=${aedkey_o}
	aedkey_o=${SWAP}
fi

aeadivlen=96 #bits
e_i="aead rfc4106(gcm(aes)) ${aedkey_i} ${aeadivlen}"
e_o="aead rfc4106(gcm(aes)) ${aedkey_o} ${aeadivlen}"

ip xfrm policy add src ${SRC}/32 dst ${DST}/32 dir out \
                tmpl src ${SRC} dst ${DST} proto esp reqid ${O} mode tunnel
ip x p add src ${DST}/32 dst ${SRC}/32 dir in \
                tmpl src ${DST} dst ${SRC} proto esp reqid ${I} mode tunnel

ip x s add src ${DST} dst ${SRC} proto esp spi ${I} reqid ${I} mode tunnel ${e_o} ${OFFLOAD_I}
ip x s add src ${SRC} dst ${DST} proto esp spi ${O} reqid ${O} mode tunnel ${e_i} replay-window 32  ${OFFLOAD_O}
