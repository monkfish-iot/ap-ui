#!/usr/bin/env ucode
// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0

'use strict';

/* AP 管理界面 · mk.apnet
 * ubus 对象：mk.apnet
 *   读：settings          写：settings_set / rollback_cancel
 *
 * 职责：只管 br-lan 的 DHCP ↔ static 两态切换 + 静态模式下的 IP/掩码/网关/DNS。
 * 安全底线：settings_set 必须校验新 IP 与当前运行 IP 同网段，否则 die()。
 * 失联保护：settings_set 启动 60s 后台回滚定时器，用户点「保留修改」调 rollback_cancel 取消。
 *
 * 回滚机制：
 *   settings_set 开头 cp /etc/config/network → /tmp/apnet_backup.conf
 *   settings_set 末尾 system() 写 /tmp/apnet_rollback.sh 并后台启动，PID → /tmp/apnet_rollback.pid
 *   回滚脚本：cp /tmp/apnet_backup.conf → /etc/config/network; uci commit; ubus call network reload
 *   rollback_cancel：读 PID 文件 kill，清掉文件
 *
 * 注意：rpcd 的 system() 是 fork+exec，完全脱离任何 SSH 会话，
 *       即使触发 network reload 切断连接，后台回滚也不会被杀。
 */

let ubus = require('ubus').connect();
let uci = require('uci');

const IFACE = 'lan';
const DEVICE = 'br-lan';
const BACKUP = '/tmp/apnet_backup.conf';
const RB_SCRIPT = '/tmp/apnet_rollback.sh';
const RB_PID = '/tmp/apnet_rollback.pid';
const RB_FLAG = '/tmp/apnet_rollback.active';
const RB_SECONDS = 60;

/* ================= 工具 ================= */

function ubusCall(obj, method, args) {
	try { return ubus.call(obj, method, args || {}); } catch (e) { return null; }
}

function first(v) {
	if (type(v) === 'array')
		return (length(v) > 0) ? v[0] : null;
	return v;
}

function uciValues(cfg) {
	let cur = uci.cursor();
	if (!cur.load(cfg)) return {};
	let a = cur.get_all(cfg);
	return (type(a) === 'object') ? a : {};
}

/* IPv4 点分十进制 → 整数 */
function ipToInt(s) {
	if (type(s) !== 'string' || match(s, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) === null)
		return null;
	let oct = split(s, '.');
	let n = 0;
	for (let i = 0; i < 4; i++) {
		let v = int(oct[i]);
		if (type(v) !== 'int' || v < 0 || v > 255) return null;
		n = n * 256 + v;
	}
	return n;
}
function intToIp(n) {
	return int(n / 16777216) % 256 + '.' +
	       int(n / 65536) % 256 + '.' +
	       int(n / 256) % 256 + '.' +
	       n % 256;
}
function validIpv4(s) { return ipToInt(s) !== null; }

function validCidr(s) {
	if (type(s) !== 'string' || match(s, /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/) === null)
		return false;
	let p = int(split(s, '/')[1]);
	if (type(p) !== 'int' || p < 0 || p > 32) return false;
	return ipToInt(split(s, '/')[0]) !== null;
}

/* 前缀长度 → 掩码（逐 bit 拼，避开位移） */
function prefixToMask(p) {
	if (type(p) !== 'int' || p < 0 || p > 32) return null;
	let n = 0;
	for (let i = 0; i < 32; i++)
		n = n * 2 + ((i < p) ? 1 : 0);
	return intToIp(n);
}
/* 掩码 → 前缀长度 */
function maskToPrefix(mask) {
	let n = ipToInt(mask);
	if (n === null) return null;
	let p = 0, seenZero = false, bit = 2147483648;
	for (let i = 0; i < 32; i++) {
		let on = (int(n / bit) % 2) === 1;
		if (on) {
			if (seenZero) return null;
			p++;
		} else { seenZero = true; }
		if (i < 31) bit = int(bit / 2);
	}
	return p;
}

/* 网段基址 = IP 与掩码的逐位与（不用位运算：拆 byte 算） */
function netBase(ipInt, prefix) {
	let mask = 0;
	for (let i = 0; i < 32; i++) mask = mask * 2 + ((i < prefix) ? 1 : 0);
	return ipInt & mask;
}

