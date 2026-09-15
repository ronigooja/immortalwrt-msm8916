#!/bin/bash
# DIY脚本
# https://github.com/P3TERX/Actions-OpenWrt
# 文件名: diy-part2.sh
# 功能说明: OpenWrt DIY脚本第2部分（更新feeds之后）
# 版权: (c) 2019-2024 P3TERX <https://p3terx.com>
# 基于 MIT 开源协议，详见 /LICENSE

# 修改默认IP地址
#sed -i 's/192.168.1.1/192.168.100.1/g' package/base-files/files/bin/config_generate


# 修改默认主题为 argon（路径不存在时跳过，不中断编译）
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile 2>/dev/null || true

# 默认使用 SSH 公钥登录，移除上游无 root 密码时的交互式登录警告。
passwordless_root_warning="package/base-files/files/etc/profile.d/00-passwordless-root.sh"
if [ -f "$passwordless_root_warning" ]; then
  cat > "$passwordless_root_warning" <<'EOF'
#!/bin/sh
return 0 2>/dev/null || true
EOF
fi

# 启用 Tailscale Exit Node 所需的 IPv4 策略路由内核选项
for cfg in target/linux/msm89xx/config-*; do
  [ -f "$cfg" ] || continue

  for opt in \
    CONFIG_IP_ADVANCED_ROUTER \
    CONFIG_IP_MULTIPLE_TABLES \
    CONFIG_IP_ROUTE_FWMARK
  do
    sed -i "/^${opt}=/d;/^# ${opt} is not set/d" "$cfg"
    echo "${opt}=y" >> "$cfg"
  done
done

# 启用 UFI/OpenStick 的标准 USB role-switch 节点，供 /sys/class/usb_role/*/role 控制 host/device。
ufi_dtsi="target/linux/msm89xx/dts/msm8916-ufi.dtsi"
if [ -f "$ufi_dtsi" ]; then
  set_led_default_off() {
    local led_node="$1"
    local tmp="${ufi_dtsi}.tmp"

    awk -v led_node="$led_node" '
      $0 ~ "^[[:space:]]*" led_node ":[[:space:]]" {
        in_led = 1
        saw_default = 0
      }
      in_led && /^[[:space:]]*default-state[[:space:]]*=/ {
        print "\t\t\tdefault-state = \"off\";"
        saw_default = 1
        next
      }
      in_led && /^[[:space:]]*};/ {
        if (!saw_default) {
          print "\t\t\tdefault-state = \"off\";"
        }
        in_led = 0
      }
      { print }
    ' "$ufi_dtsi" > "$tmp" && mv "$tmp" "$ufi_dtsi"
  }

  for led_node in led_r led_g led_b; do
    set_led_default_off "$led_node"
  done

  insert_usb_property() {
    local property="$1"
    local tmp="${ufi_dtsi}.tmp"

    awk -v property="$property" '
      /^&usb[[:space:]]*{/ { in_usb = 1 }
      in_usb && /^[[:space:]]*status[[:space:]]*=[[:space:]]*"okay";/ {
        print "\t" property
      }
      { print }
      in_usb && /^};/ { in_usb = 0 }
    ' "$ufi_dtsi" > "$tmp" && mv "$tmp" "$ufi_dtsi"
  }

  if ! awk '
    /^&usb[[:space:]]*{/ { in_usb = 1 }
    in_usb && /dr_mode[[:space:]]*=[[:space:]]*"otg";/ { found = 1 }
    in_usb && /^};/ { in_usb = 0 }
    END { exit found ? 0 : 1 }
  ' "$ufi_dtsi"; then
    insert_usb_property 'dr_mode = "otg";'
  fi

  if ! awk '
    /^&usb[[:space:]]*{/ { in_usb = 1 }
    in_usb && /usb-role-switch;/ { found = 1 }
    in_usb && /^};/ { in_usb = 0 }
    END { exit found ? 0 : 1 }
  ' "$ufi_dtsi"; then
    insert_usb_property 'usb-role-switch;'
  fi

  grep -A8 '^&usb[[:space:]]*{' "$ufi_dtsi"
else
  echo "WARN: $ufi_dtsi not found, skip USB role-switch DTS tweak"
fi

# 固定打开 role switch/extcon 支持；上游已通常开启，这里保底避免配置漂移。
for cfg in target/linux/msm89xx/config-*; do
  [ -f "$cfg" ] || continue

  for opt in \
    CONFIG_USB_ROLE_SWITCH \
    CONFIG_EXTCON \
    CONFIG_EXTCON_USB_GPIO
  do
    sed -i "/^${opt}=/d;/^# ${opt} is not set/d" "$cfg"
    echo "${opt}=y" >> "$cfg"
  done
done


# 临时添加的插件
# git clone https://github.com/lkiuyu/luci-app-cpu-perf package/luci-app-cpu-perf
# git clone https://github.com/lkiuyu/luci-app-cpu-status package/luci-app-cpu-status
# git clone https://github.com/gSpotx2f/luci-app-cpu-status-mini package/luci-app-cpu-status-mini
# git clone https://github.com/lkiuyu/luci-app-temp-status package/luci-app-temp-status
# git clone https://github.com/lkiuyu/DbusSmsForwardCPlus package/DbusSmsForwardCPlus
