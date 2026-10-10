#!/usr/bin/env ucode
// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0

'use strict';

/* AP 管理界面 · mk.apmaint
 * ubus 对象：mk.apmaint
 *   写：reboot_system
 *
 * 职责：重启设备。只有一个方法，极简。
 * 安全：confirm 必须等于 'REBOOT'。
 */

let ubus = require('ubus').connect();

function rebootSystem(args) {
	let confirm = (type(args.confirm) === 'string') ? trim(args.confirm) : '';
	if (confirm !== 'REBOOT')
		die('需要确认词 REBOOT 才能重启设备');

	try {
		ubus.call('system', 'reboot');
	} catch (e) {
		/* reboot 会立即断 ubus 连接，异常正常，忽略 */
	}

	return {
		action: 'reboot_system',
		reboot_at: time(),
		message: '重启命令已发送，设备将在几秒后关机重启。'
	};
}

function guarded(fn) {
	try { return fn(); }
	catch (e) { return { error: (type(e) === 'object') ? e.message : ('' + e) }; }
}

const methods = {
	reboot_system: {
		args: { confirm: '' },
		call: function(r) { return guarded(function() { return rebootSystem(r.args); }); }
	}
};

return { 'mk.apmaint': methods };
