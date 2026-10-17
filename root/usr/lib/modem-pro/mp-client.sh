#!/bin/sh
# modem-pro —— 客户端 wrapper：在一个进程里同时跑 udhcpc(IPv4) 与 odhcp6c(IPv6)
#
# 【为什么需要 wrapper】
# netifd 的 proto_run_command 对同一接口是「设一条、覆盖前一条」，一个 proto 只能
# 跟踪一条常驻命令。所以这里用本脚本当那唯一的一条命令，由它同时拉起两个客户端。
#
# 【两个客户端怎么做到互不干扰】
# 它们各自调用自己的上报脚本（dhcp.script / dhcpv6.script），而 netifd 的
# proto_send_update 会带一个 keep 标志：keep=1 表示「只更新我这次报的那部分，
# 别动其它的」。官方脚本里 keep 是 0，所以 v4 报完 v6 报、v6 会把 v4 抹掉 ——
# 这正是官方要把 IPv4/IPv6 拆成两张接口的根本原因。
#
# 【为什么不直接带一份改过的脚本副本】
# 那样 OpenWrt 升级 netifd 后我们手里就是过期拷贝了。这里改成**运行时**用 sed
# 从官方脚本生成一份「带 keep 的副本」，随装随用，永远跟官方同步。
#
# 【2026-10-13 重要加固：不再「任一客户端退出就整体退出」】
# 真机踩过坑：wwan0 载波抖动时 odhcp6c 会退出一次，旧版 wrapper 立刻整体退出，
# netifd 随即重启整个协议；而 netifd 收尾用 SIGKILL 时本脚本的 trap 来不及跑，
# 于是 udhcpc/odhcp6c 变孤儿继续占着 wwan0 —— 新实例更收不到 RA，形成雪崩
# （实测 5 秒一轮、几十次重拨，最后连内网 IPv6 都因 odhcpd 绑定失效而全掉）。
# 现在改成：
#   · 启动前先清掉同接口的残留客户端（孤儿）
#   · 单个客户端退出 → 只把它自己重新拉起来（最多连续 MAX_FAILS 次）
#   · 只有连续失败到上限，才整体退出让 netifd 重启协议
#   · trap 同时挂 TERM/INT/HUP 和 EXIT，尽量不留尾巴

set -u

IFACE="${MP_IFACE:-${1:-}}"
[ -n "$IFACE" ] || { logger -t modem-pro "mp-client: 缺少接口名"; exit 1; }
[ -n "${INTERFACE:-}" ] || { logger -t modem-pro "mp-client: 缺少 INTERFACE 环境变量"; exit 1; }

V4_SCRIPT="/tmp/mp-dhcp-${INTERFACE}.script"
V6_SCRIPT="/tmp/mp-dhcpv6-${INTERFACE}.script"

MAX_FAILS=5	# 单个客户端连续退出这么多次才整体重启协议
POLL=3		# 巡检间隔（秒）

gen_script() {
	local src="$1" out="$2"

	[ -r "$src" ] || { logger -t modem-pro "mp-client: 找不到 $src"; return 1; }

	# 匹配行尾的 proto_init_update "*" 0 / "*" 1，紧跟其后插入 proto_set_keep 1
	sed '/proto_init_update "\*" [01][[:space:]]*$/a proto_set_keep 1' "$src" > "$out" 2>/dev/null
	[ -s "$out" ] || { rm -f "$out"; return 1; }
	chmod 0755 "$out"
	return 0
}

# 清掉**同一个接口**上残留的旧客户端（孤儿）。
# 判据：命令行里带着我们这份 instance 专属的上报脚本路径
# （脚本名里含 $INTERFACE，所以别的 modem_pro 接口不受影响）。
cleanup_stale() {
	local p cmd n=0

	for p in /proc/[0-9]*; do
		p="${p#/proc/}"
		[ "$p" = "$$" ] && continue
		# 进程可能刚好在这行之前退出 —— 读不到就跳过（不要刷错误日志）
		[ -r "/proc/$p/cmdline" ] || continue
		cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
		[ -n "$cmd" ] || continue
		case "$cmd" in
			*"mp-dhcp-${INTERFACE}.script"*|*"mp-dhcpv6-${INTERFACE}.script"*)
				kill -9 "$p" 2>/dev/null && n=$((n + 1))
				;;
		esac
	done
	[ "$n" -gt 0 ] && logger -t modem-pro "mp-client: 清掉 $n 个残留客户端（避免孤儿占着 $IFACE）"
	return 0
}

