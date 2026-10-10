#!/usr/bin/env ucode
// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0

'use strict';

/* AP 管理界面 · mk.apwireless
 * ubus 对象：mk.apwireless
 *   读：info（无线射频 / 接口参数）
 *
 * 职责：供「无线信息」页做**只读参数展示**（本页不提供任何写方法）。
 * 数据来源：
 *   · uci wireless 配置       —— 静态参数（频段 / 信道 / HT 模式 / SSID / 加密 / 绑定网络）
 *   · network.wireless status —— netifd 运行时状态（射频是否 up、接口名 phy0-ap0）
 *
 * 硬件限制（项目经验）：**不能**在本插件里调用 iwinfo。
 *   iwinfo 是 rpcd 自带插件，rpcd 托管对象内再嵌套 ubus 调用会死锁超时。
 *   因此射频的实时信道 / 发射功率 / 噪声 / 链路质量由前端直接调 iwinfo info，
 *   信道扫描由前端直接调 iwinfo scan。
 *
 * 前端用到但此处不产出的运行时字段：由 iwinfo info 提供，按 ifname 关联。
 */

let ubus = require('ubus').connect();
let uci  = require('uci');

/* ================= 基础工具 ================= */

function ubusCall(object, method, args) {
	try {
		return ubus.call(object, method, args || {});
	} catch (e) {
		return null;
	}
}

/* 直接读 uci 文件（原生 uci 模块）。get_all() 形状：
 * { 段名: {'.type','.name','.index','.anonymous', 字段...} }，列表型选项是数组。 */
function uciValues(config) {
	let cur = uci.cursor();
	if (!cur.load(config))
		return {};

	let all = cur.get_all(config);
	return (type(all) === 'object') ? all : {};
}

/* uci 值可能是标量也可能是数组；统一取首个标量。
 * 注意：缺失键本身就是 null，不能拿 type(null) 判（它返回空串），一律用 === null */
function first(v) {
	if (type(v) === 'array')
		return (length(v) > 0) ? v[0] : null;
	return v;
}

/* 取字符串值（数字也转成字符串，便于前端统一展示） */
function strOf(v) {
	let s = first(v);
	if (type(s) === 'string') return s;
	if (type(s) === 'int' || type(s) === 'double') return '' + s;
	return '';
}

function bandLabel(band) {
	if (band === '2g') return '2.4 GHz';
	if (band === '5g') return '5 GHz';
	if (band === '6g') return '6 GHz';
	return (type(band) === 'string') ? band : '';
}

/* HE20 / HT40 / VHT80 / EHT160 末尾的数字即频宽 MHz */
function htWidth(htmode) {
	if (type(htmode) !== 'string' || htmode === '')
		return null;

	let m = match(htmode, /[0-9]+$/);
	if (m === null || length(m) < 1)
		return null;

	return int(m[0]);
}

function htmodeLabel(htmode) {
	let w = htWidth(htmode);
	if (w === null) return (htmode === '') ? '-' : htmode;
	return htmode + '（' + w + ' MHz）';
}

/* 加密方式 → 中文文案 */
function encLabel(id) {
	if (id === '' || id === 'none') return '开放（不加密）';
	if (id === 'wep') return 'WEP';
	if (id === 'psk') return 'WPA-PSK（WPA1）';
	if (id === 'psk2') return 'WPA2-PSK';
	if (id === 'psk-mixed' || id === 'psk2+psk') return 'WPA/WPA2 混合';
	if (id === 'sae') return 'WPA3-SAE';
	if (id === 'psk2+sae' || id === 'sae-mixed') return 'WPA2/WPA3 混合';
	return id;
}

function modeLabel(mode) {
	if (mode === 'ap') return 'AP（热点）';
	if (mode === 'sta') return '客户端（STA）';
	if (mode === 'mesh') return 'Mesh 组网';
	if (mode === 'adhoc') return 'Ad-Hoc（自组网）';
	if (mode === 'monitor') return '监听（Monitor）';
	return (mode === '') ? '-' : mode;
}

/* ================= network.wireless 运行时状态 ================= */

/* netifd 的 wireless 状态不是 rpcd 托管对象，可安全嵌套调用 */
function wirelessStatus() {
	let st = ubusCall('network.wireless', 'status');
	return (type(st) === 'object') ? st : {};
}

