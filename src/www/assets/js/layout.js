// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0
/* ========== AP-UI · 布局装配 ==========
 * 三个区域（顶部导航 / 左侧菜单 / 底部 footer）各自独立成文件放在 assets/layout/ 下，
 * 业务页面只放占位容器，调用 Layout.mount(当前文件名) 即可装配。
 *
 * 与 wrthub-ui 不同：
 *   · 侧边栏为一级菜单平铺（运行信息 / 网络设置 / 无线信息 / 固件升级 / 系统日志 / 退出），
 *     无手风琴二级菜单。
 *   · 不需要 buildNetworkGroup() 动态注入网络组项。
 *
 * 支持的区域容器 id：whNavbar / whSidebar / whFooter
 */
const Layout = {
    REGIONS: [
        { id: 'whNavbar', file: 'navbar.html' },
        { id: 'whSidebar', file: 'sidebar.html' },
        { id: 'whFooter', file: 'footer.html' }
    ],

    esc(s) {
        return String(s === null || s === undefined ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    },

    async mount(active) {
        await Promise.all(this.REGIONS.map(async function (r) {
            var el = document.getElementById(r.id);
            if (!el) return;
            var resp = await fetch('assets/layout/' + r.file);
            el.innerHTML = await resp.text();
        }));

        /* 高亮当前菜单项 */
        document.querySelectorAll('#whSidebar [data-nav]').forEach(function (a) {
            a.classList.toggle('active', a.getAttribute('data-nav') === active);
        });

        this.bind();
    },

    bind() {
        /* 移动端抽屉 */
        var toggle = document.getElementById('sidebarToggleBtn');
        var sidebar = document.getElementById('sidebar');
        if (toggle && sidebar)
            toggle.addEventListener('click', function () { sidebar.classList.toggle('show'); });

        /* 退出登录 */
        document.querySelectorAll('#logoutBtn, #sidebarLogoutBtn').forEach(function (btn) {
            btn.addEventListener('click', async function (e) {
                e.preventDefault();
                await API.logout();
                location.href = API.LOGIN_PAGE;
            });
        });
    },

    /* 供业务页面填充 footer 右侧信息 */
    setFooterInfo(text) {
        var el = document.getElementById('footerInfo');
        if (el) el.textContent = text;
    }
};
