#!/usr/bin/env ucode
// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0

'use strict';

/* AP 管理界面 · mk.aplogs
 * ubus 对象：mk.aplogs
 *   读：logs            写：clear
 *
 * 数据源：logd 内存环形缓冲（`ubus call log read {lines, stream:false, oneshot:true}`）
 *   logread 也可用但 ubus 更稳 —— ubus 对象 `log` 由 logd 提供，不是 rpcd 托管对象，
 *   不存在嵌套死锁问题。
 * 清空：AP 无 /etc/init.d/log，用 `logd -S 128` 重启，或 `killall logd; /sbin/logd -S 128 &`
 *   但 logd 是 procd 托管，`/etc/init.d/log restart` 更可靠（需要 log 包）。
 *   实际真机：logd 进程 `procd-run.sh /bin/ubusd /sbin/logd`，PID 跟随 ubusd。
 *   最安全：向 logd 发 SIGHUP（`killall -HUP logd`）让它重置缓冲区。
 */

let ubus = require('ubus').connect();

const MAX_LINES = 2000;

/* facility 常量（RFC 5424） */
const FAC_AUTH = 4;
const FAC_AUTHPRIV = 10;

/* 认证类 tag 关键字（全小写匹配） */
const AUTH_TAGS = ['dropbear', 'login', 'passwd', 'sshd', 'sudo', 'su', 'chpasswd'];

function ubusCall(obj, method, args) {
	try { return ubus.call(obj, method, args || {}); }
	catch (e) { return null; }
}

/* facility*8+severity → INFO/WARN/ERROR/DEBUG */
function sevLabel(priority) {
	if (type(priority) !== 'int') return 'info';
	let sev = priority % 8;
	if (sev <= 3) return 'err';
	if (sev === 4) return 'warn';
	return 'info';
}

/* facility → tag 字符串（认证类判断用） */
function facTag(priority) {
	if (type(priority) !== 'int') return '';
	let f = int(priority / 8);
	if (f === FAC_AUTH || f === FAC_AUTHPRIV) return 'auth';
	return '';
}

/* 毫秒 timestamp → HH:MM:SS（加本地时区） */
function fmtTime(ms) {
	if (type(ms) !== 'int') return '-';
	let t = int(ms / 1000);
	/* 拿本地时区偏移 */
	let info = ubusCall('system', 'info');
	if (type(info) === 'object' && type(info.localtime) === 'int')
		t = t + int(info.localtime) - time();

	let h = int(t / 3600) % 24;
	let m = int(t / 60) % 60;
	let s = t % 60;
	function p(n) { return (n < 10 ? '0' : '') + n; }
	return p(h) + ':' + p(m) + ':' + p(s);
}

/* 判断是否认证类日志 */
function isAuth(item) {
	if (facTag(item.priority) === 'auth') return true;
	let src = (type(item.source) === 'string') ? tolower(item.source) : '';
	for (let i = 0; i < length(AUTH_TAGS); i++)
		if (src === AUTH_TAGS[i] || match(src, AUTH_TAGS[i])) return true;
	return false;
}

/* 读取 logd 缓冲 */
function readLogd() {
	let data = ubusCall('log', 'read', { lines: MAX_LINES, stream: false, oneshot: true });
	let entries = [];
	if (type(data) === 'object' && type(data.log) === 'array') {
		entries = data.log;
	} else if (type(data) === 'array') {
		entries = data;
	}
	/* 新 → 旧（logd 返回顺序），前端按时间倒序显示 */
	return entries;
}

/* tabs：AP 只提供 系统 / 认证 / 防火墙（置灰） */
function tabs() {
	return [
		{ id: 'all', label: '全部', supported: true },
		{ id: 'sys', label: '系统', supported: true },
		{ id: 'auth', label: '认证', supported: true },
		{ id: 'firewall', label: '防火墙', supported: false, reason: '本机未安装防火墙服务（无 fw4/nft filter），暂无防火墙日志来源' }
	];
}

function logs(args) {
	let tab = (type(args.tab) === 'string') ? trim(args.tab) : 'all';
	let level = (type(args.level) === 'string') ? trim(args.level) : 'all';
	let q = (type(args.q) === 'string') ? trim(args.q) : '';

	let raw = readLogd();
	let out = [];
	let auth_count = 0, sys_count = 0;

	for (let i = 0; i < length(raw); i++) {
		let e = raw[i];
		if (type(e) !== 'object') continue;

		let lv = sevLabel(e.priority);
		let tag = facTag(e.priority);
		if (tag === '' && isAuth(e)) tag = 'auth';
		if (tag === 'auth') auth_count++;
		else sys_count++;

		/* tab 过滤 */
		if (tab === 'sys' && tag === 'auth') continue;
		if (tab === 'auth' && tag !== 'auth') continue;
		if (tab === 'firewall') continue;	/* unsupported */

		/* level 过滤 */
		if (level !== 'all' && level !== lv) continue;

		/* 关键字搜索（消息内容 + 来源） */
		if (q !== '') {
			let msg = (type(e.msg) === 'string') ? tolower(e.msg) : '';
			let src = (type(e.source) === 'string') ? tolower(e.source) : '';
			if (match(msg, q) === null && match(src, q) === null) continue;
		}

		push(out, {
			id: e.id || i,
			time: fmtTime(e.time),
			timestamp: e.time || 0,
			level: lv,
			level_label: (lv === 'err') ? 'ERROR' : (lv === 'warn') ? 'WARN' : 'INFO',
			tag: tag,
			source: e.source || '-',
			msg: e.msg || ''
		});
	}

	return {
		tab: tab,
		tabs: tabs(),
		total: length(out),
		auth_count: auth_count,
		sys_count: sys_count,
		logs: out,
		buffer_size: MAX_LINES,
		unsupported: [
			{ id: 'firewall', label: '防火墙日志',
			  reason: '本机未安装防火墙服务（无 fw4/nft filter），暂无防火墙日志来源' }
		]
	};
}

function clearLog(args) {
	let confirm = (type(args.confirm) === 'string') ? trim(args.confirm) : '';
	if (confirm !== 'CLEAR')
		die('需要确认词 CLEAR 才能清空日志');

	/* 最稳：killall -HUP logd 重置缓冲 */
	system('killall -HUP logd 2>/dev/null');
	/* 兜底：如果没有 killall，用 pkill */
	system('pkill -HUP logd 2>/dev/null');
	return { cleared: true, message: '日志缓冲已清空（logd HUP 重置）' };
}

function guarded(fn) {
	try { return fn(); }
	catch (e) { return { error: (type(e) === 'object') ? e.message : ('' + e) }; }
}

const methods = {
	logs: {
		args: { tab: '', level: '', q: '' },
		call: function(r) { return guarded(function() { return logs(r.args); }); }
	},
	clear: {
		args: { confirm: '' },
		call: function(r) { return guarded(function() { return clearLog(r.args); }); }
	}
};

return { 'mk.aplogs': methods };
