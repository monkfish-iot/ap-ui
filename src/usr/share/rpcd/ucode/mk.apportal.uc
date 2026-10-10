#!/usr/bin/env ucode
// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0

'use strict';

/* AP 管理界面 · mk.apportal
 * ubus 对象：mk.apportal
 *   读：info（Portal 配置 + 运行状态）
 *
 * 职责：供「Portal 认证」页做**只读**展示（本对象不提供任何写方法）。
 *   配置：/etc/config/webauthd 的 base / portal / radius / white_list 四段
 *   状态：webauthd 进程、ubus 对象注册、nginx 门户代理、监听端口、代理配置文件
 *
 * 关于在线用户：
 *   webauthd 的 ubus 读接口 `webauthd.session list_users` 在旧固件上一被调用即崩溃，
 *   新固件已修复（真机复测：连打十余次，webauthd PID 恒定不变）。
 *   但**本插件不代理该接口** —— rpcd 托管对象内再发起 ubus 调用会死锁超时，
 *   故由前端直接调 `webauthd.session list_users`（与 iwinfo 同款处理）。
 *   本对象只提供 `status.ubus_object.registered` 供前端判断该接口是否可用。
 *
 * 实现约束（项目经验）：
 *   · 不在本插件内做任何 ubus 嵌套调用（rpcd 托管对象内再调 ubus 会死锁超时）。
 *   · 查进程 / 查 ubus 对象改用 system() 起**独立**进程（ps、ubus list），输出重定向到
 *     临时文件后用 fs.readfile() 读回（ucode 的 system() 只返回 exit code）。
 *   · 监听端口直接解析 /proc/net/tcp，不依赖 netstat。
 */

let uci = require('uci');
let fs  = require('fs');

/* 关注的监听端口（真机实测 webauthd 监听这三个） */
const PORTS = [
    { port: 20002, label: '门户 HTTP 服务' },
    { port: 20080, label: 'HTTP 接口（/v1/*）' },
    { port: 60000, label: '本机接口（仅 127.0.0.1）' }
];

const PORTAL_CONF = '/etc/nginx/conf.d/portal.conf';
const CACHE_CONF  = '/etc/nginx/conf.d/cache.conf';

/* ================= 基础工具 ================= */

/* 执行命令并读回 stdout（system() 只返回 exit code） */
function cmdOut(tag, cmd) {
    let tmp = '/tmp/apportal_' + tag + '_' + time() + '.txt';
    system(cmd + ' > ' + tmp + ' 2>&1');
    let content = fs.readfile(tmp);
    system('rm -f ' + tmp);
    return (type(content) === 'string') ? trim(content) : '';
}

function fileExists(path) {
    try {
        let st = fs.stat(path);
        return (type(st) === 'object');
    } catch (e) {
        return false;
    }
}

/* 按 .type 找 uci 段（段名不固定，如 base 段的段名是 generic）。
 * 返回 { found, name, values }，避免用 undefined 判存在性 */
function uciSectionByType(config, wantType) {
    let out = { found: false, name: '', values: {} };
    try {
        let cur = uci.cursor();
        if (!cur.load(config))
            return out;

        let all = cur.get_all(config);
        if (type(all) !== 'object')
            return out;

        let names = keys(all);
        for (let i = 0; i < length(names); i++) {
            let sec = all[names[i]];
            if (type(sec) === 'object' && sec['.type'] === wantType) {
                out.found = true;
                out.name = names[i];
                out.values = sec;
                return out;
            }
        }
    } catch (e) { }
    return out;
}

/* uci 值可能是标量也可能是数组；统一取首个标量 */
function first(v) {
    if (type(v) === 'array')
        return (length(v) > 0) ? v[0] : null;
    return v;
}

function strOf(v) {
    let s = first(v);
    if (type(s) === 'string') return s;
    if (type(s) === 'int' || type(s) === 'double') return '' + s;
    return '';
}

/* 布尔选项：'' → null（未设置），'1' → true，其他 → false */
function boolOrNull(v) {
    let s = strOf(v);
    if (s === '') return null;
    return (s === '1');
}

