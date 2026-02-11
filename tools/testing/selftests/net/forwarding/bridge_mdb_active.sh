#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# +-------+      +---------+
# | brq0  |      | br0     |
# | + $h1 |      | + $swp1 |
# +----|--+      +----|----+
#      |              |
#      \--------------/
#
#
# This script checks if we have the expected mcast_active_v{4,6} state
# on br0 in a variety of scenarios. This state determines if ultimately
# multicast snooping is applied to multicast data packets
# (multicast snooping active) or if they are (by default) flooded instead
# (multicast snooping inactive).
#
# Notably, multicast snooping can be enabled but still be inactive if not all
# requirements to safely apply multicast snooping to multicast data packets
# are met.
#
# Depending on the test case an IGMP/MLD querier might be on brq0, on br0
# or neither.


ALL_TESTS="
	test_inactive
	test_active_other_querier
	test_active_own_querier
	test_inactive_brdown
	test_inactive_nov6
	test_inactive_snooping_off
	test_inactive_querier_off
	test_inactive_other_querier_norespdelay
	test_inactive_own_querier_norespdelay
	test_inactive
	test_vlan_inactive
	test_vlan_active_other_querier
	test_vlan_active_own_querier
	test_vlan_inactive_brdown
	test_vlan_inactive_nov6
	test_vlan_inactive_snooping_off
	test_vlan_inactive_vlans_snooping_off
	test_vlan_inactive_vlan_snooping_off
	test_vlan_inactive_other_querier_norespdelay
	test_vlan_inactive_own_querier_norespdelay
"
#	test_vlan_active_own_querier
ALL_TESTS="
	test_vlan_inactive_brdown
"

NUM_NETIFS=2
MCAST_MAX_RESP_IVAL_SEC=1
MCAST_VLAN_ID=42
source lib.sh

switch_create()
{
	ip link add dev br0 type bridge\
		vlan_filtering 0 \
		mcast_query_response_interval $((MCAST_MAX_RESP_IVAL_SEC*100))\
		mcast_snooping 0 \
		mcast_vlan_snooping 0
	ip link add dev brq0 type bridge\
		vlan_filtering 0 \
		mcast_query_response_interval $((MCAST_MAX_RESP_IVAL_SEC*100))\
		mcast_snooping 0 \
		mcast_vlan_snooping 0

	echo 1 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
	echo 1 > /proc/sys/net/ipv6/conf/brq0/disable_ipv6

	ip link set dev "$swp1" master br0
	ip link set dev "$h1" master brq0

	ip link set dev "$h1" up
	ip link set dev "$swp1" up
}

switch_destroy()
{
	ip link set dev "$swp1" down
	ip link set dev "$h1" down

	ip link del dev brq0
	ip link del dev br0
}

setup_prepare()
{
	h1=${NETIFS[p1]}
	swp1=${NETIFS[p2]}

	switch_create
}

cleanup()
{
	pre_cleanup
	switch_destroy
}

mcast_active_check()
{
	local af="$1"
	local state="$2"
	local lineno="$3"
	local ret

	ip -d -j link show dev br0\
		| jq -e ".[] | select(.linkinfo.info_data.mcast_active_$af == $state)"\
		&> /dev/null
	ret="$?"

	if [ "$state" -eq 0 ]; then
		check_err "$ret" "$lineno: Mcast inactive check failed ($af)"
	elif [ "$state" -eq 1 ]; then
		check_err "$ret" "$lineno: Mcast active check failed ($af)"
	fi
}

mcast_vlan_active_check()
{
	local af="$1"
	local state="$2"
	local lineno="$3"
	local vid="${MCAST_VLAN_ID}"
	local ret

	bridge -j vlan global show dev br0\
		| jq -e ".[].vlans.[] | select(.vlan == $vid and .mcast_active_$af == 1)"\
		&> /dev/null
	ret="$?"

	if [ "$state" -eq 0 ]; then
		if [ "$ret" -eq 0 ]; then
			check_err 1 "$lineno: Mcast VLAN inactive check failed ($af)"
		fi
	elif [ "$state" -eq 1 ]; then
		if [ "$ret" -ne 0 ]; then
			check_err 1 "$lineno: Mcast VLAN active check failed ($af)"
		fi
	fi
}

mcast_assert_active_v4()
{
	mcast_active_check "v4" "1" "$1"
}