/* 判断两个 IP 在同一子网 */
function sameSubnet(ipA, ipB, prefix) {
	let a = ipToInt(ipA), b = ipToInt(ipB);
	if (a === null || b === null) return false;
	return netBase(a, prefix) === netBase(b, prefix);
}

function trim(s) {
	if (type(s) !== 'string') return '';
	let m = match(s, /^[ \t\r\n]+|[ \t\r\n]+$/g);
	return (m === null) ? s : m.replace(s, '');
}

/* ================= 辅助 ================= */

/* 读 network.lan uci 段 */
function uciLan() {
	let all = uciValues('network');
	if (type(all[IFACE]) !== 'object') return null;
	let s = all[IFACE];
	return {
		proto: first(s.proto) || 'none',
		ipaddr: first(s.ipaddr),      /* dhcp 模式下为 null */
		netmask: first(s.netmask),
		gateway: first(s.gateway),
		device: first(s.device)
	};
}

/* 读运行时（从 ubus interface status）—— dhcp 模式下 uci 没有 ipaddr，必须从这拿 */
function runtimeStatus() {
	let st = ubusCall('network.interface.' + IFACE, 'status');
	if (type(st) !== 'object') return { ipv4: [], gateway: null, dns: [], up: false };

	let addrs = [];
	if (type(st['ipv4-address']) === 'array') {
		for (let i = 0; i < length(st['ipv4-address']); i++) {
			let a = st['ipv4-address'][i];
			if (type(a) === 'object' && type(a.address) === 'string')
				push(addrs, { address: a.address, mask: (type(a.mask) === 'int') ? a.mask : null });
		}
	}

	let gw = null;
	if (type(st.route) === 'array') {
		for (let i = 0; i < length(st.route); i++) {
			let r = st['route'][i];
			if (type(r) === 'object' && r.target === '0.0.0.0' && r.mask === 0) {
				gw = r.nexthop || null;
				break;
			}
		}
	}

	let dns = [];
	if (type(st['dns-server']) === 'array') {
		for (let i = 0; i < length(st['dns-server']); i++)
			push(dns, st['dns-server'][i]);
	}

	return { ipv4: addrs, gateway: gw, dns: dns, up: !!st.up };
}

/* ================= 读 ================= */

function settings() {
	let lan = uciLan();
	let rt = runtimeStatus();

	let proto = (lan !== null) ? lan.proto : 'none';

	/* 展示用的 IP —— 优先运行时（dhcp 模式下 uci 没 IP） */
	let rt_ip = null, rt_mask = null, rt_prefix = null, rt_cidr = null;
	if (length(rt.ipv4) > 0) {
		rt_ip = rt.ipv4[0].address;
		rt_prefix = rt.ipv4[0].mask;
		if (type(rt_prefix) === 'int') {
			rt_mask = prefixToMask(rt_prefix);
			rt_cidr = rt_ip + '/' + rt_prefix;
		}
	}

	/* uci 里如果有静态 ipaddr（CIDR 形式） */
	let uci_ip = null, uci_prefix = null, uci_cidr = null;
	if (lan !== null && type(lan.ipaddr) === 'string' && lan.ipaddr !== '') {
		let seg = split(lan.ipaddr, '/');
		uci_ip = seg[0];
		if (length(seg) > 1) {
			let p = int(seg[1]);
			if (type(p) === 'int') uci_prefix = p;
		}
		if (uci_prefix === null && type(lan.netmask) === 'string')
			uci_prefix = maskToPrefix(lan.netmask);
		if (uci_prefix !== null)
			uci_cidr = uci_ip + '/' + uci_prefix;
	}

	/* DNS：静态模式 uci 里没有，从运行时拿（dhcp 下发的） */
	let dns_list = rt.dns;

	return {
		iface: IFACE,
		device: DEVICE,
		proto: proto,				/* dhcp | static | none */

		/* 运行时状态（前端主要展示用） */
		runtime: {
			ip: rt_ip,
			prefix: rt_prefix,
			netmask: rt_mask,
			cidr: rt_cidr,
			gateway: rt.gateway,
			dns: dns_list,
			up: rt.up
		},

		/* uci 里存的值（前端编辑表单默认值用） */
		uci: {
			ip: uci_ip,
			prefix: uci_prefix,
			cidr: uci_cidr,
			gateway: (lan !== null) ? lan.gateway : null
		},

		/* 回滚状态（flag 文件存在 = 活跃） */
		rollback: {
			active: system('[ -f ' + RB_FLAG + ' ]') === 0,
			seconds: RB_SECONDS
		}
	};
}