UDHCPC_PID=""
ODHCP6C_PID=""
STOPPING=0

start_udhcpc() {
	# shellcheck disable=SC2086
	udhcpc -i "$IFACE" \
		-s "$V4_SCRIPT" \
		-f -R \
		-p "/var/run/mp-udhcpc-${INTERFACE}.pid" \
		${MP_UOPTS:-} &
	UDHCPC_PID=$!
	logger -t modem-pro "mp-client: udhcpc 已拉起 (pid $UDHCPC_PID)"
}

# -P0 = 请求前缀委派（hint 0），与官方 dhcpv6.sh 的默认一致；
# 顺便也让 RFC 7278 的 extendprefix 流程走起来。
start_odhcp6c() {
	# shellcheck disable=SC2086
	odhcp6c -s "$V6_SCRIPT" ${MP_OOPTS:-} -P0 "$IFACE" &
	ODHCP6C_PID=$!
	logger -t modem-pro "mp-client: odhcp6c 已拉起 (pid $ODHCP6C_PID)"
}

cleanup() {
	STOPPING=1
	[ -n "$UDHCPC_PID" ] && kill "$UDHCPC_PID" 2>/dev/null
	[ -n "$ODHCP6C_PID" ] && kill "$ODHCP6C_PID" 2>/dev/null
	sleep 1
	[ -n "$UDHCPC_PID" ] && kill -9 "$UDHCPC_PID" 2>/dev/null
	[ -n "$ODHCP6C_PID" ] && kill -9 "$ODHCP6C_PID" 2>/dev/null
	cleanup_stale
	rm -f "$V4_SCRIPT" "$V6_SCRIPT"
	return 0
}

# 收到 TERM/INT/HUP：清干净再退出（exit 会再触发下面的 EXIT trap，cleanup 幂等，跑两次无害）
trap 'cleanup; exit 0' TERM INT HUP
# 无论如何退出都清一遍（但**不能**在这里 exit，否则递归）
trap 'cleanup' EXIT

logger -t modem-pro "mp-client: 启动 $INTERFACE（设备 $IFACE）"

cleanup_stale

gen_script /lib/netifd/dhcp.script   "$V4_SCRIPT" || { logger -t modem-pro "mp-client: 生成 v4 上报脚本失败"; exit 1; }
gen_script /lib/netifd/dhcpv6.script "$V6_SCRIPT" || { logger -t modem-pro "mp-client: 生成 v6 上报脚本失败"; exit 1; }

start_udhcpc
sleep 1
start_odhcp6c

UFAIL=0
OFAIL=0

while [ "$STOPPING" = "0" ]; do
	sleep "$POLL"
	[ "$STOPPING" = "1" ] && break

	if kill -0 "$UDHCPC_PID" 2>/dev/null; then
		UFAIL=0
	else
		UFAIL=$((UFAIL + 1))
		if [ "$UFAIL" -ge "$MAX_FAILS" ]; then
			logger -t modem-pro "mp-client: udhcpc 连续退出 $UFAIL 次 → 整体重启协议（交给 netifd）"
			exit 1
		fi
		logger -t modem-pro "mp-client: udhcpc 退出，重新拉起（第 $UFAIL 次）"
		start_udhcpc
	fi

	if kill -0 "$ODHCP6C_PID" 2>/dev/null; then
		OFAIL=0
	else
		OFAIL=$((OFAIL + 1))
		if [ "$OFAIL" -ge "$MAX_FAILS" ]; then
			logger -t modem-pro "mp-client: odhcp6c 连续退出 $OFAIL 次 → 整体重启协议（交给 netifd）"
			exit 1
		fi
		logger -t modem-pro "mp-client: odhcp6c 退出，重新拉起（第 $OFAIL 次）"
		start_odhcp6c
	fi
done

cleanup
exit 0