mcast_assert_active_v6()
{
	mcast_active_check "v6" "1" "$1"
}

mcast_assert_inactive_v4()
{
	mcast_active_check "v4" "0" "$1"
}

mcast_assert_inactive_v6()
{
	mcast_active_check "v6" "0" "$1"
}

mcast_vlan_assert_active_v4()
{
	mcast_vlan_active_check "v4" "1" "$1"
}

mcast_vlan_assert_active_v6()
{
	mcast_vlan_active_check "v6" "1" "$1"
}

mcast_vlan_assert_inactive_v4()
{
	mcast_vlan_active_check "v4" "0" "$1"
}

mcast_vlan_assert_inactive_v6()
{
	mcast_vlan_active_check "v6" "0" "$1"
}

test_inactive_nolog()
{
	ip link set dev br0 down
	ip link set dev brq0 down
	ip link set dev br0 type bridge mcast_snooping 0
	ip link set dev brq0 type bridge mcast_snooping 0
	ip link set dev br0 type bridge mcast_querier 0
	ip link set dev brq0 type bridge mcast_querier 0
	ip link set dev br0 type bridge mcast_vlan_snooping 0
	ip link set dev br0 type bridge vlan_filtering 0

	echo 1 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
	echo 1 > /proc/sys/net/ipv6/conf/brq0/disable_ipv6

	mcast_assert_inactive_v4 "$1"
	mcast_assert_inactive_v6 "$1"
}

test_inactive()
{
	RET=0

	test_inactive_nolog "$1"
	log_test "Mcast inactive test"
}

wait_lladdr_dad() {
	local check_tentative

	check_tentative="map(select(.scope == \"link\" and ((.tentative == true) | not))) | .[]"

	ip -6 -j a s dev "$1"\
		| jq -e ".[].addr_info | ${check_tentative}" &> /dev/null
}

test_active_setup_bridge()
{
	[ -n "$1" ] && echo 0 > /proc/sys/net/ipv6/conf/br0/disable_ipv6
	[ -n "$2" ] && echo 0 > /proc/sys/net/ipv6/conf/brq0/disable_ipv6

	[ -n "$3" ] && ip link set dev br0 up
	[ -n "$4" ] && ip link set dev brq0 up
	[ -n "$5" ] && slowwait 3 wait_lladdr_dad br0
	[ -n "$6" ] && slowwait 3 wait_lladdr_dad brq0
}

test_active_setup_config()
{
	[ -n "$1" ] && ip link set dev br0 type bridge mcast_snooping 1
	[ -n "$2" ] && ip link set dev brq0 type bridge mcast_snooping 1
	[ -n "$3" ] && ip link set dev br0 type bridge mcast_querier 1
	[ -n "$4" ] && ip link set dev brq0 type bridge mcast_querier 1
}

test_active_setup_wait()
{
	sleep $((MCAST_MAX_RESP_IVAL_SEC * 2))
}

test_active_setup_reset_own_querier()
{
	ip link set dev br0 type bridge mcast_querier 0
	ip link set dev br0 type bridge mcast_querier 1

	test_active_setup_wait
}

test_vlan_active_setup_config()
{
	[ -n "$1" ] && ip link set dev br0 type bridge vlan_filtering 1
	[ -n "$2" ] && ip link set dev brq0 type bridge vlan_filtering 1
	[ -n "$3" ] && ip link set dev br0 type bridge mcast_vlan_snooping 1
	[ -n "$4" ] && ip link set dev brq0 type bridge mcast_vlan_snooping 1
}

test_vlan_active_setup_add_vlan()
{
	bridge vlan add vid "${MCAST_VLAN_ID}" dev "$swp1"
	bridge vlan add vid "${MCAST_VLAN_ID}" dev "$h1"
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev br0\
		mcast_query_response_interval $((MCAST_MAX_RESP_IVAL_SEC*100))
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev brq0\
		mcast_query_response_interval $((MCAST_MAX_RESP_IVAL_SEC*100))
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev br0 mcast_snooping 0
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev brq0 mcast_snooping 0
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev br0 mcast_querier 0
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev brq0 mcast_querier 0
}

