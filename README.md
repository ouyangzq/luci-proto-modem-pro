# luci-proto-modem-pro

**一个网络接口同时承载 IPv4 + IPv6。**

5G 模组传统上要建**两张** netifd 接口才能双栈：

```
modem0    proto=dhcp      → IPv4 地址 / 路由 / DNS
modem0_6  proto=dhcpv6    → IPv6 地址 / 默认路由 / 交给内网的前缀
```

本协议用**一张**接口做完这两件事。**已在 H29K + Fibocom FM160-CN 真机验证通过**：

```json
"proto": "modem_pro",
"ipv4-address": [ { "address": "10.82.128.172", "mask": 29 } ],
"ipv6-address": [ { "address": "240e:478:698:12a:...", "mask": 64 } ],
"route": [ { "target": "0.0.0.0", ... }, { "target": "::", ... } ],
"dns-server": [ "240e:5a::6666", "218.2.2.2", ... ],
"ipv6-prefix": [ { "address": "240e:478:698:12a::", "mask": 64,
                   "assigned": { "lan": { ... } } } ]
```

---

## ⚠️ 协议名是 `modem_pro`，不是 `modem-pro`

**包名**是 `luci-proto-modem-pro`（你要求的那个名字），但**协议名**必须是 `modem_pro`
（下划线）—— 因为 netifd 会按 `proto_${协议名}_setup` 去调函数，
**连字符在 shell 函数名里非法**，`proto_modem-pro_setup` 会被解析成
`proto_modem` 加参数 `-pro_setup`，报 `not found`。

官方协议全是这个约束（`dhcp` / `dhcpv6` / `qmi` / `464xlat` / `3g`，无一带连字符）。
LuCI 里显示的名字仍是「5G modem (modem_pro, IPv4 + IPv6 single interface)」。

---

## 一、原理（为什么官方要拆两张，我们能合一张）

`netifd` 的 `proto_run_command` 对同一个接口是「设一条、覆盖前一条」，所以一个
proto 脚本只能跟踪**一条**常驻命令。官方因此把 IPv4 / IPv6 拆成两张接口。

真正的障碍在**上报环节**：

```sh
# /lib/netifd/netifd-proto.sh
proto_init_update() { ...; PROTO_KEEP=0; ... }     # ← 默认 0
proto_set_keep()    { PROTO_KEEP="$1"; }
proto_send_update() { ...; json_add_boolean keep "$PROTO_KEEP"; ... }
```

`keep=0` 时 netifd **整体替换**接口的地址/路由表 —— 于是 `udhcpc` 报完 IPv4、
`odhcp6c` 再报 IPv6 时，**前者会被抹掉**。

`keep=1` 表示「**只更新我这次报的那部分，别动其它的**」。官方 `qmi.sh` 正是靠
这一点在一张接口上同时报 v4 和 v6。

本包的结构：

```
netifd ── proto_run_command ──> mp-client.sh           (唯一一条常驻命令)
                                   ├── udhcpc  -s /tmp/mp-dhcp-<iface>.script    (IPv4)
                                   └── odhcp6c -s /tmp/mp-dhcpv6-<iface>.script  (IPv6)
                                        │
                                        └─ 两个脚本里都有 proto_set_keep 1
                                           → 各自 proto_send_update $INTERFACE
                                           → netifd 合并，互不清空
```

两个客户端都靠环境变量 `INTERFACE` 认接口（由 `proto_export "INTERFACE=..."` 传下去，
wrapper 的子进程自动继承），所以报的是**同一个** netifd 接口。

### 上报脚本是运行时生成的，不是带的副本

`mp-client.sh` 启动时用 `sed` 从**官方**脚本现生成：

```sh
sed '/proto_init_update "\*" [01][[:space:]]*$/a proto_set_keep 1' \
	/lib/netifd/dhcp.script > /tmp/mp-dhcp-<iface>.script
```

改动**只有一处**（补一行 `proto_set_keep 1`）。好处：OpenWrt 升级 `netifd` 后
**自动跟随**，不会像带副本那样手里攥着一份过期代码。

---

## 二、安装

