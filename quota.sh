#!/bin/bash

# ====================================================
#  全机流量限额封禁脚本 quota.sh (Bug 修复版)
#  与 zf.sh 共享以下关联标记，请勿随意改名：
#    $TRAFFIC_DIR/manual_block_all.conf          —— 用户手动"立即封禁所有端口"
#    $TRAFFIC_DIR/quota_auto_block_all.conf      —— quota 因超限自动封禁（内部标记）
#    $TRAFFIC_DIR/quota_manual_block_<port>.conf —— quota 按端口标记，给 zf 看
#    nft 表: inet quota_block + inet realm_block —— 双写给 zf 端口状态显示 stopped
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
BLUE='\033[0;36m'

REALM_CONFIG="/etc/realm/config.toml"
TRAFFIC_DIR="/etc/realm"
CONFIG_FILE="/etc/realm/quota.conf"
STATE_FILE="/etc/realm/quota_state.txt"
SCRIPT_PATH=$(readlink -f "$0")

MONITOR_SERVICE="/etc/systemd/system/quota-traffic.service"
MONITOR_TIMER="/etc/systemd/system/quota-traffic.timer"
RESET_SERVICE="/etc/systemd/system/quota-reset.service"
RESET_TIMER="/etc/systemd/system/quota-reset.timer"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "\n${RED}错误：请使用 root 用户运行此脚本！${PLAIN}\n"
        exit 1
    fi
}

init_dirs() {
    mkdir -p /etc/realm
}

# ---------------- nft 精确匹配 helper (修复端口前缀误匹配) ----------------
nft_has_rule() {
    local table=$1 chain=$2 proto=$3 dir=$4 port=$5 action=$6
    nft -a list chain inet "$table" "$chain" 2>/dev/null | \
        awk -v p="$proto" -v d="$dir" -v port="$port" -v a="$action" '
            { for (i=1; i<=NF; i++) {
                if ($i==p && $(i+1)==d && $(i+2)==port && $(i+3)==a) { found=1; exit }
              } }
            END { exit !found }
        '
}