test_vlan_active_setup_config_vlan()
{
	[ -n "$1" ] && bridge vlan global set vid "${MCAST_VLAN_ID}" dev br0 mcast_snooping 1
	[ -n "$2" ] && bridge vlan global set vid "${MCAST_VLAN_ID}" dev brq0 mcast_snooping 1
	[ -n "$3" ] && bridge vlan global set vid "${MCAST_VLAN_ID}" dev br0 mcast_querier 1
	[ -n "$4" ] && bridge vlan global set vid "${MCAST_VLAN_ID}" dev brq0 mcast_querier 1
}

test_vlan_teardown()
{
	bridge vlan del vid "${MCAST_VLAN_ID}" dev "$swp1"
	bridge vlan del vid "${MCAST_VLAN_ID}" dev "$h1"
	mcast_assert_inactive_v4 "$1"
	mcast_assert_inactive_v6 "$1"
	mcast_vlan_assert_inactive_v4 "$1"
	mcast_vlan_assert_inactive_v6 "$1"
}

test_vlan_active_setup_reset_own_querier()
{
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev br0 mcast_querier 0
	bridge vlan global set vid "${MCAST_VLAN_ID}" dev br0 mcast_querier 1

	test_active_setup_wait
}

test_active_other_querier_nolog()
{
	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  "4"
	test_active_setup_wait

	mcast_assert_active_v4 "$1"
	mcast_assert_active_v6 "$1"
}

test_active_other_querier()
{
	RET=0

	test_active_other_querier_nolog "$LINENO"
	test_inactive_nolog "$LINENO"
	log_test "Mcast active with other querier test"
}

test_active_own_querier_nolog()
{
	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" "3" ""
	test_active_setup_wait

	mcast_assert_active_v4 "$1"
	mcast_assert_active_v6 "$1"
}

test_active_own_querier()
{
	RET=0

	test_active_own_querier_nolog "$LINENO"
	test_inactive_nolog "$LINENO"
	log_test "Mcast active with own querier test"
}

test_active_final()
{
	mcast_assert_active_v4 "$1"
	mcast_assert_active_v6 "$1"

	test_inactive_nolog "$1"
}

test_inactive_brdown()
{
	RET=0

	test_active_setup_bridge "1" "2" ""  "4" ""  "6"
	test_active_setup_config "1" "2" "3" ""
	test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_active_setup_bridge ""  ""  "3" ""  ""  ""
	mcast_assert_active_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_active_setup_bridge ""  ""  ""  ""  "5" ""
	test_active_setup_reset_own_querier
	test_active_final "$LINENO"

	log_test "Mcast inactive, bridge down test"
}

test_inactive_nov6()
{
	RET=0

	test_active_setup_bridge ""  "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" "3" ""
	test_active_setup_wait

	mcast_assert_active_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_active_setup_bridge "1" ""  ""  ""  "5" ""
	test_active_setup_reset_own_querier
	test_active_final "$LINENO"

	log_test "Mcast inactive, own querier, no IPv6 address test"
}

test_inactive_snooping_off()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config ""  "2" "3" ""
	test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_active_setup_config "1" ""  ""  ""
	test_active_setup_reset_own_querier
	test_active_final "$LINENO"

	log_test "Mcast inactive, snooping disabled test"
}

test_inactive_querier_off()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_active_setup_config ""  ""  "3" ""
	test_active_setup_wait
	test_active_final "$LINENO"

	log_test "Mcast inactive, no querier test"
}

test_inactive_other_querier_norespdelay()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" "3" ""
	# skipping: test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_active_setup_wait
	test_active_final "$LINENO"

	log_test "Mcast inactive, other querier, no response delay test"
}

test_inactive_own_querier_norespdelay()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  "4"
	# skipping: test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_active_setup_wait
	test_active_final "$LINENO"

	log_test "Mcast inactive, own querier, no response delay test"
}

test_vlan_inactive()
{
	RET=0

	test_inactive_nolog "$LINENO"
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"

	ip link set dev br0 type bridge vlan_filtering 1
	ip link set dev br0 type bridge mcast_vlan_snooping 1
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"
	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	ip link set dev br0 type bridge mcast_vlan_snooping 0
	ip link set dev br0 type bridge vlan_filtering 0
	test_active_own_querier_nolog "$LINENO"
	ip link set dev br0 type bridge vlan_filtering 1
	mcast_assert_active_v4 "$LINENO"
	mcast_assert_active_v6 "$LINENO"

	ip link set dev br0 type bridge mcast_vlan_snooping 1
	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"

	test_inactive_nolog "$LINENO"
	log_test "Mcast VLAN inactive test"
}

