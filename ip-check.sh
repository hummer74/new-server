#!/bin/bash
set -euo pipefail

# === Конфигурация ===
LOG_FILE="/root/ip-check.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Цвета для вывода (опционально)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# === Функции ===
log() {
    echo -e "$@"
}

# Определение основного интерфейса
get_main_iface() {
    local iface
    iface=$(ip -o link show | grep -v lo | grep "state UP" | head -1 | awk -F': ' '{print $2}')
    if [ -z "$iface" ]; then
        log "${RED}ERROR: No active network interface found.${NC}"
        exit 1
    fi
    echo "$iface"
}

# Проверка глобального отключения IPv6
check_ipv6_globally_disabled() {
    local disabled=0
    local reasons=()

    # Проверка GRUB
    if [ -f /proc/cmdline ] && grep -q "ipv6.disable=1" /proc/cmdline; then
        disabled=1
        reasons+=("GRUB: ipv6.disable=1 in kernel command line")
    fi

    # Проверка sysctl
    if sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "1"; then
        disabled=1
        reasons+=("sysctl: net.ipv6.conf.all.disable_ipv6 = 1")
    fi

    # Проверка blacklist модуля
    if grep -rq "blacklist[[:space:]]\+ipv6" /etc/modprobe.d/ 2>/dev/null; then
        disabled=1
        reasons+=("modprobe: blacklist ipv6 found in /etc/modprobe.d/")
    fi

    echo "$disabled"
    if [ $disabled -eq 1 ]; then
        for r in "${reasons[@]}"; do
            echo "  - $r"
        done
    fi
}

# === Начало скрипта ===
log "${CYAN}===== IPv4/IPv6 Check started at $(date) =====${NC}\n"

MAIN_IFACE=$(get_main_iface)
log "Detected main interface: ${GREEN}$MAIN_IFACE${NC}\n"

# ======================== БЛОК: ГЛОБАЛЬНЫЙ СТАТУС IPv6 ========================
log "${CYAN}========== IPv6 GLOBAL STATUS ==========${NC}"
DISABLED_REASONS=$(check_ipv6_globally_disabled)
if [ -z "$DISABLED_REASONS" ]; then
    log "${GREEN}IPv6 is globally ENABLED (no disabling flags found).${NC}"
else
    log "${RED}IPv6 is globally DISABLED. Reasons:${NC}"
    echo "$DISABLED_REASONS"
fi
log ""

# ======================== БЛОК: IPv4 ========================
log "${CYAN}========== IPv4 INFORMATION ==========${NC}"

# Адреса
log "--- IPv4 addresses on all interfaces ---"
ip -4 addr show | tee -a /dev/null
log ""

# Глобальный адрес на основном интерфейсе
GLOBAL_IPV4=$(ip -4 addr show dev "$MAIN_IFACE" scope global | grep inet | awk '{print $2}' | head -1)
if [ -n "$GLOBAL_IPV4" ]; then
    log "Global IPv4 address on $MAIN_IFACE: ${GREEN}$GLOBAL_IPV4${NC}"
else
    log "${YELLOW}WARNING: No global IPv4 address assigned to $MAIN_IFACE${NC}"
fi
log ""

# Маршрут по умолчанию
log "--- Default IPv4 route ---"
DEFAULT_V4=$(ip -4 route show default)
if [ -n "$DEFAULT_V4" ]; then
    log "$DEFAULT_V4"
else
    log "${YELLOW}WARNING: No default IPv4 route found${NC}"
fi
log ""

# Пинг до 8.8.8.8
log "--- IPv4 ping test to 8.8.8.8 ---"
if ping -4 -c 4 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log "${GREEN}IPv4 ping OK${NC}"
else
    log "${RED}IPv4 ping FAILED${NC}"
fi
log ""

# Исходящий IPv4 через curl
log "--- Outgoing IPv4 check (curl -4 ifconfig.co) ---"
if command -v curl >/dev/null; then
    CURL_V4_OUT=$(curl -4 --max-time 10 -s ifconfig.co 2>/dev/null || echo "FAILED")
    log "curl -4 returned: $CURL_V4_OUT"
else
    log "${YELLOW}curl not installed, skipping${NC}"
fi
log ""