nft_del_rule() {
    local table=$1 chain=$2 proto=$3 dir=$4 port=$5 action=$6
    local handle
    while true; do
        handle=$(nft -a list chain inet "$table" "$chain" 2>/dev/null | \
            awk -v p="$proto" -v d="$dir" -v port="$port" -v a="$action" '
                { for (i=1; i<=NF; i++) {
                    if ($i==p && $(i+1)==d && $(i+2)==port && $(i+3)==a) { print $NF; exit }
                  } }
            ')
        [[ -z "$handle" ]] && break
        nft delete rule inet "$table" "$chain" handle "$handle" 2>/dev/null || break
    done
}

install_vnstat_if_needed() {
    if command -v vnstat >/dev/null 2>&1; then
        return
    fi
    echo -e "${YELLOW}检测到未安装 vnstat，正在自动安装...${PLAIN}\n"
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y vnstat
    elif [ -f /etc/redhat-release ]; then
        yum install -y vnstat
    else
        echo -e "${RED}无法识别系统类型，请手动安装 vnstat！${PLAIN}"
        exit 1
    fi
    systemctl enable --now vnstat >/dev/null 2>&1
    echo -e "\n${GREEN}vnstat 已安装并启动${PLAIN}\n"
}

ensure_vnstat_interval() {
    local conf="/etc/vnstat.conf"
    if [ ! -f "$conf" ]; then return; fi
    if grep -q '^[[:space:]]*UpdateInterval' "$conf"; then
        sed -i 's/^[[:space:]]*UpdateInterval.*/UpdateInterval 10/' "$conf"
    else
        echo "UpdateInterval 10" >> "$conf"
    fi
    systemctl restart vnstat >/dev/null 2>&1
}

ensure_vnstat_iface() {
    local iface="$1"
    if [[ -z "$iface" ]]; then return; fi
    vnstat --json -i "$iface" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        vnstat -u -i "$iface" >/dev/null 2>&1 || vnstat --add -i "$iface" >/dev/null 2>&1 || vnstat --create -i "$iface" >/dev/null 2>&1
        systemctl restart vnstat >/dev/null 2>&1
        return
    fi
    local has_data
    has_data=$(vnstat --json -i "$iface" 2>/dev/null | awk '/"month"/ {print 1; exit}')
    if [[ -z "$has_data" ]]; then
        vnstat -u -i "$iface" >/dev/null 2>&1 || vnstat --add -i "$iface" >/dev/null 2>&1 || vnstat --create -i "$iface" >/dev/null 2>&1
        systemctl restart vnstat >/dev/null 2>&1
    fi
}

set_quota_shortcut() {
    if [ ! -f "/usr/bin/qo" ]; then
        ln -sf "$SCRIPT_PATH" /usr/bin/qo
        chmod +x /usr/bin/qo
        echo -e "${GREEN}快捷键 'qo' 已设置成功！以后输入 qo 即可打开面板！${PLAIN}"
    fi
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
MODE="$MODE"
QUOTA_GB="$QUOTA_GB"
RESET_DAY="$RESET_DAY"
IFACE="$IFACE"
EOF
}

ensure_reset_timer() {
    if [[ -z "$RESET_DAY" ]]; then return; fi
    cat > "$RESET_SERVICE" <<EOF
[Unit]
Description=Quota Monthly Reset

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH reset_exec
EOF
    # 用 10# 防止前导 0 被当作八进制 (修复)
    local day_fmt
    day_fmt=$(printf "%02d" "$((10#$RESET_DAY))")
    cat > "$RESET_TIMER" <<EOF
[Unit]
Description=Quota Monthly Reset Timer

[Timer]
OnCalendar=*-*-${day_fmt} 00:00:00
Persistent=true
Unit=quota-reset.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now quota-reset.timer >/dev/null 2>&1
}

stop_reset_timer() {
    systemctl disable --now quota-reset.timer >/dev/null 2>&1
}

detect_iface() {
    ip route | awk '/default/ {print $5; exit}'
}

setup_wizard() {
    echo -e ""
    echo -e "${YELLOW}------------ 初始化配置 ------------${PLAIN}"
    echo -e ""
    echo -e "请选择流量统计:"
    echo -e ""
    echo -e " 1. 双向总流量(入+出)"
    echo -e ""
    echo -e " 2. 仅入站总流量"
    echo -e ""
    echo -e " 3. 仅出站总流量"
    echo -e ""
    echo -e " 0. 退出"
    echo -e ""
    read -p "请选择[0-3]: " MODE
    echo -e ""
    if [[ "$MODE" == "0" ]]; then exit 0; fi
    read -p "请输入月限额(GB): " QUOTA_GB
    echo -e ""
    read -p "每月重置日(1-31): " RESET_DAY
    echo -e ""
    def_iface=$(detect_iface)
    read -p "统计网卡(回车默认 $def_iface): " IFACE
    echo -e ""
    if [[ -z "$IFACE" ]]; then IFACE="$def_iface"; fi
    ensure_vnstat_iface "$IFACE"
    save_config
    ensure_reset_timer
    ensure_monitor_timer
    echo -e "${GREEN}配置已保存${PLAIN}\n"
    read -n 1 -s -r -p "按任意键返回..."
    echo -e ""
}

# 只提取真正的 DNAT/REDIRECT 转发端口 (修复原 bug)
get_ports() {
    {
        if [ -f "$REALM_CONFIG" ]; then
            grep 'listen' "$REALM_CONFIG" | awk -F']' '{print $2}' | tr -d ':"'
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -t nat -S PREROUTING 2>/dev/null | awk '
                /-j DNAT/ || /-j REDIRECT/ {
                    for (i=1;i<=NF;i++) if ($i=="--dport") print $(i+1)
                }
            '
        fi
    } | grep -E '^[0-9]+$' | sort -u
}

ensure_block_chain() {
    if ! nft list table inet quota_block >/dev/null 2>&1; then
        nft add table inet quota_block
        nft add chain inet quota_block input { type filter hook input priority -200 \; }
    fi
    if ! nft list table inet realm_block >/dev/null 2>&1; then
        nft add table inet realm_block
        nft add chain inet realm_block input { type filter hook input priority -300 \; }
    fi
}

# 封禁所有转发端口 ($1 = source: manual|auto)
block_ports() {
    local source="${1:-auto}"
    ensure_block_chain
    if [[ "$source" == "manual" ]]; then
        touch "$TRAFFIC_DIR/manual_block_all.conf"
    else
        touch "$TRAFFIC_DIR/quota_auto_block_all.conf"
    fi
    for port in $(get_ports); do
        # quota 端口级标记，告诉 zf 这个端口被 quota 封了
        touch "$TRAFFIC_DIR/quota_manual_block_${port}.conf"
        nft_has_rule quota_block input tcp dport "$port" drop || nft add rule inet quota_block input tcp dport "$port" drop
        nft_has_rule quota_block input udp dport "$port" drop || nft add rule inet quota_block input udp dport "$port" drop
        nft_has_rule realm_block input tcp dport "$port" drop || nft add rule inet realm_block input tcp dport "$port" drop
        nft_has_rule realm_block input udp dport "$port" drop || nft add rule inet realm_block input udp dport "$port" drop
    done
}

# 解除封禁所有转发端口 ($1 = source: manual|auto|all)
#   manual 只清 manual_block_all.conf 相关封禁
#   auto   只清 quota_auto_block_all.conf 相关封禁
#   all    都清
unblock_ports() {
    local source="${1:-auto}"
    ensure_block_chain
    case "$source" in
        manual) rm -f "$TRAFFIC_DIR/manual_block_all.conf" ;;
        auto)   rm -f "$TRAFFIC_DIR/quota_auto_block_all.conf" ;;
        all)    rm -f "$TRAFFIC_DIR/manual_block_all.conf" "$TRAFFIC_DIR/quota_auto_block_all.conf" ;;
    esac
    # 如果仍存在任一封禁标记，则保留封禁，不做清理 (修复 monitor 误删手动标记的 bug)
    if [[ -f "$TRAFFIC_DIR/manual_block_all.conf" || -f "$TRAFFIC_DIR/quota_auto_block_all.conf" ]]; then
        return
    fi
    for port in $(get_ports); do
        rm -f "$TRAFFIC_DIR/quota_manual_block_${port}.conf"
        # 清 quota_block
        nft_del_rule quota_block input tcp dport "$port" drop
        nft_del_rule quota_block input udp dport "$port" drop
        # 清 realm_block，但 zf 手动封禁的端口要保留
        if [[ -f "$TRAFFIC_DIR/manual_block_${port}.conf" ]]; then
            continue
        fi
        nft_del_rule realm_block input tcp dport "$port" drop
        nft_del_rule realm_block input udp dport "$port" drop
    done
}

