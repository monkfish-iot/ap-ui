#!/usr/bin/env ucode
// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0

'use strict';

/* AP-UI · mk.apinfo
 * ubus 对象：mk.apinfo
 * 方法：overview —— 一次返回运行信息页所需全部数据
 *
 * 返回形状：
 * {
 *   system:  { hostname, model, board, firmware, kernel, uptime,
 *              mem_total, mem_free, mem_avail },
 *   network: { proto, ipaddr, netmask, gateway, dns[], mac,
 *              dhcp_server_on_brlan: true/false },
 *   traffic: { iface, rx_bytes, tx_bytes },   // iface=定位到的上行口；rx=下行、tx=上行
 *   radios:  [ { index, device, channel, bandwidth, txpower, noise,
 *                link_quality, link_quality_max, ssid, encryption,
 *                client_count } ],
 *   clients: [ { mac, signal, quality, rate, connected } ]
 * }
 */

import { readfile, popen } from 'fs';

let ubus = require('ubus').connect();
let uci  = require('uci');

function ubusCall(object, method, args) {
	try {
		return ubus.call(object, method, args || {});
	} catch (e) {
		return null;
	}
}

/* =============================================================
 * system info
 * ============================================================= */

/* 执行命令并取回 stdout（fs.popen） */
function shOut(cmd) {
	let fh = null;
	try { fh = popen(cmd); } catch (e) { return ''; }
	if (fh === null)
		return '';
	let out = '';
	try {
		let chunk = fh.read(4096);
		while (chunk !== null && chunk !== '') {
			out += chunk;
			chunk = fh.read(4096);
		}
	} catch (e) {}
	try { fh.close(); } catch (e) {}
	return out;
}

/* 默认网关 IP（network.interface.lan status 中 target 0.0.0.0 / mask 0 的 nexthop） */
function defaultGatewayIp() {
	let st = ubusCall('network.interface.lan', 'status');
	if (type(st) !== 'object' || type(st.route) !== 'array')
		return '';
	for (let i = 0; i < length(st.route); i++) {
		let r = st.route[i];
		if (r.target !== '0.0.0.0' || (r.mask !== 0 && r.mask !== null))
			continue;
		return (type(r.nexthop) === 'string') ? r.nexthop : '';
	}
	return '';
}

/* /proc/net/arp → 指定 IP 的 MAC（未解析或全 0 返回 ''） */
function arpMac(ip) {
	if (ip === '')
		return '';
	let content = '';
	try { content = readfile('/proc/net/arp') || ''; } catch (e) { return ''; }
	let lines = split(content, '\n');
	for (let i = 1; i < length(lines); i++) {
		let f = split(trim(lines[i]), /[[:space:]]+/);
		if (length(f) < 4 || f[0] !== ip)
			continue;
		if (f[3] === '00:00:00:00:00:00')
			return '';
		return f[3];
	}
	return '';
}

/* 网桥成员口 ↔ 端口号（brctl showstp 的行首形如 "wan (2)"，注意与 brctl show 的列出顺序不同） */
function bridgePortMap(bridge) {
	let out = shOut('/usr/sbin/brctl showstp ' + bridge);
	let map = {};
	let lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++) {
		let m = match(lines[i], /^([A-Za-z0-9._-]+) \(([0-9]+)\)/);
		if (m !== null)
			map[m[2]] = m[1];
	}
	return map;
}

/* 网桥 FDB：MAC → 端口号（只取非 local 表项，跳过网桥自身的 MAC） */
function bridgeFdbPort(bridge, mac) {
	if (mac === '')
		return '';
	let out = shOut('/usr/sbin/brctl showmacs ' + bridge);
	let lines = split(out, '\n');
	for (let i = 0; i < length(lines); i++) {
		let m = match(lines[i], /^[[:space:]]*([0-9]+)[[:space:]]+([0-9a-fA-F:]+)[[:space:]]+([a-z]+)/);
		if (m === null || m[3] !== 'no' || m[2] !== mac)
			continue;
		return m[1];
	}
	return '';
}