/* ================= 配置 ================= */

function collectBase(sec) {
    let v = (type(sec) === 'object') ? sec.values : {};
    return {
        enabled: boolOrNull(v.enabled),
        layer: strOf(v.layer),
        portal_interface: strOf(v.portal_interface),
        capture_dns: boolOrNull(v.capture_dns),
        layer2_ifname: strOf(v.layer2_ifname),
        layer3_ifname: strOf(v.layer3_ifname),
        idle_timeout: strOf(v.idle_timeout),
        mac_auth: boolOrNull(v.mac_auth),
        mac_auth_format: strOf(v.mac_auth_format),
        cloud_config: boolOrNull(v.cloud_config)
    };
}

function collectPortal(sec) {
    let v = (type(sec) === 'object') ? sec.values : {};
    return {
        portal_type: strOf(v.portal_type),
        http_portal_auth: boolOrNull(v.http_portal_auth),
        hw_portal_auth: boolOrNull(v.hw_portal_auth),
        login_title: strOf(v.login_title),
        login_topic: strOf(v.login_topic),
        login_footer: strOf(v.login_footer),
        success_title: strOf(v.success_title),
        success_topic: strOf(v.success_topic),
        success_footer: strOf(v.success_footer),
        failed_title: strOf(v.failed_title),
        failed_topic: strOf(v.failed_topic),
        failed_footer: strOf(v.failed_footer),
        portal_port: strOf(v.portal_port),
        portal_server: strOf(v.portal_server),
        portal_url: strOf(v.portal_url),
        proxy_pass: strOf(v.proxy_pass),
        cache_enable: boolOrNull(v.cache_enable),
        cache_valid_time: strOf(v.cache_valid_time),
        cache_max_size: strOf(v.cache_max_size),
        cache_inactive_time: strOf(v.cache_inactive_time)
    };
}

function collectRadius(sec) {
    let v = (type(sec) === 'object') ? sec.values : {};
    return {
        local_radius_client: boolOrNull(v.local_radius_client),
        primary_auth_server: strOf(v.primary_auth_server),
        primary_auth_port: strOf(v.primary_auth_port),
        primary_acct_server: strOf(v.primary_acct_server),
        primary_acct_port: strOf(v.primary_acct_port),
        /* 密钥只回「是否已设置」，永不回明文 */
        has_auth_secret: strOf(v.primary_auth_secret) !== '',
        has_acct_secret: strOf(v.primary_acct_secret) !== '',
        acct_interval: strOf(v.acct_interval),
        every_hour_acct: boolOrNull(v.every_hour_acct),
        nas_if: strOf(v.nas_if),
        nas_ip: strOf(v.nas_ip),
        tenant_org_id: strOf(v.tenant_org_id)
    };
}

/* 白名单段：收集各选项里的条目（list 型选项在 ucode 里是数组） */
function collectWhiteList(sec) {
    let v = (type(sec) === 'object') ? sec.values : {};
    let entries = [];
    let names = keys(v);

    for (let i = 0; i < length(names); i++) {
        let k = names[i];
        if (k === '.type' || k === '.name' || k === '.index' || k === '.anonymous')
            continue;

        let val = v[k];
        if (type(val) === 'array') {
            for (let j = 0; j < length(val); j++)
                if (type(val[j]) === 'string' && val[j] !== '')
                    push(entries, val[j]);
        } else if (type(val) === 'string' && val !== '') {
            push(entries, val);
        }
    }

    return { present: (type(sec) === 'object' && sec.found === true), count: length(entries), entries: entries };
}

/* ================= 运行状态 ================= */

/* ps -wwww 找程序行（busybox 格式：PID USER VSZ STAT COMMAND） */
function psFind(needle) {
    let out = cmdOut('ps', 'ps -wwww');
    if (out === '') return { running: false, pid: '' };

    let lines = split(out, '\n');
    for (let i = 0; i < length(lines); i++) {
        let line = trim(lines[i]);
        if (line === '') continue;
        if (match(line, needle) === null) continue;

        let parts = split(line, /[ \t]+/);
        return { running: true, pid: (length(parts) > 0) ? parts[0] : '' };
    }
    return { running: false, pid: '' };
}