format_bytes() {
    local b=$1
    if [[ $b -lt 1024 ]]; then
        echo "${b} B"
    elif [[ $b -lt 1048576 ]]; then
        awk -v v="$b" 'BEGIN{printf "%.2f KB\n", v/1024}'
    elif [[ $b -lt 1073741824 ]]; then
        awk -v v="$b" 'BEGIN{printf "%.2f MB\n", v/1048576}'
    else
        awk -v v="$b" 'BEGIN{printf "%.2f GB\n", v/1073741824}'
    fi
}

get_usage_bytes() {
    local mode="$1"
    local iface="$2"
    local reset_day="$3"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$mode" "$iface" "$reset_day" <<'PY'
import json, subprocess, sys, calendar
from datetime import date

mode      = sys.argv[1]
iface     = sys.argv[2]
reset_day = int(sys.argv[3])
today     = date.today()

try:
    if today.day >= reset_day:
        cycle_start = date(today.year, today.month, reset_day)
    else:
        m = today.month - 1 or 12
        y = today.year if today.month > 1 else today.year - 1
        last_day = calendar.monthrange(y, m)[1]
        cycle_start = date(y, m, min(reset_day, last_day))
except Exception:
    cycle_start = date(today.year, today.month, 1)

try:
    out = subprocess.check_output(["vnstat", "--json", "-i", iface], text=True)
    data = json.loads(out)
    interfaces = data.get("interfaces") or []
    if not interfaces:
        print(0); raise SystemExit
    days = interfaces[0].get("traffic", {}).get("day") or []
    rx = tx = 0
    for d in days:
        di = d.get("date", {})
        if date(di["year"], di["month"], di["day"]) >= cycle_start:
            rx += d.get("rx", 0)
            tx += d.get("tx", 0)
    print(rx + tx if mode == "1" else rx if mode == "2" else tx)
except Exception:
    print(0)
PY
    elif command -v python >/dev/null 2>&1; then
        python - "$mode" "$iface" "$reset_day" <<'PY'
import json, subprocess, sys, calendar
from datetime import date

mode      = sys.argv[1]
iface     = sys.argv[2]
reset_day = int(sys.argv[3])
today     = date.today()

try:
    if today.day >= reset_day:
        cycle_start = date(today.year, today.month, reset_day)
    else:
        m = today.month - 1 or 12
        y = today.year if today.month > 1 else today.year - 1
        last_day = calendar.monthrange(y, m)[1]
        cycle_start = date(y, m, min(reset_day, last_day))
except Exception:
    cycle_start = date(today.year, today.month, 1)

try:
    out = subprocess.check_output(["vnstat", "--json", "-i", iface], text=True)
    data = json.loads(out)
    interfaces = data.get("interfaces") or []
    if not interfaces:
        print(0); raise SystemExit
    days = interfaces[0].get("traffic", {}).get("day") or []
    rx = tx = 0
    for d in days:
        di = d.get("date", {})
        if date(di["year"], di["month"], di["day"]) >= cycle_start:
            rx += d.get("rx", 0)
            tx += d.get("tx", 0)
    print(rx + tx if mode == "1" else rx if mode == "2" else tx)
except Exception:
    print(0)
PY
    else
        echo 0
    fi
}