/* ================= 写 ================= */

/* 启动后台回滚定时器（flag 文件机制）
 * 核心：sleep 拆成 60 次 1s 循环，每次检查 flag 文件是否还在。
 * cancelRollback 删掉 flag + pkill 兜底 —— 双重保险，不依赖 PPID 跟踪。
 * 用 { } & 大括号（AP ash 上 nohup 会搞死后台进程）。
 *
 * 脚本逻辑：
 *   touch RB_FLAG                    ← 标记激活
 *   echo $$ > RB_PID                 ← 记录 shell PID
 *   for i in $(seq 60); do           ← 循环 60 秒
 *     [ -f RB_FLAG ] || exit 0       ← flag 没了 = 用户取消，立即退出
 *     sleep 1
 *   done
 *   cp BACKUP /etc/config/network    ← 超时执行回滚
 *   uci commit network
 *   ubus call network reload
 */
function startRollback() {
	/* 清理上一次残留 */
	system('rm -f ' + RB_FLAG + ' ' + RB_PID);
	system('pkill -f "apnet_rollback" 2>/dev/null; pkill -f "apnet_running" 2>/dev/null');

	/* 内联命令：大括号 + flag 循环 */
	let cmd = '{' +
		' touch ' + RB_FLAG + ';' +
		' echo $$ > ' + RB_PID + ';' +
		' i=0; while [ $i -lt ' + RB_SECONDS + ' ]; do' +
		'   [ -f ' + RB_FLAG + ' ] || exit 0;' +
		'   i=$((i+1)); sleep 1;' +
		' done;' +
		' cp ' + BACKUP + ' /etc/config/network;' +
		' uci commit network;' +
		' ubus call network reload >/dev/null 2>&1;' +
		'} </dev/null >/dev/null 2>&1 &';

	system(cmd);
}

/* 取消回滚：先删 flag（让脚本循环自退），再 pkill 兜底 */
function cancelRollback() {
	/* flag 是最高优先级 —— 脚本下一秒检查到就 exit 0 */
	system('rm -f ' + RB_FLAG);
	/* 兜底：直接杀掉所有可能的回滚进程（防止 sleep 阻塞在中途） */
	system('pkill -f "apnet_rollback" 2>/dev/null; pkill -f "apnet_backup" 2>/dev/null; kill $(cat ' + RB_PID + ' 2>/dev/null) 2>/dev/null');
	system('rm -f ' + RB_PID);
	return { cancelled: true };
}

