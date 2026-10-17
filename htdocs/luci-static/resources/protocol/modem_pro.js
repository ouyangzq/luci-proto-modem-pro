'use strict';
'require form';
'require network';

/*
 * Modem-Pro —— 5G 模组的单接口协议（IPv4 + IPv6 一起）
 *
 * 与官方 dhcp / dhcpv6 的区别：官方那两个各管一半，必须拆成两张接口；
 * 本协议在一张接口上同时跑 udhcpc(IPv4) 与 odhcp6c(IPv6)，两边各自上报、
 * 互不清空（靠 proto_set_keep 1 实现）。
 *
 * ⚠️ 协议注册名（uci 里的 proto= 值）是 modem_pro —— 不能写连字符，
 *    netifd 按 proto_${名}_setup 调函数，而 `-` 在 shell 函数名里非法。
 *    这里 getI18n() 返回的才是界面上显示的名字。
 */
return network.registerProtocol('modem_pro', {
	getI18n: function() {
		return _('Modem-Pro');
	},

	getPackageName: function() {
		return 'luci-proto-modem-pro';
	},

	renderFormOptions: function(s) {
		var o;

		/* ================= IPv4（udhcpc） ================= */

		o = s.taboption('general', form.Value, 'hostname',
			_('Hostname to send'),
			_('Optional hostname sent to the modem\'s built-in DHCP server.'));
		o.placeholder = _('(device hostname)');

		o = s.taboption('advanced', form.Value, 'clientid',
			_('Client ID to send when requesting DHCP'),
			_('Hex string. Leave empty to use the hardware address.'));
		o.datatype = 'hexstring';

		o = s.taboption('advanced', form.Value, 'vendorid',
			_('Vendor Class to send when requesting DHCP'));

		o = s.taboption('advanced', form.Flag, 'broadcast',
			_('Use broadcast flag'),
			_('Required for some ISPs, but unnecessary in most cases.'));

		/* ================= IPv6（odhcp6c） ================= */

		o = s.taboption('general', form.ListValue, 'reqaddress',
			_('Request IPv6-address'),
			_('Request an IPv6 address via DHCPv6 (IA_NA). Most 5G modems deliver IPv6 by SLAAC/RA instead, so "try" is fine.'));
		o.value('try', _('try'));
		o.value('force', _('force'));
		o.value('none', _('disabled'));
		o.default = 'try';

		o = s.taboption('general', form.ListValue, 'reqprefix',
			_('Request IPv6-prefix'),
			_('Prefix delegation (IA_PD). FM160-CN and most QMI modems do NOT do PD, so leave this on "Automatic".'));
		o.value('auto', _('Automatic'));
		o.value('no', _('disabled'));
		o.value('48');
		o.value('52');
		o.value('56');
		o.value('60');
		o.value('64');
		o.default = 'auto';

		o = s.taboption('general', form.Value, 'ip6prefix',
			_('IPv6 prefix to hand to the LAN'),
			_('The prefix obtained from the modem (e.g. %s). The router will assign it to the LAN, so LAN clients get a public IPv6 address. Filled automatically by modemd; normally you should not need to touch this.').format('<code>240e:xxxx:xxxx:xxxx::/64</code>'));
		o.datatype = 'cidr6';

		o = s.taboption('advanced', form.Value, 'ip6ifaceid',
			_('Override IPv6 interface ID'),
			_('Override the interface identifier used with the delegated prefix.'));
		o.datatype = 'ip6addr';

		o = s.taboption('advanced', form.Value, 'soltimeout',
			_('DHCPv6 solicit timeout'),
			_('Seconds to wait for the first RA/DHCPv6 reply before giving up.'));
		o.datatype = 'uinteger';
		o.placeholder = '120';

		o = s.taboption('advanced', form.Flag, 'accept_ra',
			_('Force accept_ra=2 on the device'),
			_('Enabled by default. Required because this router forwards IPv6 (forwarding=1), and the kernel ignores RA with accept_ra=1 in that case — without it you only ever get a link-local address.'));
		o.default = '1';

		/* ================= 公共 ================= */

		o = s.taboption('advanced', form.Value, 'mtu',
			_('Override MTU'),
			_('Maximum transmission unit. Leave empty unless you know it is needed.'));
		o.datatype = 'max(9200)';
		o.placeholder = '1500';

		o = s.taboption('advanced', form.Value, 'zone',
			_('Firewall zone name'),
			_('Custom firewall zone name exported to the DHCP scripts (rarely needed).'));
	}
});