# Слушающие порты (22, 24940, 8443)
log "--- Listening services on IPv4 (common ports) ---"
ss -4tuln | grep -E ":(22|24940|8443) " | tee -a /dev/null || log "No IPv4 listeners on common ports"
log ""

# Параметры sysctl IPv4
log "--- IPv4 sysctl settings ---"
sysctl net.ipv4.ip_forward 2>/dev/null | tee -a /dev/null
sysctl net.ipv4.icmp_echo_ignore_all 2>/dev/null | tee -a /dev/null
sysctl net.ipv4.tcp_syncookies 2>/dev/null | tee -a /dev/null
log ""

# Правила маршрутизации IPv4
log "--- IPv4 policy routing rules ---"
ip rule show | tee -a /dev/null
log ""

# ======================== БЛОК: IPv6 (только если глобально включён) ========================
if [ -z "$DISABLED_REASONS" ]; then
    log "${CYAN}========== IPv6 INFORMATION ==========${NC}"

    # Адреса
    log "--- IPv6 addresses on all interfaces ---"
    ip -6 addr show | tee -a /dev/null
    log ""

    # Глобальный адрес на основном интерфейсе
    GLOBAL_IPV6=$(ip -6 addr show dev "$MAIN_IFACE" scope global | grep inet6 | awk '{print $2}' | head -1)
    if [ -n "$GLOBAL_IPV6" ]; then
        log "Global IPv6 address on $MAIN_IFACE: ${GREEN}$GLOBAL_IPV6${NC}"
    else
        log "${YELLOW}WARNING: No global IPv6 address assigned to $MAIN_IFACE${NC}"
    fi
    log ""

    # Маршрут по умолчанию IPv6
    log "--- Default IPv6 route ---"
    DEFAULT_V6=$(ip -6 route show default)
    if [ -n "$DEFAULT_V6" ]; then
        log "$DEFAULT_V6"
    else
        log "${YELLOW}WARNING: No default IPv6 route found${NC}"
    fi
    log ""

    # Пинг до IPv6 DNS (если есть глобальный адрес и маршрут)
    if [ -n "$GLOBAL_IPV6" ] && [ -n "$DEFAULT_V6" ]; then
        log "--- IPv6 ping test to 2001:4860:4860::8888 ---"
        if ping -6 -c 4 -W 2 2001:4860:4860::8888 >/dev/null 2>&1; then
            log "${GREEN}IPv6 ping OK${NC}"
        else
            log "${RED}IPv6 ping FAILED${NC}"
        fi
        log ""

        # Исходящий IPv6 через curl
        log "--- Outgoing IPv6 check (curl -6 ifconfig.co) ---"
        if command -v curl >/dev/null; then
            CURL_V6_OUT=$(curl -6 --max-time 10 -s ifconfig.co 2>/dev/null || echo "FAILED")
            log "curl -6 returned: $CURL_V6_OUT"
        else
            log "${YELLOW}curl not installed, skipping${NC}"
        fi
        log ""
    else
        log "${YELLOW}IPv6 has no global address or default route, skipping ping and curl tests${NC}\n"
    fi

    # Слушающие порты IPv6
    log "--- Listening services on IPv6 (common ports) ---"
    ss -6tuln | grep -E ":(22|24940|8443) " | tee -a /dev/null || log "No IPv6 listeners on common ports"
    log ""

    # Параметры sysctl IPv6 на основном интерфейсе
    log "--- IPv6 sysctl settings on $MAIN_IFACE ---"
    sysctl net.ipv6.conf."$MAIN_IFACE".disable_ipv6 2>/dev/null | tee -a /dev/null
    sysctl net.ipv6.conf."$MAIN_IFACE".accept_ra 2>/dev/null | tee -a /dev/null
    sysctl net.ipv6.conf.all.forwarding 2>/dev/null | tee -a /dev/null
    log ""

    # Правила политической маршрутизации IPv6
    log "--- IPv6 policy routing rules ---"
    ip -6 rule show | tee -a /dev/null
    log ""

    # ======================== БЛОК: Политическая маршрутизация для "выход IPv6" ========================
    log "${CYAN}========== IPv6 OUTBOUND ROUTING (ip6out) ==========${NC}"

    # Проверка таблицы 100
    if ip route show table 100 | grep -q "default via"; then
        log "${GREEN}Table 100 has default route via IPv6:${NC}"
        ip route show table 100 | grep "default" | tee -a /dev/null
    else
        log "${YELLOW}Table 100 does not contain a default IPv6 route.${NC}"
    fi

    # Проверка правила fwmark
    if ip rule show | grep -q "fwmark 0x1.*lookup 100"; then
        log "${GREEN}Rule fwmark 1 table 100 exists:${NC}"
        ip rule show | grep "fwmark 0x1" | tee -a /dev/null
    else
        log "${YELLOW}Rule fwmark 1 table 100 not found.${NC}"
    fi

    # Проверка nftables
    if command -v nft >/dev/null; then
        if nft list table inet ip6out 2>/dev/null | grep -q "ct state new meta mark set 1"; then
            log "${GREEN}nftables rule for marking new connections exists.${NC}"
        else
            log "${YELLOW}nftables table 'ip6out' not found or missing mark rule.${NC}"
        fi
    else
        log "${YELLOW}nftables not installed.${NC}"
    fi
    log ""
