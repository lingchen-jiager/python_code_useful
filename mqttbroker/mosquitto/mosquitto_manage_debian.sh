#!/bin/bash
# ==========================================================
#   Debian / Ubuntu  Mosquitto 一键管理与配置脚本
#   移植自 Alpine(OpenRC / apk) 版本
#   包管理: apt    服务管理: systemd
#   用法: sudo bash mosquitto_manager_debian.sh
#
#   重要：mosquitto 2.0 中 password_file / allow_anonymous 在整个
#   配置树（主配置 + conf.d/*.conf）里只允许出现一次，重复会直接
#   报 "Duplicate xxx value in configuration" 并拒绝启动。
#   本脚本把这些"认证类指令"统一收敛到唯一托管文件：
#     /etc/mosquitto/conf.d/zz-mosquitto-manager.conf
#   文件名刻意取 99- 前缀：include_dir 按文件名排序加载，托管文件最后
#   加载，才能保证它只作用于自己声明的 listener，不会被别的文件里残留的
#   按监听器生效的指令（certfile / keyfile 等）污染。
#   写入前会把散落在其他配置文件里的同名指令移走（带时间戳备份）。
# ==========================================================

CONF_FILE="/etc/mosquitto/mosquitto.conf"
PASSWD_FILE="/etc/mosquitto/passwd"
CONF_D="/etc/mosquitto/conf.d"
MANAGED_FILE="$CONF_D/zz-mosquitto-manager.conf"
SERVICE="mosquitto"

# ---------- 基础环境检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本 (sudo bash $0)"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "未检测到 systemd，本脚本仅适用于 Debian / Ubuntu 等 systemd 系统。"
    exit 1
fi

pause() { read -r -p "按回车键继续..." _; }
clear_screen() { command -v clear >/dev/null 2>&1 && clear; }
stamp() { date +%Y%m%d%H%M%S; }

# ---------- 目录与属主修复 ----------
fix_dirs() {
    mkdir -p /var/log/mosquitto /var/lib/mosquitto /run/mosquitto "$(dirname "$PASSWD_FILE")" "$CONF_D"
    chown -R mosquitto:mosquitto /var/log/mosquitto /var/lib/mosquitto /run/mosquitto 2>/dev/null
    chmod 755 /var/log/mosquitto /var/lib/mosquitto /run/mosquitto 2>/dev/null
}