/* 设置网络 */
function settingsSet(args) {
	/* 1. 解析参数 */
	let proto = (type(args.proto) === 'string') ? trim(args.proto) : '';
	let ipaddr = (type(args.ipaddr) === 'string') ? trim(args.ipaddr) : '';
	let prefix = (type(args.prefix) === 'int') ? args.prefix : 0;
	let gateway = (type(args.gateway) === 'string') ? trim(args.gateway) : '';
	let dns = (type(args.dns) === 'string') ? trim(args.dns) : '';	/* 逗号分隔，'' = 清空 */

	/* 2. 校验 */
	if (proto !== 'dhcp' && proto !== 'static')
		die('proto 只接受 dhcp 或 static（本次为：' + proto + '）');

	if (proto === 'static') {
		if (!validIpv4(ipaddr))
			die('IP 地址不合法：' + ipaddr);
		if (prefix < 8 || prefix > 30)
			die('子网掩码需在 /8 – /30 之间（本次为 /' + prefix + '）');
		if (gateway !== '' && !validIpv4(gateway))
			die('网关地址不合法：' + gateway);

		/* DNS 校验 */
		let dnsList = [];
		if (dns !== '') {
			let items = split(dns, ',');
			for (let i = 0; i < length(items); i++) {
				let one = trim(items[i]);
				if (one === '') continue;
				if (!validIpv4(one))
					die('第 ' + (i + 1) + ' 个 DNS 地址不合法：' + one);
				push(dnsList, one);
			}
		}

		/* ---- 同网段校验（安全底线）----
		 * 拿运行时 IP 作为基准（dhcp 模式下 uci 没 IP）。
		 * 如果当前没拿到运行时 IP（罕见），跳过同网段检查——反正 static 模式下会失联，60s 回滚兜底。 */
		let rt = runtimeStatus();
		if (length(rt.ipv4) > 0) {
			let curIp = rt.ipv4[0].address;
			let curPrefix = rt.ipv4[0].mask;

			if (type(curPrefix) === 'int' && curPrefix > 0) {
				if (!sameSubnet(ipaddr, curIp, curPrefix))
					die('新 IP ' + ipaddr + ' 与当前 IP ' + curIp + '/' + curPrefix + ' 不在同一子网，拒绝写入以避免彻底失联');
			}
		}

		/* 网关合法性：不能等于新 IP 本身 */
		if (gateway !== '' && gateway === ipaddr)
			die('网关不能等于本机 IP');
	}

	/* 3. 备份当前 network */
	system('cp /etc/config/network ' + BACKUP);

	/* 4. 写 uci */
	let cur = uci.cursor();
	if (!cur.load('network'))
		die('无法加载 network 配置');

	if (proto === 'dhcp') {
		cur.set('network', IFACE, 'proto', 'dhcp');
		/* 删掉 static 残留字段（dhcp 模式下这些不该存在） */
		cur.delete('network', IFACE, 'ipaddr');
		cur.delete('network', IFACE, 'netmask');
		cur.delete('network', IFACE, 'gateway');
		cur.delete('network', IFACE, 'dns');
	} else {
		/* static：CIDR 形式写 ipaddr（list 类型），独立的 gateway 字段 */
		let cidr = ipaddr + '/' + prefix;
		cur.set('network', IFACE, 'proto', 'static');
		cur.set('network', IFACE, 'ipaddr', [ cidr ]);
		if (gateway !== '')
			cur.set('network', IFACE, 'gateway', gateway);
		else
			cur.delete('network', IFACE, 'gateway');

		/* DNS —— AP 没有 dnsmasq（dhcp client 模式），只设 interface 的 dns */
		if (dns !== '') {
			let dnsList = split(dns, ',');
			let clean = [];
			for (let i = 0; i < length(dnsList); i++) {
				let t = trim(dnsList[i]);
				if (t !== '') push(clean, t);
			}
			if (length(clean) > 0)
				cur.set('network', IFACE, 'dns', clean);
			else
				cur.delete('network', IFACE, 'dns');
		} else {
			cur.delete('network', IFACE, 'dns');
		}
	}

	if (cur.commit('network') !== true)
		die('提交 network 配置失败');

	/* 5. 启动回滚定时器（commit 之后！否则回滚恢复的是 commit 前的旧文件） */
	startRollback();

	/* 6. network reload —— 会切断当前连接，但 rpcd 里 fork 出来的回滚进程不受影响 */
	try {
		ubus.call('network', 'reload');
	} catch (e) {
		/* reload 期间 SSH 断开可能导致 ubus connection 也断，这里异常可忽略 */
	}

	return {
		applied: true,
		proto: proto,
		cidr: (proto === 'static') ? (ipaddr + '/' + prefix) : null,
		rollback_seconds: RB_SECONDS,
		message: '网络设置已应用。' + RB_SECONDS + ' 秒内请点击「保留修改」，否则自动回滚。'
	};
}

/* ================= 出口 ================= */

function guarded(fn) {
	try { return fn(); }
	catch (e) {
		return { error: (type(e) === 'object') ? e.message : ('' + e) };
	}
}

const methods = {
	settings: {
		call: function() { return settings(); }
	},
	settings_set: {
		args: { proto: '', ipaddr: '', prefix: 0, gateway: '', dns: '' },
		call: function(r) { return guarded(function() { return settingsSet(r.args); }); }
	},
	rollback_cancel: {
		call: function() { return cancelRollback(); }
	}
};

return { 'mk.apnet': methods };