/* ubus 对象是否已注册（起独立 ubus 进程查询，带 3 秒超时防挂）。
 * 注意：ucode 的 match() 第二参传「字符串」是字面量全等比较（非子串查找），
 * 多行输出永远不等于对象名，会恒判为未注册 —— 故按行做精确比对。 */
function ubusRegistered(obj) {
    let out = cmdOut('ubus', 'ubus -t 3 list');
    if (out === '') return false;

    let lines = split(out, '\n');
    for (let i = 0; i < length(lines); i++)
        if (trim(lines[i]) === obj) return true;
    return false;
}

/* /proc/net/tcp[tcp6] → 监听端口表。
 * 行格式（均十六进制）： sl local_address rem_address st ...
 *   local_address = IP:PORT（小端），st '0A' = LISTEN */
function listenPorts() {
    let found = {};
    let files = ['/proc/net/tcp', '/proc/net/tcp6'];

    for (let f = 0; f < length(files); f++) {
        let raw = '';
        try { raw = fs.readfile(files[f]); } catch (e) { raw = ''; }
        if (type(raw) !== 'string' || raw === '') continue;

        let lines = split(raw, '\n');
        for (let i = 1; i < length(lines); i++) {	/* 跳过表头 */
            let parts = split(trim(lines[i]), /[ \t]+/);
            if (length(parts) < 4) continue;
            if (parts[3] !== '0A') continue;		/* 0A = LISTEN */

            let la = parts[1];
            let mp = match(la, /:([0-9A-Fa-f]+)$/);
            if (mp === null) continue;
            let p = int(mp[1], 16);
            if (type(p) !== 'int' || p <= 0) continue;

            let mi = match(la, /^([0-9A-Fa-f]+):/);
            let ipHex = (mi !== null) ? mi[1] : '';
            let addr = '0.0.0.0';
            if (ipHex === '0100007F') addr = '127.0.0.1';
            else if (ipHex !== '00000000' && ipHex !== '') addr = ipHex;

            found['' + p] = addr;
        }
    }
    return found;
}

function collectPorts() {
    let found = listenPorts();
    let out = [];

    for (let i = 0; i < length(PORTS); i++) {
        let p = PORTS[i].port;
        let addr = found['' + p];
        let listening = (type(addr) === 'string' && addr !== '');
        push(out, {
            port: p,
            label: PORTS[i].label,
            listening: listening,
            addr: listening ? addr : ''
        });
    }
    return out;
}

/* ================= 汇总 ================= */

function info() {
    let base   = uciSectionByType('webauthd', 'base');
    let portal = uciSectionByType('webauthd', 'portal');
    let radius = uciSectionByType('webauthd', 'radius');
    let wl     = uciSectionByType('webauthd', 'white_list');

    let proc  = psFind(/\/sbin\/webauthd/);
    let nginx = psFind(/nginx/);

    return {
        config: {
            base: collectBase(base),
            portal: collectPortal(portal),
            radius: collectRadius(radius),
            white_list: collectWhiteList(wl)
        },
        status: {
            webauthd: { running: proc.running, pid: proc.pid },
            ubus_object: { name: 'webauthd.session', registered: ubusRegistered('webauthd.session') },
            nginx: { running: nginx.running, pid: nginx.pid },
            ports: collectPorts(),
            portal_conf: { path: PORTAL_CONF, exists: fileExists(PORTAL_CONF) },
            cache_conf:  { path: CACHE_CONF,  exists: fileExists(CACHE_CONF) }
        },
        read_only: true
    };
}

function guarded(fn) {
    try { return fn(); }
    catch (e) { return { error: (type(e) === 'object') ? e.message : ('' + e) }; }
}

const methods = {
    info: {
        call: function() { return guarded(function() { return info(); }); }
    }
};

return { 'mk.apportal': methods };
