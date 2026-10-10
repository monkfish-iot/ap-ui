// SPDX-FileCopyrightText: 2026 Monkfish IoT
// SPDX-License-Identifier: Apache-2.0
/* ========== AP-UI 公共脚本 ========== */
(function () {
    'use strict';

    /* 1. 移动端侧边栏抽屉 */
    var toggleBtn = document.getElementById('sidebarToggleBtn');
    var sidebar = document.getElementById('sidebar');
    if (toggleBtn && sidebar) {
        toggleBtn.addEventListener('click', function () { sidebar.classList.toggle('show'); });
    }

    /* 2. 全局 Toast：notify(message, type)  type: success|danger|warning|info */
    window.notify = function (message, type) {
        type = type || 'success';
        var container = document.getElementById('toastContainer');
        if (!container) { alert(message); return; }
        var el = document.createElement('div');
        el.className = 'toast align-items-center text-bg-' + type + ' border-0 mb-2';
        el.setAttribute('role', 'alert');
        el.innerHTML = '<div class="d-flex"><div class="toast-body small">' + message +
            '</div><button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button></div>';
        container.appendChild(el);
        var t = new bootstrap.Toast(el, { delay: 2600 });
        t.show();
        el.addEventListener('hidden.bs.toast', function () { el.remove(); });
    };
})();
