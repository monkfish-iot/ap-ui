# SPDX-FileCopyrightText: 2026 Monkfish IoT
# SPDX-License-Identifier: Apache-2.0
#
# AP-UI · 简易 AP 管理界面 —— OpenWrt 打包配方
#
# 目录结构（自包含：整包可直接丢进 OpenWrt package/，不依赖仓库其它目录）：
#
#     ap-ui/
#     ├── Makefile                              本文件
#     ├── src/                                  ← 唯一载荷真源
#     │   ├── www/                              →  /www/apui/      （index.html / *.html / assets/）
#     │   ├── usr/share/rpcd/ucode/*.uc         →  /usr/share/rpcd/ucode/
#     │   └── usr/share/rpcd/acl.d/*.json        →  /usr/share/rpcd/acl.d/
#     └── files/etc/uci-defaults/95-ap-ui      →  /etc/uci-defaults/
#
# 与 wrthub-ui 的差异：
#   · 装到 /www/apui（与开发期 /www/apui → /tmp/apui 布局一致），
#     访问入口 http://<AP>:8000/apui/index.html。
#     **不能装到 /www 根**：固件里 /www/index.html 归 luci-base 所有，apk 禁止跨包覆盖
#     （报「trying to overwrite /www/index.html owned by luci-base」），会导致 package/install 失败。
#     站点根仍指向 ap-ui：由 uci-defaults/95-ap-ui 在**首启时**把 /www/index.html 改写成跳转页
#     （apk 只校验包的文件清单，不校验脚本运行时写入，故这样合法且不受安装顺序影响）。
#     同理也不碰 /www/cgi-bin/（cgi-io 的 cgi-upload 依赖它）。
#   · 只出 ap-ui 一个包（wrthub-ui 已独立交付）。
#   · 不需要 nftables / iw / dnsmasq 等 wrthub-ui 的依赖。
#
# 开发期部署：
#     put src/**            → /tmp/apui/
#     ln -sfn /tmp/apui /www/apui
#     /etc/init.d/rpcd restart
#     # 访问 http://<AP>:8000/apui/index.html
#
# 接入 OpenWrt 构建树（任选其一）：
#   1) 直接复制：cp -a ap-ui <openwrt>/package/
#   2) 本地 feed：echo "src-link wrthub <repo绝对路径>" >> feeds.conf
#        ./scripts/feeds update wrthub && ./scripts/feeds install ap-ui
#
# 编译：
#     make menuconfig                                # Network → ap-ui（选中即随固件编译安装）
#     make package/ap-ui/compile                     # 只出 ipk
#     make                                           # 出固件（会带上本包）
#

include $(TOPDIR)/rules.mk

PKG_NAME:=ap-ui
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

# 纯数据包（脚本 + 静态页面），无编译产物 → 与架构无关
PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=AP-UI

include $(INCLUDE_DIR)/package.mk

# 载荷源目录：默认取包内自带的 src/（自包含，整包可独立打包）。
AP_UI_DIR ?= $(CURDIR)/src

define Package/ap-ui
  SECTION:=net
  CATEGORY:=Monkfish Softwares
  TITLE:=Monkfish Software
  DEPENDS:=+rpcd \
	+rpcd-mod-file \
	+rpcd-mod-ucode \
	+rpcd-mod-iwinfo \
	+cgi-io \
	+ucode \
	+ucode-mod-fs \
	+ucode-mod-uci \
	+ucode-mod-ubus \
	+uhttpd \
	+uhttpd-mod-ubus \
	+logd
endef

define Package/ap-ui/description
  Simple AP management web UI.

  Static frontend served by uhttpd from /www/apui/, plus a ucode rpcd middle
  layer (the mk.ap* ubus objects). Nothing depends on LuCI.

  Path: browser -> uhttpd /ubus -> rpcd JSON-RPC -> ucode (mk.ap*) -> uci / ubus / files.

  Depends on rpcd-mod-iwinfo (direct signal/quality), cgi-io (firmware upload)
  and logd (system log).
endef

# 首次安装（仅 ipk 安装时执行；镜像构建阶段 IPKG_INSTROOT 非空，跳过）：
#   重启 rpcd 以加载新的 ucode 插件与 ACL
define Package/ap-ui/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] || {
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart
	exit 0
}
endef

# 不下载、不解包：直接把 src/ 整棵树复制进构建目录
define Build/Prepare
	@if [ ! -d "$(AP_UI_DIR)" ]; then \
		echo "*** ap-ui: 未找到载荷源目录: $(AP_UI_DIR)"; \
		echo "*** 请确认 ap-ui/src/ 存在"; \
		exit 1; \
	fi
	rm -rf $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) $(AP_UI_DIR)/. $(PKG_BUILD_DIR)/
endef

# 纯数据包，无需编译
define Build/Compile
endef

define Package/ap-ui/install
	# 前端 → /www/apui（不装 /www 根：/www/index.html 归 luci-base，apk 拒绝跨包覆盖）
	$(INSTALL_DIR) $(1)/www/apui
	$(CP) $(PKG_BUILD_DIR)/www/. $(1)/www/apui/

	# ucode 插件
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/share/rpcd/ucode/*.uc $(1)/usr/share/rpcd/ucode/

	# ACL
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/usr/share/rpcd/acl.d/*.json $(1)/usr/share/rpcd/acl.d/

	# 首次启动脚本：改写站点根跳转页 + 重启 rpcd 加载插件与 ACL
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/etc/uci-defaults/95-ap-ui $(1)/etc/uci-defaults/95-ap-ui
endef

$(eval $(call BuildPackage,ap-ui))