/* 取指定射频下第一个运行中的无线 netdev 名 */
function radioIfname(rstat) {
	if (type(rstat) !== 'object' || type(rstat.interfaces) !== 'array')
		return '';

	for (let i = 0; i < length(rstat.interfaces); i++) {
		let it = rstat.interfaces[i];
		if (type(it) === 'object' && type(it.ifname) === 'string' && it.ifname !== '')
			return it.ifname;
	}

	return '';
}

/* 按 section 名（如 default_radio0）找该接口运行时的 ifname */
function ifaceIfname(rstat, section) {
	if (type(rstat) !== 'object' || type(rstat.interfaces) !== 'array')
		return '';

	for (let i = 0; i < length(rstat.interfaces); i++) {
		let it = rstat.interfaces[i];
		if (type(it) === 'object' && it.section === section)
			return (type(it.ifname) === 'string') ? it.ifname : '';
	}

	return '';
}

/* ================= 汇总：射频 + 接口 ================= */

function collectRadios() {
	let values = uciValues('wireless');
	let names  = keys(values);
	let st     = wirelessStatus();

	let radios = [];
	let index  = {};		/* 射频段名 → radios 元素引用，供第二遍挂接口 */
	let ifaceCount = 0;

	/* 第一遍：wifi-device（射频设备） */
	for (let i = 0; i < length(names); i++) {
		let name = names[i];
		let d = values[name];
		if (type(d) !== 'object' || d['.type'] !== 'wifi-device')
			continue;

		let rstat = (type(st[name]) === 'object') ? st[name] : null;
		let band    = strOf(d.band);
		let htmode  = strOf(d.htmode);
		let channel = strOf(d.channel);

		let item = {
			id: name,
			type: strOf(d.type),
			path: strOf(d.path),
			band: band,
			band_label: bandLabel(band),
			channel: channel,
			channel_label: (channel === '' || channel === 'auto') ? '自动' : channel,
			htmode: htmode,
			htmode_label: htmodeLabel(htmode),
			hwmode: strOf(d.hwmode),
			txpower: strOf(d.txpower),
			country: strOf(d.country),
			disabled: strOf(d.disabled) === '1',
			up: (rstat !== null) ? (rstat.up === true) : false,
			ifname: radioIfname(rstat),
			ifaces: []
		};

		push(radios, item);
		index[name] = item;
	}

	/* 第二遍：wifi-iface（无线接口），按 device 挂到所属射频 */
	for (let i = 0; i < length(names); i++) {
		let name = names[i];
		let f = values[name];
		if (type(f) !== 'object' || f['.type'] !== 'wifi-iface')
			continue;

		let dev = strOf(f.device);
		let enc = strOf(f.encryption);
		let key = strOf(f.key);
		let rstat = (type(st[dev]) === 'object') ? st[dev] : null;

		let iface = {
			section: name,
			device: dev,
			ifname: ifaceIfname(rstat, name),
			ssid: strOf(f.ssid),
			mode: strOf(f.mode),
			mode_label: modeLabel(strOf(f.mode)),
			network: strOf(f.network),
			encryption: enc,
			encryption_label: encLabel(enc),
			disabled: strOf(f.disabled) === '1',
			hidden: strOf(f.hidden) === '1',
			/* 只读展示：密码永不回传明文，只回「是否已设置」 */
			has_key: (key !== ''),
			isolate: strOf(f.isolate) === '1',
			ieee80211r: strOf(f.ieee80211r) === '1',
			wmm: strOf(f.wmm),
			maxassoc: strOf(f.maxassoc),
			beacon_int: strOf(f.beacon_int)
		};

		let owner = (type(index[dev]) === 'object') ? index[dev] : null;
		if (owner === null)
			continue;

		push(owner.ifaces, iface);
		ifaceCount = ifaceCount + 1;
	}

	return {
		radios: radios,
		total_radios: length(radios),
		total_ifaces: ifaceCount,
		note: '本页为只读参数展示；射频实时信道 / 发射功率 / 噪声来自 iwinfo，信道扫描由本页直接触发。'
	};
}

/* ================= 方法注册 ================= */

function guarded(fn) {
	try {
		return fn();
	} catch (e) {
		return { error: (type(e) === 'object') ? e.message : ('' + e) };
	}
}

const methods = {
	info: {
		call: function() {
			return guarded(function() { return collectRadios(); });
		}
	}
};

return { 'mk.apwireless': methods };