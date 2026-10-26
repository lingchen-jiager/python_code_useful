#!/bin/sh

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

CONF_FILE="/etc/mosquitto/mosquitto.conf"
PASSWD_FILE="/etc/mosquitto/passwd"

show_menu() {
    clear
    echo "=========================================="
    echo "    Alpine Mosquitto 一键管理与配置脚本   "
    echo "=========================================="
    echo " 1. 安装 Mosquitto 并配置开机自启"
    echo " 2. 卸载 Mosquitto"
    echo " 3. 启动 / 停止 / 重启服务"
    echo " 4. 配置开机自启开关 (添加/移除)"
    echo " 5. 禁用/启用匿名登录 & 绑定密码文件"
    echo " 6. 添加或修改用户名/密码 (自动修复权限)"
    echo " 7. 修改监听端口与绑定 IP 地址"
    echo " 8. 查看服务状态与运行日志"
    echo " 0. 退出"
    echo "=========================================="
    printf "请选择操作 [0-8]: "
}

install_mosq() {
    echo "正在更新源并安装 mosquitto..."
    apk update && apk add mosquitto mosquitto-clients
    
    # 自动配置开机自启
    rc-update add mosquitto default
    echo "已自动添加到开机自启服务 (default 运行级别)"
    
    rc-service mosquitto start
    echo "安装并启动完成！"
    read -p "按回车键继续..."
}

uninstall_mosq() {
    echo "警告：卸载将删除相关服务及配置。"
    echo "提示：操作前请确认 ~/.config 等目录，避免误删其他软件（如 htop）配置。"
    printf "确认卸载？[y/N]: "
    read confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rc-service mosquitto stop
        rc-update del mosquitto default 2>/dev/null
        apk del mosquitto mosquitto-clients
        rm -rf /etc/mosquitto
        echo "已卸载完成。"
    else
        echo "已取消卸载。"
    fi
    read -p "按回车键继续..."
}

manage_service() {
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    printf "请选择 [1-3]: "
    read choice
    case $choice in
        1) rc-service mosquitto start ;;
        2) rc-service mosquitto stop ;;
        3) rc-service mosquitto restart ;;
        *) echo "无效选择" ;;
    esac
    read -p "按回车键继续..."
}

manage_autostart() {
    echo "1. 启用开机自启"
    echo "2. 禁用开机自启"
    printf "请选择 [1-2]: "
    read choice
    case $choice in
        1)
            rc-update add mosquitto default
            echo "已设置开机自启。"
            ;;
        2)
            rc-update del mosquitto default
            echo "已取消开机自启。"
            ;;
        *) echo "无效选择" ;;
    esac
    read -p "按回车键继续..."
}

config_auth() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "未找到配置文件 $CONF_FILE，请先安装 Mosquitto。"
        read -p "按回车键继续..."
        return
    fi

    echo "1. 禁用匿名登录并启用密码文件"
    echo "2. 允许匿名登录（开启无密码）"
    printf "请选择 [1-2]: "
    read choice

    if [ "$choice" = "1" ]; then
        if grep -q "^allow_anonymous" "$CONF_FILE"; then
            sed -i 's/^allow_anonymous.*/allow_anonymous false/' "$CONF_FILE"
        else
            echo "allow_anonymous false" >> "$CONF_FILE"
        fi

        if grep -q "^password_file" "$CONF_FILE"; then
            sed -i "s|^password_file.*|password_file $PASSWD_FILE|" "$CONF_FILE"
        else
            echo "password_file $PASSWD_FILE" >> "$CONF_FILE"
        fi
        
        touch "$PASSWD_FILE"
        chown mosquitto:mosquitto "$PASSWD_FILE"
        chmod 600 "$PASSWD_FILE"

        echo "已禁用无密码登录，并绑定密码文件：$PASSWD_FILE"
    elif [ "$choice" = "2" ]; then
        sed -i 's/^allow_anonymous.*/allow_anonymous true/' "$CONF_FILE"
        echo "已允许匿名登录。"
    fi

    rc-service mosquitto restart
    read -p "按回车键继续..."
}

manage_user() {
    if [ ! -f "$PASSWD_FILE" ]; then
        touch "$PASSWD_FILE"
    fi

    chown mosquitto:mosquitto "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"

    printf "请输入用户名: "
    read username
    printf "请输入密码: "
    read -s password
    echo

    mosquitto_passwd -b "$PASSWD_FILE" "$username" "$password"
    
    chown mosquitto:mosquitto "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
    
    echo "用户 [$username] 密码设置成功！"
    
    if [ -f "$CONF_FILE" ]; then
        if ! grep -q "password_file" "$CONF_FILE"; then
            echo "password_file $PASSWD_FILE" >> "$CONF_FILE"
        fi
        sed -i 's/^allow_anonymous.*/allow_anonymous false/' "$CONF_FILE"
        rc-service mosquitto restart
    fi
    read -p "按回车键继续..."
}

change_port_ip() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "未找到配置文件 $CONF_FILE，请先安装 Mosquitto。"
        read -p "按回车键继续..."
        return
    fi

    printf "请输入新的监听端口 (例如 1883 或 18833): "
    read new_port
    if [ -z "$new_port" ]; then
        echo "端口不能为空！"
        read -p "按回车键继续..."
        return
    fi

    echo "1. 仅允许本地访问 (127.0.0.1)"
    echo "2. 允许所有 IP 访问 (0.0.0.0 / 推荐局域网或外网连接)"
    printf "请选择绑定 IP 模式 [1-2]: "
    read ip_choice

    if [ "$ip_choice" = "1" ]; then
        new_bind="127.0.0.1"
    else
        new_bind="0.0.0.0"
    fi

    # 清理或更新配置中的 listener 和 bind_address
    # 如果存在带端口的 listener 行，先注释或替换
    if grep -q "^listener " "$CONF_FILE"; then
        sed -i "s/^listener .*/listener $new_port $new_bind/" "$CONF_FILE"
    else
        echo "listener $new_port $new_bind" >> "$CONF_FILE"
    fi

    # 如果有单独的 bind_address，也做相应清理或更新
    if grep -q "^bind_address" "$CONF_FILE"; then
        sed -i "s/^bind_address.*/# bind_address managed by listener/" "$CONF_FILE"
    fi

    echo "已更新配置：端口 -> $new_port，绑定 IP -> $new_bind"
    rc-service mosquitto restart
    read -p "按回车键继续..."
}

view_status() {
    rc-service mosquitto status
    echo "------------------------------------------"
    echo "当前端口监听情况："
    ss -tlnp | grep mosquitto || echo "未检测到 mosquitto 监听端口"
    read -p "按回车键继续..."
}

while true; do
    show_menu
    read opt
    case $opt in
        1) install_mosq ;;
        2) uninstall_mosq ;;
        3) manage_service ;;
        4) manage_autostart ;;
        5) config_auth ;;
        6) manage_user ;;
        7) change_port_ip ;;
        8) view_status ;;
        0) exit 0 ;;
        *) echo "无效选项，请重新选择。" ; sleep 1 ;;
    esac
done