show_usage() {
    while true; do
        load_config
        ensure_vnstat_iface "$IFACE"
        local bytes=$(get_usage_bytes "$MODE" "$IFACE" "$RESET_DAY")
        local used_h=$(format_bytes ${bytes:-0})
        local limit_h="${QUOTA_GB} GB"
        echo -e "${YELLOW}------------ 当前流量使用情况 ------------${PLAIN}"
        echo -e ""
        echo -e " 网卡: ${GREEN}${IFACE}${PLAIN}"
        echo -e ""
        if [[ "$MODE" == "1" ]]; then mode_text="双向总流量"
        elif [[ "$MODE" == "2" ]]; then mode_text="仅入站"
        else mode_text="仅出站"; fi
        echo -e " 口径: ${BLUE}${mode_text}${PLAIN}"
        echo -e ""
        echo -e " 计费周期: ${BLUE}每月 ${RESET_DAY} 日重置${PLAIN}"
        echo -e ""
        echo -e " 已用: ${GREEN}${used_h}${PLAIN}"
        echo -e ""
        echo -e " 限额: ${YELLOW}${limit_h}${PLAIN}"
        echo -e ""
        echo -e " 1. 刷新统计"
        echo -e ""
        echo -e " 0. 返回"
        echo -e ""
        read -p "请输入选项[0-1]: " c
        case "$c" in
            1) echo -e "\n${GREEN}正在刷新数据...${PLAIN}"; systemctl restart vnstat; sleep 1; echo -e ""; continue ;;
            0) return ;;
            *) echo -e ""; continue ;;
        esac
    done
}

ensure_monitor_timer() {
    cat > "$MONITOR_SERVICE" <<EOF
[Unit]
Description=Quota Traffic Monitor

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT_PATH monitor
EOF
    cat > "$MONITOR_TIMER" <<EOF
[Unit]
Description=Quota Traffic Monitor Timer

[Timer]
OnBootSec=10s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=quota-traffic.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now quota-traffic.timer >/dev/null 2>&1
}

stop_monitor_timer() {
    systemctl disable --now quota-traffic.timer >/dev/null 2>&1
}

