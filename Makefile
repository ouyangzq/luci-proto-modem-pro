#
# luci-proto-modem-pro —— 一个网络接口同时承载 IPv4 + IPv6
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-proto-modem-pro
PKG_VERSION:=1.0.0
PKG_RELEASE:=2

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=daocaoren

include $(INCLUDE_DIR)/package.mk

define Package/luci-proto-modem-pro
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=LuCI protocol: modem-pro (one interface carries IPv4 + IPv6)
  DEPENDS:=+odhcp6c +busybox +luci-base
  PKGARCH:=all
endef

define Package/luci-proto-modem-pro/description
  An netifd protocol that runs IPv4 (DHCP) and IPv6 (SLAAC/DHCPv6) on a
  SINGLE network interface, so a 5G modem only needs one interface instead
  of the traditional pair (modem0 + modem0_6).
endef

define Build/Compile
endef

define Package/luci-proto-modem-pro/install
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./root/lib/netifd/proto/modem_pro.sh \
		$(1)/lib/netifd/proto/modem_pro.sh

	$(INSTALL_DIR) $(1)/usr/lib/modem-pro
	$(INSTALL_BIN) ./root/usr/lib/modem-pro/mp-client.sh \
		$(1)/usr/lib/modem-pro/mp-client.sh

	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./htdocs/luci-static/resources/protocol/modem_pro.js \
		$(1)/www/luci-static/resources/protocol/modem_pro.js
endef

$(eval $(call BuildPackage,luci-proto-modem-pro))