```sh
# 编译
make package/daocaoren/luci-proto-modem-pro/compile V=s

# 部署（OpenWrt 25.x 用 apk）
scp bin/packages/*/daocaoren/luci-proto-modem-pro_*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/luci-proto-modem-pro_*.apk'

# ⚠️ 新增 proto 脚本必须重启 netifd 才会被注册（reload 不重扫目录）
ssh root@192.168.1.1 '/etc/init.d/network restart'
ssh root@192.168.1.1 'rm -rf /tmp/luci-*; /etc/init.d/uhttpd restart'   # 清 LuCI 缓存
```

依赖：`odhcp6c`（IPv6 客户端）、`busybox`（`udhcpc`）、`luci-base`。

---

## 三、配置

**先备份**：

```sh
uci export network > /tmp/network.bak
```

改成单接口：

```sh
uci set network.modem0.proto='modem_pro'
uci set network.modem0.device='wwan0'
uci set network.modem0.ip6prefix='240e:xxxx:xxxx:xxxx::/64'   # 可选：把前缀交给内网
uci -q delete network.modem0_6                                 # 不再需要 v6 兄弟接口
uci commit network
ifup modem0
```

**验收**：

```sh
# 1. 一张接口上应该同时有 v4 和 v6
ubus call network.interface.modem0 status | grep -E '"proto"|address|nexthop'

# 2. 双栈都通
ping -4 -c 3 223.5.5.5
ping -6 -c 3 2400:3200::1

# 3. 内网设备拿到公网 IPv6 前缀
ip -6 addr show br-lan | grep 240e
```

**回滚**：

```sh
uci import network < /tmp/network.bak
/etc/init.d/network restart
```

---

## 四、文件清单

```
/lib/netifd/proto/modem_pro.sh                     netifd 协议脚本
/usr/lib/modem-pro/mp-client.sh                    wrapper：同时跑 udhcpc + odhcp6c
/www/luci-static/resources/protocol/modem_pro.js   LuCI 表单
```

---

## 五、注意事项

1. **`accept_ra` 强制设为 2**
   本机是转发设备（`forwarding=1`），内核此时**忽略** `accept_ra=1`，结果永远只有
   link-local。FM160-CN 的 IPv6 全靠 RA(SLAAC)，这步必需。可用 `accept_ra=0` 关掉。

2. **⚠️ `ifdown`/`ifup` 会打断 QMI 数据面**
   实测：换 proto 时 `ifdown modem0` → `wwan0` down/up 之后，**地址、路由、`link:1`
   全都正常，但网关 ping 不通**（FM160-CN 的经典毛病）。此时需要**重启厂商拨号器**
   重建数据面。这不是本协议的问题，是模组/驱动特性。

3. **前缀会随拨号漂移**
   运营商每次重拨可能给新前缀（实测见过 `240e:400:2408:1e38` → `240e:478:8840:200c`
   → `240e:478:698:12a`）。`ip6prefix` 需要跟着更新 —— 这正是 modemd
   「prefix handed to lan」那段逻辑在做的事。

4. **`ip6prefix` 单值 / list 都支持**
   modemd 写的是 `uci add_list`（list），手工配通常是 `uci set`（单值）。
   协议里两条路径都处理（`json_for_each_item` + 回退）。

5. **多模组**
   上报脚本按 `INTERFACE` 命名（`/tmp/mp-dhcp-<接口名>.script`），多张 modem_pro
   接口可以共存。

6. **`keep=1` 的副作用是有意的**
   `udhcpc` 单独掉线（租约丢失）时它上报的 `deconfig` 也带 keep，**不会**连带把
   IPv6 抹掉 —— 避免一次 DHCP 抖动把 v6 也带下水。接口整体 down 时
   （`proto_modem_pro_teardown`）**不设** keep，地址路由会被清干净。

7. **和 modemd 的关系**
   本包只做**接口层**。modemd 只需把 `proto` 从 `dhcp` 改成 `modem_pro` 并
   `del network.modem0_6` 即可，其余（拨号器托管、前缀下发）都不受影响。
# luci-proto-modem-pro