show_monitor_status() {
    echo -e ""
    echo -e "${YELLOW}------------ 监控状态 ------------${PLAIN}"
    echo -e ""
    if systemctl is-active --quiet quota-traffic.timer; then
        echo -e " 监控状态: ${GREEN}已运行${PLAIN}"
    else
        echo -e " 监控状态: ${RED}未运行${PLAIN}"
    fi
    echo -e ""
    if systemctl is-active --quiet quota-reset.timer; then
        echo -e " 重置定时: ${GREEN}已启用${PLAIN}"
    else
        echo -e " 重置定时: ${RED}未启用${PLAIN}"
    fi
    echo -e ""
    read -n 1 -s -r -p "按任意键返回..."
    echo -e ""
}

uninstall_all() {
    echo ""
    read -p "确定要卸载脚本及所有组件吗？(y/n): " choice
    if [[ "$choice" != "y" ]]; then return; fi
    stop_monitor_timer
    stop_reset_timer
    rm -f "$MONITOR_SERVICE" "$MONITOR_TIMER" "$RESET_SERVICE" "$RESET_TIMER"
    systemctl daemon-reload
    rm -f "$CONFIG_FILE" "$STATE_FILE" /usr/bin/qo
    # 无条件把所有封禁都撤掉 (卸载场景)
    rm -f "$TRAFFIC_DIR/manual_block_all.conf"
    rm -f "$TRAFFIC_DIR/quota_auto_block_all.conf"
    rm -f "$TRAFFIC_DIR/quota_manual_block_"*.conf
    ensure_block_chain
    for port in $(get_ports); do
        nft_del_rule quota_block input tcp dport "$port" drop
        nft_del_rule quota_block input udp dport "$port" drop
        # realm_block 里 zf 手动封禁的端口保留
        if [[ -f "$TRAFFIC_DIR/manual_block_${port}.conf" ]]; then
            continue
        fi
        nft_del_rule realm_block input tcp dport "$port" drop
        nft_del_rule realm_block input udp dport "$port" drop
    done
    nft delete table inet quota_block 2>/dev/null
    if systemctl list-unit-files | grep -q '^vnstat\.service'; then
        systemctl disable --now vnstat >/dev/null 2>&1
    fi
    if [ -f /etc/debian_version ]; then
        apt-get remove -y vnstat >/dev/null 2>&1
    elif [ -f /etc/redhat-release ]; then
        yum remove -y vnstat >/dev/null 2>&1
    fi
    echo -e "\n${GREEN}卸载完成！脚本将自动退出。${PLAIN}\n"
    rm -f "$SCRIPT_PATH"
    exit 0
}

menu() {
    while true; do
        load_config
        echo -e ""
        echo -e "${GREEN}========== 流量限额脚本 quota.sh ==========${PLAIN}"
        echo -e ""
        echo -e " 配置文件: ${BLUE}${CONFIG_FILE}${PLAIN}"
        echo -e ""
        echo -e "${GREEN}===========================================${PLAIN}"
        echo -e ""
        echo -e "${YELLOW} ------- 基本操作 -------${PLAIN}"
        echo -e ""
        echo -e " 1. 查看当前流量使用"
        echo -e ""
        echo -e " 2. 初始化/修改配置"
        echo -e ""
        echo -e " 3. 启动监控"
        echo -e ""
        echo -e " 4. 停止监控"
        echo -e ""
        echo -e " 5. 查看监控"
        echo -e ""
        echo -e "${YELLOW} ------- 端口操作 -------${PLAIN}"
        echo -e ""
        echo -e " 6. 立即封禁所有转发端口"
        echo -e ""
        echo -e " 7. 解除封禁所有转发端口"
        echo -e ""
        echo -e " 8. 卸载脚本"
        echo -e ""
        echo -e " 0. 退出"
        echo -e ""
        read -p "请输入选项[0-8]: " num
        case "$num" in
            1) echo -e ""; show_usage ;;
            2) setup_wizard ;;
            3) ensure_monitor_timer; echo -e "\n${GREEN}监控已启动${PLAIN}\n"; read -n 1 -s -r -p "按任意键返回..."; echo -e "";;
            4) stop_monitor_timer; echo -e "\n${YELLOW}监控已停止${PLAIN}\n"; read -n 1 -s -r -p "按任意键返回..."; echo -e "";;
            5) show_monitor_status ;;
            6) block_ports manual; echo -e "\n${GREEN}已封禁所有转发端口 (手动)${PLAIN}\n"; read -n 1 -s -r -p "按任意键返回..."; echo -e "";;
            7) unblock_ports all; echo -e "\n${GREEN}已解除封禁所有转发端口${PLAIN}\n"; read -n 1 -s -r -p "按任意键返回..."; echo -e "";;
            8) uninstall_all ;;
            0) echo -e ""; exit 0 ;;
            *) echo -e "\n${RED}请输入正确的数字！${PLAIN}\n"; read -p "按回车键继续..." ;;
        esac
    done
}

