#!/usr/bin/env ucode
// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0

'use strict';

/* AP 管理界面 · mk.apupgrade
 * ubus 对象：mk.apupgrade
 *   读：info              写：verify / flash / discard
 *
 * 升级机制（AP 真机实测，NatShell AX835）：
 *   - sysupgrade 存在（`which sysupgrade`），通常挂载到 /tmp/firmware.bin
 *   - /proc/mtd 里有 firmware 分区
 *   - overlay 极小（~900KB），/tmp 是 tmpfs（~120MB），固件镜像放 /tmp 没问题
 *   - 上传走 cgi-io upload 到 /tmp/firmware.bin（apui.json ACL 已放行）
 *
 * verify：sysupgrade -T /tmp/firmware.bin（测试镜像合法性，不真刷写）
 * flash：sysupgrade -v /tmp/firmware.bin（刷写 + 自动重启）—— 必须 confirm='FLASH'
 * discard：删除 /tmp/firmware.bin 临时镜像
 *
 * 注意：flash 是破坏性操作，会重启设备。前端必须加确认弹窗。
 */

let ubus = require('ubus').connect();
let uci = require('uci');
let fs = require('fs');

const FIRMWARE_PATH = '/tmp/firmware.bin';

/* helper: 执行命令返回 stdout 字符串（system() 只返回 exit code） */
function cmdOut(cmd) {
	let tmp = '/tmp/apupg_cmd_' + time() + '.txt';
	system(cmd + ' > ' + tmp + ' 2>&1');
	let content = fs.readfile(tmp);
	system('rm -f ' + tmp);
	if (type(content) === 'string') return trim(content);
	return '';
}

/* helper: 文件是否存在（exit code 0 = 存在） */
function fileExists(path) { return system('test -f ' + path) === 0; }

function ubusCall(obj, method, args) {
	try { return ubus.call(obj, method, args || {}); }
	catch (e) { return null; }
}

function first(v) {
	if (type(v) === 'array')
		return (length(v) > 0) ? v[0] : null;
	return v;
}

function str(v) { return (type(v) === 'string') ? v : ''; }

/* /proc/mtd → { name, size, erasesize, type }[]，device 是 mtdN */
function mtdList() {
	let out = [];
	let raw = fs.readfile('/proc/mtd');
	if (type(raw) !== 'string' || raw === '') return out;
	/* 格式：mtd4: 00e00000 00010000 "firmware" —— ucode 用 split '\n'，行内再用正则 */
	let lines = split(raw, '\n');
	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i]);
		if (line === '' || match(line, /^dev:/) !== null) continue;
		/* 简化：只抓 dev 名和 name，用空格和冒号分隔 */
		let parts = split(line, ' ');
		/* parts[0] = "mtd4:" parts[1] = "00e00000" parts[2] = "00010000" parts[3] = '"firmware"' */
		if (length(parts) >= 4) {
			let dev = split(parts[0], ':')[0];
			let nameRaw = parts[length(parts) - 1];
			let m = match(nameRaw, /"([^"]*)"/);
			let name = (m !== null) ? m[1] : nameRaw;
			let sizeHex = parts[1];
			let sizeBytes = int(sizeHex, 16);
			push(out, { device: dev, size_hex: sizeHex, size_bytes: sizeBytes, name: name });
		}
	}
	return out;
}

function fileSize(path) {
	/* 本机 busybox 未编入 stat applet（`ash: stat: not found`，rc=127），
	   用 shell 取大小会恒失败 —— 改用 ucode 的 fs.stat() */
	try {
		let st = fs.stat(path);
		if (type(st) === 'object' && type(st.size) === 'int') return st.size;
	} catch (e) { }
	return null;
}

function findMtd(name) {
	let list = mtdList();
	for (let i = 0; i < length(list); i++)
		if (list[i].name === name) return list[i];
	return null;
}