else
    log "${YELLOW}IPv6 is globally disabled. Skipping IPv6 tests.${NC}\n"
fi

# ======================== БЛОК: Общие проверки ========================
log "${CYAN}========== GENERAL TESTS ==========${NC}"

# Предпочтение протокола (curl без флагов)
if command -v curl >/dev/null; then
    log "--- Default protocol preference (curl ifconfig.co) ---"
    CURL_DEFAULT=$(curl --max-time 10 -s ifconfig.co 2>/dev/null || echo "FAILED")
    log "curl default returned: $CURL_DEFAULT"
    if [[ "$CURL_DEFAULT" == *":"* ]]; then
        log "System prefers IPv6 (or IPv6 address shown)"
    elif [[ "$CURL_DEFAULT" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "System prefers IPv4 (or IPv6 not available)"
    else
        log "Could not determine protocol preference"
    fi
    log ""
fi

# Статус UFW
if command -v ufw >/dev/null; then
    log "--- UFW status (IPv4 and IPv6 rules) ---"
    ufw status verbose | tee -a /dev/null || log "UFW not active"
else
    log "--- UFW not installed ---"
fi
log ""

# IPv6-only тест
if [ -z "$DISABLED_REASONS" ] && command -v curl >/dev/null; then
    log "--- External IPv6-only test (ip6only.me) ---"
    CURL_V6_ONLY=$(curl -6 --max-time 10 -s ip6only.me/api/ 2>/dev/null || echo "FAILED")
    log "IPv6-only test result: $CURL_V6_ONLY"
    log ""
fi

# IPv4-only тест
if command -v curl >/dev/null; then
    log "--- External IPv4-only test (ipv4.icanhazip.com) ---"
    CURL_V4_ONLY=$(curl -4 --max-time 10 -s ipv4.icanhazip.com 2>/dev/null || echo "FAILED")
    log "IPv4-only test result: $CURL_V4_ONLY"
    log ""
fi

# ======================== ФИНАЛЬНАЯ СВОДКА ========================
log "${CYAN}========== SUMMARY ==========${NC}"
log "Main interface: $MAIN_IFACE"
log "IPv4 address: ${GLOBAL_IPV4:-none}"
if [ -z "$DISABLED_REASONS" ]; then
    log "IPv6 address: ${GLOBAL_IPV6:-none}"
    log "Default IPv4 route: ${DEFAULT_V4:-none}"
    log "Default IPv6 route: ${DEFAULT_V6:-none}"
else
    log "IPv6: globally disabled"
fi
log "IPv4 ping: $(ping -4 -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && echo OK || echo FAILED)"
if [ -z "$DISABLED_REASONS" ] && [ -n "$GLOBAL_IPV6" ] && [ -n "$DEFAULT_V6" ]; then
    log "IPv6 ping: $(ping -6 -c 1 -W 1 2001:4860:4860::8888 >/dev/null 2>&1 && echo OK || echo FAILED)"
else
    log "IPv6 ping: N/A (disabled or not configured)"
fi
log ""

log "${CYAN}===== IPv4/IPv6 Check finished at $(date) =====${NC}"
log "Log saved to $LOG_FILE"