if [[ "$1" == "monitor" ]]; then
    init_dirs
    load_config
    if [[ -z "$MODE" || -z "$QUOTA_GB" || -z "$RESET_DAY" || -z "$IFACE" ]]; then exit 0; fi
    ensure_vnstat_iface "$IFACE"
    bytes=$(get_usage_bytes "$MODE" "$IFACE" "$RESET_DAY")
    limit_bytes=$((QUOTA_GB * 1024 * 1024 * 1024))
    # 优先级: 手动封禁 > 自动封禁 > 未超限解除自动封禁
    if [[ -f "$TRAFFIC_DIR/manual_block_all.conf" ]]; then
        # 手动封禁生效，维持封禁状态（刷新规则）
        block_ports manual
    elif [[ ${bytes:-0} -ge $limit_bytes ]]; then
        block_ports auto
    else
        # 未超限：只解除 auto 封禁，manual 封禁由用户在菜单里自己解
        unblock_ports auto
    fi
    exit 0
fi

if [[ "$1" == "reset_exec" ]]; then
    init_dirs
    load_config
    if [[ -z "$MODE" || -z "$QUOTA_GB" || -z "$RESET_DAY" || -z "$IFACE" ]]; then
        echo -e "\n${RED}重置失败：未检测到配置。${PLAIN}\n"
        exit 1
    fi
    ensure_vnstat_iface "$IFACE"
    DB_DIR=$(awk -F'"' '/DatabaseDir/ {print $2}' /etc/vnstat.conf 2>/dev/null)
    if [[ -z "$DB_DIR" ]]; then DB_DIR="/var/lib/vnstat"; fi
    systemctl stop vnstat >/dev/null 2>&1
    if [ -f "$DB_DIR/vnstat.db" ]; then
        if vnstat --longhelp 2>/dev/null | grep -q -- '--remove'; then
            vnstat --remove -i "$IFACE" --force >/dev/null 2>&1
        else
            rm -f "$DB_DIR/vnstat.db"
        fi
    else
        rm -f "$DB_DIR/$IFACE" "$DB_DIR/$IFACE.db"
    fi
    vnstat --add -i "$IFACE" >/dev/null 2>&1 || vnstat --create -i "$IFACE" >/dev/null 2>&1
    systemctl start vnstat >/dev/null 2>&1
    if vnstat --json -i "$IFACE" >/dev/null 2>&1; then
        # 每月重置：把自动封禁解除；但尊重手动封禁 (manual_block_all.conf 保留)
        unblock_ports auto
        date +%Y-%m-%d > "$STATE_FILE"
        echo -e "\n${GREEN}重置完成：流量统计已清零，自动封禁已解除（手动封禁保持不变）。${PLAIN}\n"
        exit 0
    else
        echo -e "\n${RED}重置失败：vnstat 初始化失败。${PLAIN}\n"
        exit 1
    fi
fi

check_root
init_dirs
install_vnstat_if_needed
ensure_vnstat_interval
set_quota_shortcut

if [ ! -f "$CONFIG_FILE" ]; then
    setup_wizard
else
    load_config
    ensure_reset_timer
fi

menu