test_vlan_active_final()
{
	mcast_assert_inactive_v4 "$1"
	mcast_assert_inactive_v6 "$1"
	mcast_vlan_assert_active_v4 "$1"
	mcast_vlan_assert_active_v6 "$1"

	test_vlan_teardown "$1"
	test_inactive_nolog "$1"
}

test_vlan_active_other_querier()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" ""  "4"
	test_active_setup_wait
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN active, other querier test"
}

test_vlan_active_own_querier()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" "3" ""
	test_active_setup_wait
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN active, own querier test"
}

test_vlan_inactive_brdown()
{
	RET=0

	test_active_setup_bridge "1" "2" ""  "4" ""  "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" "3" ""
	test_active_setup_wait

	log_info "~~~ here: $LINENO, RET: $RET"
	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"
	log_info "~~~ here: $LINENO, RET: $RET"

	test_active_setup_bridge ""  ""  "3" ""  ""  ""
	log_info "~~~ here: $LINENO, RET: $RET"
	test_active_setup_wait
	log_info "~~~ here: $LINENO, RET: $RET"
	mcast_vlan_assert_active_v4 "$LINENO"
	log_info "~~~ here: $LINENO, RET: $RET"
	mcast_assert_inactive_v6 "$LINENO"

	log_info "~~~ here: $LINENO, RET: $RET"
	test_active_setup_bridge ""  ""  ""  ""  "5" ""
	test_vlan_active_setup_reset_own_querier
	test_vlan_active_final "$LINENO, RET: $RET"

	log_info "~~~ here: $LINENO, RET: $RET"
	log_test "Mcast VLAN inactive, bridge down test"
}

test_vlan_inactive_nov6()
{
	RET=0

	test_active_setup_bridge ""  "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" "3" ""
	test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"
	mcast_vlan_assert_active_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"

	test_active_setup_bridge "1" ""  ""  ""  "5" ""
	test_vlan_active_setup_reset_own_querier
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN inactive, own querier, no IPv6 address test"
}

test_vlan_inactive_snooping_off()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config ""  "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" "3" ""
	test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"

	test_active_setup_config "1" ""  ""  ""
	test_vlan_active_setup_reset_own_querier
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN inactive, snooping disabled test"
}

test_vlan_inactive_vlans_snooping_off()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" ""  "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" "3" ""
	test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"

	test_vlan_active_setup_config ""  ""  "3" ""
	test_vlan_active_setup_reset_own_querier
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN inactive, snooping for VLANs disabled test"
}

test_vlan_inactive_vlan_snooping_off()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan ""  "2" "3" ""
	test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"

	test_vlan_active_setup_config_vlan "1" ""  ""  ""
	test_vlan_active_setup_reset_own_querier
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN inactive, snooping for this VLAN disabled test"
}

test_vlan_inactive_other_querier_norespdelay()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" ""  "4"
	# skipping: test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"

	test_active_setup_wait
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN inactive, other querier, no response delay test"
}

test_vlan_inactive_own_querier_norespdelay()
{
	RET=0

	test_active_setup_bridge "1" "2" "3" "4" "5" "6"
	test_active_setup_config "1" "2" ""  ""
	test_vlan_active_setup_config "1" "2" "3" "4"
	test_vlan_active_setup_add_vlan
	test_vlan_active_setup_config_vlan "1" "2" "3" ""
	# skipping: test_active_setup_wait

	mcast_assert_inactive_v4 "$LINENO"
	mcast_assert_inactive_v6 "$LINENO"
	mcast_vlan_assert_inactive_v4 "$LINENO"
	mcast_vlan_assert_inactive_v6 "$LINENO"

	test_active_setup_wait
	test_vlan_active_final "$LINENO"

	log_test "Mcast VLAN inactive, own querier, no response delay test"
}

trap cleanup EXIT

setup_prepare

if ! ip -d link show dev br0 2>&1 | grep -q "mcast_active"; then
	echo "SKIP: iproute2 too old, missing mcast_active support"
	exit "$ksft_skip"
fi

setup_wait
tests_run

exit "$EXIT_STATUS"