/* ==== info ==== */
function info() {
	let board = ubusCall('system', 'board');
	let info = ubusCall('system', 'info');

	let firmware_mtd = findMtd('firmware');
	let rootfs_mtd = findMtd('rootfs');

	let imgExists = fileExists(FIRMWARE_PATH);
	let imgSize = imgExists ? fileSize(FIRMWARE_PATH) : null;

	/* /tmp 可用空间 —— tmpfs 上 -B1 不支持，用 -k 再转字节。
	   注意 busybox df 行尾是 "Use% Mounted on"，按「倒数第二个字段」取会误夺 Use%（"0%" → int 得 0），
	   故直接用 awk 取第 4 列 Available（KB）。
	   真机输出：tmpfs  119496  460  119036  0% /tmp */
	let tmpAvail = null;
	let dfOut = cmdOut("df -k /tmp | awk 'NR==2 {print $4}'");
	if (dfOut !== '') {
		let availKb = int(trim(dfOut));
		if (type(availKb) === 'int' && availKb > 0) tmpAvail = availKb * 1024;
	}

	return {
		device: {
			model: str(board.model),
			board: str(board.board_name),
			kernel: str(board.kernel),
			target: str(board.release.distribution) + ' ' + str(board.release.version)
		},
		firmware: {
			release: str(board.release.distribution) + ' ' + str(board.release.version) + ' (' + str(board.release.revision) + ')'
		},
		storage: {
			tmp_path: '/tmp',
			tmp_avail_bytes: tmpAvail,
			overlay_total_kb: (type(info) === 'object' && type(info.root) === 'object') ? info.root.total : null,
			overlay_free_kb: (type(info) === 'object' && type(info.root) === 'object') ? info.root.free : null,
			/* 固件分区信息 */
			mtd_firmware: firmware_mtd,
			mtd_rootfs: rootfs_mtd
		},
		image: {
			path: FIRMWARE_PATH,
			exists: imgExists,
			size_bytes: imgSize
		},
		capabilities: {
			sysupgrade: system('which sysupgrade') === 0,
			verify_test: true	/* sysupgrade -T */
		}
	};
}

/* ==== verify（sysupgrade -T，不真刷）==== */
function verify() {
	let exists = fileExists(FIRMWARE_PATH);
	if (!exists)
		die('未找到上传的固件镜像 ' + FIRMWARE_PATH + '，请先上传');

	let size = fileSize(FIRMWARE_PATH);

	/* sysupgrade -T 输出到 stderr，exit code 0 = OK */
	let rc = system('sysupgrade -T ' + FIRMWARE_PATH + ' >/dev/null 2>&1');
	let out = cmdOut('sysupgrade -T ' + FIRMWARE_PATH + ' 2>&1');

	let md5 = cmdOut('md5sum ' + FIRMWARE_PATH + ' | awk \'{print $1}\'');
	let sha256 = cmdOut('sha256sum ' + FIRMWARE_PATH + ' | awk \'{print $1}\'');

	return {
		action: 'verify',
		path: FIRMWARE_PATH,
		size: size,
		md5: trim(md5),
		sha256: trim(sha256),
		valid: (rc === 0),
		rc: rc,
		output: trim(out),
		checked_at: time()
	};
}

/* ==== flash（执行刷写，破坏性操作）==== */
function flash(args) {
	let confirm = (type(args.confirm) === 'string') ? trim(args.confirm) : '';
	if (confirm !== 'FLASH')
		die('需要确认词 FLASH 才能执行固件升级');

	let exists = fileExists(FIRMWARE_PATH);
	if (!exists)
		die('未找到固件镜像 ' + FIRMWARE_PATH);

	let size = fileSize(FIRMWARE_PATH);

	/* 后台启动 sysupgrade —— 会重启，同步 call 会断。
	   注意：本机 busybox 未编入 nohup（`command -v nohup` → MISSING），
	   用 nohup 启动会直接失败：调用返回「已启动」但后台进程根本没跑，表现为「点立即升级没反应」。
	   改用 setsid 脱离会话（SIGHUP 打不到它），</dev/null 断开 stdin。 */
	let rc = system('setsid sh -c "sleep 2; sysupgrade -v ' + FIRMWARE_PATH + ' 2>&1 | logger" </dev/null >/dev/null 2>&1 &');
	if (rc !== 0)
		die('无法启动后台升级进程（setsid rc=' + rc + '，请检查 /usr/bin/setsid 是否存在）');

	return {
		action: 'flash',
		path: FIRMWARE_PATH,
		size: size,
		keep_settings: (args.keep === 0) ? false : true,
		started_at: time(),
		message: '固件升级已在后台启动（2 秒后执行），设备将在 30-120 秒后重启。'
	};
}

/* ==== discard（删除临时镜像）==== */
function discard() {
	let exists = fileExists(FIRMWARE_PATH);
	if (!exists)
		return { action: 'discard', removed: false, message: '没有待处理的固件镜像' };

	let size = fileSize(FIRMWARE_PATH);
	system('rm -f ' + FIRMWARE_PATH);

	return {
		action: 'discard',
		path: FIRMWARE_PATH,
		removed: true,
		removed_size: size,
		message: '已删除固件镜像'
	};
}

function guarded(fn) {
	try { return fn(); }
	catch (e) { return { error: (type(e) === 'object') ? e.message : ('' + e) }; }
}

const methods = {
	info: {
		call: function() { return info(); }
	},
	verify: {
		call: function() { return guarded(function() { return verify(); }); }
	},
	flash: {
		args: { confirm: '', keep: 1 },
		call: function(r) { return guarded(function() { return flash(r.args); }); }
	},
	discard: {
		call: function() { return guarded(function() { return discard(); }); }
	}
};

return { 'mk.apupgrade': methods };
