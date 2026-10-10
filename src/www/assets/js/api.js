// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0
/* ========== AP-UI · 通信层 ==========
 * 传输：浏览器直接 POST /ubus（rpcd JSON-RPC），与 docs/example 一致。
 * 鉴权：复用 rpcd 自带 session 对象，sid 存 localStorage。
 * 会话失效：调用被拒（-32002）或页面加载校验失败时，跳登录页并带 redirect 回跳地址。
 */
const API = {
    SESSION_KEY: 'apui_session',
    LOGIN_PAGE: 'login.html',
    NULL_SID: '00000000000000000000000000000000',
    RPC_ACCESS_DENIED: -32002,

    session: localStorage.getItem('apui_session') || null,

    /* 底层：发 JSON-RPC 请求 */
    raw(sid, obj, method, args) {
        return fetch('/ubus', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                jsonrpc: '2.0',
                id: 1,
                method: 'call',
                params: [sid, obj, method, args || {}]
            })
        }).then(function (r) { return r.json(); });
    },

    /* 本地会话读写 */
    saveSession(sid) {
        this.session = sid;
        localStorage.setItem(this.SESSION_KEY, sid);
    },

    clearSession() {
        this.session = null;
        localStorage.removeItem(this.SESSION_KEY);
    },

    /* 当前页面（相对路径），用于登录后回跳 */
    here() {
        var file = location.pathname.split('/').pop() || 'index.html';
        return file + location.search;
    },

    /* 跳登录页。已在登录页则不跳，避免死循环 */
    toLogin() {
        if (location.pathname.split('/').pop() === this.LOGIN_PAGE) return;
        location.href = this.LOGIN_PAGE + '?redirect=' + encodeURIComponent(this.here());
    },

    /* 登录 */
    async login(username, password) {
        var r = await this.raw(this.NULL_SID, 'session', 'login', { username: username, password: password });
        if (r.error) throw new Error(r.error.message || '登录失败');
        if (!r.result || r.result[0] !== 0) throw new Error('用户名或密码错误');
        var info = r.result[1] || {};
        if (!info.ubus_rpc_session) throw new Error('登录响应缺少 ubus_rpc_session');
        this.saveSession(info.ubus_rpc_session);
        return info;
    },

    /* 登出：先清本地会话，再通知服务端销毁 */
    async logout() {
        var sid = this.session;
        this.clearSession();
        if (!sid) return;
        try {
            await this.raw(sid, 'session', 'destroy', {});
        } catch (e) { /* 服务端不可达也视为已登出 */ }
    },

    /* 会话是否仍有效 */
    async checkSession() {
        if (!this.session) return false;
        try {
            var r = await this.raw(this.session, 'session', 'access', {});
            return !r.error && !!r.result && r.result[0] === 0;
        } catch (e) {
            return false;
        }
    },

    /* 页面入口调用：无效会话 → 跳登录页并返回 false */
    async guard() {
        if (await this.checkSession()) return true;
        this.clearSession();
        this.toLogin();
        return false;
    },

    /* 调用 ubus 对象方法；会话失效自动跳登录页 */
    async call(obj, method, args) {
        if (!this.session) {
            this.toLogin();
            throw new Error('未登录');
        }
        var r = await this.raw(this.session, obj, method, args || {});
        if (r.error) {
            if (r.error.code === this.RPC_ACCESS_DENIED) {
                this.clearSession();
                this.toLogin();
                throw new Error('会话已失效，请重新登录');
            }
            throw new Error(r.error.message || ('RPC 错误 ' + r.error.code));
        }
        if (!r.result || r.result[0] !== 0) {
            throw new Error('ubus 调用失败（status ' + (r.result ? r.result[0] : '?') + '）');
        }
        return r.result[1];
    }
};