/* /proc/net/dev → 指定 iface 的累计收发字节；接口不存在返回 null
 * 行格式：  br-lan: rx_bytes rx_packets ...（共 8 个） tx_bytes tx_packets ...
 * split 后 nums[0]=rx_bytes，nums[8]=tx_bytes */
function readIfaceCounters(iface) {
	if (iface === '')
		return null;
	let content = '';
	try { content = readfile('/proc/net/dev') || ''; } catch (e) { return null; }
	let lines = split(content, '\n');
	for (let i = 0; i < length(lines); i++) {
		let m = match(lines[i], /^[[:space:]]*([A-Za-z0-9._-]+):(.*)$/);
		if (m === null || m[1] !== iface)
			continue;
		let nums = split(trim(m[2]), /[[:space:]]+/);
		if (length(nums) < 9)
			continue;
		return { rx: int(nums[0]) || 0, tx: int(nums[8]) || 0 };
	}
	return null;
}

/* 上行口 ifname：默认网关 MAC 在网桥 FDB 中所落的成员口（换网线可自动跟随）。
 * 返回 '' 表示未能定位到。 */
function uplinkIface() {
	let mac = arpMac(defaultGatewayIp());
	if (mac === '')
		return '';
	let pno = bridgeFdbPort('br-lan', mac);
	if (pno === '')
		return '';
	let map = bridgePortMap('br-lan');
	return (type(map[pno]) === 'string') ? map[pno] : '';
}

/* 实时流量计数（前端做差分算速率）
 *
 * 注意：不能读网桥设备 br-lan —— Linux 网桥自身的收发计数只统计上送本机
 * 协议栈的帧（管理/ARP/DHCP），转发帧不计入，累计值几乎不动。
 * 故取「上行口」（默认网关所在桥成员口）的计数：rx=下行、tx=上行。 */
function collectTraffic() {
	let iface = uplinkIface();
	if (iface !== '') {
		let c = readIfaceCounters(iface);
		if (c !== null)
			return { iface: iface, rx_bytes: c.rx, tx_bytes: c.tx };
	}

	/* 退化 1：按常见上行口名挑一个存在的接口 */
	let cands = ['wan', 'eth0'];
	for (let i = 0; i < length(cands); i++) {
		let cc = readIfaceCounters(cands[i]);
		if (cc !== null)
			return { iface: cands[i], rx_bytes: cc.rx, tx_bytes: cc.tx };
	}

	/* 退化 2：网桥设备本身（仅本机终结流量，聊胜于无） */
	let cb = readIfaceCounters('br-lan');
	if (cb !== null)
		return { iface: 'br-lan', rx_bytes: cb.rx, tx_bytes: cb.tx };
	return { iface: '-', rx_bytes: 0, tx_bytes: 0 };
}

/* HE20 / HT40 / VHT80 / EHT160 → 20 / 40 / 80 / 160 */
function htWidth(htmode) {
	if (type(htmode) !== 'string' || htmode === '')
		return null;
	let m = match(htmode, /[0-9]+$/);
	if (m === null || length(m) < 1)
		return null;
	return int(m[0]);
}

/* =============================================================
 * network
 * ============================================================= */

/* br-lan 上是否还开着 dnsmasq DHCP 服务器（dhcp.lan.ignore 不存在即为在线） */
function dhcpServerOnBrlan() {
	try {
		let cur = uci.cursor();
		/* uci get dhcp.lan.ignore —— 字段不存在时 uci 会报错或返回空 */
		let v = null;
		try { v = cur.get('dhcp', 'lan', 'ignore'); } catch (e) { v = null; }
		/* type(v) === 'undefined' 或 v === null 或 v === '' → 没 ignore，DHCP 服务器在线 */
		if (type(v) === 'undefined' || v === null || v === '')
			return true;
		return false;
	} catch (e) {
		return false;
	}
}

