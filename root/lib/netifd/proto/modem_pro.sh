#!/bin/sh
# modem-pro —— 一个 netifd 接口同时承载 IPv4(DHCP) 与 IPv6(SLAAC/DHCPv6)
#
# 【为什么要这么写】
# netifd 的 proto_run_command 对同一个接口是「设一条、覆盖前一条」，所以一个 proto
# 只能跟踪一条常驻命令。官方因此把 IPv4 和 IPv6 拆成两张接口（dhcp + dhcpv6）。
# 这里换一个思路：只起一个 wrapper（mp-client.sh），由它同时拉起
#     · udhcpc  -> 向模组内置的 DHCP 服务器取 IPv4 地址 / 默认路由 / DNS
#     · odhcp6c -> 收模组的 RA / DHCPv6，取 IPv6 地址、默认路由与前缀
# 两个客户端各自调用各自的上报脚本（mp-dhcp.script / mp-dhcpv6.script），
# 而那两个脚本内部都调用了 proto_set_keep 1 —— 这是关键：
#     netifd 的 proto_send_update 会带一个 keep 标志，keep=1 表示
#     “只更新我报的这部分，别动别的”，于是 v4 与 v6 各报各的、互不清空。
# （不设 keep 的话，后报的那一半会把先报的那一半抹掉。）

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. /lib/functions/network.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_modem_pro_init_config() {
	available=1
	no_device=0

	# ---- IPv4（交给 udhcpc）----
	proto_config_add_string "hostname"
	proto_config_add_string "clientid"
	proto_config_add_string "vendorid"
	proto_config_add_boolean "broadcast"
	proto_config_add_string "reqopts:list(string)"

	# ---- IPv6（交给 odhcp6c）----
	proto_config_add_string 'reqaddress:or("try","force","none")'
	proto_config_add_string "reqprefix"
	proto_config_add_string "ip6prefix"
	proto_config_add_string "ip6ifaceid:ip6addr"
	proto_config_add_int "soltimeout"
	proto_config_add_boolean "accept_ra"
	proto_config_add_boolean "extendprefix"

	# ---- 公共 ----
	proto_config_add_int "metric"
	proto_config_add_int "mtu"
	proto_config_add_string "zone"
}

# accept_ra 必须 >= 2。
# 本机是转发设备（net.ipv6.conf.*.forwarding=1），这种情况下内核**忽略** accept_ra=1，
# 结果就是永远只有 link-local —— 实测这台 Fibocom FM160-CN 的 IPv6 全靠 RA(SLAAC)，
# 不开这个什么都拿不到。odhcp6c 会主动发 RS，所以这里是「发 RS 之前」设好即可。
proto_modem_pro_fix_accept_ra() {
	local dev="$1"
	local f="/proc/sys/net/ipv6/conf/$dev/accept_ra"

	[ -e "$f" ] || {
		logger -t modem-pro "警告：$f 不存在（设备 $dev 还没起来？），跳过 accept_ra 设置"
		return 0
	}

	[ "$(cat "$f" 2>/dev/null)" = "2" ] && return 0

	if echo 2 > "$f" 2>/dev/null; then
		logger -t modem-pro "已把 $dev 的 accept_ra 设为 2"
	else
		logger -t modem-pro "警告：$dev 的 accept_ra 设置失败，IPv6 可能只有 link-local"
	fi
}

# json_for_each_item 的回调（$1=值 $3=输出变量名）
proto_modem_pro_add_prefix() {
	append "$3" "$1"
}

proto_modem_pro_setup() {
	local interface="$1"
	local iface="$2"

	local hostname clientid vendorid broadcast reqopts
	local reqaddress reqprefix ip6prefix ip6prefixes ip6ifaceid soltimeout accept_ra extendprefix
	local metric mtu zone opt

	json_get_vars hostname clientid vendorid broadcast reqopts
	json_get_vars reqaddress reqprefix ip6prefix ip6ifaceid soltimeout accept_ra extendprefix
	json_get_vars metric mtu zone

	[ -n "$iface" ] || {
		proto_notify_error "$interface" NO_DEVICE
		proto_block_restart "$interface"
		return 1
	}

	# ---------------- IPv6 准备 ----------------
	# ip6prefix 在 uci 里既可能是 option（单值）也可能是 list，两种都收
	json_for_each_item proto_modem_pro_add_prefix ip6prefix ip6prefixes
	[ -z "$ip6prefixes" ] && [ -n "$ip6prefix" ] && ip6prefixes="$ip6prefix"

	[ "$accept_ra" = "0" ] || proto_modem_pro_fix_accept_ra "$iface"

	local oopts=""
	[ -n "$reqaddress" ] && [ "$reqaddress" != "auto" ] && append oopts "-N$reqaddress"
	case "$reqprefix" in
		""|auto|no) ;;
		*) append oopts "-P$reqprefix" ;;
	esac
	[ -n "$ip6ifaceid" ] && append oopts "-i$ip6ifaceid"
	append oopts "-t${soltimeout:-120}"

	# ---------------- IPv4 准备 ----------------
	local uopts=""
	[ "$broadcast" = "1" ] && append uopts "-B"
	[ -n "$hostname" ] && append uopts "-x hostname:$hostname"
	[ -n "$vendorid" ] && append uopts "-V $vendorid"
	[ -n "$clientid" ] && append uopts "-x 0x3d:$clientid"
	for opt in $reqopts; do
		append uopts "-O $opt"
	done
	append uopts "-O 121"	# classless static routes (RFC 3442)

	# ---------------- MTU（可选）----------------
	if [ -n "$mtu" ]; then
		ip link set dev "$iface" mtu "$mtu" 2>/dev/null
	fi

	# ---------------- 交给 wrapper ----------------
	# proto_export 出来的变量会作为环境变量传给 proto_run_command 启动的进程，
	# wrapper 及其子进程（udhcpc / odhcp6c）都会继承 —— 这正是两个客户端能
	# 往同一个 netifd 接口上报的原因（上报脚本读的就是 $INTERFACE）。
	proto_export "INTERFACE=$interface"
	proto_export "MP_IFACE=$iface"
	proto_export "MP_UOPTS=$uopts"
	proto_export "MP_OOPTS=$oopts"
	[ -n "$ip6prefixes" ] && proto_export "USERPREFIX=$ip6prefixes"
	[ -n "$zone" ] && proto_export "ZONE=$zone"

	# RFC 7278：模组只发 RA、不做 DHCPv6-PD（FM160-CN 就是这种）时，
	# 让 odhcp6c 把 RA 里的 /64 直接当**前缀**上报，netifd 会自动分给 LAN。
	# 好处是**前缀漂移自动跟随** —— 运营商换前缀时 odhcp6c 收到新 RA 会自动重新上报，
	# 既不用改 ip6prefix、也不用 ifup（而 ifup 会重启 wrapper、可能打断 QMI 数据面）。
	# 默认开。想关：uci set network.<接口>.extendprefix=0
	[ "$extendprefix" = "0" ] || proto_export "EXTENDPREFIX=1"

	local ep="关"
	[ "$extendprefix" = "0" ] || ep="开（RFC 7278，RA 里的 /64 自动交给内网）"
	logger -t modem-pro "启动接口 $interface（设备 $iface）: v4=[$uopts] v6=[$oopts] 手工前缀=[$ip6prefixes] 自动跟随=$ep"

	proto_run_command "$interface" /usr/lib/modem-pro/mp-client.sh
}

proto_modem_pro_teardown() {
	local interface="$1"

	proto_kill_command "$interface"

	# 这里**不设 keep**：接口自己 down 了，地址/路由该一起清掉
	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol modem_pro
}