# ---------- 配置树遍历 ----------
# 按 mosquitto 的实际加载顺序输出：主配置 + conf.d/*.conf（文件名排序）
conf_files() {
    local f
    [ -f "$CONF_FILE" ] && printf '%s\n' "$CONF_FILE"
    if [ -d "$CONF_D" ]; then
        for f in "$CONF_D"/*.conf; do
            [ -f "$f" ] && printf '%s\n' "$f"
        done | LC_ALL=C sort
    fi
}

ensure_conf() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "未找到配置文件 $CONF_FILE，请先安装 Mosquitto（菜单 1）。"
        return 1
    fi
    return 0
}

# 某指令在整个配置树（主配置 + conf.d，含托管文件）中出现的总次数
count_directive() {
    local key="$1" f n=0
    while IFS= read -r f; do
        n=$(( n + $(grep -cE "^[[:space:]]*${key}[[:space:]]" "$f" 2>/dev/null) ))
    done < <(conf_files)
    echo "$n"
}

# 从所有非托管配置文件中删除某指令（先备份）
strip_directive() {
    local key="$1" f
    while IFS= read -r f; do
        [ "$f" = "$MANAGED_FILE" ] && continue
        if grep -qE "^[[:space:]]*${key}[[:space:]]" "$f" 2>/dev/null; then
            cp -a "$f" "$f.bak.$(stamp)"
            sed -i -E "/^[[:space:]]*${key}[[:space:]]/d" "$f"
            echo "  - 已移出 ${f}: ${key}"
            grep -qE '[^[:space:]]' "$f" 2>/dev/null || \
                echo "  提示：${f} 已空，可直接删除（空文件不影响启动）"
        fi
    done < <(conf_files)
}

# 删除其他文件里与托管端口相同的 listener（同端口重复会 Address already in use）
prune_same_port_listener() {
    local port="$1" f
    while IFS= read -r f; do
        [ "$f" = "$MANAGED_FILE" ] && continue
        if grep -qE "^[[:space:]]*listener[[:space:]]+${port}([[:space:]]|\$)" "$f" 2>/dev/null; then
            cp -a "$f" "$f.bak.$(stamp)"
            sed -i -E "/^[[:space:]]*listener[[:space:]]+${port}([[:space:]]|\$)/d" "$f"
            echo "  - 已移出 ${f}: listener ${port}"
        fi
    done < <(conf_files)
}

# 列出不在托管范围内的其他监听器（如 websocket 9001），仅提示不处理
warn_other_listeners() {
    local port="$1" f line
    while IFS= read -r f; do
        [ "$f" = "$MANAGED_FILE" ] && continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            set -- $line
            [ "$2" = "$port" ] && continue
            echo "  提示：非托管监听器 [$line] 位于 $f，其认证不受本脚本管理。"
        done < <(grep -E '^[[:space:]]*listener[[:space:]]+' "$f" 2>/dev/null)
    done < <(conf_files)
}

# ---------- 读取当前配置 ----------
get_listener() {
    local f line last=""
    if [ -f "$MANAGED_FILE" ]; then
        line=$(grep -E '^[[:space:]]*listener[[:space:]]+' "$MANAGED_FILE" 2>/dev/null | tail -n1)
        if [ -n "$line" ]; then
            echo "$line" | awk '{print $2, $3}'
            return
        fi
    fi
    while IFS= read -r f; do
        [ "$f" = "$MANAGED_FILE" ] && continue
        line=$(grep -E '^[[:space:]]*listener[[:space:]]+' "$f" 2>/dev/null | tail -n1)
        [ -n "$line" ] && last="$line"
    done < <(conf_files)
    if [ -n "$last" ]; then
        echo "$last" | awk '{print $2, $3}'
    else
        echo "1883 127.0.0.1"
    fi
}

get_anon() {
    local f v=""
    [ -f "$MANAGED_FILE" ] && v=$(grep -E '^[[:space:]]*allow_anonymous[[:space:]]+' "$MANAGED_FILE" 2>/dev/null | tail -n1 | awk '{print $2}')
    if [ -z "$v" ]; then
        while IFS= read -r f; do
            [ "$f" = "$MANAGED_FILE" ] && continue
            v=$(grep -E '^[[:space:]]*allow_anonymous[[:space:]]+' "$f" 2>/dev/null | tail -n1 | awk '{print $2}')
        done < <(conf_files)
    fi
    echo "${v:-false}"
}

has_passwd_file() {
    local f
    while IFS= read -r f; do
        grep -qE '^[[:space:]]*password_file[[:space:]]+' "$f" 2>/dev/null && return 0
    done < <(conf_files)
    return 1
}

# ---------- 写入托管文件（唯一出口）----------
# 顺序固定：listener -> allow_anonymous -> password_file
# （2.0 中这三项是按监听器生效的，listener 必须在最前）
apply_config() {
    local port="$1" bind="$2" anon="$3" pw="$4"

    ensure_conf || return 1
    mkdir -p "$CONF_D"

    # 主配置必须有 include_dir，否则托管文件不会生效
    if ! grep -qE '^[[:space:]]*include_dir[[:space:]]+' "$CONF_FILE" 2>/dev/null; then
        echo "include_dir $CONF_D" >> "$CONF_FILE"
        echo "  - 已补回 include_dir $CONF_D"
    fi

    # 去重第一步：把散落在别处的同名指令移走
    strip_directive password_file
    strip_directive allow_anonymous
    strip_directive bind_address
    prune_same_port_listener "$port"

    # 去重第二步：写唯一托管文件
    {
        echo "# ==== BEGIN mosquitto-manager ===="
        echo "# 由 mosquitto_manager_debian.sh 托管，请勿手工改动认证相关行"
        echo "listener ${port} ${bind}"
        echo "allow_anonymous ${anon}"
        [ "$pw" = "yes" ] && echo "password_file ${PASSWD_FILE}"
        echo "# ==== END mosquitto-manager ===="
    } > "$MANAGED_FILE"
    chown root:root "$MANAGED_FILE"
    chmod 644 "$MANAGED_FILE"

    warn_other_listeners "$port"
}

restart_service() {
    # 清掉 systemd 的 start-limit 计数，否则会卡在
    # "Start request repeated too quickly"
    systemctl reset-failed "$SERVICE" 2>/dev/null
    systemctl restart "$SERVICE" 2>/dev/null
    sleep 2
    local st
    st=$(systemctl is-active "$SERVICE" 2>/dev/null)
    echo "服务状态：$st"
    if [ "$st" != "active" ]; then
        echo "!! 启动失败，最近日志如下："
        journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null
    fi
}

# ---------- 1. 安装 ----------
install_mosq() {
    echo "正在更新 apt 源并安装 mosquitto / mosquitto-clients ..."
    apt-get update -y && apt-get install -y mosquitto mosquitto-clients

    fix_dirs
    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<EOF
pid_file /run/mosquitto/mosquitto.pid

persistence true
persistence_location /var/lib/mosquitto/

log_dest file /var/log/mosquitto/mosquitto.log

include_dir $CONF_D
EOF
    fi
    chown root:root "$CONF_FILE"; chmod 644 "$CONF_FILE"

    systemctl enable --now "$SERVICE"
    sleep 1
    echo "------------------------------------------"
    echo "已安装并设为开机自启 + 立即启动。"
    echo "active : $(systemctl is-active "$SERVICE" 2>/dev/null)"
    echo "enabled: $(systemctl is-enabled "$SERVICE" 2>/dev/null)"
    pause
}

# ---------- 2. 卸载 ----------
uninstall_mosq() {
    echo "警告：卸载将删除 mosquitto 软件包及 /etc/mosquitto 配置文件。"
    printf "确认卸载？[y/N]: "
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        systemctl stop "$SERVICE" 2>/dev/null
        systemctl disable "$SERVICE" 2>/dev/null
        apt-get purge -y mosquitto mosquitto-clients
        rm -rf /etc/mosquitto
        apt-get autoremove -y
        echo "已卸载完成。"
    else
        echo "已取消卸载。"
    fi
    pause
}

# ---------- 3. 启动 / 停止 / 重启 ----------
manage_service() {
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    printf "请选择 [1-3]: "
    read -r choice
    case $choice in
        1) systemctl reset-failed "$SERVICE" 2>/dev/null; systemctl start "$SERVICE" ;;
        2) systemctl stop "$SERVICE" ;;
        3) systemctl reset-failed "$SERVICE" 2>/dev/null; systemctl restart "$SERVICE" ;;
        *) echo "无效选择" ;;
    esac
    sleep 1
    echo "服务状态：$(systemctl is-active "$SERVICE" 2>/dev/null)"
    pause
}

# ---------- 4. 开机自启开关 ----------
manage_autostart() {
    echo "1. 启用开机自启"
    echo "2. 禁用开机自启"
    printf "请选择 [1-2]: "
    read -r choice
    case $choice in
        1) systemctl enable "$SERVICE"; echo "已设置开机自启。" ;;
        2) systemctl disable "$SERVICE"; echo "已取消开机自启。" ;;
        *) echo "无效选择" ;;
    esac
    pause
}

# ---------- 5. 匿名登录 & 密码文件 ----------
config_auth() {
    ensure_conf || { pause; return; }

    echo "1. 禁用匿名登录并启用密码文件"
    echo "2. 允许匿名登录（无密码）"
    printf "请选择 [1-2]: "
    read -r choice

    local cur
    cur=$(get_listener)
    set -- $cur
    local port="$1" bind="$2"

    if [ "$choice" = "1" ]; then
        [ -f "$PASSWD_FILE" ] || touch "$PASSWD_FILE"
        chown mosquitto:mosquitto "$PASSWD_FILE"
        chmod 600 "$PASSWD_FILE"
        apply_config "$port" "$bind" "false" "yes"
        echo "已禁用匿名登录，密码文件：$PASSWD_FILE"
    elif [ "$choice" = "2" ]; then
        apply_config "$port" "$bind" "true" "no"
        echo "已允许匿名登录。"
    else
        echo "无效选择"
        pause
        return
    fi

    restart_service
    pause
}

# ---------- 6. 添加 / 修改用户名密码 ----------
manage_user() {
    ensure_conf || { pause; return; }

    [ -f "$PASSWD_FILE" ] || touch "$PASSWD_FILE"
    chown mosquitto:mosquitto "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"

    printf "请输入用户名: "
    read -r username
    if [ -z "$username" ]; then
        echo "用户名不能为空！"
        pause
        return
    fi
    printf "请输入密码: "
    read -r -s password
    echo
    if [ -z "$password" ]; then
        echo "密码不能为空！"
        pause
        return
    fi

    mosquitto_passwd -b "$PASSWD_FILE" "$username" "$password"
    chown mosquitto:mosquitto "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
    echo "用户 [$username] 密码设置成功！"

    # 建了用户就顺手关匿名 + 绑密码文件（保留当前端口/绑定 IP）
    local cur
    cur=$(get_listener)
    set -- $cur
    apply_config "$1" "$2" "false" "yes"
    restart_service
    pause
}

# ---------- 7. 修改监听端口与绑定 IP ----------
change_port_ip() {
    ensure_conf || { pause; return; }

    printf "请输入新的监听端口 (例如 1883 或 18833): "
    read -r new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo "端口无效！"
        pause
        return
    fi

    echo "1. 仅允许本地访问 (127.0.0.1)"
    echo "2. 允许所有 IP 访问 (0.0.0.0，局域网/外网连接选这个)"
    printf "请选择绑定 IP 模式 [1-2]: "
    read -r ip_choice

    if [ "$ip_choice" = "1" ]; then
        new_bind="127.0.0.1"
    else
        new_bind="0.0.0.0"
    fi

    apply_config "$new_port" "$new_bind" "$(get_anon)" "$(has_passwd_file && echo yes || echo no)"
    echo "已更新配置：端口 -> $new_port，绑定 IP -> $new_bind"

    if [ "$new_bind" = "0.0.0.0" ] && command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "^Status: active"; then
            printf "检测到 ufw 已启用，是否放行 TCP $new_port？[y/N]: "
            read -r fw
            if [ "$fw" = "y" ] || [ "$fw" = "Y" ]; then
                ufw allow "$new_port"/tcp
                echo "已放行 TCP $new_port"
            fi
        fi
    fi

    restart_service
    if [ "$new_bind" = "0.0.0.0" ]; then
        echo "提示：云服务器还需在安全组/控制台放行 TCP $new_port。"
    fi
    pause
}

# ---------- 8. 查看状态与日志 ----------
view_status() {
    echo "== 服务状态 =="
    systemctl status "$SERVICE" --no-pager -l 2>/dev/null || echo "服务不存在，请先安装。"
    echo "开机自启: $(systemctl is-enabled "$SERVICE" 2>/dev/null)"
    echo "------------------------------------------"
    echo "== 当前端口监听 =="
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp | grep -i mosquitto || echo "未检测到 mosquitto 监听端口"
    else
        netstat -tlnp 2>/dev/null | grep -i mosquitto || echo "未检测到 mosquitto 监听端口"
    fi
    echo "------------------------------------------"
    echo "== 最近 30 条日志 (journalctl -u mosquitto) =="
    journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null || echo "无可用日志"
    echo "------------------------------------------"
    echo "实时日志: journalctl -u mosquitto -f"
    pause
}

# ---------- 9. 配置体检 / 一键去重修复 ----------
health_check() {
    ensure_conf || { pause; return; }

    echo "== 配置文件清单（按加载顺序）=="
    conf_files | nl -ba

    echo
    echo "== 重复项检测（这些指令出现 2 次即启动失败）=="
    local bad=0 k n
    for k in password_file allow_anonymous bind_address; do
        n=$(count_directive "$k")
        if [ "$n" -gt 1 ]; then
            printf "  %-16s %s 次   <== 会导致 Duplicate %s value 启动失败\n" "$k" "$n" "$k"
            bad=1
        else
            printf "  %-16s %s 次   OK\n" "$k" "$n"
        fi
    done

    echo
    echo "== 监听器检测 =="
    local dup_ports
    dup_ports=$(conf_files | xargs grep -hE '^[[:space:]]*listener[[:space:]]+' 2>/dev/null | awk '{print $2}' | sort -u | while read -r p; do
        c=$(conf_files | xargs grep -hE "^[[:space:]]*listener[[:space:]]+${p}([[:space:]]|\$)" 2>/dev/null | wc -l)
        [ "$c" -gt 1 ] && echo "$p"
    done)
    if [ -n "$dup_ports" ]; then
        for p in $dup_ports; do
            echo "  端口 $p 被多个 listener 重复声明 <== 会 Address already in use"
        done
        bad=1
    else
        echo "  无同端口重复监听器  OK"
    fi

    echo
    echo "== 密码文件 =="
    if [ -f "$PASSWD_FILE" ]; then
        local ow pm
        ow=$(stat -c '%U' "$PASSWD_FILE" 2>/dev/null)
        pm=$(stat -c '%a' "$PASSWD_FILE" 2>/dev/null)
        if [ "$ow" = "mosquitto" ] && [ "$pm" = "600" ]; then
            echo "  $PASSWD_FILE  属主 $ow  权限 $pm  OK"
        else
            echo "  $PASSWD_FILE  属主 $ow  权限 $pm  <== 应为 mosquitto:mosquitto 600"
            bad=1
        fi
    else
        echo "  密码文件不存在：$PASSWD_FILE"
        has_passwd_file && { echo "  但配置里引用了它 <== 启动会失败"; bad=1; }
    fi

    echo "------------------------------------------"
    if [ "$bad" = "1" ]; then
        printf "发现问题，是否一键去重修复（自动备份原文件）？[y/N]: "
        read -r fx
        if [ "$fx" = "y" ] || [ "$fx" = "Y" ]; then
            local cur
            cur=$(get_listener)
            set -- $cur
            if [ -f "$PASSWD_FILE" ]; then
                chown mosquitto:mosquitto "$PASSWD_FILE" 2>/dev/null
                chmod 600 "$PASSWD_FILE"
                echo "  - 已修正密码文件属主/权限：mosquitto:mosquitto 600"
            fi
            apply_config "$1" "$2" "$(get_anon)" "$(has_passwd_file && echo yes || echo no)"
            restart_service
        fi
    else
        echo "未发现配置问题。"
    fi
    pause
}

# ---------- 10. 本机连通性自检 ----------
self_test() {
    if ! command -v mosquitto_pub >/dev/null 2>&1; then
        echo "未安装 mosquitto-clients，请先执行菜单 1 安装。"
        pause
        return
    fi

    local cur topic res p cargs=()
    cur=$(get_listener)
    set -- $cur
    local port="$1"

    printf "用户名（匿名登录请直接回车）: "
    read -r u
    [ -n "$u" ] && cargs+=(-u "$u")
    if [ -n "$u" ]; then
        printf "密码: "
        read -r -s p
        echo
        [ -n "$p" ] && cargs+=(-P "$p")
    fi

    topic="mosquitto-manager/selftest/$$"

    echo "== 发布测试消息 =="
    mosquitto_pub "${cargs[@]}" -h 127.0.0.1 -p "$port" -t "$topic" -m "hello-from-manager" -r \
        && echo "发布成功" || { echo "发布失败，请检查服务与认证配置"; pause; return; }

    echo "== 订阅接收测试 =="
    res=$(timeout 5 mosquitto_sub "${cargs[@]}" -h 127.0.0.1 -p "$port" -t "$topic" -C 1 -W 3 2>&1)
    if [ "$res" = "hello-from-manager" ]; then
        echo "收发正常 ✔  MQTT 链路可用（端口 $port）"
    else
        echo "未收到消息 ✘  返回: $res"
    fi

    mosquitto_pub "${cargs[@]}" -h 127.0.0.1 -p "$port" -t "$topic" -n -r >/dev/null 2>&1
    pause
}

# ---------- 菜单 ----------
show_menu() {
    clear_screen
    echo "=========================================="
    echo "   Debian Mosquitto 一键管理与配置脚本   "
    echo "=========================================="
    if [ -f "$CONF_FILE" ]; then
        printf "  当前：%s   匿名：%s\n" "$(get_listener)" "$(get_anon)"
        echo "------------------------------------------"
    fi
    echo " 1. 安装 Mosquitto 并配置开机自启"
    echo " 2. 卸载 Mosquitto"
    echo " 3. 启动 / 停止 / 重启服务"
    echo " 4. 配置开机自启开关 (添加/移除)"
    echo " 5. 禁用/启用匿名登录 & 绑定密码文件"
    echo " 6. 添加或修改用户名/密码 (自动修复权限)"
    echo " 7. 修改监听端口与绑定 IP 地址"
    echo " 8. 查看服务状态与运行日志"
    echo " 9. 配置体检 / 一键去重修复"
    echo "10. 本机连通性自检 (发布/订阅一条测试消息)"
    echo " 0. 退出"
    echo "=========================================="
    printf "请选择操作 [0-10]: "
}

# ---------- 首次运行先修一次目录 ----------
if command -v mosquitto >/dev/null 2>&1; then
    fix_dirs
fi

while true; do
    show_menu
    read -r opt
    case $opt in
        1) install_mosq ;;
        2) uninstall_mosq ;;
        3) manage_service ;;
        4) manage_autostart ;;
        5) config_auth ;;
        6) manage_user ;;
        7) change_port_ip ;;
        8) view_status ;;
        9) health_check ;;
        10) self_test ;;
        0) exit 0 ;;
        *) echo "无效选项，请重新选择。" ; sleep 1 ;;
    esac
done