function collectNetwork() {
	let st = ubusCall('network.interface.lan', 'status');
	if (type(st) !== 'object')
		return { proto: '-', ipaddr: '-', netmask: '-', gateway: '-', dns: [], mac: '-' };

	let v4 = (type(st['ipv4-address']) === 'array' && length(st['ipv4-address']) > 0)
		? st['ipv4-address'][0]
		: {};

	let dns = (type(st['dns-server']) === 'array') ? st['dns-server'] : [];

	let gateway = '-';
	/* AP 上 route 是 target:"0.0.0.0", mask:0（不是 "0.0.0.0/0"）*/
	if (type(st.route) === 'array') {
		for (let i = 0; i < length(st.route); i++) {
			let r = st.route[i];
			if (r.target === '0.0.0.0' && (r.mask === 0 || r.mask === null)) {
				gateway = r.nexthop || '-';
				break;
			}
		}
	}

	/* MAC：network.device status br-lan 的 macaddr 字段（不是 mac-address）*/
	let mac = '-';
	let ds = ubusCall('network.device', 'status', { name: 'br-lan' });
	if (type(ds) === 'object' && ds.macaddr)
		mac = ds.macaddr;
	else {
		let dev = st.device || 'br-lan';
		try {
			let m = readfile('/sys/class/net/' + dev + '/address');
			if (m !== null && m !== '') mac = trim(m);
		} catch (e) {}
	}

	return {
		proto: st.proto || '-',
		ipaddr: v4.address || '-',
		netmask: v4.mask || '-',
		gateway: gateway,
		dns: dns,
		mac: mac,
		dhcp_server_on_brlan: dhcpServerOnBrlan()
	};
}

/* =============================================================
 * radios & clients
 * ============================================================= */

/* network.wireless status → 所有 Master 接口的 ifname（phy*-ap*）
 * 真机实测：interfaces[].mode 在 interfaces[].config.mode 里！ */
function masterIfaces() {
	let st = ubusCall('network.wireless', 'status');
	if (type(st) !== 'object')
		return [];

	let out = [];
	let radios = keys(st);
	for (let i = 0; i < length(radios); i++) {
		let r = st[radios[i]];
		if (type(r) !== 'object')
			continue;
		let ifaces = (type(r.interfaces) === 'array') ? r.interfaces : [];
		for (let j = 0; j < length(ifaces); j++) {
			let it = ifaces[j];
			if (type(it) !== 'object')
				continue;
			/* mode 在 it.config.mode 里！*/
			let cfg = (type(it.config) === 'object') ? it.config : {};
			if (cfg.mode !== 'ap')
				continue;
			if (it.ifname && it.ifname !== '')
				push(out, it.ifname);
		}
	}
	return out;
}

function collectRadios() {
	/* 真机实测：ucode 内部通过 ubus.call 调 iwinfo 会卡 rpcd -t 30 秒超时
	 * （嵌套调用死锁）。改为：overview 不碰 iwinfo，
	 * 前端直接调 ubus call iwinfo info（绕过 mk.*，单独 loading）。
	 * 这里返回空数组 + 提示字段让前端知道需要额外调用。*/
	return [];
}

function collectClients() {
	return [];
}

/* =============================================================
 * collectSystem（复用 system info 的 root 字段拿 overlay）
 * ============================================================= */

function collectSystem() {
	let board = ubusCall('system', 'board');
	if (type(board) !== 'object') board = {};

	let info = ubusCall('system', 'info');
	if (type(info) !== 'object') info = {};

	let mem  = (type(info.memory) === 'object') ? info.memory : {};
	let release = (type(board.release) === 'object') ? board.release : {};

	return {
		hostname: board.hostname || '',
		model: board.model || '',
		board: board.board_name || '',
		firmware: release.version || '',
		kernel: board.kernel || '',
		uptime: int(info.uptime || 0),
		mem_total: int(mem.total  || 0),
		mem_free:  int(mem.free   || 0),
		mem_avail: int(mem.available || 0)
	};
}

/* =============================================================
 * 汇总
 * ============================================================= */

function overview() {
	return {
		system:  collectSystem(),
		network: collectNetwork(),
		traffic: collectTraffic(),
		radios:  collectRadios(),
		clients: collectClients()
	};
}

const methods = {
	overview: {
		call: function(request) {
			try {
				return overview();
			} catch (e) {
				system('logger -t mk.apinfo "overview error: ' + e + '"');
				return { error: '' + e };
			}
		}
	}
};

return { 'mk.apinfo': methods };
