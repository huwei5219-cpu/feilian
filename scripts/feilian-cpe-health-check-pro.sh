#!/bin/bash
#===============================================================================
# 名称: 飞连 CPE 全面健康巡检脚本 (Professional Edition)
# 版本: 4.2 - 模块化巡检版
# 作者: FeiLian SD-WAN CPE 巡检工具维护者
# 维护: CPE 运维/交付/故障排查场景持续沉淀
# 兼容: Debian/Ubuntu/CentOS/RHEL/Rocky Linux/Alpine 等常见 Linux 发行版
# 用途: 在无 AI Skills 环境下，通过 Shell 自动采集、判断并展示 CPE 健康状态
#
# 设计原则:
#   - 巡检项标准化展示: 检查项/检查要求/使用命令/回显结果/巡检结果/优化建议
#   - 命令只负责真实采集信息，判断逻辑由脚本内部完成，避免静态结果伪装命令
#   - 默认实时输出到终端，不自动生成文件；需要留档时显式指定 --output
#   - 官方健康检查已覆盖且成功的重复项默认跳过；使用 --full/-f 可强制展示全部项
#   - 每个巡检项对应一个 check_* 函数，新增或调整巡检项时在 run_all_checks 中编排
#
# 检查范围:
#   - Linux 基础信息、系统性能、时间同步、防火墙组件、sysctl 关键参数
#   - CPE 版本信息、关键服务状态、事件 ERROR 日志、Panic 崩溃日志
#   - 官方 CPE 网络健康检查、默认网关、DNS 解析、连接管理后台及 GRPC 连通性
#   - 中心 DNS UDP 端口探测、POP 主备链路、主备隧道、WireGuard 握手状态
#
# 使用方法:
#   chmod +x feilian-cpe-health-check-pro.sh
#   ./feilian-cpe-health-check-pro.sh [选项]
#
# 选项:
#   --no-color      禁用终端颜色输出，便于重定向或复制
#   --json, -j      输出JSON摘要；与--output搭配时保存JSON文件
#   --output FILE   保存完整文本报告或JSON报告到指定文件；默认不生成文件
#   --quiet, -q     静默模式(减少输出)
#   --full, -f      展示全部巡检项，不跳过官方健康检查已成功覆盖的重复项
#   --help, -h      显示帮助信息
#
# 输出格式:
#   终端: V4.x 标准文本格式，实时显示巡检过程，支持彩色结果高亮
#   文件: 默认不生成；指定 --output 后保存去除 ANSI 颜色码的完整文本报告或 JSON 摘要
#   退出码: 0=全部通过，1=存在失败项，2=存在警告项，127=参数或脚本执行错误
#===============================================================================

# 使用宽松的错误处理模式（避免因小错误导致整个脚本退出）
set -uo pipefail
# 注意：不使用 set -e，因为某些命令可能返回非零但非致命错误

#===============================================================================
# 全局配置
#===============================================================================
SCRIPT_VERSION="4.2"
SCRIPT_NAME="飞连CPE健康巡检"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S' || echo "unknown")
REPORT_DATE=$(date '+%Y%m%d_%H%M%S' || echo "unknown")
HOSTNAME=$(hostname || echo "unknown")
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "0.0.0.0")

# 输出控制
OUTPUT_TERMINAL=true
OUTPUT_JSON=false
OUTPUT_FILE=""
QUIET_MODE=false
FULL_MODE=false
INSPECTION_MODE=""
IP_PUBLISH_TARGET_IP=""
IP_PUBLISH_IFACE="tun0_master"
DOMAIN_SCHEDULE_DOMAIN=""

# 统计变量
TOTAL_CHECKS=0
PASSED_CHECKS=0
WARNING_CHECKS=0
FAILED_CHECKS=0
ERROR_LOG=()

NO_COLOR=false

configure_output_mode() {
    # 参数解析后统一刷新输出行为，避免 --quiet/--json/--no-color 与初始颜色状态不一致。
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        OUTPUT_TERMINAL=false
    fi

    if [[ -t 1 && "$NO_COLOR" != "true" && "$OUTPUT_TERMINAL" == "true" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        BLUE='\033[0;34m'
        PURPLE='\033[0;35m'
        CYAN='\033[0;36m'
        WHITE='\033[0;37m'
        BOLD='\033[1m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        PURPLE=''
        CYAN=''
        WHITE=''
        BOLD=''
        NC=''
    fi
}

configure_output_mode

#===============================================================================
# 工具函数 (V4.0 简洁无乱码版)
#===============================================================================

print_section() {
    if [[ "$OUTPUT_TERMINAL" == "true" && "$QUIET_MODE" != "true" ]]; then
        echo ""
        echo -e "${CYAN}■ $1${NC}"
    fi
}

string_display_width() {
    # 中文标题按终端显示宽度估算，保证巡检项分隔线整体更整齐。
    local text="${1:-}"
    local chars bytes wide_chars
    chars=${#text}
    bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
    if [[ "$bytes" =~ ^[0-9]+$ && "$chars" -gt 0 && "$bytes" -gt "$chars" ]]; then
        wide_chars=$(( (bytes - chars) / 2 ))
        echo $((chars + wide_chars))
    else
        echo "$chars"
    fi
}

print_check() {
    local check_name="$1"
    local cmd="$2"
    local requirement="${3:-}"
    local suggestion="${4:-}"
    local extra_info="${5:-}"   # 新增：附加信息（显示在【巡检结果】行尾）
    local forced_exit_code="${6:-}" # 可选：脚本内部判断结果覆盖命令退出码
    local precomputed_output="${7:-}" # 可选：复用脚本内部已采集的输出，避免命令重复执行
    local output
    local exit_code
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1)) || true

    # 无论是否打印终端详情，都必须执行采集和统计，保证 --json 模式结果真实有效。
    if [[ $# -ge 7 ]]; then
        output="$precomputed_output"
        exit_code=0
    else
        output=$(eval "$cmd" 2>&1)
        exit_code=$?
    fi
    if [[ -n "$forced_exit_code" ]]; then
        exit_code="$forced_exit_code"
    fi
    if [[ $exit_code -eq 0 ]]; then
        PASSED_CHECKS=$((PASSED_CHECKS + 1)) || true
    elif [[ $exit_code -eq 2 ]]; then
        WARNING_CHECKS=$((WARNING_CHECKS + 1)) || true
        ERROR_LOG+=("WARNING|$check_name|${extra_info:-Warning code: $exit_code}")
    else
        FAILED_CHECKS=$((FAILED_CHECKS + 1)) || true
        ERROR_LOG+=("FAILED|$check_name|Exit code: $exit_code")
    fi
    
    if [[ "$OUTPUT_TERMINAL" == "true" && "$QUIET_MODE" != "true" ]]; then
        echo ""
        
        # 左侧分隔线固定，右侧按标题显示宽度补齐，保证总长度一致且更美观。
        local name_width
        local total_width=86
        local left_dash_count=28
        local prefix_width=3
        local label_width=9
        local right_dash_count
        name_width=$(string_display_width "$check_name")
        right_dash_count=$((total_width - prefix_width - left_dash_count - label_width - name_width))
        if [[ "$right_dash_count" -lt 8 ]]; then
            right_dash_count=8
        fi
        local left_dashes=$(printf '%*s' "$left_dash_count" | tr ' ' '-')
        local right_dashes=$(printf '%*s' "$right_dash_count" | tr ' ' '-')
        
        # V4.1标准格式：◆ + 分隔线 + 检查项名称 + 分隔线（无左右空格）
        echo -e "${WHITE}◆ ${left_dashes} 检查项: ${check_name}${right_dashes}${NC}"

        # 中文括号标签
        if [[ -n "$requirement" ]]; then
            echo -e "${WHITE}【检查要求】${NC}: ${requirement}"
        fi

        printf "%b%s%b\n" "${WHITE}【使用命令】${NC}: ${CYAN}" "$cmd" "$NC"

        echo -e "${WHITE}【回显结果】${NC}:"
        while IFS= read -r line; do
            echo -e "     | ${CYAN}${line}${NC}"
        done <<< "$output"

        # 状态显示：✅通过 / ❌不通过 + 判断原因
        if [[ $exit_code -eq 0 ]]; then
            if [[ -n "$extra_info" ]]; then
                echo -e "${WHITE}【巡检结果】${NC}: ${exit_code}，${GREEN}✅ 通过${NC}，${extra_info}"
            else
                echo -e "${WHITE}【巡检结果】${NC}: ${exit_code}，${GREEN}✅ 通过${NC}，◆ 判断原因: 命令执行成功，符合检查要求"
            fi
        elif [[ $exit_code -eq 2 ]]; then
            if [[ -n "$extra_info" ]]; then
                echo -e "${WHITE}【巡检结果】${NC}: ${exit_code}，${YELLOW}⚠️ 警告${NC}，${extra_info}"
            else
                echo -e "${WHITE}【巡检结果】${NC}: ${exit_code}，${YELLOW}⚠️ 警告${NC}，◆ 判断原因: 命令执行成功，但存在需关注风险"
            fi
            if [[ -n "$suggestion" ]]; then
                echo -e "${YELLOW}【优化建议】${NC}: ${YELLOW}${suggestion}${NC}"
            fi
        else
            if [[ -n "$extra_info" ]]; then
                echo -e "${WHITE}【巡检结果】${NC}: ${exit_code}，${RED}❌ 不通过${NC}，${extra_info}"
            else
                echo -e "${WHITE}【巡检结果】${NC}: ${exit_code}，${RED}❌ 不通过${NC}，◆ 判断原因: 命令执行失败，退出码=${exit_code}"
            fi

            # 仅失败时显示建议
            if [[ -n "$suggestion" ]]; then
                echo -e "${YELLOW}【优化建议】${NC}: ${YELLOW}${suggestion}${NC}"
            fi
        fi
    fi
}

compare_float_gt() {
    awk -v left="$1" -v right="$2" 'BEGIN { exit !(left > right) }'
}

compare_float_lt() {
    awk -v left="$1" -v right="$2" 'BEGIN { exit !(left < right) }'
}

version_ge() {
    local current="$1"
    local required="$2"
    [[ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1)" == "$required" ]]
}

should_show_detail_check() {
    # 默认跳过官方健康检查已覆盖且成功的重复项；--full/-f 强制展示。
    local upstream_ok="${1:-false}"
    [[ "$FULL_MODE" == "true" || "$upstream_ok" != "true" ]]
}

get_default_wan_dev() {
    # 外网探测固定优先走真实默认出口，避免被 tun/docker/容器网桥等虚拟接口劫持。
    ip -o route show default 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    dev = $(i + 1)
                    if (dev !~ /^(tun|docker|br-|veth|virbr|flannel|cni|wg)/) {
                        print dev
                        exit
                    }
                }
            }
        }
    '
}

print_mode_banner() {
    local title="$1"
    local label="$2"
    local value="$3"
    local iface="${4:-}"

    [[ "$OUTPUT_TERMINAL" == "true" ]] || return 0
    echo -e "${BOLD}${WHITE}>>> ${title} v${SCRIPT_VERSION}${NC}"
    [[ -n "$label" ]] && echo -e "${WHITE}  ${label}: ${CYAN}${value}${NC}"
    [[ -n "$iface" ]] && echo -e "${WHITE}  调度接口: ${CYAN}${iface}${NC}"
    echo -e "${WHITE}  时间: ${CYAN}${TIMESTAMP}${NC}"
}

extract_route_dev_from_output() {
    awk '/^[0-9]/ {for(i=1;i<=NF;i++){if($i=="dev" && (i+1)<=NF){print $(i+1); exit}}}'
}

extract_route_table_from_output() {
    awk '/^[0-9]/ {for(i=1;i<=NF;i++){if($i=="table" && (i+1)<=NF){print $(i+1); exit}}}'
}

normalize_domain_input() {
    # 允许用户粘贴 URL，统一提取 host，避免命令行与交互输入出现两套处理逻辑。
    local input="${1:-}"
    input="${input#http://}"
    input="${input#https://}"
    input="${input%%/*}"
    input="${input%%:*}"
    printf '%s\n' "$input"
}

run_native_cpe_health_check_step() {
    local check_name="$1"
    local pass_context="$2"
    local suggestion="$3"
    local cmd output extra code
    local native_health_code checked_output failed_output total failed_count failed_one
    local wan_dev wan_label

    wan_dev=$(get_default_wan_dev)
    wan_label="${wan_dev:-未指定(未找到非tun默认路由)}"
    cmd="printf '%s\n' \"默认出接口: ${wan_label}\"; /opt/feilian/cpe/bin/feilian-cpe-health-check 2>&1"
    output=$(printf '%s\n' "默认出接口: ${wan_label}"; /opt/feilian/cpe/bin/feilian-cpe-health-check 2>&1)
    native_health_code=$?

    # 原生命令中的“探测网关”只作为展示信息，避免和脚本自身路由判断重复计失败。
    checked_output=$(printf '%s\n' "$output" | grep -vE '探测网关|^默认出接口:')
    failed_output=$(printf '%s\n' "$checked_output" | awk 'NF && $0 !~ /成功/ {print}')
    total=$(printf '%s\n' "$checked_output" | awk 'NF {count++} END {print count+0}')

    if [[ "$native_health_code" -ne 0 ]]; then
        extra="${RED}◆ 判断原因: 原生CPE健康检查执行失败，退出码=${native_health_code}${NC}"
        code=1
    elif [[ -z "$failed_output" ]]; then
        extra="${GREEN}◆ 判断原因: 原生CPE健康检查均显示成功，共${total}项，具备继续排查${pass_context}前提${NC}"
        code=0
    else
        failed_count=$(printf '%s\n' "$failed_output" | awk 'NF {count++} END {print count+0}')
        failed_one=$(printf '%s\n' "$failed_output" | head -1)
        extra="${RED}◆ 判断原因: 原生CPE健康检查发现${failed_count}项非成功结果，首个异常: ${failed_one}${NC}"
        code=1
    fi

    print_check "$check_name" "$cmd" "原生CPE健康检查应正常执行，网络/隧道相关检查项均需显示成功；探测网关仅展示，不参与通过/失败判断" "$suggestion" "$extra" "$code" "$output"
    return "$code"
}

collect_dispatch_match_analysis() {
    local target_ip="$1"
    local iface="$2"
    local line saas_ip saas_action saas_forward
    local rule_net rule_mask rule_forward
    local priority_file="/opt/feilian/cpe/conf/dispatch_priority.json"

    DISPATCH_RAW=$(feilian-tun-ctrl show -i "$iface" dispatch 2>&1 || true)
    DISPATCH_PRIORITY=$(printf '%s\n' "$DISPATCH_RAW" | sed -nE 's/.*priority: ([A-Za-z]+).*/\1/p' | head -n 1)
    DISPATCH_PRIORITY_CONF_VALUE=$(sed -nE 's/.*"dispatch_priority"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$priority_file" 2>/dev/null | head -n 1)
    case "$DISPATCH_PRIORITY_CONF_VALUE" in
        1)
            DISPATCH_PRIORITY_CONF_LABEL="DispatchSaas"
            DISPATCH_PRIORITY_CONF_DESC="1代表DispatchSaas域名调度优先"
            ;;
        0)
            DISPATCH_PRIORITY_CONF_LABEL="DispatchIP"
            DISPATCH_PRIORITY_CONF_DESC="0代表IP调度优先"
            ;;
        "")
            DISPATCH_PRIORITY_CONF_LABEL="未获取"
            DISPATCH_PRIORITY_CONF_DESC="未读取到dispatch_priority配置"
            ;;
        *)
            DISPATCH_PRIORITY_CONF_LABEL="未知(${DISPATCH_PRIORITY_CONF_VALUE})"
            DISPATCH_PRIORITY_CONF_DESC="未知dispatch_priority配置值: ${DISPATCH_PRIORITY_CONF_VALUE}"
            ;;
    esac
    if [[ -z "$DISPATCH_PRIORITY" && "$DISPATCH_PRIORITY_CONF_LABEL" != "未获取" ]]; then
        DISPATCH_PRIORITY="$DISPATCH_PRIORITY_CONF_LABEL"
    fi
    if [[ -n "$DISPATCH_PRIORITY" && "$DISPATCH_PRIORITY_CONF_LABEL" != "未获取" && "$DISPATCH_PRIORITY_CONF_LABEL" != 未知* ]]; then
        if [[ "$DISPATCH_PRIORITY" == "$DISPATCH_PRIORITY_CONF_LABEL" ]]; then
            DISPATCH_PRIORITY_CONSISTENCY="一致"
        else
            DISPATCH_PRIORITY_CONSISTENCY="不一致，运行态=${DISPATCH_PRIORITY}，配置=${DISPATCH_PRIORITY_CONF_LABEL}"
        fi
    else
        DISPATCH_PRIORITY_CONSISTENCY="无法比对"
    fi
    IP_MATCH_RULES=""
    SAAS_MATCH_RULES=""
    EXPECTED_DOWNSTREAM_IP=""
    MATCH_TYPE="未命中"

    # IP调度通常以网段+mask呈现；这里统一转换成可读 CIDR 命中列表。
    while IFS= read -r line; do
        if [[ "$line" =~ ip[[:space:]]addr:([0-9.]+),[[:space:]]mask:([0-9]+).*action_option:[[:space:]]([0-9.]+) ]]; then
            rule_net="${BASH_REMATCH[1]}"
            rule_mask="${BASH_REMATCH[2]}"
            rule_forward="${BASH_REMATCH[3]}"
            if ipv4_in_cidr "$target_ip" "$rule_net" "$rule_mask"; then
                IP_MATCH_RULES+="${rule_net}/${rule_mask} -> ${rule_forward}"$'\n'
                EXPECTED_DOWNSTREAM_IP="${EXPECTED_DOWNSTREAM_IP:-${rule_forward}}"
            fi
        fi
    done <<< "$DISPATCH_RAW"

    # 域名调度落到 dispatch 后是单 IP saas policy，IP排查和域名排查共用同一解析逻辑。
    while read -r saas_ip saas_action saas_forward; do
        [[ -n "$saas_ip" ]] || continue
        if [[ "$target_ip" == "$saas_ip" ]]; then
            SAAS_MATCH_RULES+="${saas_ip} ${saas_action} -> ${saas_forward}"$'\n'
            EXPECTED_DOWNSTREAM_IP="${EXPECTED_DOWNSTREAM_IP:-${saas_forward}}"
        fi
    done < <(printf '%s\n' "$DISPATCH_RAW" \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}: DispatchAction \{ action: [A-Za-z]+, action_option: ([0-9]{1,3}\.){3}[0-9]{1,3}' \
        | sed -E 's/: DispatchAction \{ action: / /; s/, action_option: / /' \
        | sort -u)

    if [[ -n "$IP_MATCH_RULES" && -n "$SAAS_MATCH_RULES" ]]; then
        MATCH_TYPE="同时命中IP调度和域名调度"
    elif [[ -n "$IP_MATCH_RULES" ]]; then
        MATCH_TYPE="命中IP调度"
    elif [[ -n "$SAAS_MATCH_RULES" ]]; then
        MATCH_TYPE="命中域名调度"
    fi
}

format_dispatch_analysis_block() {
    local title="$1"
    local target_label="$2"
    local target_value="$3"
    local target_ip="$4"
    local iface="$5"
    local result_summary="$6"
    local route_dev="${7:-}"
    local route_table="${8:-}"

    {
        echo "【${title}】"
        echo "  ${target_label}: ${target_value}"
        [[ -n "$target_ip" && "$target_ip" != "$target_value" ]] && echo "  首个解析IP: ${target_ip}"
        [[ -n "$route_dev" ]] && echo "  路由出接口: ${route_dev}"
        [[ -n "$route_table" ]] && echo "  路由表: ${route_table}"
        echo "  调度接口: ${iface}"
        echo "  默认调度优先级: ${DISPATCH_PRIORITY:-未获取}"
        echo "  优先级配置: dispatch_priority=${DISPATCH_PRIORITY_CONF_VALUE:-未获取} (${DISPATCH_PRIORITY_CONF_DESC:-未获取})"
        echo "  优先级一致性: ${DISPATCH_PRIORITY_CONSISTENCY:-无法比对}"
        echo "  IP调度命中:"
        if [[ -n "$IP_MATCH_RULES" ]]; then
            printf '%s' "$IP_MATCH_RULES" | sed 's/^/    /'
        else
            echo "      未命中"
        fi
        echo "  域名调度命中:"
        if [[ -n "$SAAS_MATCH_RULES" ]]; then
            printf '%s' "$SAAS_MATCH_RULES" | sed 's/^/    /'
        else
            echo "      未命中"
        fi
        echo "  【结果】${result_summary}"
    }
}

run_dig_short_a() {
    local domain="$1"
    shift
    if ! command -v dig >/dev/null 2>&1; then
        echo "dig命令不存在，无法执行DNS解析验证"
        return 127
    fi
    dig "$@" +time=3 +tries=1 +short A "$domain" @127.0.0.1 2>&1
}

get_route_dev_for_target() {
    local target="${1:-}"
    [[ -n "$target" ]] || return 0
    ip route get "$target" 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

json_escape() {
    # 生成JSON摘要时对字符串做基础转义，避免日志内容中的引号破坏JSON结构。
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

normalize_output_file_path() {
    # 输出文件统一转为绝对路径，避免交互输入相对路径时生成位置不明确或提示不直观。
    local raw_path="${1:-}"
    local clean_path
    clean_path=$(printf '%s' "$raw_path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/　//g')
    if command -v iconv >/dev/null 2>&1; then
        clean_path=$(printf '%s' "$clean_path" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || printf '%s' "$clean_path")
    fi

    if [[ -z "$clean_path" ]]; then
        return 1
    fi

    case "$clean_path" in
        /*)
            printf '%s\n' "$clean_path"
            ;;
        *)
            printf '%s/%s\n' "$(pwd -P)" "$clean_path"
            ;;
    esac
}

ensure_output_parent_dir() {
    # 允许用户指定不存在的报告目录，提升在不同Linux环境下手工运行的容错性。
    local output_file="$1"
    local output_dir
    output_dir=$(dirname "$output_file")
    if [[ -n "$output_dir" && "$output_dir" != "." && ! -d "$output_dir" ]]; then
        mkdir -p "$output_dir"
    fi
}

apply_interactive_menu_options() {
    # 允许在菜单输入时追加常用参数，例如: 1 -f 或 1 --full -o /tmp/report.txt
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--full)
                FULL_MODE=true
                shift
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                configure_output_mode
                shift
                ;;
            -o|--output)
                if [[ $# -lt 2 || "${2:-}" == -* ]]; then
                    echo -e "${RED}参数错误: $1 需要指定输出文件路径。${NC}"
                    return 1
                fi
                OUTPUT_FILE=$(normalize_output_file_path "$2") || {
                    echo -e "${RED}参数错误: 输出文件路径不能为空。${NC}"
                    return 1
                }
                shift 2
                ;;
            --output=*)
                OUTPUT_FILE=$(normalize_output_file_path "${1#*=}") || {
                    echo -e "${RED}参数错误: --output= 需要指定输出文件路径。${NC}"
                    return 1
                }
                shift
                ;;
            -j|--json)
                echo -e "${RED}交互菜单不支持追加 $1；如需JSON输出，请在启动脚本时使用: $0 -j 或 $0 --mode cpe -j。${NC}"
                return 1
                ;;
            *)
                echo -e "${RED}无效附加参数: $1；菜单中支持 -f/--full、-q/--quiet、--no-color、-o/--output。${NC}"
                return 1
                ;;
        esac
    done
    return 0
}

select_inspection_mode() {
    # 交互式场景选择：手工运行时先明确巡检目标，自动化参数运行时不阻塞。
    if [[ -n "$INSPECTION_MODE" ]]; then
        return
    fi

    if [[ "$OUTPUT_TERMINAL" != "true" || ! -t 0 ]]; then
        INSPECTION_MODE="${INSPECTION_MODE:-cpe}"
        return
    fi

    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${WHITE} 飞连 CPE 巡检工具 - 请选择执行场景${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${GREEN}  1. [已实现] CPE巡检${NC}          针对 CPE 状态异常进行全面检查"
    echo -e "${GREEN}  2. [已实现] CPE IP发布检查${NC}   针对 CPE IP/调度不生效进行排查"
    echo -e "${GREEN}  3. [已实现] CPE 域名调度检查${NC} 针对 CPE 域名调度异常进行查看"
    echo -e "${GREEN}  4. [已实现] CPE常见优化脚本${NC}  提供常见优化动作确认式执行入口"
    echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
    echo -e "${WHITE}提示: 当前已实现 1.CPE巡检、2.CPE IP发布检查、3.CPE域名调度检查 和 4.CPE常见优化脚本。${NC}"
    echo -e "${WHITE}说明: 选择 4 后会进入优化脚本子菜单，展示脚本详情并二次确认后才执行。${NC}"
    echo -e "${WHITE}示例: 输入 ${GREEN}1 -f${NC}${WHITE} 可执行 CPE 巡检并展示全部巡检项。${NC}"
    echo -e "${WHITE}示例: 输入 ${GREEN}1 -f -o /home/11.txt${NC}${WHITE} 可保存报告；相对路径会自动转为绝对路径。${NC}"
    echo ""

    local input
    local choice
    local menu_parts
    while true; do
        printf "%b" "${BOLD}请输入选项 [1-4，可追加 -f/--full，直接回车保持不变]: ${NC}"
        read -r input || input=""
        if [[ -z "$input" ]]; then
            continue
        fi
        read -r -a menu_parts <<< "$input"
        choice="${menu_parts[0]:-}"
        case "$choice" in
            1)
                apply_interactive_menu_options "${menu_parts[@]:1}" || continue
                INSPECTION_MODE="cpe"
                break
                ;;
            2)
                apply_interactive_menu_options "${menu_parts[@]:1}" || continue
                INSPECTION_MODE="ip_publish"
                break
                ;;
            3)
                apply_interactive_menu_options "${menu_parts[@]:1}" || continue
                INSPECTION_MODE="domain_schedule"
                break
                ;;
            4)
                apply_interactive_menu_options "${menu_parts[@]:1}" || continue
                INSPECTION_MODE="optimizer"
                break
                ;;
            *)
                echo -e "${RED}无效选项: $choice，请输入 1、2、3 或 4。${NC}"
                ;;
        esac
    done
}

show_reserved_mode() {
    local title="$1"
    local description="$2"
    echo ""
    echo -e "${BOLD}${YELLOW}◆ ${title} - 预留功能${NC}"
    echo -e "${WHITE}当前状态${NC}: 功能入口已保留，巡检逻辑待补充，本次不会执行任何检查。"
    echo -e "${WHITE}适用场景${NC}: ${description}"
    echo -e "${WHITE}后续扩展${NC}: 将按一个场景一个函数组的方式实现，保持与 CPE巡检相同的输出规范。"
    echo ""
    echo -e "${YELLOW}未执行任何变更或诊断命令。${NC}"
}

confirm_y_or_cancel() {
    local prompt="$1"
    local empty_message="${2:-直接回车保持当前确认项，请输入 y/Y 确认，或输入其他任意内容取消。}"
    local confirm

    while true; do
        printf "%b" "${BOLD}${YELLOW}${prompt}${NC}"
        read -r confirm || confirm=""
        if [[ -z "$confirm" ]]; then
            echo -e "${YELLOW}${empty_message}${NC}"
            continue
        fi
        [[ "$confirm" == "y" || "$confirm" == "Y" ]] && return 0
        return 1
    done
}

normalize_ipv4_input() {
    # 手工输入时经常会复制到首尾空格或中文全角空格，先标准化再做 IPv4 校验。
    printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/^[[:space:]　]*//; s/[[:space:]　]*$//'
}

validate_ipv4() {
    local ip
    ip=$(normalize_ipv4_input "${1:-}")
    local IFS=.
    local -a parts=()
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    read -r -a parts <<< "$ip"
    [[ "${#parts[@]}" -eq 4 ]] || return 1
    local part
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]+$ && "$part" -ge 0 && "$part" -le 255 ]] || return 1
    done
    return 0
}

ipv4_to_int() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

ipv4_in_cidr() {
    local ip="$1"
    local network="$2"
    local mask="$3"
    local ip_int net_int mask_int

    validate_ipv4 "$ip" || return 1
    validate_ipv4 "$network" || return 1
    [[ "$mask" =~ ^[0-9]+$ && "$mask" -ge 0 && "$mask" -le 32 ]] || return 1

    ip_int=$(ipv4_to_int "$ip")
    net_int=$(ipv4_to_int "$network")
    if [[ "$mask" -eq 0 ]]; then
        mask_int=0
    else
        mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    fi
    [[ $((ip_int & mask_int)) -eq $((net_int & mask_int)) ]]
}

is_pop_ip_in_all_servers() {
    local ip="$1"
    local all_pop_json

    all_pop_json=$(get_ucistore_option_json "all_pop_servers")
    [[ -n "$all_pop_json" ]] || return 0

    if command -v jq >/dev/null 2>&1; then
        jq -e --arg ip "$ip" 'any(.all_pop_servers[]?; .public_ip == $ip)' >/dev/null 2>&1 <<< "$all_pop_json"
        return $?
    fi

    grep -q "\"public_ip\":\"${ip}\"" <<< "$all_pop_json"
}

prompt_pop_ip() {
    local label="$1"
    local current_ip="$2"
    local input
    while true; do
        if [[ -n "$current_ip" ]]; then
            printf "%b" "${BOLD}请输入${label}POP IP [当前 ${current_ip}]: ${NC}" >&2
        else
            printf "%b" "${BOLD}请输入${label}POP IP: ${NC}" >&2
        fi
        read -r input || input=""
        input=$(normalize_ipv4_input "$input")
        if [[ -z "$input" ]]; then
            echo -e "${RED}POP IP 不能为空，请重新输入。${NC}" >&2
            continue
        fi
        if ! validate_ipv4 "$input"; then
            echo -e "${RED}IP地址格式无效: $input，请重新输入。${NC}" >&2
            continue
        fi
        if ! is_pop_ip_in_all_servers "$input"; then
            echo -e "${RED}IP地址不在【所有POP延迟信息】列表中: $input，请重新输入。${NC}" >&2
            continue
        fi
        printf '%s\n' "$input"
        return 0
    done
}

get_feilian_tun_cli_output() {
    if command -v feilian-tun-cli >/dev/null 2>&1; then
        feilian-tun-cli 2>&1
    elif [[ -x /opt/feilian/cpe/bin/feilian-tun-cli ]]; then
        /opt/feilian/cpe/bin/feilian-tun-cli 2>&1
    else
        return 1
    fi
}

extract_tun_endpoint() {
    local cli_output="$1"
    local iface="$2"
    printf '%s\n' "$cli_output" | awk -v iface="$iface" '
        /^interface: / {
            in_block = ($2 == iface)
            next
        }
        in_block && /^[[:space:]]+endpoint:/ {
            print $2
            exit
        }
    '
}

extract_tun_cli_value() {
    local cli_output="$1"
    local iface="$2"
    local field="$3"
    printf '%s\n' "$cli_output" | awk -v iface="$iface" -v field="$field" '
        /^interface: / {
            in_block = ($2 == iface)
            next
        }
        in_block && index($0, field ":") {
            sub("^[[:space:]]*" field ":[[:space:]]*", "")
            print
            exit
        }
    '
}

extract_endpoint_ip() {
    local endpoint="${1:-}"
    [[ -n "$endpoint" ]] || return 0
    printf '%s\n' "${endpoint%%:*}"
}

get_fixed_pop_ip() {
    local role="$1"
    local env_file="/opt/feilian/cpe/conf/cpe.env"
    local key

    case "$role" in
        master) key="SPECIFIC_MASTER_POP_SERVER" ;;
        slave) key="SPECIFIC_SLAVE_POP_SERVER" ;;
        *) return 0 ;;
    esac
    sed -n "s/^${key}=//p" "$env_file" 2>/dev/null | tail -1
}

format_ipinfo_summary() {
    local ipinfo="$1"
    local org city region country
    if command -v jq >/dev/null 2>&1; then
        org=$(printf '%s\n' "$ipinfo" | jq -r '.org // empty' 2>/dev/null)
        city=$(printf '%s\n' "$ipinfo" | jq -r '.city // empty' 2>/dev/null)
        region=$(printf '%s\n' "$ipinfo" | jq -r '.region // empty' 2>/dev/null)
        country=$(printf '%s\n' "$ipinfo" | jq -r '.country // empty' 2>/dev/null)
    else
        org=$(printf '%s\n' "$ipinfo" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        city=$(printf '%s\n' "$ipinfo" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        region=$(printf '%s\n' "$ipinfo" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        country=$(printf '%s\n' "$ipinfo" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    printf '运营商: %s; 位置: %s%s%s\n' \
        "${org:-未知}" \
        "${country:-未知}" \
        "${region:+/${region}}" \
        "${city:+/${city}}"
}

show_single_pop_probe() {
    local iface="$1"
    local endpoint="$2"
    local tunnel_json="${3:-}"
    local info_mode="${4:-current}"
    local fixed_ip="${5:-}"
    local cli_status="${6:-}"
    local latest_handshake="${7:-}"
    local transfer="${8:-}"
    local pop_info_json="${9:-}"
    local pop_ip="${endpoint%%:*}"
    local wan_dev
    local wan_label
    local route_dev
    local ping_dev
    local ping_label
    local ping_if=""
    local ipinfo
    local ipinfo_summary=""
    local ping_output
    local loss
    local avg
    local tunnel_id=""
    local tunnel_name=""
    local tunnel_isp=""
    local tunnel_public_ip=""
    local tunnel_inner_ip=""
    local tunnel_api_port=""
    local tunnel_vpn_port=""
    local tunnel_consistency
    local fixed_consistency
    local pop_port
    local expected_endpoint=""
    local pop_status=""

    echo "  ${iface}:"
    if [[ -z "$endpoint" || "$endpoint" == "$pop_ip" ]]; then
        echo "    endpoint: 未获取"
        return 0
    fi

    if [[ -n "$tunnel_json" ]]; then
        if command -v jq >/dev/null 2>&1; then
            tunnel_id=$(printf '%s\n' "$tunnel_json" | jq -r '.id // "N/A"' 2>/dev/null)
            tunnel_name=$(printf '%s\n' "$tunnel_json" | jq -r '.name // "N/A"' 2>/dev/null)
            tunnel_isp=$(printf '%s\n' "$tunnel_json" | jq -r '.isp // "N/A"' 2>/dev/null)
            tunnel_public_ip=$(printf '%s\n' "$tunnel_json" | jq -r '.public_ip // "N/A"' 2>/dev/null)
            tunnel_inner_ip=$(printf '%s\n' "$tunnel_json" | jq -r '.inner_ip // "N/A"' 2>/dev/null)
            tunnel_api_port=$(printf '%s\n' "$tunnel_json" | jq -r '.api_port // "N/A"' 2>/dev/null)
            tunnel_vpn_port=$(printf '%s\n' "$tunnel_json" | jq -r '.vpn_port // "N/A"' 2>/dev/null)
        else
            tunnel_id=$(parse_json_number_by_sed "$tunnel_json" "id")
            tunnel_name=$(parse_json_field_by_sed "$tunnel_json" "name")
            tunnel_isp=$(parse_json_field_by_sed "$tunnel_json" "isp")
            tunnel_public_ip=$(parse_json_field_by_sed "$tunnel_json" "public_ip")
            tunnel_inner_ip=$(parse_json_field_by_sed "$tunnel_json" "inner_ip")
            tunnel_api_port=$(parse_json_number_by_sed "$tunnel_json" "api_port")
            tunnel_vpn_port=$(parse_json_number_by_sed "$tunnel_json" "vpn_port")
        fi
    fi
    pop_status=$(parse_json_number_by_sed "$pop_info_json" "status")

    wan_dev=$(get_default_wan_dev)
    wan_label="${wan_dev:-未指定(未找到非tun默认路由)}"
    route_dev=$(get_route_dev_for_target "$pop_ip")
    ping_dev="${wan_dev:-$route_dev}"
    ping_label="${ping_dev:-未指定(未找到可用出接口)}"
    [[ -n "$ping_dev" ]] && ping_if="-I $ping_dev"
    pop_port="${endpoint##*:}"
    [[ "$pop_port" == "$endpoint" ]] && pop_port="N/A"

    if [[ "$info_mode" == "current" ]]; then
        expected_endpoint="${tunnel_public_ip}${tunnel_vpn_port:+:${tunnel_vpn_port}}"
        if [[ "${tunnel_public_ip:-}" == "$pop_ip" ]]; then
            tunnel_consistency="一致"
        elif [[ -n "${tunnel_public_ip:-}" ]]; then
            tunnel_consistency="不一致，CLI=${endpoint}, ucistore=${expected_endpoint:-${tunnel_public_ip}}"
        else
            tunnel_consistency="未获取到ucistore隧道信息"
        fi
        if [[ -n "$fixed_ip" && "${tunnel_public_ip:-}" == "$fixed_ip" ]]; then
            fixed_consistency="一致"
        elif [[ -n "$fixed_ip" && -n "${tunnel_public_ip:-}" ]]; then
            fixed_consistency="不一致，固定选点=${fixed_ip}, ucistore=${tunnel_public_ip}"
        elif [[ -n "$fixed_ip" ]]; then
            fixed_consistency="未获取到ucistore隧道信息"
        else
            fixed_consistency="未配置固定选点"
        fi
        echo "    - 当前feilian-tun-cli: IP=${pop_ip:-未获取}, 端口=${pop_port:-N/A}, 握手=${cli_status:-未获取}, 最近握手=${latest_handshake:-未获取}, 传输=${transfer:-未获取}"
        echo "    - ucistore隧道信息: IP=${tunnel_public_ip:-N/A}, 端口=${tunnel_vpn_port:-N/A}, POP_ID=${tunnel_id:-N/A}, 名称=${tunnel_name:-N/A}, 运营商=${tunnel_isp:-N/A}, status=${pop_status:-N/A}"
        echo "    - 固定选点配置: IP=${fixed_ip:-未配置}"
        echo "    一致性: CLI/ucistore=${tunnel_consistency}; 固定选点/ucistore=${fixed_consistency}"
    else
        echo "    endpoint: ${endpoint}"
        if [[ -n "$tunnel_json" ]]; then
            if [[ "${tunnel_public_ip:-}" == "$pop_ip" ]]; then
                tunnel_consistency="一致"
            else
                tunnel_consistency="不一致，指定POP=${pop_ip}, ucistore=${tunnel_public_ip:-未获取}"
            fi
            echo "    POP信息: ID=${tunnel_id:-N/A}, 名称=${tunnel_name:-N/A}, 运营商=${tunnel_isp:-N/A}"
            echo "    POP地址: 公网=${tunnel_public_ip:-N/A}, 内网=${tunnel_inner_ip:-N/A}, API端口=${tunnel_api_port:-N/A}, VPN端口=${tunnel_vpn_port:-N/A}"
            echo "    POP匹配: ${tunnel_consistency}"
        fi
    fi
    if [[ "${route_dev:-}" == "${wan_dev:-}" && "${ping_dev:-}" == "${wan_dev:-}" ]]; then
        echo "    出接口: ${ping_label}"
    else
        echo "    出接口: ${ping_label} (路由=${route_dev:-未获取}, 公网出口=${wan_label})"
    fi

    if [[ -z "$tunnel_json" ]]; then
        if [[ -n "$wan_dev" ]]; then
            ipinfo=$(curl --interface "$wan_dev" -sk --max-time 5 "https://ipinfo.io/${pop_ip}/json" 2>/dev/null || true)
        else
            ipinfo=$(curl -sk --max-time 5 "https://ipinfo.io/${pop_ip}/json" 2>/dev/null || true)
        fi
        if [[ -n "$ipinfo" ]]; then
            ipinfo_summary=$(format_ipinfo_summary "$ipinfo")
        else
            ipinfo_summary="运营商/位置: 获取失败"
        fi
    fi

    ping_output=$(ping $ping_if -W2 -c3 "$pop_ip" 2>&1 || true)
    loss=$(printf '%s\n' "$ping_output" | awk -F',' '/packet loss/ {gsub(/[^0-9.]/, "", $3); print $3; exit}')
    avg=$(printf '%s\n' "$ping_output" | awk -F'/' '/^rtt|^round-trip/ {print $5; exit}')
    [[ -n "$ipinfo_summary" ]] && echo "    ${ipinfo_summary}"
    echo "    网络质量: 丢包率=${loss:-N/A}%，平均延迟=${avg:-N/A}ms"
}

get_ucistore_option_json() {
    local option_name="$1"
    local ucistore="/opt/feilian/cpe/.cache/ucistore"

    [[ -f "$ucistore" ]] || return 0
    grep "option ${option_name} " "$ucistore" 2>/dev/null | awk -F "'" '{print $2}' | tail -1
}

get_pop_server_json_by_ip() {
    local ip="$1"
    local all_pop_json
    local object

    all_pop_json=$(get_ucistore_option_json "all_pop_servers")
    [[ -n "$all_pop_json" ]] || return 0

    if command -v jq >/dev/null 2>&1; then
        jq -c --arg ip "$ip" '.all_pop_servers[]? | select(.public_ip == $ip)' 2>/dev/null <<< "$all_pop_json" | head -1
        return 0
    fi

    object=$(printf '%s\n' "$all_pop_json" | sed 's/},{/}\n{/g' | grep "\"public_ip\":\"${ip}\"" | head -1)
    [[ -n "$object" ]] && printf '%s\n' "$object"
}

parse_json_field_by_sed() {
    local object="$1"
    local key="$2"
    printf '%s\n' "$object" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

parse_json_number_by_sed() {
    local object="$1"
    local key="$2"
    printf '%s\n' "$object" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p"
}

extract_probe_metric_without_jq() {
    local probe_json="$1"
    local public_ip="$2"
    local metric="$3"
    local object
    object=$(printf '%s\n' "$probe_json" | sed 's/},{/}\n{/g' | grep "\"public_ip\":\"${public_ip}\"" | head -1)
    [[ -n "$object" ]] || return 0
    case "$metric" in
        failed)
            parse_json_number_by_sed "$object" "failed"
            ;;
        delay)
            parse_json_number_by_sed "$object" "delay_in_mill_second"
            ;;
        err)
            parse_json_field_by_sed "$object" "err_message"
            ;;
    esac
}

format_pop_latency_without_jq() {
    local all_pop_json="$1"
    local probe_json="$2"
    local objects
    local object
    local id name isp public_ip inner_ip api_port vpn_port failed delay

    objects=$(printf '%s\n' "$all_pop_json" | sed 's/},{/}\n{/g')
    while IFS= read -r object; do
        [[ "$object" == *'"public_ip"'* ]] || continue
        id=$(parse_json_number_by_sed "$object" "id")
        name=$(parse_json_field_by_sed "$object" "name")
        isp=$(parse_json_field_by_sed "$object" "isp")
        public_ip=$(parse_json_field_by_sed "$object" "public_ip")
        inner_ip=$(parse_json_field_by_sed "$object" "inner_ip")
        api_port=$(parse_json_number_by_sed "$object" "api_port")
        vpn_port=$(parse_json_number_by_sed "$object" "vpn_port")
        failed=$(extract_probe_metric_without_jq "$probe_json" "$public_ip" "failed")
        delay=$(extract_probe_metric_without_jq "$probe_json" "$public_ip" "delay")

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s/%s\n' \
            "${delay:-N/A}" \
            "${failed:-N/A}" \
            "${id:-N/A}" \
            "${name:-N/A}" \
            "${isp:-N/A}" \
            "${public_ip:-N/A}" \
            "${inner_ip:-N/A}" \
            "${api_port:-N/A}" \
            "${vpn_port:-N/A}"
    done <<< "$objects"
}

show_all_pop_latency_info() {
    local ucistore="/opt/feilian/cpe/.cache/ucistore"
    local all_pop_json
    local probe_json
    local probe_output
    local cli_output=""
    local cli_master_ip=""
    local cli_slave_ip=""
    local ucistore_master_ip=""
    local ucistore_slave_ip=""
    local fixed_master_ip=""
    local fixed_slave_ip=""
    local master_tunnel_json=""
    local slave_tunnel_json=""

    echo "【所有POP延迟信息】:"
    if [[ ! -f "$ucistore" ]]; then
        echo "  未找到 $ucistore，无法获取 POP 延迟探测结果。"
        echo ""
        return 0
    fi

    all_pop_json=$(grep 'all_pop_servers' "$ucistore" 2>/dev/null | awk -F "'" '{print $2}' | tail -1)
    probe_json=$(grep 'out_band_probe_result' "$ucistore" 2>/dev/null | awk -F "'" '{print $2}' | tail -1)
    if [[ -z "$all_pop_json" ]]; then
        echo "  未找到 all_pop_servers 记录。"
        echo ""
        return 0
    fi
    if [[ -z "$probe_json" ]]; then
        echo "  未找到 out_band_probe_result 记录。"
        echo ""
        return 0
    fi

    cli_output=$(get_feilian_tun_cli_output 2>/dev/null || true)
    cli_master_ip=$(extract_endpoint_ip "$(extract_tun_endpoint "$cli_output" "tun0_master")")
    cli_slave_ip=$(extract_endpoint_ip "$(extract_tun_endpoint "$cli_output" "tun0_slave")")
    master_tunnel_json=$(get_ucistore_option_json "master_tunnel")
    slave_tunnel_json=$(get_ucistore_option_json "slave_tunnel")
    ucistore_master_ip=$(parse_json_field_by_sed "$master_tunnel_json" "public_ip")
    ucistore_slave_ip=$(parse_json_field_by_sed "$slave_tunnel_json" "public_ip")
    fixed_master_ip=$(get_fixed_pop_ip "master")
    fixed_slave_ip=$(get_fixed_pop_ip "slave")
    if command -v jq >/dev/null 2>&1; then
        probe_output=$(jq -n -r --argjson servers "$all_pop_json" --argjson probes "$probe_json" '
            ($probes | map({
                key: .public_ip,
                value: {
                    failed: (if (.delay | has("failed")) then .delay.failed else "N/A" end),
                    delay: (.delay.delay_in_mill_second // "N/A")
                }
            }) | from_entries) as $probe_map
            | ($servers.all_pop_servers // [])[]
            | ($probe_map[.public_ip] // {failed:"N/A", delay:"N/A", err:""}) as $probe
            | [
                ($probe.delay | tostring),
                ($probe.failed | tostring),
                (.id | tostring),
                (.name // "N/A"),
                (.isp // "N/A"),
                (.public_ip // "N/A"),
                (.inner_ip // "N/A"),
                "\(.api_port // "N/A")/\(.vpn_port // "N/A")"
            ]
            | @tsv
        ' 2>/dev/null || true)
    else
        probe_output=$(format_pop_latency_without_jq "$all_pop_json" "$probe_json")
    fi
    if [[ -z "$probe_output" ]]; then
        echo "  all_pop_servers/out_band_probe_result 解析失败或内容为空。"
        echo ""
        return 0
    fi

    {
        printf '延迟(ms)\t失败\tPOP_ID\t名称\t运营商\t公网IP\t内网IP\t端口(API/VPN)\t备注\n'
        printf '%s\n' "$probe_output" \
            | awk -F '\t' \
                -v cli_master_ip="$cli_master_ip" \
                -v cli_slave_ip="$cli_slave_ip" \
                -v ucistore_master_ip="$ucistore_master_ip" \
                -v ucistore_slave_ip="$ucistore_slave_ip" \
                -v fixed_master_ip="$fixed_master_ip" \
                -v fixed_slave_ip="$fixed_slave_ip" '
                function append_note(note, text) {
                    return note == "" ? text : note "," text
                }
                {
                    note = ""
                    if (cli_master_ip != "" && $6 == cli_master_ip) {
                        note = append_note(note, "feilian-tun-cli主选点")
                    }
                    if (cli_slave_ip != "" && $6 == cli_slave_ip) {
                        note = append_note(note, "feilian-tun-cli备选点")
                    }
                    if (ucistore_master_ip != "" && $6 == ucistore_master_ip) {
                        note = append_note(note, "ucistore主选点")
                    }
                    if (ucistore_slave_ip != "" && $6 == ucistore_slave_ip) {
                        note = append_note(note, "ucistore备选点")
                    }
                    if (fixed_master_ip != "" && $6 == fixed_master_ip) {
                        note = append_note(note, "固定主选点")
                    }
                    if (fixed_slave_ip != "" && $6 == fixed_slave_ip) {
                        note = append_note(note, "固定备选点")
                    }
                    key=($1 ~ /^[0-9]+$/ ? $1 : 999999)
                    print key "\t" $0 "\t" (note == "" ? "-" : note)
                }' \
            | sort -n -k1,1 \
            | cut -f2-
    } | if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' | awk -v green="$GREEN" -v cyan="$CYAN" -v yellow="$YELLOW" -v purple="$PURPLE" -v nc="$NC" '
            NR == 1 {print "  " $0; next}
            /,/ && /选点/ {print "  " purple $0 nc; next}
            /feilian-tun-cli.*选点/ {print "  " green $0 nc; next}
            /ucistore.*选点/ {print "  " cyan $0 nc; next}
            /固定.*选点/ {print "  " yellow $0 nc; next}
            {print "  " $0}
        '
    else
        awk -F '\t' -v green="$GREEN" -v cyan="$CYAN" -v yellow="$YELLOW" -v purple="$PURPLE" -v nc="$NC" '
            NR == 1 {
                printf "  %-10s %-8s %-8s %-18s %-15s %-16s %-16s %-14s %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9
                next
            }
            {
                color = ""
                if ($9 ~ /,/ && $9 ~ /选点/) {
                    color = purple
                } else if ($9 ~ /feilian-tun-cli.*选点/) {
                    color = green
                } else if ($9 ~ /ucistore.*选点/) {
                    color = cyan
                } else if ($9 ~ /固定.*选点/) {
                    color = yellow
                }
                printf "  %s%-10s %-8s %-8s %-18s %-15s %-16s %-16s %-14s %s%s\n", color, $1, $2, $3, $4, $5, $6, $7, $8, $9, (color == "" ? "" : nc)
            }'
    fi
    echo ""
}

show_current_pop_selection_info() {
    local cli_output
    local master_endpoint
    local slave_endpoint
    local master_tunnel_json
    local slave_tunnel_json
    local master_pop_info_json
    local slave_pop_info_json
    local fixed_master_ip
    local fixed_slave_ip
    local master_status
    local slave_status
    local master_latest_handshake
    local slave_latest_handshake
    local master_transfer
    local slave_transfer

    echo "【当前选点信息】:"
    if ! cli_output=$(get_feilian_tun_cli_output); then
        echo "  未获取到 feilian-tun-cli 输出，无法解析当前 POP 选点。"
        return 0
    fi

    master_endpoint=$(extract_tun_endpoint "$cli_output" "tun0_master")
    slave_endpoint=$(extract_tun_endpoint "$cli_output" "tun0_slave")
    master_tunnel_json=$(get_ucistore_option_json "master_tunnel")
    slave_tunnel_json=$(get_ucistore_option_json "slave_tunnel")
    master_pop_info_json=$(get_ucistore_option_json "master_pop_info")
    slave_pop_info_json=$(get_ucistore_option_json "slave_pop_info")
    fixed_master_ip=$(get_fixed_pop_ip "master")
    fixed_slave_ip=$(get_fixed_pop_ip "slave")
    master_status=$(extract_tun_cli_value "$cli_output" "tun0_master" "current handshake status")
    slave_status=$(extract_tun_cli_value "$cli_output" "tun0_slave" "current handshake status")
    master_latest_handshake=$(extract_tun_cli_value "$cli_output" "tun0_master" "latest handshake")
    slave_latest_handshake=$(extract_tun_cli_value "$cli_output" "tun0_slave" "latest handshake")
    master_transfer=$(extract_tun_cli_value "$cli_output" "tun0_master" "transfer")
    slave_transfer=$(extract_tun_cli_value "$cli_output" "tun0_slave" "transfer")
    show_single_pop_probe "interface: tun0_master" "$master_endpoint" "$master_tunnel_json" "current" "$fixed_master_ip" "$master_status" "$master_latest_handshake" "$master_transfer" "$master_pop_info_json"
    show_single_pop_probe "interface: tun0_slave" "$slave_endpoint" "$slave_tunnel_json" "current" "$fixed_slave_ip" "$slave_status" "$slave_latest_handshake" "$slave_transfer" "$slave_pop_info_json"
    echo ""
    show_all_pop_latency_info
}

show_specified_pop_selection_info() {
    local master_ip="$1"
    local slave_ip="$2"
    local title="${3:-指定POP点信息}"
    local master_tunnel_json=""
    local slave_tunnel_json=""
    local master_pop_info_json=""
    local slave_pop_info_json=""
    local info_mode="specified"
    local fixed_master_ip=""
    local fixed_slave_ip=""
    local cli_output=""
    local master_label="主POP"
    local slave_label="备POP"
    local master_status=""
    local slave_status=""
    local master_latest_handshake=""
    local slave_latest_handshake=""
    local master_transfer=""
    local slave_transfer=""

    if [[ "$title" == "当前选点信息" ]]; then
        cli_output=$(get_feilian_tun_cli_output 2>/dev/null || true)
        master_tunnel_json=$(get_ucistore_option_json "master_tunnel")
        slave_tunnel_json=$(get_ucistore_option_json "slave_tunnel")
        master_pop_info_json=$(get_ucistore_option_json "master_pop_info")
        slave_pop_info_json=$(get_ucistore_option_json "slave_pop_info")
        info_mode="current"
        fixed_master_ip=$(get_fixed_pop_ip "master")
        fixed_slave_ip=$(get_fixed_pop_ip "slave")
        master_label="interface: tun0_master"
        slave_label="interface: tun0_slave"
        master_status=$(extract_tun_cli_value "$cli_output" "tun0_master" "current handshake status")
        slave_status=$(extract_tun_cli_value "$cli_output" "tun0_slave" "current handshake status")
        master_latest_handshake=$(extract_tun_cli_value "$cli_output" "tun0_master" "latest handshake")
        slave_latest_handshake=$(extract_tun_cli_value "$cli_output" "tun0_slave" "latest handshake")
        master_transfer=$(extract_tun_cli_value "$cli_output" "tun0_master" "transfer")
        slave_transfer=$(extract_tun_cli_value "$cli_output" "tun0_slave" "transfer")
    else
        master_tunnel_json=$(get_pop_server_json_by_ip "$master_ip")
        slave_tunnel_json=$(get_pop_server_json_by_ip "$slave_ip")
    fi

    echo "【${title}】:"
    show_single_pop_probe "$master_label" "${master_ip}:9108" "$master_tunnel_json" "$info_mode" "$fixed_master_ip" "$master_status" "$master_latest_handshake" "$master_transfer" "$master_pop_info_json"
    show_single_pop_probe "$slave_label" "${slave_ip}:9108" "$slave_tunnel_json" "$info_mode" "$fixed_slave_ip" "$slave_status" "$slave_latest_handshake" "$slave_transfer" "$slave_pop_info_json"
    echo ""
    if [[ "$title" == "当前选点信息" ]]; then
        show_all_pop_latency_info
    fi
}

show_pop_reselect_optimizer_detail() {
    local env_file="/opt/feilian/cpe/conf/cpe.env"
    local has_fixed_pop_config=false

    if [[ -f "$env_file" ]] && grep -qE '^SPECIFIC_(MASTER|SLAVE)_POP_SERVER=' "$env_file" 2>/dev/null; then
        has_fixed_pop_config=true
    fi

    cat <<'EOF'
------------------------------------------------------------
优化脚本 1: 清理已有的POP连接信息，重新选择POP点连接
------------------------------------------------------------
EOF
    show_current_pop_selection_info
    cat <<'EOF'
【适用场景】:
  - CPE 已连接的 POP 点异常、延迟高或调度不符合预期。
  - 需要清理本地缓存的 master_tunnel/slave_tunnel 后触发重新选点。

【风险提示】:
  - 会停止并重启 feilian-cpe 服务，期间业务可能短暂中断。
  - 会重启 feilian-tun@tun0_master 和 feilian-tun@tun0_slave，主备隧道会重新建立。
  - 会修改 /opt/feilian/cpe/.cache/ucistore。
  - 执行前会自动备份 ucistore 到同目录 .bak.<时间戳> 文件。
EOF
    if [[ "$has_fixed_pop_config" == "true" ]]; then
        cat <<'EOF'
  - 会删除 /opt/feilian/cpe/conf/cpe.env 中的固定选点配置。
  - 执行前会自动备份 cpe.env 到同目录 .bak.<时间戳> 文件。
EOF
    fi

    cat <<'EOF'
【将执行的脚本】:
  sudo -s
  systemctl stop feilian-cpe
  cp -a /opt/feilian/cpe/.cache/ucistore /opt/feilian/cpe/.cache/ucistore.bak.<时间戳>
  sed -i '/master_tunnel/d' /opt/feilian/cpe/.cache/ucistore
  sed -i '/slave_tunnel/d' /opt/feilian/cpe/.cache/ucistore
EOF
    if [[ "$has_fixed_pop_config" == "true" ]]; then
        cat <<'EOF'
  cp -a /opt/feilian/cpe/conf/cpe.env /opt/feilian/cpe/conf/cpe.env.bak.<时间戳>
  sed -i '/SPECIFIC_MASTER_POP_SERVER/d' /opt/feilian/cpe/conf/cpe.env
  sed -i '/SPECIFIC_SLAVE_POP_SERVER/d' /opt/feilian/cpe/conf/cpe.env
EOF
    fi

    cat <<'EOF'
  systemctl restart feilian-cpe
  systemctl restart feilian-tun@tun0_master
  systemctl restart feilian-tun@tun0_slave
  timeout 3m tail -F /opt/feilian/cpe/log/cpe.event.log | grep -v pbr | jq -r '"[\(.level)] [\(.time)] [\(.module)] \(.msg)"'
  feilian-tun-cli

【说明】:
  - 日志观察默认 3 分钟，避免脚本长期阻塞；如需持续观察，请手工执行 tail -f 命令。
  - 如果 jq 不存在，会回退展示过滤 pbr 后的原始日志。
EOF
    if [[ "$has_fixed_pop_config" == "true" ]]; then
        echo "  - 检测到固定选点配置，会同时清理 SPECIFIC_MASTER_POP_SERVER/SPECIFIC_SLAVE_POP_SERVER。"
    else
        echo "  - 未检测到固定选点配置，跳过 cpe.env 备份和固定选点清理。"
    fi
}

run_pop_reselect_optimizer() {
    show_pop_reselect_optimizer_detail
    echo ""
    if ! confirm_y_or_cancel "输入 y/Y 确认执行，直接回车保持当前确认项，输入其他任意内容取消: "; then
        echo -e "${YELLOW}已取消执行，未修改系统配置。${NC}"
        return 0
    fi

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo -e "${RED}执行失败: 该优化脚本需要 root 权限，请先 sudo -s 后重新执行。${NC}"
        return 1
    fi

    local ucistore="/opt/feilian/cpe/.cache/ucistore"
    local env_file="/opt/feilian/cpe/conf/cpe.env"
    local backup="${ucistore}.bak.$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo unknown)"
    local env_backup="${env_file}.bak.$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo unknown)"
    local step=1

    echo -e "${CYAN}开始执行优化脚本: 清理已有POP连接信息并重新选点${NC}"
    echo -e "${WHITE}${step}. 停止 feilian-cpe 服务${NC}"
    ((step++))
    systemctl stop feilian-cpe || {
        echo -e "${RED}执行失败: systemctl stop feilian-cpe 失败${NC}"
        return 1
    }

    if [[ -f "$ucistore" ]]; then
        echo -e "${WHITE}${step}. 备份 ucistore: ${backup}${NC}"
        ((step++))
        cp -a "$ucistore" "$backup" || {
            echo -e "${RED}执行失败: 备份 $ucistore 失败${NC}"
            return 1
        }
        echo -e "${WHITE}${step}. 清理 master_tunnel/slave_tunnel 缓存${NC}"
        ((step++))
        sed -i '/master_tunnel/d' "$ucistore"
        sed -i '/slave_tunnel/d' "$ucistore"
    else
        echo -e "${YELLOW}警告: $ucistore 不存在，跳过缓存清理。${NC}"
    fi

    if [[ -f "$env_file" ]] && grep -qE '^SPECIFIC_(MASTER|SLAVE)_POP_SERVER=' "$env_file" 2>/dev/null; then
        echo -e "${WHITE}${step}. 备份 cpe.env: ${env_backup}${NC}"
        ((step++))
        cp -a "$env_file" "$env_backup" || {
            echo -e "${RED}执行失败: 备份 $env_file 失败${NC}"
            return 1
        }
        echo -e "${WHITE}${step}. 删除固定主备 POP 配置${NC}"
        ((step++))
        sed -i '/SPECIFIC_MASTER_POP_SERVER/d' "$env_file"
        sed -i '/SPECIFIC_SLAVE_POP_SERVER/d' "$env_file"
    fi

    echo -e "${WHITE}${step}. 重启 feilian-cpe 服务${NC}"
    ((step++))
    systemctl restart feilian-cpe || {
        echo -e "${RED}执行失败: systemctl restart feilian-cpe 失败${NC}"
        return 1
    }

    echo -e "${WHITE}${step}. 重启 feilian-tun@tun0_master 服务${NC}"
    ((step++))
    systemctl restart feilian-tun@tun0_master || {
        echo -e "${RED}执行失败: systemctl restart feilian-tun@tun0_master 失败${NC}"
        return 1
    }

    echo -e "${WHITE}${step}. 重启 feilian-tun@tun0_slave 服务${NC}"
    ((step++))
    systemctl restart feilian-tun@tun0_slave || {
        echo -e "${RED}执行失败: systemctl restart feilian-tun@tun0_slave 失败${NC}"
        return 1
    }

    echo -e "${WHITE}${step}. 观察 cpe.event.log 最新日志(3分钟)${NC}"
    ((step++))
    if command -v timeout >/dev/null 2>&1; then
        if command -v jq >/dev/null 2>&1; then
            timeout 3m sh -c "tail -F /opt/feilian/cpe/log/cpe.event.log 2>/dev/null | grep -v pbr | jq -r '\"[\\(.level)] [\\(.time)] [\\(.module)] \\(.msg)\"'" || true
        else
            timeout 3m sh -c "tail -F /opt/feilian/cpe/log/cpe.event.log 2>/dev/null | grep -v pbr" || true
        fi
    else
        echo -e "${YELLOW}timeout命令不存在，跳过自动日志观察；可手工执行 tail -f /opt/feilian/cpe/log/cpe.event.log。${NC}"
    fi

    echo -e "${WHITE}${step}. 查看最新连接信息${NC}"
    ((step++))
    if command -v feilian-tun-cli >/dev/null 2>&1; then
        feilian-tun-cli || true
    elif [[ -x /opt/feilian/cpe/bin/feilian-tun-cli ]]; then
        /opt/feilian/cpe/bin/feilian-tun-cli || true
    else
        echo -e "${YELLOW}feilian-tun-cli 不存在或不可执行，请手工确认隧道连接状态。${NC}"
    fi

    echo -e "${WHITE}${step}. 重新探测当前选点信息${NC}"
    show_current_pop_selection_info

    echo -e "${GREEN}优化脚本执行完成。${NC}"
}

show_fixed_pop_optimizer_detail() {
    local master_ip="$1"
    local slave_ip="$2"
    cat <<EOF
------------------------------------------------------------
优化脚本 2: 将自动选点修改为固定POP点
------------------------------------------------------------
【适用场景】:
  - 需要将 CPE 从自动选点切换为指定主备 POP 点。
  - 已确认主备 POP IP，需要固定连接到指定 POP。

【风险提示】:
  - 会停止并重启 feilian-cpe 服务，期间业务可能短暂中断。
  - 会修改 /opt/feilian/cpe/.cache/ucistore 和 /opt/feilian/cpe/conf/cpe.env。
  - 会删除 already_report_environment，触发 CPE 重新上报环境并按固定 POP 配置连接。

【将执行的脚本】:
  sudo -s
  systemctl stop feilian-cpe
  sed -i '/already_report_environment/d' /opt/feilian/cpe/.cache/ucistore
  sed -i '/SPECIFIC_MASTER_POP_SERVER/d' /opt/feilian/cpe/conf/cpe.env
  sed -i '/SPECIFIC_SLAVE_POP_SERVER/d' /opt/feilian/cpe/conf/cpe.env
  echo "SPECIFIC_MASTER_POP_SERVER=${master_ip}" >> /opt/feilian/cpe/conf/cpe.env
  echo "SPECIFIC_SLAVE_POP_SERVER=${slave_ip}" >> /opt/feilian/cpe/conf/cpe.env
  systemctl restart feilian-cpe
  timeout 3m tail -F /opt/feilian/cpe/log/cpe.event.log | grep -v pbr | jq -r '"[\(.level)] [\(.time)] [\(.module)] \(.msg)"'
  cat /opt/feilian/cpe/conf/cpe.env
  feilian-tun-cli
  结构化查看当前选点信息

【说明】:
  - 主 POP IP: ${master_ip}
  - 备 POP IP: ${slave_ip}
  - 日志观察默认 3 分钟，避免脚本长期阻塞；如需持续观察，请手工执行 tail -f 命令。
  - 如果 jq 不存在，会回退展示过滤 pbr 后的原始日志。
  - 如需恢复自动选点，请删除 cpe.env 中 SPECIFIC_MASTER_POP_SERVER/SPECIFIC_SLAVE_POP_SERVER 后重启 feilian-cpe。
EOF
}

run_fixed_pop_optimizer() {
    local cli_output=""
    local default_master_ip=""
    local default_slave_ip=""
    local master_ip
    local slave_ip

    cli_output=$(get_feilian_tun_cli_output 2>/dev/null || true)
    default_master_ip=$(extract_endpoint_ip "$(extract_tun_endpoint "$cli_output" "tun0_master")")
    default_slave_ip=$(extract_endpoint_ip "$(extract_tun_endpoint "$cli_output" "tun0_slave")")

    show_specified_pop_selection_info "$default_master_ip" "$default_slave_ip" "当前选点信息"
    master_ip=$(prompt_pop_ip "固定的主" "$default_master_ip") || return 1
    slave_ip=$(prompt_pop_ip "固定的备" "$default_slave_ip") || return 1

    if [[ "$master_ip" != "$default_master_ip" || "$slave_ip" != "$default_slave_ip" ]]; then
        show_specified_pop_selection_info "$master_ip" "$slave_ip" "指定POP点信息"
    fi
    show_fixed_pop_optimizer_detail "$master_ip" "$slave_ip"
    echo ""
    if ! confirm_y_or_cancel "输入 y/Y 确认执行，直接回车保持当前确认项，输入其他任意内容取消: "; then
        echo -e "${YELLOW}已取消执行，未修改系统配置。${NC}"
        return 0
    fi

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo -e "${RED}执行失败: 该优化脚本需要 root 权限，请先 sudo -s 后重新执行。${NC}"
        return 1
    fi

    local ucistore="/opt/feilian/cpe/.cache/ucistore"
    local env_file="/opt/feilian/cpe/conf/cpe.env"

    echo -e "${CYAN}开始执行优化脚本: 将自动选点修改为固定POP点${NC}"
    echo -e "${WHITE}1. 停止 feilian-cpe 服务${NC}"
    systemctl stop feilian-cpe || {
        echo -e "${RED}执行失败: systemctl stop feilian-cpe 失败${NC}"
        return 1
    }

    if [[ -f "$ucistore" ]]; then
        echo -e "${WHITE}2. 清理 already_report_environment 缓存${NC}"
        sed -i '/already_report_environment/d' "$ucistore"
    else
        echo -e "${YELLOW}警告: $ucistore 不存在，跳过 already_report_environment 清理。${NC}"
    fi

    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}执行失败: $env_file 不存在${NC}"
        return 1
    fi

    echo -e "${WHITE}3. 写入固定主备 POP 配置${NC}"
    sed -i '/SPECIFIC_MASTER_POP_SERVER/d' "$env_file"
    sed -i '/SPECIFIC_SLAVE_POP_SERVER/d' "$env_file"
    echo "SPECIFIC_MASTER_POP_SERVER=${master_ip}" >> "$env_file"
    echo "SPECIFIC_SLAVE_POP_SERVER=${slave_ip}" >> "$env_file"

    echo -e "${WHITE}4. 重启 feilian-cpe 服务${NC}"
    systemctl restart feilian-cpe || {
        echo -e "${RED}执行失败: systemctl restart feilian-cpe 失败${NC}"
        return 1
    }

    echo -e "${WHITE}5. 观察 cpe.event.log 最新日志(3分钟)${NC}"
    if command -v timeout >/dev/null 2>&1; then
        if command -v jq >/dev/null 2>&1; then
            timeout 3m sh -c "tail -F /opt/feilian/cpe/log/cpe.event.log 2>/dev/null | grep -v pbr | jq -r '\"[\\(.level)] [\\(.time)] [\\(.module)] \\(.msg)\"'" || true
        else
            timeout 3m sh -c "tail -F /opt/feilian/cpe/log/cpe.event.log 2>/dev/null | grep -v pbr" || true
        fi
    else
        echo -e "${YELLOW}timeout命令不存在，跳过自动日志观察；可手工执行 tail -f /opt/feilian/cpe/log/cpe.event.log。${NC}"
    fi

    echo -e "${WHITE}6. 查看 cpe.env 最新配置${NC}"
    cat "$env_file"

    echo -e "${WHITE}7. 查看 feilian-tun-cli 原始连接信息${NC}"
    if command -v feilian-tun-cli >/dev/null 2>&1; then
        feilian-tun-cli || true
    elif [[ -x /opt/feilian/cpe/bin/feilian-tun-cli ]]; then
        /opt/feilian/cpe/bin/feilian-tun-cli || true
    else
        echo -e "${YELLOW}feilian-tun-cli 不存在或不可执行，请手工确认隧道连接状态。${NC}"
    fi

    echo -e "${WHITE}8. 重新探测当前选点信息${NC}"
    show_current_pop_selection_info

    echo -e "${GREEN}固定POP点配置完成。${NC}"
}

get_default_route_field() {
    local field="$1"
    ip -o route show default 2>/dev/null | awk -v field="$field" '
        {
            dev = ""; via = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) dev = $(i + 1)
                if ($i == "via" && (i + 1) <= NF) via = $(i + 1)
            }
            if (dev != "" && dev !~ /^(tun|docker|br-|veth|virbr|flannel|cni|wg)/) {
                if (field == "dev") print dev
                else if (field == "via") print via
                else print $0
                exit
            }
        }'
}

get_static_default_route_rules_file() {
    echo "/etc/feilian-default-egress-static-routes.rules"
}

get_static_default_route_script_file() {
    echo "/usr/local/sbin/feilian-default-egress-static-routes.sh"
}

get_static_default_route_service_file() {
    echo "/etc/systemd/system/feilian-default-egress-static-routes.service"
}

get_legacy_default_ingress_script_file() {
    echo "/usr/local/sbin/feilian-default-ingress-main-route.sh"
}

get_legacy_default_ingress_service_file() {
    echo "/etc/systemd/system/feilian-default-ingress-main-route.service"
}

extract_host_from_target() {
    local target="${1:-}"
    target="${target#*://}"
    target="${target%%/*}"
    if [[ "$target" == \[*\] ]]; then
        target="${target#\[}"
        target="${target%\]}"
    fi
    if [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$ ]]; then
        target="${target%:*}"
    elif [[ "$target" != *:*:* && "$target" == *:* ]]; then
        target="${target%:*}"
    fi
    printf '%s\n' "$target"
}

resolve_host_ipv4s() {
    local host="${1:-}"
    [[ -n "$host" ]] || return 0
    if validate_ipv4 "$host"; then
        printf '%s\n' "$host"
        return 0
    fi

    {
        if command -v getent >/dev/null 2>&1; then
            getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}'
        fi
        if command -v dig >/dev/null 2>&1; then
            dig +short A "$host" 2>/dev/null
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}'
        fi
    } | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/' | sort -u
}

collect_legacy_default_egress_route_targets() {
    local platform_url platform_host
    local mgmt_grpc_endpoint mgmt_grpc_host
    local center_dns_grpc_endpoint center_dns_grpc_host
    local center_dns_ip master_pop slave_pop
    local ip

    platform_url=$(sed -n 's/^url: //p' /opt/feilian/cpe/conf/config.yaml 2>/dev/null)
    platform_host=$(extract_host_from_target "$platform_url")
    for ip in $(resolve_host_ipv4s "$platform_host"); do
        printf '%s\n' "$ip/32"
    done

    mgmt_grpc_endpoint=$(awk -F "'" '/option ops_controller_grpc_addr/ {print $2; exit}' /opt/feilian/cpe/.cache/ucistore 2>/dev/null)
    mgmt_grpc_host=$(extract_host_from_target "$mgmt_grpc_endpoint")
    for ip in $(resolve_host_ipv4s "$mgmt_grpc_host"); do
        printf '%s\n' "$ip/32"
    done

    center_dns_grpc_endpoint=$(awk -F "'" '/option dns_controller_grpc_addr/ {print $2; exit}' /opt/feilian/cpe/.cache/ucistore 2>/dev/null)
    center_dns_grpc_host=$(extract_host_from_target "$center_dns_grpc_endpoint")
    for ip in $(resolve_host_ipv4s "$center_dns_grpc_host"); do
        printf '%s\n' "$ip/32"
    done

    center_dns_ip=$(awk -F '=' '/add-dns-server-ip/ {print $2; exit}' /etc/dnsmasq.d/cpe.conf 2>/dev/null)
    if validate_ipv4 "$center_dns_ip"; then
        printf '%s\n' "$center_dns_ip/32"
    fi

    master_pop=$(awk '/Endpoint = / {print $3}' /opt/feilian/cpe/conf/tun0_master.conf 2>/dev/null | awk -F : '{print $1}' | head -n 1)
    for ip in $(resolve_host_ipv4s "$master_pop"); do
        printf '%s\n' "$ip/32"
    done

    slave_pop=$(awk '/Endpoint = / {print $3}' /opt/feilian/cpe/conf/tun0_slave.conf 2>/dev/null | awk -F : '{print $1}' | head -n 1)
    for ip in $(resolve_host_ipv4s "$slave_pop"); do
        printf '%s\n' "$ip/32"
    done
}

list_legacy_default_ingress_main_rules() {
    ip rule show 2>/dev/null | awk '/iif [^[:space:]]+[[:space:]].* lookup main/ {print}'
}

remove_legacy_default_ingress_main_rules() {
    while read -r pref; do
        [[ -n "$pref" ]] || continue
        ip rule del pref "$pref" 2>/dev/null || true
    done < <(
        list_legacy_default_ingress_main_rules \
            | awk -F: '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 ~ /^[0-9]+$/) print $1}' \
            | sort -rn
    )
}

remove_static_default_route_destinations_from_main() {
    local destinations_csv="${1:-}"
    local old_ifs="$IFS"
    local destination

    [[ -n "$destinations_csv" ]] || return 0

    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$destinations_csv"
    IFS="$old_ifs"

    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        ip route del "$destination" 2>/dev/null || true
    done
}

apply_static_default_route_destinations_to_main() {
    local destinations_csv="$1"
    local default_dev="$2"
    local default_gw="$3"
    local old_ifs="$IFS"
    local destination

    [[ -n "$destinations_csv" ]] || return 0
    [[ -n "$default_dev" ]] || return 1

    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$destinations_csv"
    IFS="$old_ifs"

    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        if [[ -n "$default_gw" ]]; then
            ip route replace "$destination" via "$default_gw" dev "$default_dev" || return 1
        else
            ip route replace "$destination" dev "$default_dev" || return 1
        fi
    done
}

get_static_default_route_destinations_csv() {
    local rules_file
    rules_file=$(get_static_default_route_rules_file)
    [[ -s "$rules_file" ]] || return 0
    awk 'NF >= 1 && $1 !~ /^#/ {print $1}' "$rules_file" | paste -sd, -
}

write_static_default_route_rules_from_csv() {
    local destinations_csv="${1:-}"
    local rules_file
    local old_ifs="$IFS"
    local destination

    rules_file=$(get_static_default_route_rules_file)
    if [[ -z "$destinations_csv" ]]; then
        rm -f "$rules_file"
        return 0
    fi

    : > "$rules_file"
    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$destinations_csv"
    IFS="$old_ifs"
    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        printf '%s\n' "$destination" >> "$rules_file"
    done
}

validate_static_route_destination() {
    local raw ip prefix
    raw=$(normalize_ipv4_input "${1:-}")
    if validate_ipv4 "$raw"; then
        is_safe_static_route_destination "$raw" 32 || return 1
        return 0
    fi
    if [[ "$raw" =~ ^([^/]+)/([0-9]{1,2})$ ]]; then
        ip=$(normalize_ipv4_input "${BASH_REMATCH[1]}")
        prefix="${BASH_REMATCH[2]}"
        validate_ipv4 "$ip" || return 1
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        [[ "$prefix" -ge 0 && "$prefix" -le 32 ]]
        is_safe_static_route_destination "$ip" "$prefix" || return 1
        return $?
    fi
    return 1
}

is_safe_static_route_destination() {
    local ip="$1"
    local prefix="$2"
    local first_octet

    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    # 0.0.0.0/0 等价于改默认路由，不属于“指定目的地址”场景。
    [[ "$prefix" -ge 1 && "$prefix" -le 32 ]] || return 1
    first_octet="${ip%%.*}"
    [[ "$first_octet" =~ ^[0-9]+$ ]] || return 1
    [[ "$first_octet" -ne 0 ]] || return 1
    [[ "$first_octet" -ne 127 ]] || return 1
    [[ "$first_octet" -lt 224 ]] || return 1
    [[ "$ip" != "255.255.255.255" ]] || return 1
    return 0
}

normalize_static_route_destination() {
    local raw ip prefix
    raw=$(normalize_ipv4_input "${1:-}")
    if validate_ipv4 "$raw"; then
        is_safe_static_route_destination "$raw" 32 || return 1
        printf '%s/32\n' "$raw"
        return 0
    fi
    if [[ "$raw" =~ ^([^/]+)/([0-9]{1,2})$ ]]; then
        ip=$(normalize_ipv4_input "${BASH_REMATCH[1]}")
        prefix="${BASH_REMATCH[2]}"
        validate_ipv4 "$ip" || return 1
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        [[ "$prefix" -ge 0 && "$prefix" -le 32 ]] || return 1
        is_safe_static_route_destination "$ip" "$prefix" || return 1
        printf '%s/%s\n' "$ip" "$prefix"
        return 0
    fi
    return 1
}

normalize_static_route_destinations() {
    local raw="$1"
    local item destination
    local normalized=""
    local seen=""

    raw=${raw//，/,}
    raw=${raw// /}
    IFS=',' read -r -a STATIC_ROUTE_INPUT_ITEMS <<< "$raw"
    for item in "${STATIC_ROUTE_INPUT_ITEMS[@]}"; do
        [[ -n "$item" ]] || continue
        destination=$(normalize_static_route_destination "$item") || return 1
        case ",${seen}," in
            *,"${destination}",*) continue ;;
        esac
        seen+="${seen:+,}${destination}"
        normalized+="${normalized:+,}${destination}"
    done
    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

normalize_existing_static_route_destinations() {
    local raw="$1"
    local existing_csv item destination
    local normalized=""
    local seen=""

    existing_csv=$(get_static_default_route_destinations_csv)
    [[ -n "$existing_csv" ]] || return 2

    raw=${raw//，/,}
    raw=${raw// /}
    IFS=',' read -r -a STATIC_ROUTE_INPUT_ITEMS <<< "$raw"
    for item in "${STATIC_ROUTE_INPUT_ITEMS[@]}"; do
        [[ -n "$item" ]] || continue
        destination=$(normalize_static_route_destination "$item") || return 1
        case ",${existing_csv}," in
            *,"${destination}",*) ;;
            *) return 2 ;;
        esac
        case ",${seen}," in
            *,"${destination}",*) continue ;;
        esac
        seen+="${seen:+,}${destination}"
        normalized+="${normalized:+,}${destination}"
    done
    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

merge_static_route_destinations_csv() {
    local existing_csv="${1:-}"
    local added_csv="${2:-}"
    local merged="${existing_csv}"
    local old_ifs="$IFS"
    local destination

    [[ -n "$added_csv" ]] || {
        printf '%s\n' "$existing_csv"
        return 0
    }

    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$added_csv"
    IFS="$old_ifs"
    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        case ",${merged}," in
            *,"${destination}",*) ;;
            *) merged+="${merged:+,}${destination}" ;;
        esac
    done
    printf '%s\n' "$merged"
}

subtract_static_route_destinations_csv() {
    local existing_csv="${1:-}"
    local removed_csv="${2:-}"
    local result=""
    local old_ifs="$IFS"
    local destination

    [[ -n "$existing_csv" ]] || return 0
    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$existing_csv"
    IFS="$old_ifs"
    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        case ",${removed_csv}," in
            *,"${destination}",*) ;;
            *) result+="${result:+,}${destination}" ;;
        esac
    done
    printf '%s\n' "$result"
}

validate_static_route_destinations_not_exist() {
    local destinations_csv="${1:-}"
    local existing_csv destination
    local old_ifs="$IFS"

    existing_csv=$(get_static_default_route_destinations_csv)
    [[ -n "$destinations_csv" ]] || return 0
    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$destinations_csv"
    IFS="$old_ifs"
    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        case ",${existing_csv}," in
            *,"${destination}",*)
                echo "静态路由 ${destination} 已存在"
                return 1
                ;;
        esac
    done
    return 0
}

format_static_route_destinations_for_display() {
    local destinations_csv="${1:-}"
    local old_ifs="$IFS"
    local destination
    if [[ -z "$destinations_csv" ]]; then
        echo "  未发现已配置的静态路由"
        return 0
    fi
    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$destinations_csv"
    IFS="$old_ifs"
    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        echo "  - ${destination}"
    done
}

find_static_default_route_in_table() {
    local table="${1:-main}"
    local destination="$2"
    local route_cmd=(ip route show)
    if [[ -n "$table" && "$table" != "main" ]]; then
        route_cmd+=(table "$table")
    fi
    "${route_cmd[@]}" 2>/dev/null | awk -v destination="$destination" '
        BEGIN {
            host_destination = destination
            sub(/\/32$/, "", host_destination)
        }
        $1 == destination || $1 == host_destination {print; exit}'
}

format_static_default_route_runtime_status() {
    local destinations_csv="${1:-}"
    local old_ifs="$IFS"
    local destination route_line

    if [[ -z "$destinations_csv" ]]; then
        echo "  未发现运行态静态路由"
        return 0
    fi

    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$destinations_csv"
    IFS="$old_ifs"
    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        route_line=$(find_static_default_route_in_table "main" "$destination")
        if [[ -n "$route_line" ]]; then
            echo "  ${destination} -> ${route_line}"
        else
            echo "  ${destination} -> 未下发"
        fi
    done
}

show_static_default_route_status() {
    local rules_file script_file service_file
    local default_line default_dev default_gw destinations_csv
    local svc_state

    rules_file=$(get_static_default_route_rules_file)
    script_file=$(get_static_default_route_script_file)
    service_file=$(get_static_default_route_service_file)
    default_line=$(get_default_route_field line)
    default_dev=$(get_default_route_field dev)
    default_gw=$(get_default_route_field via)
    destinations_csv=$(get_static_default_route_destinations_csv)

    echo "【当前配置】:"
    format_static_route_destinations_for_display "$destinations_csv"
    echo ""
    echo "【默认出口识别】:"
    echo "  - 默认路由: ${default_line:-未获取}"
    echo "  - 默认路由口: ${default_dev:-未获取}"
    echo "  - 默认网关: ${default_gw:-未获取}"
    echo "  - 生效路由表: main"
    echo ""
    echo "【main表静态路由详情】:"
    format_static_default_route_runtime_status "$destinations_csv"
    echo ""
    echo "【配置文件状态】:"
    echo "  - 规则文件: ${rules_file} $([[ -s "$rules_file" ]] && echo "存在" || echo "不存在/为空")"
    echo "  - 持久化脚本: ${script_file} $([[ -f "$script_file" ]] && echo "存在" || echo "不存在")"
    echo "  - systemd服务: ${service_file} $([[ -f "$service_file" ]] && echo "存在" || echo "不存在")"
    echo ""
    echo "【服务状态】:"
    svc_state=$(systemctl is-enabled feilian-default-egress-static-routes.service 2>/dev/null || true)
    echo "  - static-route enabled: ${svc_state:-未启用}"
    svc_state=$(systemctl is-active feilian-default-egress-static-routes.service 2>/dev/null || true)
    echo "  - static-route active: ${svc_state:-未运行}"
}

show_static_default_route_add_detail() {
    local destinations_csv="$1"
    local default_line default_dev default_gw
    local rules_file script_file service_file

    default_line=$(get_default_route_field line)
    default_dev=$(get_default_route_field dev)
    default_gw=$(get_default_route_field via)
    rules_file=$(get_static_default_route_rules_file)
    script_file=$(get_static_default_route_script_file)
    service_file=$(get_static_default_route_service_file)

    cat <<EOF
------------------------------------------------------------
优化脚本 3: 静态路由默认出接口管理
------------------------------------------------------------
【适用场景】:
  - 需要把指定目的IP/网段固定从默认路由口出去。
  - 仅对手工指定的静态路由生效，不再自动固化管理平台、GRPC、中心DNS、POP等地址。

【当前默认出口】:
  - 默认路由: ${default_line:-未获取}
  - 默认路由口: ${default_dev:-未获取}
  - 默认网关: ${default_gw:-未获取}
  - 生效路由表: main

【将追加的静态路由】:
$(format_static_route_destinations_for_display "$destinations_csv")

【将执行的动作】:
  1. 在 main 表中为上述目的地址写入静态路由，出口与默认路由一致。
  2. 本地访问这些目的地址时优先按默认路由口出去，不走 tun。
  3. 写入规则文件: ${rules_file}
  4. 写入持久化脚本: ${script_file}
  5. 写入并启用 systemd 服务: ${service_file}
  6. 重启后自动恢复静态路由，避免配置丢失。
EOF
}

show_static_default_route_delete_detail() {
    local destinations_csv="$1"
    local delete_scope="$2"
    local rules_file script_file service_file

    rules_file=$(get_static_default_route_rules_file)
    script_file=$(get_static_default_route_script_file)
    service_file=$(get_static_default_route_service_file)

    cat <<EOF
------------------------------------------------------------
优化脚本 3: 静态路由默认出接口管理
------------------------------------------------------------
【将删除的静态路由】:
$(if [[ "$delete_scope" == "ALL" ]]; then echo "  - 全部静态路由"; else format_static_route_destinations_for_display "$destinations_csv"; fi)

【将执行的动作】:
  1. 删除对应的运行态静态路由。
  2. 更新规则文件: ${rules_file}
  3. 如已无静态路由，则删除持久化脚本和 systemd 服务:
     ${script_file}
     ${service_file}
EOF
}

write_static_default_route_persistence_from_rules() {
    local rules_file script_file service_file
    rules_file=$(get_static_default_route_rules_file)
    script_file=$(get_static_default_route_script_file)
    service_file=$(get_static_default_route_service_file)

    cat > "$script_file" <<EOF
#!/bin/sh
set -eu

RULES_FILE="${rules_file}"
OLD_SERVICE="$(get_legacy_default_ingress_service_file)"
OLD_SCRIPT="$(get_legacy_default_ingress_script_file)"

DEFAULT_DEV=\$(ip -o route show default 2>/dev/null | awk '
    {
        dev = ""; via = ""
        for (i = 1; i <= NF; i++) {
            if (\$i == "dev" && (i + 1) <= NF) dev = \$(i + 1)
            if (\$i == "via" && (i + 1) <= NF) via = \$(i + 1)
        }
        if (dev != "" && dev !~ /^(tun|docker|br-|veth|virbr|flannel|cni|wg)/) {
            print dev
            exit
        }
    }')

DEFAULT_GW=\$(ip -o route show default 2>/dev/null | awk '
    {
        dev = ""; via = ""
        for (i = 1; i <= NF; i++) {
            if (\$i == "dev" && (i + 1) <= NF) dev = \$(i + 1)
            if (\$i == "via" && (i + 1) <= NF) via = \$(i + 1)
        }
        if (dev != "" && dev !~ /^(tun|docker|br-|veth|virbr|flannel|cni|wg)/) {
            print via
            exit
        }
    }')

if [ -z "\$DEFAULT_DEV" ]; then
    echo "未识别到非隧道默认路由口，跳过"
    exit 0
fi

ip rule show 2>/dev/null \
    | awk '/iif [^[:space:]]+[[:space:]].* lookup main/ {sub(/:$/, "", \$1); if (\$1 ~ /^[0-9]+$/) print \$1}' \
    | sort -rn \
    | while read -r pref; do
        [ -n "\$pref" ] || continue
        ip rule del pref "\$pref" 2>/dev/null || true
    done

if [ -f "\$OLD_SERVICE" ]; then
    systemctl disable --now \"\$(basename \"\$OLD_SERVICE\")\" 2>/dev/null || true
    rm -f "\$OLD_SERVICE"
fi
rm -f "\$OLD_SCRIPT"
systemctl daemon-reload 2>/dev/null || true

if [ ! -s "\$RULES_FILE" ]; then
    echo "无静态路由配置，跳过"
    exit 0
fi

while read -r destination; do
    [ -n "\$destination" ] || continue
    case "\$destination" in \#*) continue ;; esac
    if [ -n "\$DEFAULT_GW" ]; then
        ip route replace "\$destination" via "\$DEFAULT_GW" dev "\$DEFAULT_DEV"
    else
        ip route replace "\$destination" dev "\$DEFAULT_DEV"
    fi
done < "\$RULES_FILE"

ip route flush cache 2>/dev/null || true
EOF
    chmod +x "$script_file"

    cat > "$service_file" <<EOF
[Unit]
Description=Feilian CPE static routes via default WAN
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_file}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable feilian-default-egress-static-routes.service >/dev/null 2>&1 || return 1
    systemctl restart feilian-default-egress-static-routes.service || {
        systemctl --no-pager --full status feilian-default-egress-static-routes.service 2>/dev/null | tail -80 || true
        return 1
    }
}

cleanup_legacy_default_ingress_artifacts() {
    local legacy_script legacy_service
    legacy_script=$(get_legacy_default_ingress_script_file)
    legacy_service=$(get_legacy_default_ingress_service_file)

    remove_legacy_default_ingress_main_rules
    systemctl disable --now feilian-default-ingress-main-route.service 2>/dev/null || true
    rm -f "$legacy_service"
    rm -f "$legacy_script"
    systemctl daemon-reload 2>/dev/null || true
}

sync_static_default_route_runtime() {
    local old_destinations_csv="${1:-}"
    local new_destinations_csv="${2:-}"
    local default_dev="$3"
    local default_gw="$4"
    cleanup_legacy_default_ingress_artifacts
    remove_static_default_route_destinations_from_main "$old_destinations_csv"
    apply_static_default_route_destinations_to_main "$new_destinations_csv" "$default_dev" "$default_gw" || return 1
    ip route flush cache 2>/dev/null || true
}

remove_static_default_route_runtime_and_persistence() {
    local old_destinations_csv="${1:-}"
    local rules_file script_file service_file

    rules_file=$(get_static_default_route_rules_file)
    script_file=$(get_static_default_route_script_file)
    service_file=$(get_static_default_route_service_file)

    cleanup_legacy_default_ingress_artifacts
    remove_static_default_route_destinations_from_main "$old_destinations_csv"
    systemctl disable --now feilian-default-egress-static-routes.service 2>/dev/null || true
    rm -f "$service_file"
    rm -f "$script_file"
    rm -f "$rules_file"
    systemctl daemon-reload
    ip route flush cache 2>/dev/null || true
}

apply_static_default_route_rules() {
    local old_destinations_csv="${1:-}"
    local new_destinations_csv
    local default_dev default_gw destination route_line

    default_dev=$(get_default_route_field dev)
    default_gw=$(get_default_route_field via)
    new_destinations_csv=$(get_static_default_route_destinations_csv)

    [[ -n "$default_dev" ]] || {
        echo "未识别到非隧道默认路由口"
        return 1
    }

    if [[ -z "$new_destinations_csv" ]]; then
        remove_static_default_route_runtime_and_persistence "$old_destinations_csv"
        echo -e "${YELLOW}当前已无静态路由配置，已清理运行态和持久化。${NC}"
        return 0
    fi

    sync_static_default_route_runtime "$old_destinations_csv" "$new_destinations_csv" "$default_dev" "$default_gw" || return 1
    write_static_default_route_persistence_from_rules || return 1

    local old_ifs="$IFS"
    IFS=','
    read -r -a STATIC_ROUTE_DEST_ITEMS <<< "$new_destinations_csv"
    IFS="$old_ifs"
    for destination in "${STATIC_ROUTE_DEST_ITEMS[@]}"; do
        [[ -n "$destination" ]] || continue
        route_line=$(find_static_default_route_in_table "main" "$destination")
        [[ -n "$route_line" ]] || {
            echo "未检测到运行态静态路由: table=main destination=${destination}"
            return 1
        }
    done
    return 0
}

show_static_default_route_optimizer_detail() {
    cat <<EOF
------------------------------------------------------------
优化脚本 3: 静态路由默认出接口管理
------------------------------------------------------------
【适用场景】:
  - 需要将指定目的IP或网段固定从默认路由口出去。
  - 本地访问这些目的地址时优先走默认路由，不走 tun。

【能力说明】:
  - 检查当前静态路由配置和 main 表运行态。
  - 追加新的静态路由。
  - 删除指定静态路由或全部静态路由。
  - 写入 systemd 持久化，重启后自动恢复配置。
EOF
}

run_default_ingress_route_optimizer() {
    local action input destinations_csv old_destinations_csv new_destinations_csv delete_scope
    local rules_file backup_file

    rules_file=$(get_static_default_route_rules_file)
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
        echo -e "${BOLD}${WHITE} 静态路由默认出接口管理${NC}"
        echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
        show_static_default_route_status
        echo ""
        echo -e "${GREEN}  1. 检查现有配置${NC}"
        echo -e "${GREEN}  2. 追加静态路由${NC}"
        echo -e "${GREEN}  3. 删除静态路由${NC}"
        echo -e "${WHITE}  0. 返回/退出${NC}"
        printf "%b" "${BOLD}请选择操作 [0-3，直接回车保持当前菜单]: ${NC}"
        read -r action || action=""
        if [[ -z "$action" ]]; then
            continue
        fi

        case "$action" in
            1)
                continue
                ;;
            2)
                while true; do
                    printf "%b" "${BOLD}请输入静态路由目标IP或网段，多个用逗号分隔: ${NC}"
                    read -r input || input=""
                    if [[ -z "$input" ]]; then
                        echo -e "${YELLOW}未输入静态路由目标，请继续输入。${NC}"
                        continue
                    fi
                    if destinations_csv=$(normalize_static_route_destinations "$input"); then
                        break
                    fi
                    echo -e "${RED}静态路由格式无效，请输入 192.0.2.10 或 198.51.100.0/24 这种格式。${NC}"
                done
                if ! validate_static_route_destinations_not_exist "$destinations_csv"; then
                    continue
                fi
                show_static_default_route_add_detail "$destinations_csv"
                echo ""
                if ! confirm_y_or_cancel "输入 y/Y 确认追加，直接回车保持当前确认项，输入其他任意内容取消: "; then
                    echo -e "${YELLOW}已取消追加。${NC}"
                    continue
                fi
                if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
                    echo -e "${RED}执行失败: 该功能需要 root 权限，请先 sudo -s 后重新执行。${NC}"
                    continue
                fi
                old_destinations_csv=$(get_static_default_route_destinations_csv)
                backup_file=$(mktemp)
                [[ -f "$rules_file" ]] && cp "$rules_file" "$backup_file" || : > "$backup_file"
                new_destinations_csv=$(merge_static_route_destinations_csv "$old_destinations_csv" "$destinations_csv")
                write_static_default_route_rules_from_csv "$new_destinations_csv"
                if ! apply_static_default_route_rules "$old_destinations_csv"; then
                    echo -e "${YELLOW}正在回滚到应用前的静态路由配置...${NC}"
                    if [[ -s "$backup_file" ]]; then
                        cp "$backup_file" "$rules_file"
                    else
                        rm -f "$rules_file"
                    fi
                    apply_static_default_route_rules "$new_destinations_csv" >/dev/null 2>&1 || true
                    rm -f "$backup_file"
                    echo -e "${RED}执行失败: 静态路由追加失败${NC}"
                    continue
                fi
                rm -f "$backup_file"
                show_static_default_route_status
                echo -e "${GREEN}静态路由已追加并持久化。${NC}"
                ;;
            3)
                delete_scope=""
                destinations_csv=""
                while true; do
                    echo ""
                    echo -e "${WHITE}请选择删除范围:${NC}"
                    echo -e "${GREEN}  1. 删除指定静态路由${NC}"
                    echo -e "${GREEN}  2. 删除全部静态路由${NC}"
                    echo -e "${WHITE}  0. 返回${NC}"
                    printf "%b" "${BOLD}请选择删除范围 [0-2，直接回车保持当前菜单]: ${NC}"
                    read -r input || input=""
                    if [[ -z "$input" ]]; then
                        continue
                    fi
                    case "$input" in
                        1)
                            while true; do
                                printf "%b" "${BOLD}请输入要删除的静态路由目标IP或网段，多个用逗号分隔: ${NC}"
                                read -r input || input=""
                                if [[ -z "$input" ]]; then
                                    echo -e "${YELLOW}未输入静态路由目标，请继续输入。${NC}"
                                    continue
                                fi
                                if destinations_csv=$(normalize_existing_static_route_destinations "$input"); then
                                    delete_scope="PART"
                                    break
                                fi
                                rc=$?
                                if [[ "$rc" -eq 2 ]]; then
                                    echo -e "${RED}存在未配置的静态路由，请重新输入。${NC}"
                                else
                                    echo -e "${RED}静态路由格式无效，请重新输入。${NC}"
                                fi
                            done
                            break
                            ;;
                        2)
                            delete_scope="ALL"
                            destinations_csv=$(get_static_default_route_destinations_csv)
                            if [[ -z "$destinations_csv" ]]; then
                                echo -e "${YELLOW}当前没有可删除的静态路由。${NC}"
                                delete_scope=""
                                break
                            fi
                            break
                            ;;
                        0|q|Q|exit)
                            delete_scope="CANCEL"
                            break
                            ;;
                        *)
                            echo -e "${RED}无效选项: ${input:-空}，请输入 0、1 或 2。${NC}"
                            ;;
                    esac
                done
                [[ "$delete_scope" == "CANCEL" || -z "$delete_scope" ]] && continue
                show_static_default_route_delete_detail "$destinations_csv" "$delete_scope"
                echo ""
                if ! confirm_y_or_cancel "输入 y/Y 确认删除，直接回车保持当前确认项，输入其他任意内容取消: "; then
                    echo -e "${YELLOW}已取消删除。${NC}"
                    continue
                fi
                if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
                    echo -e "${RED}执行失败: 该功能需要 root 权限，请先 sudo -s 后重新执行。${NC}"
                    continue
                fi
                old_destinations_csv=$(get_static_default_route_destinations_csv)
                backup_file=$(mktemp)
                [[ -f "$rules_file" ]] && cp "$rules_file" "$backup_file" || : > "$backup_file"
                if [[ "$delete_scope" == "ALL" ]]; then
                    new_destinations_csv=""
                else
                    new_destinations_csv=$(subtract_static_route_destinations_csv "$old_destinations_csv" "$destinations_csv")
                fi
                write_static_default_route_rules_from_csv "$new_destinations_csv"
                if ! apply_static_default_route_rules "$old_destinations_csv"; then
                    echo -e "${YELLOW}正在回滚到应用前的静态路由配置...${NC}"
                    if [[ -s "$backup_file" ]]; then
                        cp "$backup_file" "$rules_file"
                    else
                        rm -f "$rules_file"
                    fi
                    apply_static_default_route_rules "$new_destinations_csv" >/dev/null 2>&1 || true
                    rm -f "$backup_file"
                    echo -e "${RED}执行失败: 静态路由删除失败${NC}"
                    continue
                fi
                rm -f "$backup_file"
                show_static_default_route_status
                echo -e "${GREEN}静态路由已删除并同步持久化。${NC}"
                ;;
            0|q|Q|exit)
                echo -e "${YELLOW}未执行任何静态路由变更。${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}无效选项: ${action:-空}，请输入 0、1、2 或 3。${NC}"
                ;;
        esac
    done
}

validate_tcp_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]]
}

normalize_tcp_proxy_mappings() {
    local raw="$1"
    local item backend_port local_port
    local normalized=""

    raw=${raw//，/,}
    raw=${raw// /}
    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$raw"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        [[ -n "$item" ]] || continue
        backend_port="${item%%:*}"
        local_port="${item#*:}"
        if [[ "$backend_port" == "$local_port" ]] || ! validate_tcp_port "$backend_port" || ! validate_tcp_port "$local_port"; then
            return 1
        fi
        normalized+="${backend_port}:${local_port},"
    done
    normalized="${normalized%,}"
    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

is_tcp_proxy_local_port_used() {
    local port="$1"
    local extra_used="${2:-}"
    local rules_file

    case ",${extra_used}," in
        *,"${port}",*) return 0 ;;
    esac
    rules_file=$(get_tcp_proxy_rules_file)
    if [[ -f "$rules_file" ]] && awk -v port="$port" 'NF >= 3 && $3 == port {found=1} END {exit found ? 0 : 1}' "$rules_file"; then
        return 0
    fi
    ss -lnt 2>/dev/null | awk -v port="$port" '
        {
            local_addr=$4
            n=split(local_addr, parts, ":")
            if (parts[n] == port) found=1
        }
        END {exit found ? 0 : 1}'
}

allocate_tcp_proxy_local_port() {
    local extra_used="${1:-}"
    local port=20000

    while [[ "$port" -le 65535 ]]; do
        if ! is_tcp_proxy_local_port_used "$port" "$extra_used"; then
            printf '%s\n' "$port"
            return 0
        fi
        port=$((port + 1))
    done
    return 1
}

normalize_tcp_proxy_backend_ports() {
    local raw="$1"
    local item backend_port local_port
    local normalized=""
    local allocated_ports=""
    local backend_ports=""

    raw=${raw//，/,}
    raw=$(printf '%s' "$raw" | tr -d '[:space:]' | sed 's/　//g')
    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$raw"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        [[ -n "$item" ]] || continue
        backend_port="$item"
        if ! validate_tcp_port "$backend_port"; then
            return 1
        fi
        case ",${backend_ports}," in
            *,"${backend_port}",*) return 1 ;;
        esac
        backend_ports+="${backend_ports:+,}${backend_port}"
        local_port=$(allocate_tcp_proxy_local_port "$allocated_ports") || return 2
        allocated_ports+="${allocated_ports:+,}${local_port}"
        normalized+="${backend_port}:${local_port},"
    done
    normalized="${normalized%,}"
    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

normalize_tcp_proxy_existing_backend_ports() {
    local target_ip="$1"
    local raw="$2"
    local rules_file item backend_port local_port
    local normalized=""

    rules_file=$(get_tcp_proxy_rules_file)
    raw=${raw//，/,}
    raw=$(printf '%s' "$raw" | tr -d '[:space:]' | sed 's/　//g')
    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$raw"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        [[ -n "$item" ]] || continue
        backend_port="$item"
        validate_tcp_port "$backend_port" || return 1
        local_port=$(awk -v ip="$target_ip" -v backend="$backend_port" 'NF >= 3 && $1 == ip && $2 == backend {print $3; exit}' "$rules_file" 2>/dev/null)
        [[ -n "$local_port" ]] || return 2
        normalized+="${backend_port}:${local_port},"
    done
    normalized="${normalized%,}"
    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

prompt_tcp_proxy_config() {
    local input normalized rc

    TCP_PROXY_TARGET_IP=""
    TCP_PROXY_MAPPINGS=""

    while [[ -z "$TCP_PROXY_TARGET_IP" ]]; do
        printf "%b" "${BOLD}请输入透明代理目标IP: ${NC}"
        read -r input || input=""
        input=$(normalize_ipv4_input "$input")
        if [[ -z "$input" ]]; then
            echo -e "${YELLOW}未输入目标IP，请继续输入。${NC}"
            continue
        fi
        if validate_ipv4 "$input"; then
            TCP_PROXY_TARGET_IP="$input"
        else
            echo -e "${RED}目标IP格式无效，请重新输入。${NC}"
        fi
    done

    while [[ -z "$TCP_PROXY_MAPPINGS" ]]; do
        printf "%b" "${BOLD}请输入透明代理目标端口，多个用逗号分隔: ${NC}"
        read -r input || input=""
        if [[ -z "$input" ]]; then
            echo -e "${YELLOW}未输入目标端口，请继续输入。${NC}"
            continue
        fi
        normalized=$(normalize_tcp_proxy_backend_ports "$input")
        rc=$?
        if [[ "$rc" -eq 0 ]]; then
            TCP_PROXY_MAPPINGS="$normalized"
        elif [[ "$rc" -eq 2 ]]; then
            echo -e "${RED}未找到可用本地代理端口，请检查已有透明代理规则和系统监听端口。${NC}"
        else
            echo -e "${RED}目标端口格式无效或重复，多个端口请使用 995,587 这种格式；本地端口将从20000开始自动分配。${NC}"
        fi
    done
}

show_tcp_transparent_proxy_optimizer_detail() {
    local target_ip="$1"
    local mappings="$2"
    local item backend_port local_port

    cat <<EOF
------------------------------------------------------------
优化脚本 4: TCP透明代理(iptables REDIRECT + Nginx stream)
------------------------------------------------------------
【适用场景】:
  - 需要对从 tun0_master/tun0_slave 隧道进入的指定目的IP和TCP端口做透明代理。
  - 仅代理匹配目标IP和端口的隧道入站流量，不影响公网入口和其他调度业务。

【当前配置】:
  - 目标IP: ${target_ip}
  - 隧道入口: tun0_master, tun0_slave
  - 自定义链: FEILIAN_T_PROXY(脚本专用链，不改动已有iptables链)
  - 端口映射(本地监听端口自动分配):
EOF
    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        backend_port="${item%%:*}"
        local_port="${item#*:}"
        echo "    ${target_ip}:${backend_port} -> 127.0.0.1:${local_port}"
    done

    cat <<'EOF'

【将执行的动作】:
  1. 自动安装 nginx 及 stream 模块(apt/yum/dnf 环境自动适配)。
  2. 写入独立 Nginx stream 配置:
     /etc/nginx/feilian-tcp-transparent-proxy.conf
  3. 写入并启用独立 Nginx systemd 服务:
     /etc/systemd/system/feilian-tcp-transparent-proxy-nginx.service
  4. 写入 iptables 持久化脚本:
     /usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh
  5. 写入并启用 iptables 开机恢复服务:
     /etc/systemd/system/feilian-tcp-transparent-proxy-iptables.service
  6. 核对监听端口、iptables NAT规则和服务状态。

【iptables逻辑】:
  - PREROUTING 先跳转到 FEILIAN_T_PROXY 脚本专用链。
  - 仅匹配 -i tun0_master/tun0_slave、目标IP、TCP目标端口。
  - 命中后 REDIRECT 到本地 Nginx 监听端口。
EOF
}

install_nginx_for_tcp_proxy() {
    if command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y nginx libnginx-mod-stream || apt-get install -y nginx
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx nginx-mod-stream || dnf install -y nginx
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nginx nginx-mod-stream || yum install -y nginx
    else
        echo "未找到 apt-get/dnf/yum，无法自动安装 nginx"
        return 1
    fi
}

write_tcp_proxy_nginx_config() {
    local target_ip="$1"
    local mappings="$2"
    local config_file="/etc/nginx/feilian-tcp-transparent-proxy.conf"
    local item backend_port local_port upstream_name

    {
        cat <<'EOF'
worker_processes auto;
pid /run/feilian-tcp-transparent-proxy-nginx.pid;
error_log /var/log/nginx/feilian_tcp_proxy_error.log;
EOF
        if [[ -f /etc/nginx/modules-enabled/50-mod-stream.conf ]]; then
            echo "include /etc/nginx/modules-enabled/50-mod-stream.conf;"
        elif [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
            echo "load_module modules/ngx_stream_module.so;"
        fi
        cat <<'EOF'

events {
    worker_connections 10240;
}

stream {
    log_format feilian_tcp_proxy '$remote_addr:$remote_port -> $server_addr:$server_port '
                                 'upstream=$upstream_addr status=$status '
                                 'bytes_sent=$bytes_sent bytes_received=$bytes_received '
                                 'session_time=$session_time';
    access_log /var/log/nginx/feilian_tcp_proxy_access.log feilian_tcp_proxy;

EOF
        IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
        for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
            backend_port="${item%%:*}"
            local_port="${item#*:}"
            upstream_name="feilian_tcp_backend_${backend_port}"
            cat <<EOF
    upstream ${upstream_name} {
        server ${target_ip}:${backend_port};
    }

    server {
        listen 0.0.0.0:${local_port} reuseport so_keepalive=on;
        proxy_connect_timeout 5s;
        proxy_timeout 10m;
        proxy_pass ${upstream_name};
    }

EOF
        done
        echo "}"
    } > "$config_file"
}

get_tcp_proxy_rules_file() {
    echo "/etc/feilian-tcp-transparent-proxy.rules"
}

import_legacy_tcp_proxy_rules() {
    local rules_file
    local script_file="/usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh"
    local target_ip mappings item backend_port local_port

    rules_file=$(get_tcp_proxy_rules_file)
    [[ -s "$rules_file" ]] && return 0
    [[ -f "$script_file" ]] || return 0

    target_ip=$(sed -nE 's/^TARGET_IP="([^"]+)".*/\1/p' "$script_file" | head -n 1)
    mappings=$(sed -nE 's/^MAPPINGS="([^"]+)".*/\1/p' "$script_file" | head -n 1)
    [[ -n "$target_ip" && -n "$mappings" ]] || return 0

    mkdir -p "$(dirname "$rules_file")"
    : > "$rules_file"
    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        backend_port="${item%%:*}"
        local_port="${item#*:}"
        if validate_ipv4 "$target_ip" && validate_tcp_port "$backend_port" && validate_tcp_port "$local_port"; then
            echo "${target_ip} ${backend_port} ${local_port}" >> "$rules_file"
        fi
    done
    sort -u "$rules_file" -o "$rules_file"
}

append_tcp_proxy_rules() {
    local target_ip="$1"
    local mappings="$2"
    local rules_file item backend_port local_port

    rules_file=$(get_tcp_proxy_rules_file)
    mkdir -p "$(dirname "$rules_file")"
    touch "$rules_file"
    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        backend_port="${item%%:*}"
        local_port="${item#*:}"
        grep -Eq "^${target_ip}[[:space:]]+${backend_port}[[:space:]]+${local_port}$" "$rules_file" 2>/dev/null \
            || echo "${target_ip} ${backend_port} ${local_port}" >> "$rules_file"
    done
    sort -u "$rules_file" -o "$rules_file"
}

validate_tcp_proxy_local_port_uniqueness() {
    local target_ip="${1:-}"
    local mappings="${2:-}"
    local rules_file item backend_port local_port existing
    local tmp_rules

    rules_file=$(get_tcp_proxy_rules_file)
    tmp_rules=$(mktemp /tmp/feilian_tcp_proxy_rules.XXXXXX 2>/dev/null || echo "/tmp/feilian_tcp_proxy_rules.$$")
    [[ -f "$rules_file" ]] && cat "$rules_file" > "$tmp_rules" || : > "$tmp_rules"
    if [[ -n "$target_ip" && -n "$mappings" ]]; then
        IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
        for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
            backend_port="${item%%:*}"
            local_port="${item#*:}"
            grep -Eq "^${target_ip}[[:space:]]+${backend_port}[[:space:]]+${local_port}$" "$tmp_rules" 2>/dev/null \
                || echo "${target_ip} ${backend_port} ${local_port}" >> "$tmp_rules"
        done
    fi

    existing=$(awk '
        NF >= 3 {
            key = $3
            rule = $1 ":" $2 " -> 127.0.0.1:" $3
            if (seen[key] != "" && seen[key] != rule) {
                conflict[key] = conflict[key] "\n    " seen[key] "\n    " rule
            }
            seen[key] = rule
        }
        END {
            for (key in conflict) {
                print "本地端口 " key " 存在重复监听配置:" conflict[key]
            }
        }' "$tmp_rules")
    rm -f "$tmp_rules"
    if [[ -n "$existing" ]]; then
        printf '%s\n' "$existing"
        return 1
    fi
    return 0
}

validate_tcp_proxy_backend_rule_not_exists() {
    local target_ip="$1"
    local mappings="$2"
    local rules_file item backend_port existing

    rules_file=$(get_tcp_proxy_rules_file)
    [[ -f "$rules_file" ]] || return 0
    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        backend_port="${item%%:*}"
        existing=$(awk -v ip="$target_ip" -v backend="$backend_port" 'NF >= 3 && $1 == ip && $2 == backend {print $1 ":" $2 " -> 127.0.0.1:" $3; exit}' "$rules_file")
        if [[ -n "$existing" ]]; then
            echo "目标 ${target_ip}:${backend_port} 已存在透明代理规则: ${existing}"
            return 1
        fi
    done
    return 0
}

validate_tcp_proxy_new_local_ports_available() {
    local mappings="$1"
    local item local_port

    IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
    for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
        local_port="${item#*:}"
        if is_tcp_proxy_local_port_used "$local_port"; then
            echo "本地代理端口 ${local_port} 已被已有规则或系统监听端口占用"
            return 1
        fi
    done
    return 0
}

delete_tcp_proxy_rules() {
    local target_ip="$1"
    local mappings="$2"
    local rules_file tmp_file item backend_port local_port

    rules_file=$(get_tcp_proxy_rules_file)
    [[ -f "$rules_file" ]] || return 0
    tmp_file="${rules_file}.tmp.$$"
    cp "$rules_file" "$tmp_file"
    if [[ "$mappings" == "ALL" ]]; then
        awk -v ip="$target_ip" '$1 != ip' "$tmp_file" > "$rules_file"
    else
        IFS=',' read -r -a TCP_PROXY_MAPPING_ITEMS <<< "$mappings"
        for item in "${TCP_PROXY_MAPPING_ITEMS[@]}"; do
            backend_port="${item%%:*}"
            local_port="${item#*:}"
            awk -v ip="$target_ip" -v bp="$backend_port" -v lp="$local_port" \
                '!(($1 == ip) && ($2 == bp) && ($3 == lp))' "$rules_file" > "$tmp_file"
            mv "$tmp_file" "$rules_file"
            tmp_file="${rules_file}.tmp.$$"
        done
    fi
    rm -f "$tmp_file"
    [[ -s "$rules_file" ]] || rm -f "$rules_file"
}

format_tcp_proxy_rules_for_display() {
    local rules_file
    rules_file=$(get_tcp_proxy_rules_file)
    import_legacy_tcp_proxy_rules
    if [[ ! -s "$rules_file" ]]; then
        echo "  未发现已配置的TCP透明代理规则"
        return 0
    fi
    awk '
        NF >= 3 {
            printf "  - %s:%s -> 127.0.0.1:%s\n", $1, $2, $3
        }' "$rules_file"
}

write_tcp_proxy_nginx_config_from_rules() {
    local rules_file
    local config_file="/etc/nginx/feilian-tcp-transparent-proxy.conf"
    local target_ip backend_port local_port upstream_name safe_ip

    rules_file=$(get_tcp_proxy_rules_file)
    [[ -s "$rules_file" ]] || return 1
    {
        cat <<'EOF'
worker_processes auto;
pid /run/feilian-tcp-transparent-proxy-nginx.pid;
error_log /var/log/nginx/feilian_tcp_proxy_error.log;
EOF
        if [[ -f /etc/nginx/modules-enabled/50-mod-stream.conf ]]; then
            echo "include /etc/nginx/modules-enabled/50-mod-stream.conf;"
        elif [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]]; then
            echo "load_module modules/ngx_stream_module.so;"
        fi
        cat <<'EOF'

events {
    worker_connections 10240;
}

stream {
    log_format feilian_tcp_proxy '$remote_addr:$remote_port -> $server_addr:$server_port '
                                 'upstream=$upstream_addr status=$status '
                                 'bytes_sent=$bytes_sent bytes_received=$bytes_received '
                                 'session_time=$session_time';
    access_log /var/log/nginx/feilian_tcp_proxy_access.log feilian_tcp_proxy;

EOF
        while read -r target_ip backend_port local_port; do
            [[ -n "$target_ip" && -n "$backend_port" && -n "$local_port" ]] || continue
            safe_ip=${target_ip//./_}
            upstream_name="feilian_tcp_backend_${safe_ip}_${backend_port}_${local_port}"
            cat <<EOF
    upstream ${upstream_name} {
        server ${target_ip}:${backend_port};
    }

    server {
        listen 0.0.0.0:${local_port} reuseport so_keepalive=on;
        proxy_connect_timeout 5s;
        proxy_timeout 10m;
        proxy_pass ${upstream_name};
    }

EOF
        done < "$rules_file"
        echo "}"
    } > "$config_file"
}

write_tcp_proxy_nginx_service() {
    local service_file="/etc/systemd/system/feilian-tcp-transparent-proxy-nginx.service"
    cat > "$service_file" <<'EOF'
[Unit]
Description=Feilian TCP transparent proxy nginx stream service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/nginx -c /etc/nginx/feilian-tcp-transparent-proxy.conf -g 'daemon off;'
ExecReload=/usr/sbin/nginx -c /etc/nginx/feilian-tcp-transparent-proxy.conf -s reload
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

write_tcp_proxy_iptables_persistence() {
    local target_ip="$1"
    local mappings="$2"
    local script_file="/usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh"
    local service_file="/etc/systemd/system/feilian-tcp-transparent-proxy-iptables.service"

    cat > "$script_file" <<EOF
#!/bin/sh
set -eu

TARGET_IP="${target_ip}"
MAPPINGS="${mappings}"
TUN_IFACES="tun0_master tun0_slave"
CHAIN="FEILIAN_T_PROXY"

iptables -t nat -N "\$CHAIN" 2>/dev/null || true
iptables -t nat -C PREROUTING -j "\$CHAIN" 2>/dev/null || iptables -t nat -A PREROUTING -j "\$CHAIN"

OLD_IFS="\$IFS"
IFS=","
for mapping in \$MAPPINGS; do
    backend_port="\${mapping%%:*}"
    local_port="\${mapping#*:}"
    for iface in \$TUN_IFACES; do
        iptables -t nat -C "\$CHAIN" -d "\$TARGET_IP/32" -i "\$iface" -p tcp --dport "\$backend_port" -j REDIRECT --to-ports "\$local_port" 2>/dev/null \
            || iptables -t nat -A "\$CHAIN" -d "\$TARGET_IP/32" -i "\$iface" -p tcp --dport "\$backend_port" -j REDIRECT --to-ports "\$local_port"
    done
done
IFS="\$OLD_IFS"
EOF
    chmod +x "$script_file"

    cat > "$service_file" <<EOF
[Unit]
Description=Feilian TCP transparent proxy iptables restore
After=network-online.target feilian-tcp-transparent-proxy-nginx.service
Wants=network-online.target feilian-tcp-transparent-proxy-nginx.service

[Service]
Type=oneshot
ExecStart=${script_file}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_tcp_proxy_iptables_persistence_from_rules() {
    local script_file="/usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh"
    local service_file="/etc/systemd/system/feilian-tcp-transparent-proxy-iptables.service"
    local rules_file

    rules_file=$(get_tcp_proxy_rules_file)
    cat > "$script_file" <<EOF
#!/bin/sh
set -eu

RULES_FILE="${rules_file}"
TUN_IFACES="tun0_master tun0_slave"
CHAIN="FEILIAN_T_PROXY"

iptables -t nat -N "\$CHAIN" 2>/dev/null || true
iptables -t nat -C PREROUTING -j "\$CHAIN" 2>/dev/null || iptables -t nat -A PREROUTING -j "\$CHAIN"
iptables -t nat -F "\$CHAIN"

[ -s "\$RULES_FILE" ] || exit 0

while read -r target_ip backend_port local_port; do
    [ -n "\$target_ip" ] || continue
    case "\$target_ip" in \#*) continue ;; esac
    for iface in \$TUN_IFACES; do
        iptables -t nat -A "\$CHAIN" -d "\$target_ip/32" -i "\$iface" -p tcp --dport "\$backend_port" -j REDIRECT --to-ports "\$local_port"
    done
done < "\$RULES_FILE"
EOF
    chmod +x "$script_file"

    cat > "$service_file" <<EOF
[Unit]
Description=Feilian TCP transparent proxy iptables restore
After=network-online.target feilian-tcp-transparent-proxy-nginx.service
Wants=network-online.target feilian-tcp-transparent-proxy-nginx.service

[Service]
Type=oneshot
ExecStart=${script_file}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

test_tcp_proxy_nginx_config() {
    local output
    local code

    output=$(nginx -t -c /etc/nginx/feilian-tcp-transparent-proxy.conf 2>&1)
    code=$?
    printf '%s\n' "$output"
    if [[ "$code" -eq 0 ]]; then
        return 0
    fi
    # 某些低版本/裁剪版 nginx stream 模块在 -t 退出阶段可能段错误，但已明确输出 syntax is ok。
    if [[ "$code" -eq 139 ]] && printf '%s\n' "$output" | grep -q 'syntax is ok'; then
        echo "警告: nginx -t 已显示 syntax is ok，但退出码=139，继续通过 systemd 启动和端口监听做最终验证。"
        return 0
    fi
    return "$code"
}

remove_tcp_proxy_runtime_and_persistence_if_empty() {
    local rules_file
    rules_file=$(get_tcp_proxy_rules_file)
    [[ -s "$rules_file" ]] && return 0

    systemctl disable --now feilian-tcp-transparent-proxy-iptables.service 2>/dev/null || true
    systemctl disable --now feilian-tcp-transparent-proxy-nginx.service 2>/dev/null || true
    rm -f /etc/systemd/system/feilian-tcp-transparent-proxy-iptables.service
    rm -f /etc/systemd/system/feilian-tcp-transparent-proxy-nginx.service
    rm -f /usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh
    rm -f /etc/nginx/feilian-tcp-transparent-proxy.conf
    rm -f "$rules_file"
    if iptables -t nat -S FEILIAN_T_PROXY >/dev/null 2>&1; then
        while iptables -t nat -C PREROUTING -j FEILIAN_T_PROXY 2>/dev/null; do
            iptables -t nat -D PREROUTING -j FEILIAN_T_PROXY 2>/dev/null || break
        done
        iptables -t nat -F FEILIAN_T_PROXY 2>/dev/null || true
        iptables -t nat -X FEILIAN_T_PROXY 2>/dev/null || true
    fi
    systemctl daemon-reload
}

apply_tcp_proxy_rules() {
    local rules_file
    local missing_ports=""
    local local_port
    local wait_round
    rules_file=$(get_tcp_proxy_rules_file)
    if [[ ! -s "$rules_file" ]]; then
        remove_tcp_proxy_runtime_and_persistence_if_empty
        echo -e "${YELLOW}当前已无TCP透明代理规则，已清理服务、配置和iptables链。${NC}"
        return 0
    fi

    validate_tcp_proxy_local_port_uniqueness || return 1
    install_nginx_for_tcp_proxy || return 1
    write_tcp_proxy_nginx_config_from_rules || return 1
    test_tcp_proxy_nginx_config || return 1
    write_tcp_proxy_nginx_service
    write_tcp_proxy_iptables_persistence_from_rules
    systemctl daemon-reload
    systemctl enable feilian-tcp-transparent-proxy-nginx.service >/dev/null 2>&1 || return 1
    systemctl restart feilian-tcp-transparent-proxy-nginx.service || {
        systemctl --no-pager --full status feilian-tcp-transparent-proxy-nginx.service 2>/dev/null | tail -80 || true
        return 1
    }
    systemctl enable feilian-tcp-transparent-proxy-iptables.service >/dev/null 2>&1 || return 1
    systemctl restart feilian-tcp-transparent-proxy-iptables.service || {
        systemctl --no-pager --full status feilian-tcp-transparent-proxy-iptables.service 2>/dev/null | tail -80 || true
        return 1
    }

    for wait_round in 1 2 3 4 5; do
        missing_ports=""
        while read -r _target_ip _backend_port local_port; do
            [[ -n "$local_port" ]] || continue
            if ! ss -lnt 2>/dev/null | grep -Eq ":${local_port}\\b"; then
                missing_ports+="${local_port} "
            fi
        done < "$rules_file"
        [[ -z "$missing_ports" ]] && break
        sleep 1
    done
    if [[ -n "$missing_ports" ]]; then
        echo "透明代理本地监听端口未就绪: ${missing_ports}"
        systemctl --no-pager --full status feilian-tcp-transparent-proxy-nginx.service 2>/dev/null | tail -80 || true
        return 1
    fi
}

show_tcp_proxy_status() {
    local rules_file
    local svc_state
    local conflict_output
    rules_file=$(get_tcp_proxy_rules_file)
    import_legacy_tcp_proxy_rules
    echo "【已配置规则】:"
    format_tcp_proxy_rules_for_display
    echo ""
    echo "【配置冲突检查】:"
    if conflict_output=$(validate_tcp_proxy_local_port_uniqueness 2>&1); then
        echo "  未发现本地监听端口冲突"
    else
        printf '%s\n' "$conflict_output" | sed 's/^/  /'
        echo "  处理建议: 删除冲突目标IP或改用未占用的本地代理端口。"
    fi
    echo ""
    echo "【配置文件状态】:"
    echo "  - 规则文件: ${rules_file} $([[ -s "$rules_file" ]] && echo "存在" || echo "不存在/为空")"
    echo "  - Nginx配置: /etc/nginx/feilian-tcp-transparent-proxy.conf $([[ -f /etc/nginx/feilian-tcp-transparent-proxy.conf ]] && echo "存在" || echo "不存在")"
    echo "  - iptables脚本: /usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh $([[ -f /usr/local/sbin/feilian-tcp-transparent-proxy-iptables.sh ]] && echo "存在" || echo "不存在")"
    echo ""
    echo "【服务状态】:"
    svc_state=$(systemctl is-enabled feilian-tcp-transparent-proxy-nginx.service 2>/dev/null || true)
    echo "  - nginx enabled: ${svc_state:-未启用}"
    svc_state=$(systemctl is-active feilian-tcp-transparent-proxy-nginx.service 2>/dev/null || true)
    echo "  - nginx active: ${svc_state:-未运行}"
    svc_state=$(systemctl is-enabled feilian-tcp-transparent-proxy-iptables.service 2>/dev/null || true)
    echo "  - iptables enabled: ${svc_state:-未启用}"
    svc_state=$(systemctl is-active feilian-tcp-transparent-proxy-iptables.service 2>/dev/null || true)
    echo "  - iptables active: ${svc_state:-未运行}"
    echo ""
    echo "【iptables FEILIAN_T_PROXY】:"
    echo "  说明: 仅展示/维护脚本专用链，不修改系统已有iptables规则。"
    iptables -t nat -S FEILIAN_T_PROXY 2>/dev/null | sed 's/^/  /' || echo "  未发现FEILIAN_T_PROXY链"
    echo ""
    echo "【Nginx透明代理配置】:"
    if [[ -f /etc/nginx/feilian-tcp-transparent-proxy.conf ]]; then
        sed 's/^/  /' /etc/nginx/feilian-tcp-transparent-proxy.conf
    else
        echo "  未生成 /etc/nginx/feilian-tcp-transparent-proxy.conf"
    fi
}

run_tcp_transparent_proxy_optimizer() {
    local action confirm target_ip mappings delete_scope input
    local rules_file rules_backup

    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
        echo -e "${BOLD}${WHITE} TCP透明代理配置管理${NC}"
        echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
        show_tcp_proxy_status
        echo ""
        echo -e "${GREEN}  1. 检查现有配置${NC}"
        echo -e "${GREEN}  2. 追加透明代理配置${NC}"
        echo -e "${GREEN}  3. 删除透明代理配置${NC}"
        echo -e "${WHITE}  0. 返回/退出${NC}"
        printf "%b" "${BOLD}请选择操作 [0-3，直接回车保持当前菜单]: ${NC}"
        read -r action || action=""
        if [[ -z "$action" ]]; then
            continue
        fi

        case "$action" in
            1)
                continue
                ;;
            2)
                import_legacy_tcp_proxy_rules
                prompt_tcp_proxy_config
                target_ip="$TCP_PROXY_TARGET_IP"
                mappings="$TCP_PROXY_MAPPINGS"
                show_tcp_transparent_proxy_optimizer_detail "$target_ip" "$mappings"
                echo ""
                if ! confirm_y_or_cancel "输入 y/Y 确认追加，直接回车保持当前确认项，输入其他任意内容取消: "; then
                    echo -e "${YELLOW}已取消追加。${NC}"
                    continue
                fi
                if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
                    echo -e "${RED}执行失败: 该优化脚本需要 root 权限，请先 sudo -s 后重新执行。${NC}"
                    return 1
                fi
                if ! validate_tcp_proxy_local_port_uniqueness; then
                    echo -e "${RED}执行失败: 当前已有TCP透明代理本地端口冲突，请先通过删除配置清理冲突规则。${NC}"
                    return 1
                fi
                if ! validate_tcp_proxy_backend_rule_not_exists "$target_ip" "$mappings"; then
                    echo -e "${RED}执行失败: 目标IP和目标端口已存在透明代理配置，请先删除旧规则。${NC}"
                    return 1
                fi
                if ! validate_tcp_proxy_new_local_ports_available "$mappings"; then
                    echo -e "${RED}执行失败: 自动分配的本地代理端口已被占用，请重新追加以分配新的可用端口。${NC}"
                    return 1
                fi
                if ! validate_tcp_proxy_local_port_uniqueness "$target_ip" "$mappings"; then
                    echo -e "${RED}执行失败: 本地代理端口不能重复使用。请先删除旧规则，或换一个本地代理端口。${NC}"
                    return 1
                fi
                rules_file=$(get_tcp_proxy_rules_file)
                rules_backup="${rules_file}.bak.$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo unknown)"
                [[ -f "$rules_file" ]] && cp "$rules_file" "$rules_backup" || rm -f "$rules_backup"
                append_tcp_proxy_rules "$target_ip" "$mappings"
                echo -e "${WHITE}正在重新生成并应用 nginx/iptables 持久化配置...${NC}"
                apply_tcp_proxy_rules || {
                    if [[ -f "$rules_backup" ]]; then
                        mv "$rules_backup" "$rules_file"
                    else
                        rm -f "$rules_file"
                    fi
                    echo -e "${YELLOW}正在回滚到应用前的透明代理配置...${NC}"
                    apply_tcp_proxy_rules >/dev/null 2>&1 || echo -e "${YELLOW}警告: 自动回滚应用失败，请通过检查现有配置确认服务状态。${NC}"
                    echo -e "${RED}执行失败: TCP透明代理配置应用失败${NC}"
                    return 1
                }
                rm -f "$rules_backup"
                show_tcp_proxy_status
                echo -e "${GREEN}TCP透明代理配置已追加并持久化。${NC}"
                continue
                ;;
            3)
                import_legacy_tcp_proxy_rules
                echo ""
                echo "【删除范围】"
                echo "  1. 删除指定目标IP的全部透明代理规则"
                echo "  2. 删除指定目标IP下的指定端口映射"
                echo "  3. 删除全部TCP透明代理配置"
                echo "  0. 取消"
                printf "%b" "${BOLD}请选择删除范围 [0-3，直接回车保持当前菜单]: ${NC}"
                read -r delete_scope || delete_scope=""
                if [[ -z "$delete_scope" ]]; then
                    echo -e "${YELLOW}未选择删除范围，继续选择。${NC}"
                    continue
                fi
                case "$delete_scope" in
                    1)
                        TCP_PROXY_TARGET_IP=""
                        while [[ -z "$TCP_PROXY_TARGET_IP" ]]; do
                            printf "%b" "${BOLD}请输入要删除的目标IP: ${NC}"
                            read -r target_ip || target_ip=""
                            target_ip=$(normalize_ipv4_input "$target_ip")
                            if validate_ipv4 "$target_ip"; then
                                TCP_PROXY_TARGET_IP="$target_ip"
                            else
                                echo -e "${RED}目标IP格式无效，请重新输入。${NC}"
                            fi
                        done
                        target_ip="$TCP_PROXY_TARGET_IP"
                        mappings="ALL"
                        ;;
                    2)
                        TCP_PROXY_TARGET_IP=""
                        TCP_PROXY_MAPPINGS=""
                        while [[ -z "$TCP_PROXY_TARGET_IP" ]]; do
                            printf "%b" "${BOLD}请输入要删除的目标IP: ${NC}"
                            read -r target_ip || target_ip=""
                            target_ip=$(normalize_ipv4_input "$target_ip")
                            if validate_ipv4 "$target_ip"; then
                                TCP_PROXY_TARGET_IP="$target_ip"
                            else
                                echo -e "${RED}目标IP格式无效，请重新输入。${NC}"
                            fi
                        done
                        target_ip="$TCP_PROXY_TARGET_IP"
                        while [[ -z "$TCP_PROXY_MAPPINGS" ]]; do
                            printf "%b" "${BOLD}请输入要删除的透明代理目标端口，多个用逗号分隔: ${NC}"
                            read -r input || input=""
                            if [[ -z "$input" ]]; then
                                echo -e "${YELLOW}未输入目标端口，请继续输入。${NC}"
                                continue
                            fi
                            if mappings=$(normalize_tcp_proxy_existing_backend_ports "$target_ip" "$input"); then
                                TCP_PROXY_MAPPINGS="$mappings"
                            else
                                echo -e "${RED}未找到对应的目标IP/端口规则，请检查已配置规则后重新输入。${NC}"
                            fi
                        done
                        mappings="$TCP_PROXY_MAPPINGS"
                        ;;
                    3)
                        target_ip="ALL"
                        mappings="ALL"
                        ;;
                    *)
                        echo -e "${YELLOW}已取消删除。${NC}"
                        return 0
                        ;;
                esac
                echo ""
                echo -e "${YELLOW}即将删除TCP透明代理配置: 目标=${target_ip}, 映射=${mappings}${NC}"
                if ! confirm_y_or_cancel "输入 y/Y 确认删除，直接回车保持当前确认项，输入其他任意内容取消: "; then
                    echo -e "${YELLOW}已取消删除。${NC}"
                    continue
                fi
                if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
                    echo -e "${RED}执行失败: 该优化脚本需要 root 权限，请先 sudo -s 后重新执行。${NC}"
                    return 1
                fi
                if [[ "$target_ip" == "ALL" ]]; then
                    rm -f "$(get_tcp_proxy_rules_file)"
                else
                    delete_tcp_proxy_rules "$target_ip" "$mappings"
                fi
                echo -e "${WHITE}正在重新生成并应用 nginx/iptables 持久化配置...${NC}"
                apply_tcp_proxy_rules || {
                    echo -e "${RED}执行失败: TCP透明代理配置删除后应用失败${NC}"
                    return 1
                }
                show_tcp_proxy_status
                echo -e "${GREEN}TCP透明代理配置已删除并同步清理。${NC}"
                continue
                ;;
            0|q|Q|exit)
                echo -e "${YELLOW}未修改TCP透明代理配置。${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}无效选项: ${action:-空}，请输入 1、2、3 或 0。${NC}"
                ;;
        esac
    done
}

run_optimizer_menu() {
    if [[ "$OUTPUT_TERMINAL" != "true" || ! -t 0 ]]; then
        echo "CPE常见优化脚本需要交互确认，请在终端中执行: $0 --mode optimize"
        return 1
    fi

    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}============================================================${NC}"
        echo -e "${BOLD}${WHITE} CPE常见优化脚本 - 请选择优化动作${NC}"
        echo -e "${BOLD}${CYAN}============================================================${NC}"
        echo -e "${GREEN}  1. 清理已有的POP连接信息，重新选择POP点连接${NC}"
        echo -e "${GREEN}  2. 将自动选点修改为固定POP点${NC}"
        echo -e "${GREEN}  3. 静态路由默认出接口管理${NC}"
        echo -e "${GREEN}  4. TCP透明代理(iptables REDIRECT + Nginx stream)${NC}"
        echo -e "${WHITE}  0. 返回/退出${NC}"
        echo -e "${BOLD}${CYAN}------------------------------------------------------------${NC}"
        printf "%b" "${BOLD}请输入优化脚本序号 [0-4，直接回车保持当前菜单]: ${NC}"

        local choice
        read -r choice || choice=""
        if [[ -z "$choice" ]]; then
            continue
        fi
        case "$choice" in
            1)
                run_pop_reselect_optimizer || return $?
                continue
                ;;
            2)
                run_fixed_pop_optimizer || return $?
                continue
                ;;
            3)
                run_default_ingress_route_optimizer || return $?
                continue
                ;;
            4)
                run_tcp_transparent_proxy_optimizer || return $?
                continue
                ;;
            0|q|Q|exit)
                echo -e "${YELLOW}未执行任何优化脚本。${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}无效选项: ${choice:-空}，请输入 1、2、3、4 或 0。${NC}"
                ;;
        esac
    done
}

finish_text_report_capture() {
    local save_text_report="${1:-false}"
    local tmp_fifo="${2:-}"
    local fifo_pid="${3:-}"

    if [[ "$save_text_report" == "true" ]]; then
        echo ""
        echo -e "${GREEN}✅ 报告已保存至: ${CYAN}$OUTPUT_FILE${NC}"
        exec > /dev/null 2>&1
        sleep 0.2
        rm -f "$tmp_fifo"
        wait "$fifo_pid" 2>/dev/null || true
    fi
}

#===============================================================================
# 第一部分：Linux基础信息检查（含命令回显格式）
#===============================================================================

#===============================================================================
# 巡检项函数
# 约定：一个巡检项对应一个 check_* 函数，新增巡检项只需增加函数并在 run_all_checks 中编排。
#===============================================================================

check_os_kernel() {
    # 合并：操作系统+内核版本检查（命令只做数据采集，判断逻辑在脚本内）
    # 脚本内部智能检测内核版本并生成附加信息
    KERNEL_VER=$(uname -r | awk -F. '{print $1}')
    KERNEL_FULL=$(uname -r)
    if [[ "$KERNEL_VER" -le 3 ]]; then
        EXTRA_INFO="${YELLOW}◆ 内核版本警告: 检测到 ${RED}${KERNEL_FULL}${NC} (3.x)，${YELLOW}强烈建议升级至5.x LTS${NC}"
        KERNEL_CODE=2
    else
        EXTRA_INFO="${GREEN}◆ 内核版本检测: 当前内核 ${KERNEL_FULL} 符合要求(4.x/5.x)${NC}"
        KERNEL_CODE=0
    fi

    print_check "操作系统与内核版本" \
        "hostnamectl" \
        "成功输出完整系统信息（OS/内核/架构），内核版本应为4.x或5.x+" \
        "确认发行版为主流Linux（Debian/CentOS等），架构为x86_64" \
        "$EXTRA_INFO" \
        "$KERNEL_CODE"
}

check_system_performance() {
    # 系统性能检查（CPU/负载/内存/磁盘/Inode合并）
    PERF_CMD="cpu=\$(top -bn1 2>/dev/null | awk -F',' '/Cpu/ {for (i=1;i<=NF;i++) if (\$i ~ /id/) {gsub(/[^0-9.]/, \"\", \$i); printf \"%.1f\", 100-\$i; exit}}'); load=\$(awk '{print \$1}' /proc/loadavg 2>/dev/null); mem=\$(free -m 2>/dev/null | awk '/Mem:/ {if (\$2>0) printf \"%.1f%% (已用 %sMiB / 总计 %sMiB，可用 %sMiB)\", \$3/\$2*100, \$3, \$2, \$7}'); disk=\$(df -hP / 2>/dev/null | awk 'NR==2 {print \$5 \" (已用 \" \$3 \" / 总计 \" \$2 \"，可用 \" \$4 \")\"}'); inode=\$(df -Pi / 2>/dev/null | awk 'NR==2 {print \$5 \" (已用 \" \$3 \" / 总计 \" \$2 \"，可用 \" \$4 \")\"}'); printf '%s\n' \"CPU使用率: \${cpu:-获取失败}%\" \"1分钟负载: \${load:-获取失败}\" \"内存使用率: \${mem:-获取失败}\" \"磁盘使用率(/): \${disk:-获取失败}\" \"Inode使用率(/): \${inode:-获取失败}\""
    PERF_OUTPUT=$(eval "$PERF_CMD" 2>&1 || true)
    CPU_USAGE_NUM=$(top -bn1 2>/dev/null | awk -F',' '/Cpu/ {for (i=1;i<=NF;i++) if ($i ~ /id/) {gsub(/[^0-9.]/, "", $i); printf "%.1f", 100-$i; exit}}')
    CPU_USAGE_NUM=${CPU_USAGE_NUM:-100}
    LOAD_1MIN=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 99)
    MEM_USAGE_NUM=$(free -m 2>/dev/null | awk '/Mem:/ {if ($2 > 0) printf "%.1f", ($3/$2)*100; else print "100.0"}')
    MEM_USAGE_NUM=${MEM_USAGE_NUM:-100}
    DISK_USAGE_NUM=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5+0}')
    DISK_USAGE_NUM=${DISK_USAGE_NUM:-100}
    INODE_USAGE_NUM=$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5+0}')
    INODE_USAGE_NUM=${INODE_USAGE_NUM:-100}
    PERF_ISSUES=()
    compare_float_lt "$CPU_USAGE_NUM" "70" || PERF_ISSUES+=("CPU使用率${CPU_USAGE_NUM}%≥70%")
    compare_float_lt "$LOAD_1MIN" "2.0" || PERF_ISSUES+=("1分钟负载${LOAD_1MIN}≥2.0")
    compare_float_lt "$MEM_USAGE_NUM" "80" || PERF_ISSUES+=("内存使用率${MEM_USAGE_NUM}%≥80%")
    compare_float_lt "$DISK_USAGE_NUM" "80" || PERF_ISSUES+=("磁盘使用率${DISK_USAGE_NUM}%≥80%")
    compare_float_lt "$INODE_USAGE_NUM" "90" || PERF_ISSUES+=("Inode使用率${INODE_USAGE_NUM}%≥90%")
    if [[ "${#PERF_ISSUES[@]}" -eq 0 ]]; then
        PERF_EXTRA="${GREEN}◆ 判断原因: CPU ${CPU_USAGE_NUM}%<70%，负载 ${LOAD_1MIN}<2.0，内存 ${MEM_USAGE_NUM}%<80%，磁盘 ${DISK_USAGE_NUM}%<80%，Inode ${INODE_USAGE_NUM}%<90%${NC}"
        PERF_CODE=0
    else
        PERF_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${PERF_ISSUES[*]}")${NC}"
        PERF_CODE=1
    fi
    print_check "系统性能检查" \
        "$PERF_CMD" \
        "CPU使用率<70%，负载<2.0，内存使用率<80%，磁盘使用率<80%，Inode使用率<90%" \
        "请结合top/free/df结果排查高负载、高内存或磁盘空间不足问题" \
        "$PERF_EXTRA" \
        "$PERF_CODE" \
        "$PERF_OUTPUT"
}

check_time_sync() {
    # 本地时间同步检查（纯净命令 + 脚本内智能判断）
    PLATFORM_URL=$(sed -n 's/^url: //p' /opt/feilian/cpe/conf/config.yaml 2>/dev/null)
    TIME_SOURCE="${PLATFORM_URL}/api/open/v1/token"
    CURL_WAN_DEV=$(get_default_wan_dev)
    CURL_WAN_LABEL="${CURL_WAN_DEV:-未指定(未找到非tun默认路由)}"
    CURL_WAN_ARG=""
    [[ -n "$CURL_WAN_DEV" ]] && CURL_WAN_ARG="--interface $CURL_WAN_DEV"
    CURL_WAN_ARGS=()
    if [[ -n "$CURL_WAN_ARG" ]]; then
        read -r -a CURL_WAN_ARGS <<< "$CURL_WAN_ARG"
    fi
    SERVER_DATE=$(curl "${CURL_WAN_ARGS[@]}" -sIk --max-time 3 "$TIME_SOURCE" 2>/dev/null | grep -i '^date:' | cut -d' ' -f2- | tr -d '\r')
    LOCAL_TIME=$(date '+%Y-%m-%d %H:%M:%S %Z')
    LOCAL_TZ=$(date '+%Z %z')
    SERVER_TIME_LOCAL="获取失败"
    TIME_DIFF="N/A"

    if [[ -z "$SERVER_DATE" ]]; then
        TIME_EXTRA="${RED}◆ 时间检测失败: 无法获取服务端时间${NC}"
        TIME_CODE=1
    else
        SERVER_TIMESTAMP=$(date -d "$SERVER_DATE" +%s 2>/dev/null || echo "0")
        LOCAL_TIMESTAMP=$(date +%s)
        SERVER_TIME_LOCAL=$(date -d "$SERVER_DATE" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "解析失败")
        TIME_DIFF=$((SERVER_TIMESTAMP > LOCAL_TIMESTAMP ? SERVER_TIMESTAMP - LOCAL_TIMESTAMP : LOCAL_TIMESTAMP - SERVER_TIMESTAMP))

        if [[ "$TIME_DIFF" -gt 30 ]]; then
            TIME_EXTRA="${RED}◆ 时间异常: 偏差 ${TIME_DIFF}秒 > 30秒阈值，需检查NTP配置${NC}"
            TIME_CODE=1
        else
            TIME_EXTRA="${GREEN}◆ 时间正常: 偏差 ${TIME_DIFF}秒 (≤30秒)${NC}"
            TIME_CODE=0
        fi
    fi

    TIME_DETAIL_CMD="u=\$(sed -n 's/^url: //p' /opt/feilian/cpe/conf/config.yaml 2>/dev/null); src=\"\${u}/api/open/v1/token\"; d=\$(curl ${CURL_WAN_ARG} -sIk --max-time 3 \"\$src\" 2>/dev/null | grep -i '^date:' | cut -d' ' -f2- | tr -d '\r'); lt=\$(date '+%Y-%m-%d %H:%M:%S %Z'); tz=\$(date '+%Z %z'); if [ -n \"\$d\" ]; then sl=\$(date -d \"\$d\" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo '解析失败'); st=\$(date -d \"\$d\" +%s 2>/dev/null || echo 0); now=\$(date +%s); diff=\$((st>now?st-now:now-st)); else sl='获取失败'; diff='N/A'; fi; printf '%s\n' \"curl出接口: ${CURL_WAN_LABEL}\" \"服务端时间: \${d:-获取失败}\" \"服务端时间(本地时区): \$sl\" \"本地时间: \$lt\" \"本地时区: \$tz\" \"时间偏差: \${diff}秒\" \"允许阈值: 30秒\" \"时间源: \$src\""

    print_check "本地时间同步状态" \
        "$TIME_DETAIL_CMD" \
        "本地时间应与管理平台时间同步，偏差<30秒" \
        "如时间不同步，请检查NTP服务或手动校准" \
        "$TIME_EXTRA" \
        "$TIME_CODE"
}

check_network_interfaces() {
    # 网络接口状态检查（默认出口接口 + CPE主备隧道）
    NET_WAN_DEV=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    NET_IF_CMD="wan=\$(ip route show default 2>/dev/null | awk '{print \$5; exit}'); for dev in \$wan tun0_master tun0_slave; do [ -n \"\$dev\" ] || continue; echo \"=== \$dev ===\"; if ip link show \"\$dev\" >/dev/null 2>&1; then flags=\$(ip -o link show dev \"\$dev\" | sed -n 's/.*<\\([^>]*\\)>.*/\\1/p'); oper=\$(cat /sys/class/net/\$dev/operstate 2>/dev/null || echo unknown); ipv4=\$(ip -o -4 addr show dev \"\$dev\" 2>/dev/null | awk '{print \$4}' | paste -sd, -); rxerr=\$(cat /sys/class/net/\$dev/statistics/rx_errors 2>/dev/null || echo 0); txerr=\$(cat /sys/class/net/\$dev/statistics/tx_errors 2>/dev/null || echo 0); rxdrop=\$(cat /sys/class/net/\$dev/statistics/rx_dropped 2>/dev/null || echo 0); txdrop=\$(cat /sys/class/net/\$dev/statistics/tx_dropped 2>/dev/null || echo 0); note=''; echo \"\$dev\" | grep -q '^tun' && [ \"\$oper\" = 'unknown' ] && note=' (隧道接口常见，按UP标记判断)'; verdict='正常'; echo \"\$flags\" | grep -qw 'UP' || verdict='异常: 未UP'; { [ \"\${rxerr:-0}\" -eq 0 ] && [ \"\${txerr:-0}\" -eq 0 ]; } || verdict='异常: 存在错误计数'; if echo \"\$dev\" | grep -q '^tun0_'; then echo \"\$ipv4\" | grep -Eq '(^|,)169\\.254\\.[0-9]{1,3}\\.[0-9]{1,3}/[0-9]+' || verdict='异常: 隧道IP非169.254.x.x'; fi; printf '%s\n' \"状态标记: \$flags\" \"运行状态: \$oper\$note\" \"IPv4地址: \${ipv4:-无}\" \"错误计数: RX=\$rxerr, TX=\$txerr\" \"丢包计数: RX=\$rxdrop, TX=\$txdrop\" \"状态判定: \$verdict\"; else echo '接口不存在'; fi; done"
    NET_IF_OUTPUT=$(eval "$NET_IF_CMD" 2>&1 || true)
    NET_IF_ISSUES=()
    NET_IF_OK=()
    NET_CHECKED_DEVS=()
    if [[ -z "$NET_WAN_DEV" ]]; then
        NET_IF_ISSUES+=("未找到默认出口接口")
    fi
    for dev in "$NET_WAN_DEV" "tun0_master" "tun0_slave"; do
        [[ -n "$dev" ]] || continue
        if [[ " ${NET_CHECKED_DEVS[*]} " == *" $dev "* ]]; then
            continue
        fi
        NET_CHECKED_DEVS+=("$dev")
        if ! ip link show "$dev" >/dev/null 2>&1; then
            NET_IF_ISSUES+=("${dev}接口不存在")
            continue
        fi
        dev_flags=$(ip -o link show dev "$dev" 2>/dev/null | sed -n 's/.*<\([^>]*\)>.*/\1/p')
        if [[ ",${dev_flags}," != *",UP,"* ]]; then
            NET_IF_ISSUES+=("${dev}未处于UP状态")
        fi
        rx_errors=$(cat "/sys/class/net/$dev/statistics/rx_errors" 2>/dev/null || echo 0)
        tx_errors=$(cat "/sys/class/net/$dev/statistics/tx_errors" 2>/dev/null || echo 0)
        if [[ "${rx_errors:-0}" -gt 0 || "${tx_errors:-0}" -gt 0 ]]; then
            NET_IF_ISSUES+=("${dev}存在错误计数(RX=${rx_errors},TX=${tx_errors})")
        fi
        if [[ "$dev" == tun0_* ]]; then
            dev_ipv4=$(ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)
            if [[ ! "$dev_ipv4" =~ ^169\.254\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]+$ ]]; then
                NET_IF_ISSUES+=("${dev}隧道IP异常(${dev_ipv4:-无})，应为169.254.x.x格式")
            fi
        fi
        NET_IF_OK+=("$dev")
    done
    if [[ "${#NET_IF_ISSUES[@]}" -eq 0 ]]; then
        NET_IF_EXTRA="${GREEN}◆ 判断原因: 已检查关键接口 $(IFS='，'; echo "${NET_IF_OK[*]}")，均为UP且RX/TX错误计数为0，主备tun IP均为169.254.x.x格式${NC}"
        NET_IF_CODE=0
    else
        NET_IF_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${NET_IF_ISSUES[*]}")${NC}"
        NET_IF_CODE=1
    fi
    print_check "所有网络接口状态" \
        "$NET_IF_CMD" \
        "默认出口接口和主备tun接口应为UP状态，RX/TX错误计数应为0，tun0_master/tun0_slave IP应为169.254.x.x格式" \
        "请检查接口链路、驱动、隧道服务和网卡错误计数" \
        "$NET_IF_EXTRA" \
        "$NET_IF_CODE" \
        "$NET_IF_OUTPUT"
}

check_iptables_policy() {
    # iptables智能检测（提取默认策略、规则统计、异常DROP）
    IPTABLES_INPUT_POLICY=$(iptables -L INPUT -n 2>/dev/null | awk -F'[()]' '/^Chain/ {gsub(/^policy /, "", $2); print $2; exit}')
    IPTABLES_FORWARD_POLICY=$(iptables -L FORWARD -n 2>/dev/null | awk -F'[()]' '/^Chain/ {gsub(/^policy /, "", $2); print $2; exit}')
    IPTABLES_OUTPUT_POLICY=$(iptables -L OUTPUT -n 2>/dev/null | awk -F'[()]' '/^Chain/ {gsub(/^policy /, "", $2); print $2; exit}')
    IPTABLES_RULE_COUNT=$(iptables -L -n 2>/dev/null | awk 'NF && $1 !~ /^(Chain|target)$/ {count++} END {print count+0}')
    IPTABLES_DROP_COUNT=$(iptables -L -n 2>/dev/null | awk '$1=="DROP" {count++} END {print count+0}')

    if [[ "$IPTABLES_INPUT_POLICY" == "ACCEPT" && "$IPTABLES_FORWARD_POLICY" == "ACCEPT" && "$IPTABLES_OUTPUT_POLICY" == "ACCEPT" ]]; then
        IPTABLES_EXTRA="${GREEN}◆ 防火墙正常: 三链默认策略均为ACCEPT，共${IPTABLES_RULE_COUNT}条规则，DROP规则${IPTABLES_DROP_COUNT}条（需结合业务确认）${NC}"
        IPTABLES_CODE=0
    else
        IPTABLES_EXTRA="${RED}◆ 策略异常: INPUT=${IPTABLES_INPUT_POLICY:-N/A} FORWARD=${IPTABLES_FORWARD_POLICY:-N/A} OUTPUT=${IPTABLES_OUTPUT_POLICY:-N/A}${NC}"
        IPTABLES_CODE=1
    fi

    print_check "iptables防火墙状态与策略" \
        "iptables -nvL --line-numbers" \
        "iptables已安装，所有链默认策略为ACCEPT，无异常DROP规则" \
        "如发现DROP策略或异常规则需立即排查" \
        "$IPTABLES_EXTRA" \
        "$IPTABLES_CODE"
}

check_ufw_status() {
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status 2>/dev/null | head -1)
        if echo "$UFW_STATUS" | grep -Eqi '^Status:[[:space:]]+active'; then
            UFW_EXTRA="${RED}◆ 判断原因: ufw处于启用状态，可能与iptables规则冲突${NC}"
            UFW_CODE=1
        else
            UFW_EXTRA="${GREEN}◆ 判断原因: ufw已安装但未启用，不影响iptables统一管理${NC}"
            UFW_CODE=0
        fi
    else
        UFW_EXTRA="${GREEN}◆ 判断原因: ufw未安装，不会与iptables冲突${NC}"
        UFW_CODE=0
    fi

    print_check "ufw防火墙状态" \
        "(command -v ufw > /dev/null 2>&1 && ufw status) || echo 'ufw未安装'" \
        "建议关闭ufw，统一由iptables管理" \
        "请关闭ufw或确认其规则不会覆盖iptables策略" \
        "$UFW_EXTRA" \
        "$UFW_CODE"
}

check_firewalld_status() {
    FIREWALLD_STATUS=$(systemctl is-active firewalld 2>/dev/null || echo "未运行")
    if [[ "$FIREWALLD_STATUS" == "active" ]]; then
        FIREWALLD_EXTRA="${RED}◆ 判断原因: firewalld处于active状态，可能与iptables冲突${NC}"
        FIREWALLD_CODE=1
    else
        FIREWALLD_EXTRA="${GREEN}◆ 判断原因: firewalld状态为${FIREWALLD_STATUS}，未运行或未启用${NC}"
        FIREWALLD_CODE=0
    fi

    print_check "firewalld服务状态" \
        "systemctl is-active firewalld 2>/dev/null || echo 'firewalld未运行'" \
        "应停止firewalld避免与iptables冲突" \
        "请执行systemctl disable --now firewalld" \
        "$FIREWALLD_EXTRA" \
        "$FIREWALLD_CODE"
}

check_nftables_status() {
    if command -v nft >/dev/null 2>&1; then
        NFT_RULE_COUNT=$(nft list ruleset 2>/dev/null | awk 'NF {count++} END {print count+0}')
        if [[ "$NFT_RULE_COUNT" -gt 0 ]]; then
            NFT_EXTRA="${RED}◆ 判断原因: nftables存在${NFT_RULE_COUNT}行活跃规则，可能与iptables冲突${NC}"
            NFT_CODE=1
        else
            NFT_EXTRA="${GREEN}◆ 判断原因: nftables已安装但无活跃规则集${NC}"
            NFT_CODE=0
        fi
    else
        NFT_EXTRA="${GREEN}◆ 判断原因: nftables未安装或不可用，无活跃规则集${NC}"
        NFT_CODE=0
    fi

    print_check "nftables状态" \
        "(command -v nft > /dev/null 2>&1 && nft list ruleset 2>/dev/null | head -10) || echo 'nftables未激活'" \
        "不应有活跃的nftables规则集" \
        "请清理nftables规则或确认不会与iptables冲突" \
        "$NFT_EXTRA" \
        "$NFT_CODE"
}

check_selinux_status() {
    if command -v getenforce >/dev/null 2>&1; then
        SELINUX_STATUS=$(getenforce 2>/dev/null)
        if [[ "$SELINUX_STATUS" == "Disabled" ]]; then
            SELINUX_EXTRA="${GREEN}◆ 判断原因: SELinux为Disabled，符合CPE运行要求${NC}"
            SELINUX_CODE=0
        else
            SELINUX_EXTRA="${RED}◆ 判断原因: SELinux当前为${SELINUX_STATUS}，要求为Disabled${NC}"
            SELINUX_CODE=1
        fi
    else
        SELINUX_EXTRA="${GREEN}◆ 判断原因: SELinux未安装，不会限制CPE服务${NC}"
        SELINUX_CODE=0
    fi

    print_check "SELinux状态" \
        "(command -v getenforce > /dev/null 2>&1 && getenforce) || echo 'SELinux未安装'" \
        "必须设置为Disabled模式，否则会导致CPE服务异常" \
        "请关闭SELinux或设置为Disabled" \
        "$SELINUX_EXTRA" \
        "$SELINUX_CODE"
}

check_ip_forwarding() {
    IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    IPV4_ALL_FORWARD=$(sysctl -n net.ipv4.conf.all.forwarding 2>/dev/null || echo 0)
    IPV6_ALL_FORWARD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
    if [[ "$IP_FORWARD" == "1" && "$IPV4_ALL_FORWARD" == "1" && "$IPV6_ALL_FORWARD" == "1" ]]; then
        FORWARD_EXTRA="${GREEN}◆ 判断原因: IPv4/IPV6转发均已启用${NC}"
        FORWARD_CODE=0
    else
        FORWARD_EXTRA="${RED}◆ 判断原因: 转发配置异常(ip_forward=${IP_FORWARD}, ipv4_all=${IPV4_ALL_FORWARD}, ipv6_all=${IPV6_ALL_FORWARD})${NC}"
        FORWARD_CODE=1
    fi

    print_check "IP转发功能" \
        "sysctl net.ipv4.ip_forward net.ipv4.conf.all.forwarding net.ipv6.conf.all.forwarding" \
        "IPv4和IPv6转发均需设置为1（启用）" \
        "请通过sysctl配置启用IP转发" \
        "$FORWARD_EXTRA" \
        "$FORWARD_CODE"
}

check_tcp_congestion_control() {
    TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    TCP_CC_AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if [[ "$TCP_CC" == "bbr" && " $TCP_CC_AVAILABLE " == *" bbr "* ]]; then
        TCP_CC_EXTRA="${GREEN}◆ 判断原因: 当前拥塞算法为bbr，且可用算法包含bbr${NC}"
        TCP_CC_CODE=0
    else
        TCP_CC_EXTRA="${RED}◆ 判断原因: 当前拥塞算法为${TCP_CC}，可用算法为${TCP_CC_AVAILABLE:-N/A}，未满足bbr要求${NC}"
        TCP_CC_CODE=1
    fi

    print_check "TCP拥塞控制算法" \
        "sysctl net.ipv4.tcp_congestion_control && sysctl net.ipv4.tcp_available_congestion_control" \
        "推荐使用BBR算法提升网络性能30-50%" \
        "请启用tcp_bbr并设置net.ipv4.tcp_congestion_control=bbr" \
        "$TCP_CC_EXTRA" \
        "$TCP_CC_CODE"
}

check_nf_conntrack() {
    CONNTRACK_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
    CONNTRACK_COUNT=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo 0)
    CONNTRACK_USAGE=$(awk -v count="$CONNTRACK_COUNT" -v max="$CONNTRACK_MAX" 'BEGIN { if (max > 0) printf "%.2f", count/max*100; else print "0.00" }')
    if [[ "$CONNTRACK_MAX" -ge 1000000 ]] && compare_float_lt "$CONNTRACK_USAGE" "80"; then
        CONNTRACK_EXTRA="${GREEN}◆ 判断原因: 最大值${CONNTRACK_MAX}≥1000000，当前使用率${CONNTRACK_USAGE}%<80%${NC}"
        CONNTRACK_CODE=0
    else
        CONNTRACK_EXTRA="${RED}◆ 判断原因: 最大值${CONNTRACK_MAX}，当前${CONNTRACK_COUNT}，使用率${CONNTRACK_USAGE}%，不满足阈值要求${NC}"
        CONNTRACK_CODE=1
    fi

    print_check "连接跟踪表(nfconntrack)配置" \
        "sysctl net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_count" \
        "最大值应≥1000000，当前使用率应<80%" \
        "请调大nf_conntrack_max或排查异常连接数" \
        "$CONNTRACK_EXTRA" \
        "$CONNTRACK_CODE"
}

check_tcp_buffers() {
    RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    if [[ "$RMEM_MAX" -ge 16777216 && "$WMEM_MAX" -ge 16777216 ]]; then
        TCP_BUF_EXTRA="${GREEN}◆ 判断原因: rmem_max=${RMEM_MAX}, wmem_max=${WMEM_MAX}，均≥16MB${NC}"
        TCP_BUF_CODE=0
    else
        TCP_BUF_EXTRA="${RED}◆ 判断原因: rmem_max=${RMEM_MAX}, wmem_max=${WMEM_MAX}，未达到16MB要求${NC}"
        TCP_BUF_CODE=1
    fi

    print_check "TCP缓冲区配置" \
        "sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem" \
        "rmem_max/wmem_max应≥16MB以支持高速传输" \
        "请将net.core.rmem_max和net.core.wmem_max设置为至少16777216" \
        "$TCP_BUF_EXTRA" \
        "$TCP_BUF_CODE"
}

check_cpe_version() {
    CPE_CLI_VERSION_OUTPUT=$(/opt/feilian/cpe/bin/feilian-cpe-cli version 2>/dev/null || true)
    CPE_CLI_VERSION=$(echo "$CPE_CLI_VERSION_OUTPUT" | awk -F': ' '/^Version:/ {print $2; exit}')
    CPE_CLI_REQUIRED_VERSION="3.0.17"
    if [[ -z "$CPE_CLI_VERSION" ]]; then
        CPE_CLI_EXTRA="${RED}◆ 判断原因: 未获取到CLI版本，可能工具不存在或执行异常${NC}"
        CPE_CLI_CODE=1
    elif version_ge "$CPE_CLI_VERSION" "$CPE_CLI_REQUIRED_VERSION"; then
        CPE_CLI_EXTRA="${GREEN}◆ 判断原因: 当前版本${CPE_CLI_VERSION}≥${CPE_CLI_REQUIRED_VERSION}，符合要求${NC}"
        CPE_CLI_CODE=0
    else
        CPE_CLI_EXTRA="${RED}◆ 判断原因: 当前版本${CPE_CLI_VERSION}<${CPE_CLI_REQUIRED_VERSION}，需升级CPE CLI工具${NC}"
        CPE_CLI_CODE=1
    fi

    print_check "CPE版本信息" \
        "/opt/feilian/cpe/bin/feilian-cpe-cli version 2>/dev/null || echo 'CLI工具不存在'" \
        "版本号应≥3.0.17以获得完整功能和bug修复" \
        "请升级CPE CLI工具至3.0.17或以上版本" \
        "$CPE_CLI_EXTRA" \
        "$CPE_CLI_CODE"
}

check_cpe_services() {
    CPE_SERVICES=(
        "feilian-cpe"
        "feilian-dnsmasq"
        "feilian-tun@tun0_master"
        "feilian-tun@tun0_slave"
        "feilian-cpe-sentry"
        "feilian-keepalived"
    )
    CPE_SERVICE_FAILED=()
    CPE_SERVICE_OK=()
    for svc in "${CPE_SERVICES[@]}"; do
        svc_state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        svc_load_state=$(systemctl show "$svc" --property=LoadState --value 2>/dev/null || echo "not-found")
        svc_unit_file_state=$(systemctl show "$svc" --property=UnitFileState --value 2>/dev/null || echo "unknown")
        [[ -n "$svc_load_state" ]] || svc_load_state="not-found"
        [[ -n "$svc_unit_file_state" ]] || svc_unit_file_state="unknown"
        if [[ "$svc_state" == "active" && "$svc_load_state" == "loaded" ]]; then
            CPE_SERVICE_OK+=("$svc")
        else
            CPE_SERVICE_FAILED+=("$svc active=${svc_state}, loaded=${svc_load_state}, unit=${svc_unit_file_state}")
        fi
    done
    if [[ "${#CPE_SERVICE_FAILED[@]}" -eq 0 ]]; then
        CPE_SERVICE_EXTRA="${GREEN}◆ 判断原因: ${#CPE_SERVICE_OK[@]}个CPE关键服务均为active且unit加载状态为loaded${NC}"
        CPE_SERVICE_CODE=0
    else
        CPE_SERVICE_EXTRA="${RED}◆ 判断原因: 异常服务 $(IFS='，'; echo "${CPE_SERVICE_FAILED[*]}")${NC}"
        CPE_SERVICE_CODE=1
    fi

    CPE_SERVICE_CMD="for s in feilian-cpe feilian-dnsmasq feilian-tun@tun0_master feilian-tun@tun0_slave feilian-cpe-sentry feilian-keepalived; do active=\$(systemctl is-active \"\$s\" 2>/dev/null || echo inactive); load=\$(systemctl show \"\$s\" --property=LoadState --value 2>/dev/null || echo not-found); unit=\$(systemctl show \"\$s\" --property=UnitFileState --value 2>/dev/null || echo unknown); fragment=\$(systemctl show \"\$s\" --property=FragmentPath --value 2>/dev/null || true); ts=\$(systemctl show \"\$s\" --property=ActiveEnterTimestamp --value 2>/dev/null || true); [ -n \"\$load\" ] || load=not-found; [ -n \"\$unit\" ] || unit=unknown; printf '%-32s active=%-10s loaded=%-10s unit=%s\n' \"\$s\" \"\$active\" \"\$load\" \"\$unit\"; printf '  启动时间: %s\n' \"\${ts:-未获取}\"; printf '  Unit文件: %s\n' \"\${fragment:-未找到}\"; done"

    print_check "CPE服务运行状态检查" \
        "$CPE_SERVICE_CMD" \
        "CPE关键服务均应处于active状态，且systemd unit加载状态应为loaded" \
        "请检查异常服务日志、恢复缺失的systemd unit文件并重启对应服务" \
        "$CPE_SERVICE_EXTRA" \
        "$CPE_SERVICE_CODE"
}

check_cpe_network_health() {
    CPE_HEALTH_WAN_DEV=$(get_default_wan_dev)
    CPE_HEALTH_WAN_LABEL="${CPE_HEALTH_WAN_DEV:-未指定(未找到非tun默认路由)}"
    CPE_HEALTH_OUTPUT=$(printf '%s\n' "默认出接口: ${CPE_HEALTH_WAN_LABEL}"; /opt/feilian/cpe/bin/feilian-cpe-health-check 2>&1)
    CPE_HEALTH_CMD_CODE=$?
    CPE_HEALTH_CHECKED_OUTPUT=$(echo "$CPE_HEALTH_OUTPUT" | grep -vE '探测网关|^默认出接口:')
    CPE_HEALTH_TOTAL=$(echo "$CPE_HEALTH_CHECKED_OUTPUT" | awk 'NF {count++} END {print count+0}')
    CPE_HEALTH_FAILED=$(echo "$CPE_HEALTH_CHECKED_OUTPUT" | awk 'NF && $0 !~ /成功/ {print}')
    if echo "$CPE_HEALTH_OUTPUT" | grep -q '探测网关.*成功'; then
        CPE_HEALTH_GATEWAY_OK=true
    else
        CPE_HEALTH_GATEWAY_OK=false
    fi
    if echo "$CPE_HEALTH_OUTPUT" | grep -q 'DNS 解析 www\.baidu\.com 成功'; then
        CPE_HEALTH_DNS_OK=true
    else
        CPE_HEALTH_DNS_OK=false
    fi
    if echo "$CPE_HEALTH_OUTPUT" | grep -q '连接管理后台 .* 成功'; then
        CPE_HEALTH_PLATFORM_OK=true
    else
        CPE_HEALTH_PLATFORM_OK=false
    fi
    CPE_HEALTH_MGMT_GRPC_LINES=$(echo "$CPE_HEALTH_OUTPUT" | awk '/连接管理后台GRPC/ {print}')
    CPE_HEALTH_MGMT_GRPC_FAILED=$(echo "$CPE_HEALTH_MGMT_GRPC_LINES" | awk 'NF && $0 !~ /成功/ {print}')
    if [[ -n "$CPE_HEALTH_MGMT_GRPC_LINES" && -z "$CPE_HEALTH_MGMT_GRPC_FAILED" ]]; then
        CPE_HEALTH_MGMT_GRPC_OK=true
    else
        CPE_HEALTH_MGMT_GRPC_OK=false
    fi
    CPE_HEALTH_CENTER_DNS_GRPC_NET_OK=$(echo "$CPE_HEALTH_OUTPUT" | awk '/网络测试连接中心[[:space:]]+DNS GRPC/ && /成功/ {print; exit}')
    CPE_HEALTH_CENTER_DNS_GRPC_APP_OK=$(echo "$CPE_HEALTH_OUTPUT" | awk '/业务应用连接中心DNS GRPC/ && /成功/ {print; exit}')
    if [[ -n "$CPE_HEALTH_CENTER_DNS_GRPC_NET_OK" && -n "$CPE_HEALTH_CENTER_DNS_GRPC_APP_OK" ]]; then
        CPE_HEALTH_CENTER_DNS_GRPC_OK=true
    else
        CPE_HEALTH_CENTER_DNS_GRPC_OK=false
    fi
    if echo "$CPE_HEALTH_OUTPUT" | grep -q '中心 DNS UDP端口.*探测成功'; then
        CPE_HEALTH_CENTER_DNS_UDP_OK=true
    else
        CPE_HEALTH_CENTER_DNS_UDP_OK=false
    fi
    if [[ "$CPE_HEALTH_CMD_CODE" -ne 0 ]]; then
        CPE_HEALTH_EXTRA="${RED}◆ 判断原因: 健康检查脚本执行失败，退出码=${CPE_HEALTH_CMD_CODE}${NC}"
        CPE_HEALTH_CODE=1
    elif [[ -z "$CPE_HEALTH_FAILED" ]]; then
        CPE_HEALTH_EXTRA="${GREEN}◆ 判断原因: 网络健康检查均显示成功，共${CPE_HEALTH_TOTAL}项${NC}"
        CPE_HEALTH_CODE=0
    else
        CPE_HEALTH_FAILED_ONE=$(echo "$CPE_HEALTH_FAILED" | head -1)
        CPE_HEALTH_FAILED_COUNT=$(echo "$CPE_HEALTH_FAILED" | awk 'NF {count++} END {print count+0}')
        CPE_HEALTH_EXTRA="${RED}◆ 判断原因: 发现${CPE_HEALTH_FAILED_COUNT}项非成功结果，首个异常: ${CPE_HEALTH_FAILED_ONE}${NC}"
        CPE_HEALTH_CODE=1
    fi

    print_check "执行CPE网络健康检查脚本" \
        "printf '%s\n' \"默认出接口: ${CPE_HEALTH_WAN_LABEL}\"; /opt/feilian/cpe/bin/feilian-cpe-health-check 2>&1" \
        "脚本正常执行，网络健康检查项均需显示成功；探测网关仅展示，不参与通过/失败判断" \
        "请再次尝试执行健康检查脚本/opt/feilian/cpe/bin/feilian-cpe-health-check 2>&1，如还有问题请根据非成功项排查网络、DNS、GRPC、认证凭据或隧道连通性" \
        "$CPE_HEALTH_EXTRA" \
        "$CPE_HEALTH_CODE" \
        "$CPE_HEALTH_OUTPUT"
}

check_cpe_event_error_log() {
    EVENT_LOG_PATH="/opt/feilian/cpe/log/cpe.event.log"
    EVENT_LOG_CMD="log=/opt/feilian/cpe/log/cpe.event.log; if [ -f \"\$log\" ]; then echo \"===近5分钟ERROR===\"; c=\$(date -d '5min ago' +%s 2>/dev/null || echo 0); tail -2000 \"\$log\" 2>/dev/null | while IFS= read -r line; do t=\$(printf '%s\n' \"\$line\" | sed -n 's/.*\"time\":\"\\([^\"]*\\)\".*/\\1/p'); [ -n \"\$t\" ] || continue; ts=\$(date -d \"\$t\" +%s 2>/dev/null || echo 0); [ \"\$ts\" -gt \"\$c\" ] && printf '%s\n' \"\$line\"; done | grep -i '\"level\":\"error\"' || true; else echo '日志文件不存在'; fi"
    EVENT_LOG_OUTPUT=$(eval "$EVENT_LOG_CMD" 2>&1 || true)
    EVENT_LOG_SIZE_BYTES=$(stat -c%s "$EVENT_LOG_PATH" 2>/dev/null || stat -f%z "$EVENT_LOG_PATH" 2>/dev/null || echo 0)
    EVENT_LOG_SIZE_MB=$(awk -v bytes="$EVENT_LOG_SIZE_BYTES" 'BEGIN { printf "%.1f", bytes/1024/1024 }')
    EVENT_LOG_ERROR_COUNT=$(echo "$EVENT_LOG_OUTPUT" | grep -iv '^===近5分钟ERROR===$' | awk 'NF {count++} END {print count+0}')
    if [[ ! -f "$EVENT_LOG_PATH" ]]; then
        EVENT_LOG_EXTRA="${RED}◆ 判断原因: 日志文件不存在，路径=${EVENT_LOG_PATH}${NC}"
        EVENT_LOG_CODE=1
    elif compare_float_gt "$EVENT_LOG_SIZE_MB" "100"; then
        EVENT_LOG_EXTRA="${RED}◆ 判断原因: 日志文件大小${EVENT_LOG_SIZE_MB}MB>100MB，近5分钟ERROR ${EVENT_LOG_ERROR_COUNT}条${NC}"
        EVENT_LOG_CODE=1
    elif [[ "$EVENT_LOG_ERROR_COUNT" -gt 0 ]]; then
        EVENT_LOG_EXTRA="${RED}◆ 判断原因: 日志文件大小${EVENT_LOG_SIZE_MB}MB，近5分钟发现${EVENT_LOG_ERROR_COUNT}条ERROR日志${NC}"
        EVENT_LOG_CODE=1
    else
        EVENT_LOG_EXTRA="${GREEN}◆ 判断原因: 日志文件大小${EVENT_LOG_SIZE_MB}MB<100MB，近5分钟未发现ERROR日志${NC}"
        EVENT_LOG_CODE=0
    fi
    print_check "CPE事件ERROR日志检查" \
        "$EVENT_LOG_CMD" \
        "日志文件应<100MB，近5分钟内应无Error级别日志" \
        "请检查cpe.event.log近5分钟ERROR并确认日志轮转配置，必要时清理或归档日志" \
        "$EVENT_LOG_EXTRA" \
        "$EVENT_LOG_CODE" \
        "$EVENT_LOG_OUTPUT"
}

check_panic_logs() {
    PANIC_LOG_CMD="for log in /opt/feilian/cpe/log/tun.event.log /opt/feilian/cpe/log/cpe.event.log /opt/feilian/cpe/log/cpe.panic.log; do echo \"=== \$log ===\"; if [ -f \"\$log\" ]; then grep -i 'panic' \"\$log\" | tail -20 || echo '未发现panic记录'; else echo '日志文件不存在'; fi; done"
    PANIC_LOG_OUTPUT=$(eval "$PANIC_LOG_CMD" 2>&1 || true)
    PANIC_LOG_COUNT=$(echo "$PANIC_LOG_OUTPUT" | grep -viE '^(===|日志文件不存在|未发现panic记录)' | awk 'NF {count++} END {print count+0}')
    if [[ "$PANIC_LOG_COUNT" -gt 0 ]]; then
        PANIC_LOG_EXTRA="${RED}◆ 判断原因: 发现${PANIC_LOG_COUNT}条panic相关记录，请优先排查隧道或CPE进程崩溃原因${NC}"
        PANIC_LOG_CODE=1
    else
        PANIC_LOG_EXTRA="${GREEN}◆ 判断原因: 已检查tun.event.log、cpe.event.log、cpe.panic.log，未发现panic记录${NC}"
        PANIC_LOG_CODE=0
    fi
    print_check "Panic崩溃日志检查" \
        "$PANIC_LOG_CMD" \
        "不应存在Panic记录，如有需排查原因" \
        "请结合panic堆栈、服务重启时间和对应进程日志排查崩溃原因" \
        "$PANIC_LOG_EXTRA" \
        "$PANIC_LOG_CODE" \
        "$PANIC_LOG_OUTPUT"
}

check_default_gateway() {
    # 官方健康检查已探测网关成功时，跳过单独网关检查，避免重复巡检。
    if should_show_detail_check "${CPE_HEALTH_GATEWAY_OK:-false}"; then
        # 默认网关连通性（ping + ARP/邻居表）
        GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
        GATEWAY_DEV=$(ip route | awk '/default/ {print $5; exit}')
        GATEWAY_LABEL="${GATEWAY_DEV:-未指定(未找到默认出口接口)}"
        GATEWAY_PING_IF=""
        [[ -n "$GATEWAY_DEV" ]] && GATEWAY_PING_IF="-I $GATEWAY_DEV"
        GATEWAY_CMD="printf '%s\n' \"出接口: ${GATEWAY_LABEL}\"; ping ${GATEWAY_PING_IF} -W2 -c3 $GATEWAY && echo '---ARP信息---' && (ip neigh show $GATEWAY 2>/dev/null || arp -n $GATEWAY 2>/dev/null || true)"
        GATEWAY_OUTPUT=$(eval "$GATEWAY_CMD" 2>&1 || true)
        GATEWAY_LOSS=$(echo "$GATEWAY_OUTPUT" | awk -F',' '/packet loss/ {gsub(/[^0-9.]/, "", $3); print $3; exit}')
        GATEWAY_AVG_RTT=$(echo "$GATEWAY_OUTPUT" | awk -F'/' '/^rtt|^round-trip/ {print $5; exit}')
        GATEWAY_ARP_LINE=$(echo "$GATEWAY_OUTPUT" | awk '/---ARP信息---/ {show=1; next} show && NF {print; exit}')
        GATEWAY_ISSUES=()
        [[ -n "$GATEWAY" ]] || GATEWAY_ISSUES+=("未找到默认网关")
        [[ "${GATEWAY_LOSS:-100}" == "0" ]] || GATEWAY_ISSUES+=("丢包率${GATEWAY_LOSS:-100}%>0%")
        compare_float_lt "${GATEWAY_AVG_RTT:-999}" "50" || GATEWAY_ISSUES+=("平均延迟${GATEWAY_AVG_RTT:-N/A}ms≥50ms")
        if [[ -z "$GATEWAY_ARP_LINE" ]]; then
            GATEWAY_ISSUES+=("未获取到网关ARP/邻居表信息")
        elif echo "$GATEWAY_ARP_LINE" | grep -Eqi 'FAILED|INCOMPLETE'; then
            GATEWAY_ISSUES+=("网关ARP状态异常: ${GATEWAY_ARP_LINE}")
        fi
        if [[ "${#GATEWAY_ISSUES[@]}" -eq 0 ]]; then
            GATEWAY_EXTRA="${GREEN}◆ 判断原因: 网关${GATEWAY}(${GATEWAY_DEV:-N/A})可达，丢包率${GATEWAY_LOSS}% ，平均延迟${GATEWAY_AVG_RTT}ms<50ms，ARP信息正常${NC}"
            GATEWAY_CODE=0
        else
            GATEWAY_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${GATEWAY_ISSUES[*]}")${NC}"
            GATEWAY_CODE=1
        fi

        print_check "默认网关连通性" \
            "$GATEWAY_CMD" \
            "网关应可达，延迟<50ms，丢包率0%，ARP/邻居表信息正常" \
            "请检查默认路由、网关ARP解析、链路连通性和上联交换机配置" \
            "$GATEWAY_EXTRA" \
            "$GATEWAY_CODE" \
            "$GATEWAY_OUTPUT"
    fi
}

check_dns_resolv_conf() {
    # 官方健康检查已确认DNS解析成功时，跳过单独DNS检查，避免重复巡检。
    if should_show_detail_check "${CPE_HEALTH_DNS_OK:-false}"; then
        # DNS解析与连通性检查（读取/etc/resolv.conf中的nameserver）
        DNS_CONF="/etc/resolv.conf"
        DNS_CMD="conf=/etc/resolv.conf; echo \"配置文件: \$conf\"; echo '---DNS服务器---'; awk '/^nameserver/{print \$2}' \"\$conf\" 2>/dev/null; for dns in \$(awk '/^nameserver/{print \$2}' \"\$conf\" 2>/dev/null); do echo \"=== DNS \$dns ===\"; dev=\$(ip route get \"\$dns\" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if(\$i==\"dev\" && (i+1)<=NF){print \$(i+1); exit}}}'); echo \"出接口: \${dev:-未获取}\"; ping_if=''; [ -n \"\$dev\" ] && ping_if=\"-I \$dev\"; if ping \$ping_if -W2 -c2 \"\$dns\" >/dev/null 2>&1; then echo 'ICMP连通性: 成功'; else echo 'ICMP连通性: 失败(仅供参考，部分DNS服务器禁ping)'; fi; if command -v dig >/dev/null 2>&1; then r=\$(dig @\"\$dns\" +time=2 +tries=1 www.baidu.com A +short 2>/dev/null | head -5); [ -n \"\$r\" ] && printf 'DNS解析结果: %s\n' \"\$r\" || echo 'DNS解析结果: 失败'; elif command -v nslookup >/dev/null 2>&1; then nslookup www.baidu.com \"\$dns\" 2>/dev/null | awk 'NR<=8'; else getent hosts www.baidu.com 2>/dev/null | head -3 || echo '解析工具不可用且系统解析失败'; fi; done"
        DNS_OUTPUT=$(eval "$DNS_CMD" 2>&1 || true)
        DNS_SERVERS=$(awk '/^nameserver/{print $2}' "$DNS_CONF" 2>/dev/null)
        DNS_ISSUES=()
        DNS_OK_COUNT=0
        DNS_TOTAL_COUNT=0
        [[ -f "$DNS_CONF" ]] || DNS_ISSUES+=("${DNS_CONF}不存在")
        [[ -n "$DNS_SERVERS" ]] || DNS_ISSUES+=("${DNS_CONF}未配置nameserver")
        while IFS= read -r dns; do
            [[ -n "$dns" ]] || continue
            DNS_TOTAL_COUNT=$((DNS_TOTAL_COUNT + 1)) || true
            if command -v dig >/dev/null 2>&1; then
                if dig @"$dns" +time=2 +tries=1 www.baidu.com A +short 2>/dev/null | grep -Eq '^[0-9a-fA-F:.]+$'; then
                    DNS_OK_COUNT=$((DNS_OK_COUNT + 1)) || true
                else
                    DNS_ISSUES+=("DNS服务器${dns}解析www.baidu.com失败")
                fi
            elif command -v nslookup >/dev/null 2>&1; then
                if nslookup www.baidu.com "$dns" >/dev/null 2>&1; then
                    DNS_OK_COUNT=$((DNS_OK_COUNT + 1)) || true
                else
                    DNS_ISSUES+=("DNS服务器${dns}解析www.baidu.com失败")
                fi
            elif getent hosts www.baidu.com >/dev/null 2>&1; then
                DNS_OK_COUNT=$((DNS_OK_COUNT + 1)) || true
            else
                DNS_ISSUES+=("系统DNS解析www.baidu.com失败，且未安装dig/nslookup")
            fi
        done <<< "$DNS_SERVERS"
        if [[ "${#DNS_ISSUES[@]}" -eq 0 ]]; then
            DNS_EXTRA="${GREEN}◆ 判断原因: ${DNS_CONF}已配置${DNS_TOTAL_COUNT}个DNS服务器，${DNS_OK_COUNT}个解析www.baidu.com成功；ICMP连通性仅供参考${NC}"
            DNS_CODE=0
        else
            DNS_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${DNS_ISSUES[*]}")${NC}"
            DNS_CODE=1
        fi
        print_check "DNS解析与连通性检查" \
            "$DNS_CMD" \
            "/etc/resolv.conf应配置DNS服务器，且能够成功解析www.baidu.com；ICMP连通性仅供参考" \
            "请检查/etc/resolv.conf中的nameserver配置和DNS 53端口解析能力，ICMP ping失败但解析成功可忽略" \
            "$DNS_EXTRA" \
            "$DNS_CODE" \
            "$DNS_OUTPUT"
    fi
}

check_management_backend() {
    # 官方健康检查已确认连接管理后台成功时，跳过单独后台连接检查，避免重复巡检。
    local platform_token_cmd
    local platform_token_raw
    local platform_token_output
    PLATFORM=$(grep '^url:' /opt/feilian/cpe/conf/config.yaml 2>/dev/null | awk '{print $2}' | tr -d "'")
    if should_show_detail_check "${CPE_HEALTH_PLATFORM_OK:-false}"; then
        # 管理平台HTTPS连接与认证凭据校验（token接口返回code=0代表成功）
        CURL_WAN_DEV=$(get_default_wan_dev)
        CURL_WAN_LABEL="${CURL_WAN_DEV:-未指定(未找到非tun默认路由)}"
        CURL_WAN_ARG=""
        [[ -n "$CURL_WAN_DEV" ]] && CURL_WAN_ARG="--interface $CURL_WAN_DEV"
        platform_token_cmd="curl ${CURL_WAN_ARG} -skv \"\$(sed -n 's/^url: //p' /opt/feilian/cpe/conf/config.yaml)/api/open/v1/token\" -H 'Content-Type: application/json' -d \"{\\\"access_key_id\\\":\\\"\$(sed -n 's/^app_id: //p' /opt/feilian/cpe/conf/config.yaml)\\\",\\\"access_key_secret\\\":\\\"\$(sed -n 's/^app_secret: //p' /opt/feilian/cpe/conf/config.yaml)\\\"}\" 2>&1"
        platform_token_raw=$(eval "$platform_token_cmd" 2>&1 || true)
        platform_token_output=$(printf 'curl出接口: %s\n%s\n' "$CURL_WAN_LABEL" "$platform_token_raw")
        if echo "$platform_token_raw" | grep -q '"code":0'; then
            PLATFORM_EXTRA="${GREEN}◆ 判断原因: 管理平台${PLATFORM}/api/open/v1/token访问成功，返回code=0，HTTPS连通性与认证凭据校验均正常${NC}"
            PLATFORM_CODE=0
        else
            PLATFORM_HTTP_STATUS=$(echo "$platform_token_raw" | awk '/< HTTP\// {status=$3} END {print status}')
            PLATFORM_EXTRA="${RED}◆ 判断原因: token接口未返回code=0，HTTP状态=${PLATFORM_HTTP_STATUS:-N/A}，请检查管理平台连通性或认证凭据配置${NC}"
            PLATFORM_CODE=1
        fi

        print_check "连接管理后台" \
            "printf '%s\n' \"curl出接口: ${CURL_WAN_LABEL}\"; ${platform_token_cmd}" \
            "调用/api/open/v1/token应返回code=0，代表HTTPS连通性与认证凭据校验成功" \
            "请检查管理平台地址、HTTPS连通性、app_id/app_secret配置和证书链信任情况" \
            "$PLATFORM_EXTRA" \
            "$PLATFORM_CODE" \
            "$platform_token_output"
    fi
}

check_management_grpc() {
    # 官方健康检查已确认连接管理后台GRPC成功时，跳过单独GRPC检查，避免重复巡检。
    local mgmt_token_cmd
    local mgmt_grpc_cmd
    local mgmt_token_raw
    local mgmt_grpc_raw
    if should_show_detail_check "${CPE_HEALTH_MGMT_GRPC_OK:-false}"; then
        # 连接管理后台GRPC（token + gRPC HTTP/2探测）
        MGMT_GRPC_ENDPOINT=$(awk -F "'" '/option ops_controller_grpc_addr/ {print $2; exit}' /opt/feilian/cpe/.cache/ucistore 2>/dev/null)
        MGMT_GRPC_HOST=$(echo "$MGMT_GRPC_ENDPOINT" | sed -E 's#^[a-zA-Z]+://##; s/:?[0-9]+$//')
        MGMT_GRPC_PORT=$(echo "$MGMT_GRPC_ENDPOINT" | sed -nE 's#.*:([0-9]+)$#\1#p')
        CURL_WAN_DEV=$(get_default_wan_dev)
        CURL_WAN_LABEL="${CURL_WAN_DEV:-未指定(未找到非tun默认路由)}"
        CURL_WAN_ARG=""
        [[ -n "$CURL_WAN_DEV" ]] && CURL_WAN_ARG="--interface $CURL_WAN_DEV"
        mgmt_token_cmd="curl ${CURL_WAN_ARG} -skS --http2 -D - \"\$(sed -n 's/^url: //p' /opt/feilian/cpe/conf/config.yaml)/api/open/v1/token\" -H 'Content-Type: application/json' -d \"{\\\"access_key_id\\\":\\\"\$(sed -n 's/^app_id: //p' /opt/feilian/cpe/conf/config.yaml)\\\",\\\"access_key_secret\\\":\\\"\$(sed -n 's/^app_secret: //p' /opt/feilian/cpe/conf/config.yaml)\\\"}\" 2>&1"
        mgmt_token_raw=$(eval "$mgmt_token_cmd" 2>&1 || true)
        cred=$(echo "$mgmt_token_raw" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
        mgmt_grpc_raw="获取访问凭据或GRPC地址失败"
        if [[ -n "$cred" && -n "$MGMT_GRPC_HOST" && -n "$MGMT_GRPC_PORT" ]]; then
            mgmt_grpc_cmd="curl ${CURL_WAN_ARG} -skv \"https://${MGMT_GRPC_HOST}:${MGMT_GRPC_PORT}\" -X POST -H \"Authorization: Bearer ${cred}\" -H 'content-type: application/grpc+proto' 2>&1"
            mgmt_grpc_raw=$(eval "$mgmt_grpc_cmd" 2>&1 || true)
        fi
        MGMT_GRPC_OUTPUT=$(printf 'curl出接口: %s\n=== token接口探测 ===\n%s\n管理后台GRPC地址: %s:%s\n=== 管理后台GRPC探测 ===\n%s\n' "$CURL_WAN_LABEL" "$mgmt_token_raw" "${MGMT_GRPC_HOST:-}" "${MGMT_GRPC_PORT:-}" "$mgmt_grpc_raw")
        MGMT_GRPC_HTTP_STATUS=$(echo "$mgmt_grpc_raw" | awk '/< HTTP\// {status=$3} END {print status}')
        if [[ -n "$cred" && "$MGMT_GRPC_HTTP_STATUS" == "200" ]]; then
            MGMT_GRPC_EXTRA="${GREEN}◆ 判断原因: 访问凭据获取成功，管理后台GRPC ${MGMT_GRPC_HOST:-N/A}:${MGMT_GRPC_PORT:-N/A} 返回HTTP 200，连接成功${NC}"
            MGMT_GRPC_CODE=0
        else
            MGMT_GRPC_EXTRA="${RED}◆ 判断原因: 访问凭据获取或管理后台GRPC连接异常，HTTP状态=${MGMT_GRPC_HTTP_STATUS:-N/A}，GRPC地址=${MGMT_GRPC_HOST:-N/A}:${MGMT_GRPC_PORT:-N/A}${NC}"
            MGMT_GRPC_CODE=1
        fi

        print_check "连接管理后台GRPC" \
            "printf '%s\n' \"curl出接口: ${CURL_WAN_LABEL}\"; echo '=== token接口探测 ==='; ${mgmt_token_cmd}; echo \"管理后台GRPC地址: ${MGMT_GRPC_HOST:-} : ${MGMT_GRPC_PORT:-}\"; echo '=== 管理后台GRPC探测 ==='; ${mgmt_grpc_cmd:-echo '获取访问凭据或GRPC地址失败'}" \
            "应能获取访问凭据，并使用Bearer认证信息连接管理后台GRPC返回HTTP 200" \
            "请检查认证凭据、ops_controller_grpc_addr配置、DNS解析、49905端口和管理后台GRPC服务状态" \
            "$MGMT_GRPC_EXTRA" \
            "$MGMT_GRPC_CODE" \
            "$MGMT_GRPC_OUTPUT"
    fi
}

check_center_dns_grpc() {
    # 官方健康检查已确认连接中心DNS GRPC成功时，跳过单独GRPC检查，避免重复巡检。
    local center_dns_token_cmd
    local center_dns_grpc_cmd
    local center_dns_token_raw
    local center_dns_grpc_raw
    if should_show_detail_check "${CPE_HEALTH_CENTER_DNS_GRPC_OK:-false}"; then
        CENTER_DNS_GRPC_ENDPOINT=$(awk -F "'" '/option dns_controller_grpc_addr/ {print $2; exit}' /opt/feilian/cpe/.cache/ucistore 2>/dev/null)
        CENTER_DNS_GRPC_HOST=$(echo "$CENTER_DNS_GRPC_ENDPOINT" | sed -E 's#^[a-zA-Z]+://##; s/:?[0-9]+$//')
        CENTER_DNS_GRPC_PORT=$(echo "$CENTER_DNS_GRPC_ENDPOINT" | sed -nE 's#.*:([0-9]+)$#\1#p')
        CURL_WAN_DEV=$(get_default_wan_dev)
        CURL_WAN_LABEL="${CURL_WAN_DEV:-未指定(未找到非tun默认路由)}"
        CURL_WAN_ARG=""
        [[ -n "$CURL_WAN_DEV" ]] && CURL_WAN_ARG="--interface $CURL_WAN_DEV"
        center_dns_token_cmd="curl ${CURL_WAN_ARG} -skS --http2 -D - \"\$(sed -n 's/^url: //p' /opt/feilian/cpe/conf/config.yaml)/api/open/v1/token\" -H 'Content-Type: application/json' -d \"{\\\"access_key_id\\\":\\\"\$(sed -n 's/^app_id: //p' /opt/feilian/cpe/conf/config.yaml)\\\",\\\"access_key_secret\\\":\\\"\$(sed -n 's/^app_secret: //p' /opt/feilian/cpe/conf/config.yaml)\\\"}\" 2>&1"
        center_dns_token_raw=$(eval "$center_dns_token_cmd" 2>&1 || true)
        cred=$(echo "$center_dns_token_raw" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
        center_dns_grpc_raw="获取访问凭据或DNS GRPC地址失败"
        if [[ -n "$cred" && -n "$CENTER_DNS_GRPC_HOST" && -n "$CENTER_DNS_GRPC_PORT" ]]; then
            center_dns_grpc_cmd="curl ${CURL_WAN_ARG} -skv \"https://${CENTER_DNS_GRPC_HOST}:${CENTER_DNS_GRPC_PORT}\" -X POST -H \"Authorization: Bearer ${cred}\" -H 'content-type: application/grpc+proto' 2>&1"
            center_dns_grpc_raw=$(eval "$center_dns_grpc_cmd" 2>&1 || true)
        fi
        CENTER_DNS_GRPC_OUTPUT=$(printf 'curl出接口: %s\n=== token接口探测 ===\n%s\n连接中心DNS GRPC地址: %s:%s\n=== 连接中心DNS GRPC探测 ===\n%s\n' "$CURL_WAN_LABEL" "$center_dns_token_raw" "${CENTER_DNS_GRPC_HOST:-}" "${CENTER_DNS_GRPC_PORT:-}" "$center_dns_grpc_raw")
        CENTER_DNS_GRPC_HTTP_STATUS=$(echo "$center_dns_grpc_raw" | awk '/< HTTP\// {status=$3} END {print status}')
        if [[ -n "$cred" && "$CENTER_DNS_GRPC_HTTP_STATUS" == "200" ]]; then
            CENTER_DNS_GRPC_EXTRA="${GREEN}◆ 判断原因: 访问凭据获取成功，连接中心DNS GRPC ${CENTER_DNS_GRPC_HOST:-N/A}:${CENTER_DNS_GRPC_PORT:-N/A} 返回HTTP 200，连接成功${NC}"
            CENTER_DNS_GRPC_CODE=0
        else
            CENTER_DNS_GRPC_EXTRA="${RED}◆ 判断原因: 访问凭据获取或连接中心DNS GRPC连接异常，HTTP状态=${CENTER_DNS_GRPC_HTTP_STATUS:-N/A}，GRPC地址=${CENTER_DNS_GRPC_HOST:-N/A}:${CENTER_DNS_GRPC_PORT:-N/A}${NC}"
            CENTER_DNS_GRPC_CODE=1
        fi

        print_check "连接中心DNS GRPC" \
            "printf '%s\n' \"curl出接口: ${CURL_WAN_LABEL}\"; echo '=== token接口探测 ==='; ${center_dns_token_cmd}; echo \"连接中心DNS GRPC地址: ${CENTER_DNS_GRPC_HOST:-} : ${CENTER_DNS_GRPC_PORT:-}\"; echo '=== 连接中心DNS GRPC探测 ==='; ${center_dns_grpc_cmd:-echo '获取访问凭据或DNS GRPC地址失败'}" \
            "应能获取访问凭据，并使用Bearer认证信息连接中心DNS GRPC返回HTTP 200" \
            "请检查认证凭据、dns_controller_grpc_addr配置、DNS解析、49920端口和连接中心DNS GRPC服务状态" \
            "$CENTER_DNS_GRPC_EXTRA" \
            "$CENTER_DNS_GRPC_CODE" \
            "$CENTER_DNS_GRPC_OUTPUT"
    fi
}

check_center_dns_udp() {
    # 官方健康检查已确认中心DNS UDP端口探测成功时，跳过单独探测，避免重复巡检。
    if should_show_detail_check "${CPE_HEALTH_CENTER_DNS_UDP_OK:-false}"; then
        # 中心 DNS UDP端口探测（认证凭据 + UDP 443 DNS探测）
        CENTER_DNS_UDP_CMD="cred_json=\$(awk -F \"'\" '/option token/ {print \$2; exit}' /opt/feilian/cpe/.cache/ucistore 2>/dev/null); if command -v jq >/dev/null 2>&1; then cred=\$(echo \"\$cred_json\" | jq -r .access_token 2>/dev/null); else cred=\$(echo \"\$cred_json\" | sed -n 's/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p'); fi; cred_len=\$(echo \"\$cred\" | wc -c); [ \"\$cred_len\" -eq 41 ] && echo '认证凭据 验证成功' || echo '认证凭据 验证失败'; dns_ip=\$(awk -F '=' '/add-dns-server-ip/ {print \$2; exit}' /etc/dnsmasq.d/cpe.conf 2>/dev/null); echo \"中心 DNS: \${dns_ip:-未配置}\"; if [ -n \"\$dns_ip\" ]; then dev=\$(ip route get \"\$dns_ip\" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if(\$i==\"dev\" && (i+1)<=NF){print \$(i+1); exit}}}'); echo \"出接口: \${dev:-未获取}\"; else echo '出接口: 未获取'; fi; if [ -n \"\$dns_ip\" ] && command -v dig >/dev/null 2>&1; then echo '=== UDP 443 DNS探测 ==='; echo \"探测命令: dig @\$dns_ip apple.com A +time=1 +tries=2 -p 443 +noall +answer +comments +stats\"; dig_output=\$(dig @\"\$dns_ip\" apple.com A +time=1 +tries=2 -p 443 +noall +answer +comments +stats 2>&1); printf '%s\n' \"\$dig_output\"; if printf '%s\n' \"\$dig_output\" | grep -Eq 'status: NOERROR|status: FORMERR|[[:space:]]IN[[:space:]]+(A|AAAA|CNAME)[[:space:]]'; then if printf '%s\n' \"\$dig_output\" | grep -q 'status: FORMERR'; then echo '中心 DNS UDP端口探测成功(FORMERR表示服务端已响应)'; else echo '中心 DNS UDP端口探测成功'; fi; else echo '中心 DNS UDP端口探测失败'; fi; elif ! command -v dig >/dev/null 2>&1; then echo '中心 DNS UDP端口探测失败: dig命令不存在'; else echo '中心 DNS UDP端口探测失败: 未获取到中心DNS地址'; fi"
        CENTER_DNS_UDP_OUTPUT=$(eval "$CENTER_DNS_UDP_CMD" 2>&1 || true)
        CENTER_DNS_UDP_IP=$(awk -F '=' '/add-dns-server-ip/ {print $2; exit}' /etc/dnsmasq.d/cpe.conf 2>/dev/null)
        CENTER_DNS_UDP_ISSUES=()
        echo "$CENTER_DNS_UDP_OUTPUT" | grep -q '认证凭据 验证成功' || CENTER_DNS_UDP_ISSUES+=("认证凭据校验失败")
        [[ -n "$CENTER_DNS_UDP_IP" ]] || CENTER_DNS_UDP_ISSUES+=("未获取到中心DNS地址")
        echo "$CENTER_DNS_UDP_OUTPUT" | grep -q '中心 DNS UDP端口探测成功' || CENTER_DNS_UDP_ISSUES+=("中心DNS UDP 443探测失败")
        if [[ "${#CENTER_DNS_UDP_ISSUES[@]}" -eq 0 ]]; then
            if echo "$CENTER_DNS_UDP_OUTPUT" | grep -q 'status: FORMERR'; then
                CENTER_DNS_UDP_EXTRA="${GREEN}◆ 判断原因: 认证凭据验证成功，中心DNS ${CENTER_DNS_UDP_IP}:443 UDP探测已收到服务端响应，返回FORMERR也按成功处理${NC}"
            else
                CENTER_DNS_UDP_EXTRA="${GREEN}◆ 判断原因: 认证凭据验证成功，中心DNS ${CENTER_DNS_UDP_IP}:443 UDP探测成功${NC}"
            fi
            CENTER_DNS_UDP_CODE=0
        else
            CENTER_DNS_UDP_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${CENTER_DNS_UDP_ISSUES[*]}")${NC}"
            CENTER_DNS_UDP_CODE=1
        fi

        print_check "中心 DNS UDP端口探测" \
            "$CENTER_DNS_UDP_CMD" \
            "认证凭据应有效，中心DNS UDP 443端口应可完成DNS解析探测" \
            "请检查认证凭据、/etc/dnsmasq.d/cpe.conf中的add-dns-server-ip、UDP 443出站策略和中心DNS服务状态" \
            "$CENTER_DNS_UDP_EXTRA" \
            "$CENTER_DNS_UDP_CODE" \
            "$CENTER_DNS_UDP_OUTPUT"
    fi
}

check_pop_nodes() {
    # POP节点探测（提取主备POP地址到extra_info）
    MASTER_POP=$(awk '/Endpoint = / {print $3}' /opt/feilian/cpe/conf/tun0_master.conf 2>/dev/null | awk -F : '{print $1}')
    SLAVE_POP=$(awk '/Endpoint = / {print $3}' /opt/feilian/cpe/conf/tun0_slave.conf 2>/dev/null | awk -F : '{print $1}')
    MASTER_POP_DEV=$(get_route_dev_for_target "$MASTER_POP")
    SLAVE_POP_DEV=$(get_route_dev_for_target "$SLAVE_POP")
    MASTER_POP_LABEL="${MASTER_POP_DEV:-未获取}"
    SLAVE_POP_LABEL="${SLAVE_POP_DEV:-未获取}"
    MASTER_POP_PING_IF=""
    SLAVE_POP_PING_IF=""
    [[ -n "$MASTER_POP_DEV" ]] && MASTER_POP_PING_IF="-I $MASTER_POP_DEV"
    [[ -n "$SLAVE_POP_DEV" ]] && SLAVE_POP_PING_IF="-I $SLAVE_POP_DEV"
    POP_CMD="printf '%s\n' \"主POP出接口: ${MASTER_POP_LABEL}\"; ping ${MASTER_POP_PING_IF} -W2 -c3 $MASTER_POP; echo '---'; printf '%s\n' \"备POP出接口: ${SLAVE_POP_LABEL}\"; ping ${SLAVE_POP_PING_IF} -W2 -c3 $SLAVE_POP"
    POP_OUTPUT=$(eval "$POP_CMD" 2>&1 || true)
    POP_MASTER_LOSS=$(echo "$POP_OUTPUT" | awk -F',' '/packet loss/ {gsub(/[^0-9.]/, "", $3); count++; if (count==1) {print $3; exit}}')
    POP_SLAVE_LOSS=$(echo "$POP_OUTPUT" | awk -F',' '/packet loss/ {gsub(/[^0-9.]/, "", $3); count++; if (count==2) {print $3; exit}}')
    POP_MASTER_AVG=$(echo "$POP_OUTPUT" | awk -F'/' '/^rtt|^round-trip/ {count++; if (count==1) {print $5; exit}}')
    POP_SLAVE_AVG=$(echo "$POP_OUTPUT" | awk -F'/' '/^rtt|^round-trip/ {count++; if (count==2) {print $5; exit}}')
    POP_MASTER_LOSS=${POP_MASTER_LOSS:-100}
    POP_SLAVE_LOSS=${POP_SLAVE_LOSS:-100}
    POP_MASTER_AVG=${POP_MASTER_AVG:-999}
    POP_SLAVE_AVG=${POP_SLAVE_AVG:-999}
    POP_ISSUES=()
    [[ -n "$MASTER_POP" ]] || POP_ISSUES+=("未获取到主POP地址")
    [[ -n "$SLAVE_POP" ]] || POP_ISSUES+=("未获取到备POP地址")
    [[ "$POP_MASTER_LOSS" == "0" ]] || POP_ISSUES+=("主POP丢包率${POP_MASTER_LOSS}%>0%")
    [[ "$POP_SLAVE_LOSS" == "0" ]] || POP_ISSUES+=("备POP丢包率${POP_SLAVE_LOSS}%>0%")
    compare_float_lt "$POP_MASTER_AVG" "100" || POP_ISSUES+=("主POP平均延迟${POP_MASTER_AVG}ms≥100ms")
    compare_float_lt "$POP_SLAVE_AVG" "100" || POP_ISSUES+=("备POP平均延迟${POP_SLAVE_AVG}ms≥100ms")
    if compare_float_gt "$POP_MASTER_LOSS" "$POP_SLAVE_LOSS" || compare_float_gt "$POP_MASTER_AVG" "$POP_SLAVE_AVG"; then
        POP_ISSUES+=("主POP链路质量比备POP差(主${POP_MASTER_LOSS}%/${POP_MASTER_AVG}ms，备${POP_SLAVE_LOSS}%/${POP_SLAVE_AVG}ms)")
    fi
    if [[ "${#POP_ISSUES[@]}" -eq 0 ]]; then
        POP_EXTRA="${GREEN}◆ 判断原因: 主POP ${MASTER_POP} 丢包${POP_MASTER_LOSS}% 平均${POP_MASTER_AVG}ms，备POP ${SLAVE_POP} 丢包${POP_SLAVE_LOSS}% 平均${POP_SLAVE_AVG}ms，主链路质量不差于备链路${NC}"
        POP_CODE=0
    else
        POP_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${POP_ISSUES[*]}")${NC}"
        POP_CODE=1
    fi

    print_check "POP节点探测(主备)" \
        "$POP_CMD" \
        "主备POP节点应均可ping通，延迟<100ms，且主链路质量不应比备链路差" \
        "请检查主POP链路质量、运营商出口、路由调度和主备POP配置" \
        "$POP_EXTRA" \
        "$POP_CODE" \
        "$POP_OUTPUT"
}

check_tunnel_connectivity() {
    # 隧道连通性（提取隧道IP到extra_info）
    MASTER_TUN=$(ip ro show table 1998 2>/dev/null | awk '/tun0_master/ {print $1}')
    [ -z "$MASTER_TUN" ] && MASTER_TUN=$(ip ro show table 1996 | awk '/tun0_master/ {print $1}')
    SLAVE_TUN=$(ip ro show table 1998 2>/dev/null | awk '/tun0_slave/ {print $1}')
    [ -z "$SLAVE_TUN" ] && SLAVE_TUN=$(ip ro show table 1997 | awk '/tun0_slave/ {print $1}')
    MASTER_TUN_DEV=$(ip ro show table 1998 2>/dev/null | awk '/tun0_master/ {print "tun0_master"; exit}')
    [ -z "$MASTER_TUN_DEV" ] && MASTER_TUN_DEV=$(ip ro show table 1996 2>/dev/null | awk '/tun0_master/ {print "tun0_master"; exit}')
    SLAVE_TUN_DEV=$(ip ro show table 1998 2>/dev/null | awk '/tun0_slave/ {print "tun0_slave"; exit}')
    [ -z "$SLAVE_TUN_DEV" ] && SLAVE_TUN_DEV=$(ip ro show table 1997 2>/dev/null | awk '/tun0_slave/ {print "tun0_slave"; exit}')
    MASTER_TUN_LABEL="${MASTER_TUN_DEV:-未获取}"
    SLAVE_TUN_LABEL="${SLAVE_TUN_DEV:-未获取}"
    MASTER_TUN_PING_IF=""
    SLAVE_TUN_PING_IF=""
    [[ -n "$MASTER_TUN_DEV" ]] && MASTER_TUN_PING_IF="-I $MASTER_TUN_DEV"
    [[ -n "$SLAVE_TUN_DEV" ]] && SLAVE_TUN_PING_IF="-I $SLAVE_TUN_DEV"
    TUN_CMD="printf '%s\n' \"主隧道出接口: ${MASTER_TUN_LABEL}\"; ping ${MASTER_TUN_PING_IF} -W2 -c3 $MASTER_TUN; echo '---'; printf '%s\n' \"备隧道出接口: ${SLAVE_TUN_LABEL}\"; ping ${SLAVE_TUN_PING_IF} -W2 -c3 $SLAVE_TUN"
    TUN_OUTPUT=$(eval "$TUN_CMD" 2>&1 || true)
    TUN_MASTER_LOSS=$(echo "$TUN_OUTPUT" | awk -F',' '/packet loss/ {gsub(/[^0-9.]/, "", $3); count++; if (count==1) {print $3; exit}}')
    TUN_SLAVE_LOSS=$(echo "$TUN_OUTPUT" | awk -F',' '/packet loss/ {gsub(/[^0-9.]/, "", $3); count++; if (count==2) {print $3; exit}}')
    TUN_MASTER_AVG=$(echo "$TUN_OUTPUT" | awk -F'/' '/^rtt|^round-trip/ {count++; if (count==1) {print $5; exit}}')
    TUN_SLAVE_AVG=$(echo "$TUN_OUTPUT" | awk -F'/' '/^rtt|^round-trip/ {count++; if (count==2) {print $5; exit}}')
    TUN_MASTER_LOSS=${TUN_MASTER_LOSS:-100}
    TUN_SLAVE_LOSS=${TUN_SLAVE_LOSS:-100}
    TUN_MASTER_AVG=${TUN_MASTER_AVG:-999}
    TUN_SLAVE_AVG=${TUN_SLAVE_AVG:-999}
    TUN_ISSUES=()
    [[ -n "$MASTER_TUN" ]] || TUN_ISSUES+=("未获取到主隧道地址")
    [[ -n "$SLAVE_TUN" ]] || TUN_ISSUES+=("未获取到备隧道地址")
    [[ "$TUN_MASTER_LOSS" == "0" ]] || TUN_ISSUES+=("主隧道丢包率${TUN_MASTER_LOSS}%>0%")
    [[ "$TUN_SLAVE_LOSS" == "0" ]] || TUN_ISSUES+=("备隧道丢包率${TUN_SLAVE_LOSS}%>0%")
    if compare_float_gt "$TUN_MASTER_LOSS" "$TUN_SLAVE_LOSS" || compare_float_gt "$TUN_MASTER_AVG" "$TUN_SLAVE_AVG"; then
        TUN_ISSUES+=("主隧道链路质量比备隧道差(主${TUN_MASTER_LOSS}%/${TUN_MASTER_AVG}ms，备${TUN_SLAVE_LOSS}%/${TUN_SLAVE_AVG}ms)")
    fi
    if [[ "${#TUN_ISSUES[@]}" -eq 0 ]]; then
        TUN_EXTRA="${GREEN}◆ 判断原因: 主隧道 ${MASTER_TUN} 丢包${TUN_MASTER_LOSS}% 平均${TUN_MASTER_AVG}ms，备隧道 ${SLAVE_TUN} 丢包${TUN_SLAVE_LOSS}% 平均${TUN_SLAVE_AVG}ms，主链路质量不差于备链路${NC}"
        TUN_CODE=0
    else
        TUN_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${TUN_ISSUES[*]}")${NC}"
        TUN_CODE=1
    fi

    print_check "隧道连通性(主备)" \
        "$TUN_CMD" \
        "主备隧道应可达且0丢包，主链路质量不应比备链路差" \
        "请检查主隧道链路质量、POP调度、路由策略和feilian-tun服务状态" \
        "$TUN_EXTRA" \
        "$TUN_CODE" \
        "$TUN_OUTPUT"
}

format_wireguard_tunnel_analysis() {
    local iface="$1"
    local cli_endpoint="$2"
    local cli_status="$3"
    local latest_handshake="$4"
    local transfer="$5"
    local tunnel_json="$6"
    local pop_info_json="$7"
    local conf_endpoint="$8"
    local fixed_ip="${9:-}"
    local tunnel_id=""
    local tunnel_name=""
    local tunnel_isp=""
    local tunnel_public_ip=""
    local tunnel_vpn_port=""
    local expected_endpoint=""
    local pop_status=""
    local cli_ip=""
    local cli_port=""
    local cli_match=""
    local fixed_match=""

    tunnel_id=$(parse_json_number_by_sed "$tunnel_json" "id")
    tunnel_name=$(parse_json_field_by_sed "$tunnel_json" "name")
    tunnel_isp=$(parse_json_field_by_sed "$tunnel_json" "isp")
    tunnel_public_ip=$(parse_json_field_by_sed "$tunnel_json" "public_ip")
    tunnel_vpn_port=$(parse_json_number_by_sed "$tunnel_json" "vpn_port")
    expected_endpoint="${tunnel_public_ip}${tunnel_vpn_port:+:${tunnel_vpn_port}}"
    pop_status=$(parse_json_number_by_sed "$pop_info_json" "status")
    cli_ip=$(extract_endpoint_ip "$cli_endpoint")
    cli_port="${cli_endpoint##*:}"
    [[ "$cli_port" == "$cli_endpoint" ]] && cli_port="N/A"
    if [[ -n "$expected_endpoint" && "$cli_endpoint" == "$expected_endpoint" ]]; then
        cli_match="一致"
    elif [[ -n "$expected_endpoint" ]]; then
        cli_match="不一致，CLI=${cli_endpoint:-未获取}, ucistore=${expected_endpoint}"
    else
        cli_match="未获取到ucistore隧道配置"
    fi
    if [[ -n "$fixed_ip" && -n "$tunnel_public_ip" && "$fixed_ip" == "$tunnel_public_ip" ]]; then
        fixed_match="一致"
    elif [[ -n "$fixed_ip" && -n "$tunnel_public_ip" ]]; then
        fixed_match="不一致，固定选点=${fixed_ip}, ucistore=${tunnel_public_ip}"
    elif [[ -n "$fixed_ip" ]]; then
        fixed_match="未获取到ucistore隧道配置"
    else
        fixed_match="未配置固定选点"
    fi

    cat <<EOF
${iface}:
  - 当前feilian-tun-cli: IP=${cli_ip:-未获取}, 端口=${cli_port:-N/A}, 握手=${cli_status:-未获取}, 最近握手=${latest_handshake:-未获取}, 传输=${transfer:-未获取}
  - ucistore隧道信息: IP=${tunnel_public_ip:-N/A}, 端口=${tunnel_vpn_port:-N/A}, POP_ID=${tunnel_id:-N/A}, 名称=${tunnel_name:-N/A}, 运营商=${tunnel_isp:-N/A}, status=${pop_status:-N/A}
  - 固定选点配置: IP=${fixed_ip:-未配置}
  一致性: CLI/ucistore=${cli_match}; 固定选点/ucistore=${fixed_match}
EOF
}

check_wireguard_cli() {
    TUN_CLI_CMD="/opt/feilian/cpe/bin/feilian-tun-cli 2>/dev/null || echo 'feilian-tun-cli命令不存在'"
    TUN_CLI_OUTPUT=$(eval "$TUN_CLI_CMD" 2>&1 || true)
    TUN_CLI_ISSUES=()
    echo "$TUN_CLI_OUTPUT" | grep -q '^interface: tun0_master' || TUN_CLI_ISSUES+=("未发现tun0_master接口信息")
    echo "$TUN_CLI_OUTPUT" | grep -q '^interface: tun0_slave' || TUN_CLI_ISSUES+=("未发现tun0_slave接口信息")
    TUN_MASTER_STATUS=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_master/{in_block=1; next} /^interface: /{in_block=0} in_block && /current handshake status:/ {print $4; exit}')
    TUN_SLAVE_STATUS=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_slave/{in_block=1; next} /^interface: /{in_block=0} in_block && /current handshake status:/ {print $4; exit}')
    [[ "$TUN_MASTER_STATUS" == "connected" ]] || TUN_CLI_ISSUES+=("tun0_master握手状态=${TUN_MASTER_STATUS:-未获取}，应为connected")
    [[ "$TUN_SLAVE_STATUS" == "connected" ]] || TUN_CLI_ISSUES+=("tun0_slave握手状态=${TUN_SLAVE_STATUS:-未获取}，应为connected")
    if [[ "${#TUN_CLI_ISSUES[@]}" -eq 0 ]]; then
        TUN_CLI_EXTRA="${GREEN}◆ 判断原因: tun0_master和tun0_slave均存在，current handshake status均为connected${NC}"
        TUN_CLI_CODE=0
    else
        TUN_CLI_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${TUN_CLI_ISSUES[*]}")${NC}"
        TUN_CLI_CODE=1
    fi

    print_check "WireGuard隧道详细状态(feilian-tun-cli)" \
        "$TUN_CLI_CMD" \
        "输出必须包含tun0_master和tun0_slave，且current handshake status均为connected" \
        "请检查feilian-tun服务、POP连通性和最近握手状态" \
        "$TUN_CLI_EXTRA" \
        "$TUN_CLI_CODE" \
        "$TUN_CLI_OUTPUT"
}

check_wireguard_config_consistency() {
    local ucistore="/opt/feilian/cpe/.cache/ucistore"
    local all_pop_json
    local probe_json
    local pop_latency_output
    local pop_latency_failed_count
    local pop_latency_total
    TUN_CLI_CMD="/opt/feilian/cpe/bin/feilian-tun-cli 2>/dev/null || echo 'feilian-tun-cli命令不存在'"
    TUN_CLI_OUTPUT=$(eval "$TUN_CLI_CMD" 2>&1 || true)
    TUN_CONFIG_ISSUES=()
    TUN_MASTER_STATUS=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_master/{in_block=1; next} /^interface: /{in_block=0} in_block && /current handshake status:/ {print $4; exit}')
    TUN_SLAVE_STATUS=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_slave/{in_block=1; next} /^interface: /{in_block=0} in_block && /current handshake status:/ {print $4; exit}')
    TUN_MASTER_ENDPOINT=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_master/{in_block=1; next} /^interface: /{in_block=0} in_block && /endpoint:/ {print $2; exit}')
    TUN_SLAVE_ENDPOINT=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_slave/{in_block=1; next} /^interface: /{in_block=0} in_block && /endpoint:/ {print $2; exit}')
    TUN_MASTER_LATEST_HANDSHAKE=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_master/{in_block=1; next} /^interface: /{in_block=0} in_block && /latest handshake:/ {sub(/^[[:space:]]*latest handshake:[[:space:]]*/, ""); print; exit}')
    TUN_SLAVE_LATEST_HANDSHAKE=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_slave/{in_block=1; next} /^interface: /{in_block=0} in_block && /latest handshake:/ {sub(/^[[:space:]]*latest handshake:[[:space:]]*/, ""); print; exit}')
    TUN_MASTER_TRANSFER=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_master/{in_block=1; next} /^interface: /{in_block=0} in_block && /transfer:/ {sub(/^[[:space:]]*transfer:[[:space:]]*/, ""); print; exit}')
    TUN_SLAVE_TRANSFER=$(echo "$TUN_CLI_OUTPUT" | awk '/^interface: tun0_slave/{in_block=1; next} /^interface: /{in_block=0} in_block && /transfer:/ {sub(/^[[:space:]]*transfer:[[:space:]]*/, ""); print; exit}')
    TUN_MASTER_TUNNEL_JSON=$(get_ucistore_option_json "master_tunnel")
    TUN_SLAVE_TUNNEL_JSON=$(get_ucistore_option_json "slave_tunnel")
    TUN_MASTER_POP_INFO_JSON=$(get_ucistore_option_json "master_pop_info")
    TUN_SLAVE_POP_INFO_JSON=$(get_ucistore_option_json "slave_pop_info")
    TUN_MASTER_CONF_ENDPOINT=$(awk -F '= ' '/^Endpoint = / {print $2; exit}' /opt/feilian/cpe/conf/tun0_master.conf 2>/dev/null || true)
    TUN_SLAVE_CONF_ENDPOINT=$(awk -F '= ' '/^Endpoint = / {print $2; exit}' /opt/feilian/cpe/conf/tun0_slave.conf 2>/dev/null || true)
    TUN_FIXED_MASTER_IP=$(sed -n 's/^SPECIFIC_MASTER_POP_SERVER=//p' /opt/feilian/cpe/conf/cpe.env 2>/dev/null | tail -1)
    TUN_FIXED_SLAVE_IP=$(sed -n 's/^SPECIFIC_SLAVE_POP_SERVER=//p' /opt/feilian/cpe/conf/cpe.env 2>/dev/null | tail -1)
    TUN_MASTER_PUBLIC_IP=$(parse_json_field_by_sed "$TUN_MASTER_TUNNEL_JSON" "public_ip")
    TUN_SLAVE_PUBLIC_IP=$(parse_json_field_by_sed "$TUN_SLAVE_TUNNEL_JSON" "public_ip")
    TUN_MASTER_VPN_PORT=$(parse_json_number_by_sed "$TUN_MASTER_TUNNEL_JSON" "vpn_port")
    TUN_SLAVE_VPN_PORT=$(parse_json_number_by_sed "$TUN_SLAVE_TUNNEL_JSON" "vpn_port")
    TUN_MASTER_EXPECTED_ENDPOINT="${TUN_MASTER_PUBLIC_IP}${TUN_MASTER_VPN_PORT:+:${TUN_MASTER_VPN_PORT}}"
    TUN_SLAVE_EXPECTED_ENDPOINT="${TUN_SLAVE_PUBLIC_IP}${TUN_SLAVE_VPN_PORT:+:${TUN_SLAVE_VPN_PORT}}"
    TUN_MASTER_DISPLAY=$(format_wireguard_tunnel_analysis "tun0_master" "$TUN_MASTER_ENDPOINT" "$TUN_MASTER_STATUS" "$TUN_MASTER_LATEST_HANDSHAKE" "$TUN_MASTER_TRANSFER" "$TUN_MASTER_TUNNEL_JSON" "$TUN_MASTER_POP_INFO_JSON" "$TUN_MASTER_CONF_ENDPOINT" "$TUN_FIXED_MASTER_IP")
    TUN_SLAVE_DISPLAY=$(format_wireguard_tunnel_analysis "tun0_slave" "$TUN_SLAVE_ENDPOINT" "$TUN_SLAVE_STATUS" "$TUN_SLAVE_LATEST_HANDSHAKE" "$TUN_SLAVE_TRANSFER" "$TUN_SLAVE_TUNNEL_JSON" "$TUN_SLAVE_POP_INFO_JSON" "$TUN_SLAVE_CONF_ENDPOINT" "$TUN_FIXED_SLAVE_IP")
    TUN_CONFIG_DISPLAY_OUTPUT=$(cat <<EOF
【配置关联分析】
${TUN_MASTER_DISPLAY}
${TUN_SLAVE_DISPLAY}
EOF
)
    pop_latency_output=$(show_all_pop_latency_info)
    [[ -n "$TUN_MASTER_EXPECTED_ENDPOINT" ]] || TUN_CONFIG_ISSUES+=("未获取到master_tunnel公网IP/VPN端口配置")
    [[ -n "$TUN_SLAVE_EXPECTED_ENDPOINT" ]] || TUN_CONFIG_ISSUES+=("未获取到slave_tunnel公网IP/VPN端口配置")
    [[ -z "$TUN_MASTER_EXPECTED_ENDPOINT" || "$TUN_MASTER_ENDPOINT" == "$TUN_MASTER_EXPECTED_ENDPOINT" ]] || TUN_CONFIG_ISSUES+=("tun0_master CLI=${TUN_MASTER_ENDPOINT:-未获取}，ucistore=${TUN_MASTER_EXPECTED_ENDPOINT}")
    [[ -z "$TUN_SLAVE_EXPECTED_ENDPOINT" || "$TUN_SLAVE_ENDPOINT" == "$TUN_SLAVE_EXPECTED_ENDPOINT" ]] || TUN_CONFIG_ISSUES+=("tun0_slave CLI=${TUN_SLAVE_ENDPOINT:-未获取}，ucistore=${TUN_SLAVE_EXPECTED_ENDPOINT}")
    [[ -z "$TUN_FIXED_MASTER_IP" || -z "$TUN_MASTER_PUBLIC_IP" || "$TUN_FIXED_MASTER_IP" == "$TUN_MASTER_PUBLIC_IP" ]] || TUN_CONFIG_ISSUES+=("固定主选点=${TUN_FIXED_MASTER_IP}，ucistore=${TUN_MASTER_PUBLIC_IP}")
    [[ -z "$TUN_FIXED_SLAVE_IP" || -z "$TUN_SLAVE_PUBLIC_IP" || "$TUN_FIXED_SLAVE_IP" == "$TUN_SLAVE_PUBLIC_IP" ]] || TUN_CONFIG_ISSUES+=("固定备选点=${TUN_FIXED_SLAVE_IP}，ucistore=${TUN_SLAVE_PUBLIC_IP}")
    if [[ ! -f "$ucistore" ]]; then
        TUN_CONFIG_ISSUES+=("未找到 $ucistore")
    else
        all_pop_json=$(get_ucistore_option_json "all_pop_servers")
        probe_json=$(get_ucistore_option_json "out_band_probe_result")
        [[ -n "$all_pop_json" ]] || TUN_CONFIG_ISSUES+=("未找到 all_pop_servers")
        [[ -n "$probe_json" ]] || TUN_CONFIG_ISSUES+=("未找到 out_band_probe_result")
    fi
    pop_latency_total=$(printf '%s\n' "$pop_latency_output" | awk 'BEGIN{count=0} /^[^0-9]*[0-9]+[[:space:]]/ {count++} END{print count}')
    pop_latency_failed_count=$(printf '%s\n' "$pop_latency_output" | awk 'BEGIN{count=0} /^[^0-9]*[0-9]+[[:space:]]+true[[:space:]]/ {count++} END{print count}')
    [[ "${pop_latency_total:-0}" -gt 0 ]] || TUN_CONFIG_ISSUES+=("POP延迟信息解析为空")
    [[ "${pop_latency_failed_count:-0}" -eq 0 ]] || TUN_CONFIG_ISSUES+=("存在${pop_latency_failed_count}个POP探测失败")
    TUN_CONFIG_DISPLAY_OUTPUT=$(cat <<EOF
${TUN_CONFIG_DISPLAY_OUTPUT}

${pop_latency_output}
EOF
)
    if [[ "${#TUN_CONFIG_ISSUES[@]}" -eq 0 ]]; then
        TUN_CONFIG_EXTRA="${GREEN}◆ 判断原因: feilian-tun-cli、ucistore隧道信息和固定选点配置一致；已解析${pop_latency_total}条POP延迟信息，均未标记探测失败${NC}"
        TUN_CONFIG_CODE=0
    else
        TUN_CONFIG_EXTRA="${RED}◆ 判断原因: $(IFS='，'; echo "${TUN_CONFIG_ISSUES[*]}")${NC}"
        TUN_CONFIG_CODE=1
    fi

    print_check "WireGuard隧道配置一致性与所有POP延迟信息" \
        "/opt/feilian/cpe/bin/feilian-tun-cli; awk -F \"'\" '/option master_tunnel|option slave_tunnel|option master_pop_info|option slave_pop_info|option all_pop_servers|option out_band_probe_result/ {print}' /opt/feilian/cpe/.cache/ucistore 2>/dev/null; grep -E '^SPECIFIC_(MASTER|SLAVE)_POP_SERVER=' /opt/feilian/cpe/conf/cpe.env 2>/dev/null" \
        "feilian-tun-cli endpoint应与ucistore master_tunnel/slave_tunnel一致；固定选点如已配置应与ucistore隧道一致；POP延迟信息应可解析并按延迟升序展示" \
        "请检查ucistore隧道配置、固定选点配置、out_band_probe_result和feilian-tun当前endpoint，必要时清理缓存或重新选点" \
        "$TUN_CONFIG_EXTRA" \
        "$TUN_CONFIG_CODE" \
        "$TUN_CONFIG_DISPLAY_OUTPUT"
}

format_tunnel_quality_measure_output() {
    # 解析 feilian-tun-ctrl measure 的多隧道输出，统一将 us 转为 ms，并生成适合报告复用的 Markdown 表格。
    awk '
        function reset_record() {
            tunn = mode = endpoint = running = task_id = local_id = ""
            tx_packets = tx_bytes = rx_packets = rx_bytes = ""
            q_count = loss_count = rtt_count = rtt_zero_count = spike_count = 0
            loss_sum = max_loss = jitter_sum = 0
            rtt_all_zero = no_receive_traffic = all_loss = 0
            delete rtt_values
            delete sorted
        }
        function bytes_human(bytes) {
            bytes += 0
            if (bytes >= 1048576) return sprintf("%.2fMB", bytes / 1048576)
            if (bytes >= 1024) return sprintf("%.2fKB", bytes / 1024)
            return bytes "B"
        }
        function us_to_ms(value) {
            return sprintf("%.2f", (value + 0) / 1000)
        }
        function append_reason(text) {
            if (text == "") return
            abnormal_reasons = abnormal_reasons == "" ? text : abnormal_reasons "；" text
        }
        function sort_numbers(n,    i,j,tmp) {
            for (i = 1; i <= n; i++) sorted[i] = rtt_values[i]
            for (i = 2; i <= n; i++) {
                tmp = sorted[i]
                j = i - 1
                while (j >= 1 && sorted[j] > tmp) {
                    sorted[j + 1] = sorted[j]
                    j--
                }
                sorted[j + 1] = tmp
            }
        }
        function format_loss_pct(value) {
            value += 0
            if (value > 0 && value < 0.01) return "<0.01%"
            return sprintf("%.2f%%", value)
        }
        function analyze_loss(    ratio,avg_loss) {
            if (q_count <= 0) {
                loss_desc = "N/A"
                sustained_loss = 0
                return
            }
            ratio = loss_count * 100 / q_count
            if (loss_count == 0) {
                loss_desc = "0.00%"
                sustained_loss = 0
            } else if (ratio < 5) {
                loss_desc = format_loss_pct(max_loss)
                sustained_loss = 0
            } else {
                avg_loss = loss_sum / q_count
                loss_desc = format_loss_pct(max_loss)
                sustained_loss = 1
            }
            all_loss = (q_count > 0 && loss_count == q_count)
        }
        function analyze_rtt(    i,median,threshold,sum,valid,min,max) {
            if (rtt_count <= 0) {
                avg_rtt_ms = "N/A"
                rtt_range = "N/A"
                spike_note = "无RTT采样"
                return
            }
            sort_numbers(rtt_count)
            if (rtt_count % 2 == 1) {
                median = sorted[(rtt_count + 1) / 2]
            } else {
                median = (sorted[rtt_count / 2] + sorted[rtt_count / 2 + 1]) / 2
            }
            threshold = median * 3
            sum = valid = spike_count = 0
            min = max = ""
            for (i = 1; i <= rtt_count; i++) {
                if (rtt_values[i] > threshold) {
                    spike_count++
                    continue
                }
                sum += rtt_values[i]
                valid++
                if (min == "" || rtt_values[i] < min) min = rtt_values[i]
                if (max == "" || rtt_values[i] > max) max = rtt_values[i]
            }
            if (valid <= 0) {
                avg_rtt_ms = "N/A"
                rtt_range = "N/A"
                spike_note = "RTT有效样本为空"
                return
            }
            rtt_all_zero = (rtt_count > 0 && rtt_zero_count == rtt_count)
            avg_rtt_ms = sprintf("%.2f", (sum / valid) / 1000)
            rtt_range = sprintf("%.2f~%.2f", min / 1000, max / 1000)
            spike_note = spike_count > 0 ? "存在偶发时延尖峰" : "-"
        }
        function rate_quality(    avg_rtt,avg_jitter,online) {
            avg_rtt = avg_rtt_ms + 0
            avg_jitter = avg_jitter_ms + 0
            online = (running == "true")
            abnormal_reason = ""
            if (!online) abnormal_reason = abnormal_reason "运行状态异常 "
            if (no_receive_traffic) abnormal_reason = abnormal_reason "有发送但无接收流量 "
            if (avg_rtt_ms == "N/A") abnormal_reason = abnormal_reason "RTT采样不可用 "
            else if (rtt_all_zero) abnormal_reason = abnormal_reason "RTT采样全为0 "
            else if (avg_rtt >= 10) abnormal_reason = abnormal_reason "平均基线RTT>=10ms "
            if (all_loss) abnormal_reason = abnormal_reason "质量采样全部丢包 "
            if (sustained_loss) abnormal_reason = abnormal_reason "存在持续性丢包 "
            if (avg_jitter_ms == "N/A") abnormal_reason = abnormal_reason "抖动采样不可用 "
            else if (avg_jitter >= 1) abnormal_reason = abnormal_reason "平均抖动>=1ms "
            if (abnormal_reason != "") {
                rating = "异常"
                return
            }
            if (avg_rtt < 7 && avg_jitter < 0.2) rating = "最优"
            else if (avg_rtt < 8 && avg_jitter < 0.3) rating = "优秀"
            else if (avg_rtt < 10 && avg_jitter < 0.5) rating = "良好"
            else rating = "异常"
        }
        function flush_record(    status,tx,rx,detail) {
            if (tunn == "") return
            tunnel_total++
            if (running == "false") offline_count++
            no_receive_traffic = ((tx_packets + 0) > 0 && (rx_packets + 0) == 0 && (rx_bytes + 0) == 0)
            analyze_rtt()
            avg_jitter_ms = q_count > 0 ? sprintf("%.2f", (jitter_sum / q_count) / 1000) : "N/A"
            analyze_loss()
            rate_quality()
            status = running == "true" ? "正常运行" : "异常离线"
            tx = (tx_packets == "" ? "N/A" : tx_packets) "包/" bytes_human(tx_bytes)
            rx = (rx_packets == "" ? "N/A" : rx_packets) "包/" bytes_human(rx_bytes)
            detail = rating == "异常" ? abnormal_reason : spike_note
            gsub(/[[:space:]]+$/, "", detail)
            if (detail == "") detail = "-"
            printf "  %-12s %-8s %-5s %-22s %-16s %-16s %-8s %-13s %-8s %-8s %s/%s\n", \
                iface, tunn, mode, endpoint, tx, rx, avg_rtt_ms, rtt_range, avg_jitter_ms, loss_desc, status, rating
            if (detail != "-") {
                note_details = note_details sprintf("  - %s: %s\n", tunn, detail)
            }
            if (rating == "异常") {
                abnormal_count++
                append_reason(iface "/" tunn ": " abnormal_reason)
            }
            reset_record()
        }
        BEGIN {
            print "【飞连CPE隧道质量检测】"
            print "说明: 当前仅检测主隧道接口 tun0_master"
            print "列说明: IFACE=接口, TUN=隧道ID, MODE=模式, ENDPOINT=POP节点地址, TX=发送流量, RX=接收流量, RTT=平均基线RTT(ms), RANGE=RTT波动范围(ms), JIT=平均抖动(ms), LOSS=最大丢包率, RESULT=运行状态/质量评级"
            print "明细:"
            printf "  %-12s %-8s %-5s %-22s %-16s %-16s %-8s %-13s %-8s %-8s %s\n", \
                "IFACE", "TUN", "MODE", "ENDPOINT", "TX", "RX", "RTT", "RANGE", "JIT", "LOSS", "RESULT"
            printf "  %-12s %-8s %-5s %-22s %-16s %-16s %-8s %-13s %-8s %-8s %s\n", \
                "------------", "--------", "-----", "----------------------", "----------------", "----------------", "--------", "-------------", "--------", "--------", "------"
            reset_record()
        }
        /^### interface: / {
            flush_record()
            iface = $3
            next
        }
        /^tunn:/ {
            flush_record()
            tunn = $2
            next
        }
        /^mode:/ {
            mode = $2
            next
        }
        /^(endpoint|enpoint):/ {
            endpoint = $0
            sub(/^[^:]+:[[:space:]]*/, "", endpoint)
            gsub(/^Some\(|\)$/, "", endpoint)
            next
        }
        /^tx packets:/ {
            tx_packets = $3
            tx_bytes = $6
            next
        }
        /^rx packets:/ {
            rx_packets = $3
            rx_bytes = $6
            next
        }
        /^running:/ {
            running = $2
            next
        }
        /^task id:/ {
            task_id = $3
            next
        }
        /^local id:/ {
            local_id = $3
            next
        }
        /^quality:/ {
            line = $0
            while (match(line, /loss: [-+0-9.eE]+, rtt: [0-9]+, jitter: [0-9]+/)) {
                seg = substr(line, RSTART, RLENGTH)
                loss = seg
                sub(/^.*loss: /, "", loss)
                sub(/,.*/, "", loss)
                loss += 0
                jitter = seg
                sub(/^.*jitter: /, "", jitter)
                jitter += 0
                q_count++
                loss_sum += loss
                if (loss > 0) {
                    loss_count++
                    if (loss > max_loss) max_loss = loss
                }
                jitter_sum += jitter
                line = substr(line, RSTART + RLENGTH)
            }
            next
        }
        /^rtt:/ {
            line = $0
            gsub(/[^0-9]+/, " ", line)
            n = split(line, parts, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                if (parts[i] != "") {
                    rtt_count++
                    rtt_values[rtt_count] = parts[i] + 0
                    if ((parts[i] + 0) == 0) rtt_zero_count++
                }
            }
            next
        }
        END {
            flush_record()
            if (tunnel_total == 0) {
                print ""
                print "隧道质量数据不可用: 未解析到任何隧道 measure 数据"
                exit 2
            }
            print ""
            print "汇总:"
            print "- 隧道总数: " tunnel_total
            print "- 异常隧道数: " abnormal_count + 0
            print "- 离线隧道数: " offline_count + 0
            if (note_details != "") {
                print "- 备注:"
                printf "%s", note_details
            }
            if (offline_count == tunnel_total) {
                print "- 结论: 隧道全部离线，优先排查隧道认证、网络连通性、飞连进程状态"
                exit 3
            }
            if (abnormal_count > 0) {
                print "- 结论: 存在异常等级隧道，异常详情: " abnormal_reasons
                print "- 建议: 检查POP节点连通性、本地运营商链路、隧道认证配置"
                exit 1
            }
            print "- 结论: 所有隧道评级均为良好及以上，隧道层无明显故障"
            exit 0
        }
    '
}

check_wireguard_tunnel_quality() {
    local cmd
    local measure_raw
    local quality_output
    local quality_code
    local extra
    local code

    cmd="echo \"### interface: tun0_master\"; feilian-tun-ctrl show -i tun0_master measure"
    measure_raw=$(
        echo "### interface: tun0_master"
        feilian-tun-ctrl show -i tun0_master measure 2>&1 || true
    )
    quality_output=$(printf '%s\n' "$measure_raw" | format_tunnel_quality_measure_output 2>&1)
    quality_code=$?

    WIREGUARD_TUNNEL_QUALITY_CODE=0
    case "$quality_code" in
        0)
            extra="${GREEN}◆ 判断原因: 所有隧道评级均为良好及以上，隧道层无明显故障${NC}"
            code=0
            ;;
        1|3)
            extra="${RED}◆ 判断原因: 隧道质量检测发现异常，请优先处理隧道层问题后再排查调度层${NC}"
            code=1
            WIREGUARD_TUNNEL_QUALITY_CODE=1
            ;;
        *)
            extra="${YELLOW}◆ 判断原因: 隧道质量数据不可用或解析为空，本步骤不阻断整体排障主流程${NC}"
            code=2
            WIREGUARD_TUNNEL_QUALITY_CODE=2
            ;;
    esac

    print_check "WireGuard隧道质量检测(feilian-tun-ctrl measure)" \
        "$cmd" \
        "tun0_master主隧道应处于running=true，平均基线RTT、平均抖动和丢包率应满足良好及以上评级；rtt/jitter按微秒换算为毫秒" \
        "如主隧道存在异常等级隧道，请检查POP节点连通性、本地运营商链路、隧道认证配置和feilian-tun进程状态" \
        "$extra" \
        "$code" \
        "$quality_output"
}

run_all_checks() {
    check_os_kernel
    check_system_performance
    check_time_sync
    check_network_interfaces
    check_iptables_policy
    check_ufw_status
    check_firewalld_status
    check_nftables_status
    check_selinux_status


    check_ip_forwarding
    check_tcp_congestion_control
    check_nf_conntrack
    check_tcp_buffers

    check_cpe_version
    check_cpe_services
    check_cpe_network_health
    check_cpe_event_error_log
    check_panic_logs
    check_default_gateway
    check_dns_resolv_conf
    check_management_backend
    check_management_grpc
    check_center_dns_grpc
    check_center_dns_udp
    check_pop_nodes
    check_tunnel_connectivity
    check_wireguard_cli
    check_wireguard_config_consistency
    check_wireguard_tunnel_quality
}

prompt_ip_publish_target() {
    local input
    while [[ -z "$IP_PUBLISH_TARGET_IP" && "$OUTPUT_TERMINAL" == "true" && -t 0 ]]; do
        printf "%b" "${BOLD}请输入待验证目标IP: ${NC}"
        read -r input || input=""
        input=$(normalize_ipv4_input "$input")
        if validate_ipv4 "$input"; then
            IP_PUBLISH_TARGET_IP="$input"
            break
        fi
        echo -e "${RED}目标IP格式无效，请重新输入。${NC}"
    done
}

validate_domain_name() {
    local domain="$1"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_iface_name() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || return 1
    [[ "$iface" =~ ^[A-Za-z0-9._:-]+$ ]]
}

prompt_domain_schedule_domain() {
    local input
    while [[ -z "$DOMAIN_SCHEDULE_DOMAIN" && "$OUTPUT_TERMINAL" == "true" && -t 0 ]]; do
        printf "%b" "${BOLD}请输入待验证域名: ${NC}"
        read -r input || input=""
        input=$(normalize_domain_input "$input")
        if validate_domain_name "$input"; then
            DOMAIN_SCHEDULE_DOMAIN="$input"
            break
        fi
        echo -e "${RED}域名格式无效，请重新输入。${NC}"
    done
}

list_physical_up_interfaces() {
    ip -o link show up 2>/dev/null \
        | awk -F': ' '
            $2 !~ /^(lo|tun|docker|br-|veth|virbr|flannel|cni|wg)/ {
                split($2, a, "@")
                print a[1]
            }' \
        | sort -u
}

get_iface_ipv4() {
    local iface="$1"
    ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'
}

find_domain_schedule_rule_matches() {
    local domain="$1"
    local conf="/etc/dnsmasq.d/gfw_domain.conf"
    awk -F/ -v domain="$domain" '
        /^server=\// {
            rule=$2
            if (rule == "" || rule ~ /\*/) next
            if (domain == rule || domain ~ ("\\." rule "$")) {
                print "server=/" rule "/" $3
            }
        }' "$conf" 2>/dev/null
}

extract_domain_schedule_dns_from_rules() {
    # 从 server=/example.com/192.0.2.53#443 中提取上游 DNS IP，用于和 dnsmasq forwarded 日志比对。
    awk -F/ '
        NF >= 3 {
            upstream = $3
            sub(/#.*/, "", upstream)
            if (upstream != "") print upstream
        }' \
        | sort -u \
        | paste -sd, -
}

extract_forwarded_dns_from_query_log() {
    # dnsmasq 日志中的 forwarded 行能证明实际转发给了哪个上游 DNS。
    awk '/ forwarded / && / to / {print $NF}' \
        | sort -u \
        | paste -sd, -
}

find_missing_dns_in_config() {
    local forwarded_dns="${1:-}"
    local configured_dns="${2:-}"
    awk -v forwarded="$forwarded_dns" -v configured="$configured_dns" '
        BEGIN {
            split(configured, configured_items, ",")
            for (i in configured_items) {
                if (configured_items[i] != "") allow[configured_items[i]] = 1
            }
            forwarded_count = split(forwarded, forwarded_items, ",")
            for (i = 1; i <= forwarded_count; i++) {
                dns = forwarded_items[i]
                if (dns != "" && !(dns in allow)) {
                    print dns
                }
            }
        }' \
        | sort -u \
        | paste -sd, -
}

find_dnsmasq_query_log_for_domain() {
    local domain="$1"
    local log_file="/opt/feilian/cpe/log/dnsmasq.query.log"
    local f
    {
        for f in "$log_file"*; do
            [[ -f "$f" ]] || continue
            if [[ "$f" == *.gz ]]; then
                zgrep -h -- "$domain" "$f" 2>/dev/null
            else
                grep -h -- "$domain" "$f" 2>/dev/null
            fi
        done
    } | tail -n 50
}

reverse_ip_to_domain_from_dnsmasq_cache() {
    local target_ip="$1"
    local log_file="/opt/feilian/cpe/log/dnsmasq.query.log"
    local pid_file="/run/dnsmasq.pid"
    local dnsmasq_pid=""
    local start_line
    local result
    local f

    result=$(
        {
            for f in "$log_file"*; do
                [[ -f "$f" ]] || continue
                if [[ "$f" == *.gz ]]; then
                    zgrep -h -- "$target_ip" "$f" 2>/dev/null
                else
                    grep -h -- "$target_ip" "$f" 2>/dev/null
                fi
            done
        } | awk -v ip="$target_ip" '
            $0 ~ ip {
                line=$0
                sub(/^.*dnsmasq\[[0-9]+\]:[[:space:]]*/, "", line)
                split(line, f, /[[:space:]]+/)
                if ((f[1] == "reply" || f[1] == "cached") && f[3] == "is" && f[4] == ip) {
                    print f[2]
                    next
                }
                if (f[2] == ip) print f[1]
            }' \
        | sort -u \
        | paste -sd, -
    )
    if [[ -n "$result" ]]; then
        echo "$target_ip <= $result (来源: dnsmasq历史日志)"
        return 0
    fi

    [[ -f "$log_file" ]] || {
        echo "未找到dnsmasq查询日志: $log_file"
        return 1
    }
    if [[ -f "$pid_file" ]]; then
        dnsmasq_pid=$(cat "$pid_file" 2>/dev/null)
    else
        dnsmasq_pid=$(pgrep -f '/opt/feilian/cpe/bin/feilian-dnsmasq|[d]nsmasq' 2>/dev/null | head -n 1)
    fi
    if [[ -z "$dnsmasq_pid" ]] || ! kill -0 "$dnsmasq_pid" 2>/dev/null; then
        echo "未找到运行中的feilian-dnsmasq进程"
        return 1
    fi

    start_line=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    kill -USR1 "$dnsmasq_pid" 2>/dev/null || {
        echo "触发dnsmasq缓存转储失败"
        return 1
    }
    sleep 1
    result=$(sed -n "$((start_line + 1)),\$p" "$log_file" 2>/dev/null \
        | awk -v ip="$target_ip" '
            $0 ~ ip {
                line=$0
                sub(/^.*dnsmasq\[[0-9]+\]:[[:space:]]*/, "", line)
                split(line, f, /[[:space:]]+/)
                if ((f[1] == "reply" || f[1] == "cached") && f[3] == "is" && f[4] == ip) {
                    print f[2]
                    next
                }
                if (f[2] == ip) print f[1]
            }' \
        | sort -u \
        | paste -sd, -)

    if [[ -n "$result" ]]; then
        echo "$target_ip <= $result (来源: dnsmasq当前缓存转储)"
        return 0
    fi
    echo "$target_ip <= 未在dnsmasq历史日志和当前缓存中找到"
    return 2
}

run_ip_publish_checks() {
    local target_ip="$IP_PUBLISH_TARGET_IP"
    local iface="${IP_PUBLISH_IFACE:-tun0_master}"
    local cmd output extra code
    local issues=()
    local route_dev route_table
    local dispatch_output
    local domain_reverse_output=""
    local result_summary=""
    local traceroute_output second_hop

    prompt_ip_publish_target
    target_ip="$IP_PUBLISH_TARGET_IP"
    if ! validate_ipv4 "$target_ip"; then
        echo -e "${RED}参数错误: 请通过 --target-ip 指定有效目标IP，例如: $0 --mode ip --target-ip 203.0.113.10${NC}" >&2
        return 127
    fi

    print_mode_banner "飞连CPE IP调度不生效排查" "目标IP" "$target_ip" "$iface"
    run_native_cpe_health_check_step "IP调度-步骤1 原生CPE健康检查" "IP调度" "请先根据/opt/feilian/cpe/bin/feilian-cpe-health-check 的非成功项修复网络、DNS、GRPC、认证凭据或隧道连通性，再继续IP调度排查" || true

    cmd="echo '=== 目标IP路由详情 ==='; ip route get ${target_ip}; echo; echo '=== 策略路由规则 ==='; ip rule"
    output=$(eval "$cmd" 2>&1 || true)
    route_dev=$(printf '%s\n' "$output" | extract_route_dev_from_output)
    route_table=$(printf '%s\n' "$output" | extract_route_table_from_output)
    issues=()
    [[ "$route_dev" =~ ^tun0_(master|slave)$ ]] || issues+=("目标IP当前路由出接口=${route_dev:-未获取}，未走tun隧道")
    if [[ "${#issues[@]}" -eq 0 ]]; then
        extra="${GREEN}◆ 判断原因: ${target_ip} 当前路由出接口=${route_dev}，路由表=${route_table:-main/未显示}，流量已进入隧道路径${NC}"
        code=0
    else
        extra="${RED}◆ 判断原因: $(IFS='，'; echo "${issues[*]}")${NC}"
        code=1
    fi
    print_check "IP调度-步骤2 路由走向校验" "$cmd" "目标IP应通过tun0_master或tun0_slave进入飞连隧道路径" "如果目标IP走物理网卡或main表，请优先排查策略路由和飞连路由下发" "$extra" "$code" "$output"

    if [[ "$route_dev" =~ ^tun0_(master|slave)$ ]]; then
        iface="$route_dev"
    fi

    cmd="feilian-tun-ctrl show -i ${iface} dispatch; cat /opt/feilian/cpe/conf/dispatch_priority.json 2>/dev/null"
    collect_dispatch_match_analysis "$target_ip" "$iface"
    if [[ -n "$SAAS_MATCH_RULES" ]]; then
        domain_reverse_output=$(reverse_ip_to_domain_from_dnsmasq_cache "$target_ip" 2>&1 || true)
    fi
    case "$MATCH_TYPE" in
        "命中IP调度")
            result_summary="命中IP调度，预期下车CPE隧道IP: ${EXPECTED_DOWNSTREAM_IP:-未获取}"
            ;;
        "命中域名调度")
            result_summary="命中域名调度，不符合IP调度检查预期；预期下车CPE隧道IP: ${EXPECTED_DOWNSTREAM_IP:-未获取}，域名调度IP反向溯源: ${domain_reverse_output:-未触发}"
            ;;
        "同时命中IP调度和域名调度")
            result_summary="同时命中IP调度和域名调度，不符合IP调度检查预期；预期下车CPE隧道IP: ${EXPECTED_DOWNSTREAM_IP:-未获取}，域名调度IP反向溯源: ${domain_reverse_output:-未触发}"
            ;;
        *)
            result_summary="未命中任何调度规则，预期下车CPE隧道IP: 未获取"
            ;;
    esac
    dispatch_output=$(format_dispatch_analysis_block "目标IP匹配分析" "目标IP" "$target_ip" "$target_ip" "$iface" "$result_summary")
    issues=()
    [[ -n "$IP_MATCH_RULES" ]] || issues+=("目标IP未命中IP调度规则")
    [[ "${DISPATCH_PRIORITY_CONSISTENCY:-}" != 不一致* ]] || issues+=("默认调度优先级与dispatch_priority.json不一致")
    if [[ -n "$SAAS_MATCH_RULES" ]]; then
        issues+=("目标IP命中域名调度，不符合IP调度检查预期")
    fi
    if [[ "${#issues[@]}" -eq 0 ]]; then
        extra="${GREEN}◆ 判断原因: ${target_ip} ${MATCH_TYPE}，预期下车隧道IP=${EXPECTED_DOWNSTREAM_IP:-未获取}${NC}"
        code=0
    else
        extra="${RED}◆ 判断原因: $(IFS='，'; echo "${issues[*]}")${NC}"
        code=1
    fi
    print_check "IP调度-步骤3 调度规则匹配校验" "$cmd; 如命中域名调度则先查 /opt/feilian/cpe/log/dnsmasq.query.log* 反推域名，未命中再 kill -USR1 \$(cat /run/dnsmasq.pid) 转储dnsmasq当前缓存反查域名" "目标IP应命中预期IP调度网段，且不应命中域名调度；如命中域名调度，需反查来源域名辅助定位；默认调度优先级应与dispatch_priority.json一致" "如未命中IP调度请新增/修正IP调度规则；如命中域名调度请确认域名策略、调度优先级或清理非预期域名调度记录" "$extra" "$code" "$dispatch_output"

    cmd="traceroute -n -q 3 -w 2 ${target_ip}"
    if command -v traceroute >/dev/null 2>&1; then
        traceroute_output=$(eval "$cmd" 2>&1 || true)
    else
        traceroute_output="traceroute命令不存在，无法执行数据面第二跳验证"
    fi
    second_hop=$(printf '%s\n' "$traceroute_output" | awk '$1=="2" {for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+){3}$/) {print $i; exit}}')
    issues=()
    if [[ -n "$EXPECTED_DOWNSTREAM_IP" && "$second_hop" != "$EXPECTED_DOWNSTREAM_IP" ]]; then
        issues+=("traceroute第二跳=${second_hop:-未获取}，预期=${EXPECTED_DOWNSTREAM_IP}")
    fi
    if [[ -z "$EXPECTED_DOWNSTREAM_IP" ]]; then
        issues+=("未获取预期下车隧道IP，无法判断第二跳")
    fi
    if [[ "${#issues[@]}" -eq 0 ]]; then
        extra="${GREEN}◆ 判断原因: traceroute第二跳=${second_hop}，符合预期下车隧道IP${NC}"
        code=0
    else
        extra="${YELLOW}◆ 判断原因: $(IFS='，'; echo "${issues[*]}")${NC}"
        code=2
    fi
    print_check "IP调度-步骤4 数据面转发验证" "$cmd" "traceroute第二跳应为调度规则中的下车CPE隧道IP" "如果第二跳不符合预期，请继续检查DNAT规则和调度下发状态" "$extra" "$code" "$traceroute_output"

}

run_domain_schedule_checks() {
    local domain="$DOMAIN_SCHEDULE_DOMAIN"
    local cmd output extra code
    local issues=()
    local rule_matches
    local dnsmasq_pid="" dnsmasq_active dnsmasq_loaded dnsmasq_ports
    local dig_output first_ip
    local query_log_output
    local configured_dns forwarded_dns missing_forwarded_dns dns_consistency
    local route_dev route_table iface
    local result_summary dispatch_output
    local traceroute_output second_hop

    prompt_domain_schedule_domain
    domain="$DOMAIN_SCHEDULE_DOMAIN"
    if ! validate_domain_name "$domain"; then
        echo -e "${RED}参数错误: 请通过 --domain 指定有效域名，例如: $0 --mode domain --domain www.aliyun.com${NC}" >&2
        return 127
    fi

    print_mode_banner "飞连CPE 域名调度异常排查" "目标域名" "$domain"
    run_native_cpe_health_check_step "域名调度-步骤1 原生CPE健康检查" "域名调度" "请先修复原生健康检查中的非成功项，再继续域名调度排查" || true

    cmd="awk -F/ '/^server=\\// {print}' /etc/dnsmasq.d/gfw_domain.conf 2>/dev/null"
    rule_matches=$(find_domain_schedule_rule_matches "$domain")
    output=$(cat <<EOF
【域名调度列表匹配】
  目标域名: ${domain}
  匹配方式: 精确匹配或子域名后缀匹配，不支持*通配
  配置文件: /etc/dnsmasq.d/gfw_domain.conf
  匹配规则:
$(printf '%s' "${rule_matches:-  未命中}" | sed 's/^/    /')
EOF
)
    if [[ -n "$rule_matches" ]]; then
        extra="${GREEN}◆ 判断原因: ${domain} 已命中域名调度列表${NC}"
        code=0
    else
        extra="${RED}◆ 判断原因: ${domain} 未命中 /etc/dnsmasq.d/gfw_domain.conf 域名调度列表${NC}"
        code=1
    fi
    print_check "域名调度-步骤2 域名调度列表匹配" "$cmd" "目标域名应在/etc/dnsmasq.d/gfw_domain.conf中命中域名调度规则；不支持*通配" "如未命中，请检查控制器域名策略是否下发到gfw_domain.conf" "$extra" "$code" "$output"

    cmd="systemctl is-active feilian-dnsmasq; systemctl show feilian-dnsmasq --property=LoadState --value; pgrep -af '/opt/feilian/cpe/bin/feilian-dnsmasq|[d]nsmasq'; ss -lntup 2>/dev/null | grep -E '(:53\\b|feilian-dnsmasq|dnsmasq)'"
    dnsmasq_active=$(systemctl is-active feilian-dnsmasq 2>/dev/null || echo inactive)
    dnsmasq_loaded=$(systemctl show feilian-dnsmasq --property=LoadState --value 2>/dev/null || echo not-found)
    dnsmasq_pid=$(pgrep -f '/opt/feilian/cpe/bin/feilian-dnsmasq|[d]nsmasq' 2>/dev/null | head -n 1 || true)
    dnsmasq_ports=$(ss -lntup 2>/dev/null | grep -E '(:53\b|feilian-dnsmasq|dnsmasq)' || true)
    output=$(cat <<EOF
【feilian-dnsmasq运行状态】
  active: ${dnsmasq_active:-未获取}
  loaded: ${dnsmasq_loaded:-未获取}
  pid: ${dnsmasq_pid:-未获取}
  监听端口:
$(printf '%s' "${dnsmasq_ports:-  未获取到53端口监听信息}" | sed 's/^/    /')
EOF
)
    issues=()
    [[ "$dnsmasq_active" == "active" ]] || issues+=("feilian-dnsmasq active=${dnsmasq_active:-未获取}")
    [[ "$dnsmasq_loaded" == "loaded" ]] || issues+=("feilian-dnsmasq loaded=${dnsmasq_loaded:-未获取}")
    [[ -n "$dnsmasq_pid" ]] || issues+=("未找到feilian-dnsmasq进程")
    [[ -n "$dnsmasq_ports" ]] || issues+=("未获取到dnsmasq 53端口监听信息")
    if [[ "${#issues[@]}" -eq 0 ]]; then
        extra="${GREEN}◆ 判断原因: feilian-dnsmasq服务、进程和监听端口均正常${NC}"
        code=0
    else
        extra="${RED}◆ 判断原因: $(IFS='，'; echo "${issues[*]}")${NC}"
        code=1
    fi
    print_check "域名调度-步骤3 feilian-dnsmasq运行状态及端口检查" "$cmd" "feilian-dnsmasq应处于active/loaded状态，进程存在且DNS监听端口正常" "如异常，请检查feilian-dnsmasq服务状态、配置文件和53端口占用" "$extra" "$code" "$output"

    cmd="dig +time=3 +tries=1 +short A ${domain} @127.0.0.1; for dev in \$(ip -o link show up | awk -F': ' '\$2 !~ /^(lo|tun|docker|br-|veth|virbr|flannel|cni|wg)/ {split(\$2,a,\"@\"); print a[1]}'); do ip=\$(ip -o -4 addr show dev \"\$dev\" | awk '{split(\$4,a,\"/\"); print a[1]; exit}'); [ -n \"\$ip\" ] && dig -b \"\$ip\" +time=3 +tries=1 +short A ${domain} @127.0.0.1; done"
    dig_output=$(
        {
            echo "【DNS解析验证】"
            echo "  域名: ${domain}"
            echo "  @127.0.0.1:"
            run_dig_short_a "$domain" | sed 's/^/    /'
            echo "  物理UP接口绑定源IP解析:"
            local dev src_ip dev_result
            while IFS= read -r dev; do
                [[ -n "$dev" ]] || continue
                src_ip=$(get_iface_ipv4 "$dev")
                if [[ -z "$src_ip" ]]; then
                    echo "    ${dev}: 未获取IPv4地址，跳过"
                    continue
                fi
                dev_result=$(run_dig_short_a "$domain" -b "$src_ip" || true)
                echo "    ${dev}(${src_ip}):"
                printf '%s\n' "${dev_result:-无解析结果}" | sed 's/^/      /'
            done < <(list_physical_up_interfaces)
        }
    )
    first_ip=$(printf '%s\n' "$dig_output" | grep -E '^[[:space:]]*[0-9]+(\.[0-9]+){3}[[:space:]]*$' | awk '{print $1; exit}')
    if [[ -n "$first_ip" ]]; then
        extra="${GREEN}◆ 判断原因: ${domain} 可通过本机DNS代理解析，首个A记录=${first_ip}${NC}"
        code=0
    else
        extra="${RED}◆ 判断原因: ${domain} 通过@127.0.0.1及物理UP接口绑定源IP均未解析到A记录${NC}"
        code=1
    fi
    print_check "域名调度-步骤4 DNS解析验证" "$cmd" "dig 域名 @127.0.0.1 以及绑定所有非tun/非docker UP物理接口源IP均应可正常解析" "如解析失败，请检查feilian-dnsmasq、上游DNS、域名策略和本机DNS代理" "$extra" "$code" "$dig_output"

    cmd="grep/zgrep ${domain} /opt/feilian/cpe/log/dnsmasq.query.log*"
    query_log_output=$(find_dnsmasq_query_log_for_domain "$domain")
    configured_dns=$(printf '%s\n' "$rule_matches" | extract_domain_schedule_dns_from_rules)
    forwarded_dns=$(printf '%s\n' "$query_log_output" | extract_forwarded_dns_from_query_log)
    missing_forwarded_dns=$(find_missing_dns_in_config "$forwarded_dns" "$configured_dns")
    if [[ -z "$forwarded_dns" ]]; then
        dns_consistency="未发现forwarded转发记录，无法比对实际上游DNS"
    elif [[ -z "$configured_dns" ]]; then
        dns_consistency="未获取到域名调度配置DNS，无法比对"
    elif [[ -z "$missing_forwarded_dns" ]]; then
        dns_consistency="一致，forwarded DNS均命中域名调度配置"
    else
        dns_consistency="不一致，forwarded DNS未在配置中: ${missing_forwarded_dns}"
    fi
    output=$(cat <<EOF
【dnsmasq.query.log解析记录】
  日志路径: /opt/feilian/cpe/log/dnsmasq.query.log*
  配置DNS(gfw_domain.conf): ${configured_dns:-未获取}
  forwarded实际DNS: ${forwarded_dns:-未发现}
  DNS一致性: ${dns_consistency}
  解析日志:
$(printf '%s' "${query_log_output:-  未找到相关解析日志}" | sed 's/^/  /')
EOF
)
    if [[ -n "$missing_forwarded_dns" ]]; then
        extra="${RED}◆ 判断原因: dnsmasq.query.log* 中 ${domain} 的 forwarded DNS 与 gfw_domain.conf 配置不一致: ${missing_forwarded_dns}${NC}"
        code=1
    elif [[ -n "$query_log_output" ]]; then
        if [[ -n "$forwarded_dns" ]]; then
            extra="${GREEN}◆ 判断原因: dnsmasq.query.log* 中存在 ${domain} 的解析记录，forwarded DNS=${forwarded_dns}，与配置DNS=${configured_dns:-未获取}一致${NC}"
        else
            extra="${GREEN}◆ 判断原因: dnsmasq.query.log* 中存在 ${domain} 的解析记录，未发现forwarded记录，本步骤仅确认query/reply/cached记录${NC}"
        fi
        code=0
    else
        extra="${YELLOW}◆ 判断原因: dnsmasq.query.log* 中未找到 ${domain} 的解析记录，可能日志已轮转清理或尚未产生查询${NC}"
        code=2
    fi
    print_check "域名调度-步骤5 dnsmasq解析日志检查" "$cmd" "dnsmasq.query.log中应能看到目标域名的query/forwarded/reply/cached解析记录；如存在forwarded，上游DNS应与gfw_domain.conf命中的配置DNS一致" "如未找到，请重新执行dig触发解析，或检查日志轮转和dnsmasq log-queries配置；如forwarded DNS不一致，请检查gfw_domain.conf下发和feilian-dnsmasq配置加载状态" "$extra" "$code" "$output"

    if [[ -n "$first_ip" ]]; then
        output=$(ip route get "$first_ip" 2>/dev/null || true)
        route_dev=$(printf '%s\n' "$output" | extract_route_dev_from_output)
        route_table=$(printf '%s\n' "$output" | extract_route_table_from_output)
    else
        route_dev=""
        route_table=""
    fi
    if [[ "$route_dev" =~ ^tun0_(master|slave)$ ]]; then
        iface="$route_dev"
    else
        iface="${IP_PUBLISH_IFACE:-tun0_master}"
    fi
    cmd="first_ip='${first_ip:-未获取}'; ip route get \"\$first_ip\"; feilian-tun-ctrl show -i ${iface} dispatch; cat /opt/feilian/cpe/conf/dispatch_priority.json 2>/dev/null"
    collect_dispatch_match_analysis "${first_ip:-}" "$iface"
    if [[ -n "$SAAS_MATCH_RULES" ]]; then
        result_summary="首个解析IP命中域名调度，预期下车CPE隧道IP: ${EXPECTED_DOWNSTREAM_IP:-未获取}"
    elif [[ -n "$IP_MATCH_RULES" ]]; then
        result_summary="首个解析IP命中IP调度，未命中域名调度，不符合域名调度检查预期"
    else
        result_summary="首个解析IP未命中域名调度"
    fi
    dispatch_output=$(format_dispatch_analysis_block "域名解析IP调度分析" "目标域名" "$domain" "${first_ip:-未获取}" "$iface" "$result_summary" "${route_dev:-未获取}" "${route_table:-main/未显示}")
    issues=()
    [[ -n "$first_ip" ]] || issues+=("未获取域名首个A记录")
    [[ -n "$SAAS_MATCH_RULES" ]] || issues+=("首个解析IP未命中域名调度")
    [[ "${DISPATCH_PRIORITY_CONSISTENCY:-}" != 不一致* ]] || issues+=("默认调度优先级与dispatch_priority.json不一致")
    if [[ "${#issues[@]}" -eq 0 ]]; then
        extra="${GREEN}◆ 判断原因: ${domain} 首个解析IP=${first_ip} 已命中域名调度，预期下车隧道IP=${EXPECTED_DOWNSTREAM_IP:-未获取}${NC}"
        code=0
    else
        extra="${RED}◆ 判断原因: $(IFS='，'; echo "${issues[*]}")${NC}"
        code=1
    fi
    print_check "域名调度-步骤6 解析IP调度命中分析" "$cmd" "域名首个A记录应命中域名调度，并能看到预期下车CPE隧道IP；默认调度优先级应与dispatch_priority.json一致" "如未命中域名调度，请检查gfw_domain.conf、dnsmasq解析日志、dispatch saas_policies、dispatch_priority.json和控制器策略下发" "$extra" "$code" "$dispatch_output"

    cmd="traceroute -n -q 3 -w 2 ${first_ip:-未获取}"
    if [[ -z "$first_ip" ]]; then
        traceroute_output="未获取域名首个A记录，无法执行数据面第二跳验证"
    elif command -v traceroute >/dev/null 2>&1; then
        traceroute_output=$(traceroute -n -q 3 -w 2 "$first_ip" 2>&1 || true)
    else
        traceroute_output="traceroute命令不存在，无法执行数据面第二跳验证"
    fi
    second_hop=$(printf '%s\n' "$traceroute_output" | awk '$1=="2" {for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+){3}$/) {print $i; exit}}')
    issues=()
    [[ -n "$first_ip" ]] || issues+=("未获取域名首个A记录，无法执行traceroute")
    if [[ -n "$EXPECTED_DOWNSTREAM_IP" && "$second_hop" != "$EXPECTED_DOWNSTREAM_IP" ]]; then
        issues+=("traceroute第二跳=${second_hop:-未获取}，预期=${EXPECTED_DOWNSTREAM_IP}")
    fi
    if [[ -z "$EXPECTED_DOWNSTREAM_IP" ]]; then
        issues+=("未获取预期下车隧道IP，无法判断第二跳")
    fi
    if [[ "${#issues[@]}" -eq 0 ]]; then
        extra="${GREEN}◆ 判断原因: ${domain} 首个解析IP=${first_ip}，traceroute第二跳=${second_hop}，符合预期下车隧道IP${NC}"
        code=0
    else
        extra="${YELLOW}◆ 判断原因: $(IFS='，'; echo "${issues[*]}")${NC}"
        code=2
    fi
    print_check "域名调度-步骤7 数据面转发验证" "$cmd" "traceroute目标为域名首个A记录，第二跳应为域名调度规则中的下车CPE隧道IP" "如果第二跳不符合预期，请继续检查DNAT规则、域名调度下发状态和下车CPE连通性" "$extra" "$code" "$traceroute_output"
}



generate_report() {
    local output_file="${1:-}"
    local score=0
    if [[ "$TOTAL_CHECKS" -gt 0 ]]; then
        score=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))
    fi
    
    # 终端摘要
    if [[ "$OUTPUT_TERMINAL" == "true" ]]; then
        echo ""
        echo -e "${BOLD}${BLUE}>>> 巡检报告摘要${NC}"
        echo ""
        echo -e "  设备:   ${CYAN}$HOSTNAME${NC} (${YELLOW}$IP_ADDRESS${NC})"
        echo -e "  时间:   ${CYAN}$TIMESTAMP${NC}"
        echo -e "  编号:   INS-${REPORT_DATE}"
        echo ""
        echo -e "  总检查项: ${WHITE}$TOTAL_CHECKS${NC}"
        echo -e "  ✅ 通过:   ${GREEN}$PASSED_CHECKS${NC}"
        echo -e "  ⚠️ 警告:   ${YELLOW}$WARNING_CHECKS${NC}"
        echo -e "  ❌ 失败:   ${RED}$FAILED_CHECKS${NC}"
        echo ""
        
        if [[ $score -ge 90 ]]; then
            echo -e "  评分: ${GREEN}$score/100 (优秀) ✨${NC}"
        elif [[ $score -ge 70 ]]; then
            echo -e "  评分: ${YELLOW}$score/100 (良好) 👍${NC}"
        elif [[ $score -ge 50 ]]; then
            echo -e "  评分: ${RED}$score/100 (需关注) ⚠️${NC}"
        else
            echo -e "  评分: ${RED}$score/100 (不达标) ❌${NC}"
        fi
        echo ""
    fi
    
    # JSON输出
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        local json_output="{"
        json_output+="\"report_metadata\":{"
        json_output+="\"version\":\"$(json_escape "$SCRIPT_VERSION")\","
        json_output+="\"timestamp\":\"$(date -Iseconds)\","
        json_output+="\"device\":{\"hostname\":\"$(json_escape "$HOSTNAME")\",\"ip\":\"$(json_escape "$IP_ADDRESS")\"},"
        json_output+="\"inspection_summary\":{"
        json_output+="\"total_checks\":$TOTAL_CHECKS,"
        json_output+="\"passed\":$PASSED_CHECKS,"
        json_output+="\"warnings\":$WARNING_CHECKS,"
        json_output+="\"failed\":$FAILED_CHECKS,"
        json_output+="\"score\":$score"
        json_output+="},"
        
        json_output+="\"errors\":["
        local first_error=true
        for error in "${ERROR_LOG[@]}"; do
            IFS='|' read -r type name msg <<< "$error"
            if [[ "$first_error" == "true" ]]; then
                first_error=false
            else
                json_output+=","
            fi
            json_output+="{\"type\":\"$(json_escape "$type")\",\"item\":\"$(json_escape "$name")\",\"message\":\"$(json_escape "$msg")\"}"
        done
        json_output+="]"
        json_output+="}}"
        
        if [[ -n "$output_file" ]]; then
            echo "$json_output" | jq '.' > "$output_file" 2>/dev/null || echo "$json_output" > "$output_file"
            if [[ "$OUTPUT_TERMINAL" == "true" ]]; then
                echo -e "${CYAN}JSON报告已保存至: $output_file${NC}"
            fi
        else
            echo "$json_output" | jq '.' 2>/dev/null || echo "$json_output"
        fi
    fi
    
    # 文件输出
    if [[ -n "$output_file" ]] && [[ "$OUTPUT_JSON" != "true" ]]; then
        {
            echo "# 飞连CPE健康巡检报告"
            echo "# 生成时间: $TIMESTAMP"
            echo "# 设备: $HOSTNAME ($IP_ADDRESS)"
            echo "# 报告编号: INS-$REPORT_DATE"
            echo ""
            echo "## 摘要"
            echo "- 总检查项: $TOTAL_CHECKS"
            echo "- 通过: $PASSED_CHECKS"
            echo "- 警告: $WARNING_CHECKS"
            echo "- 失败: $FAILED_CHECKS"
            if [[ "$TOTAL_CHECKS" -gt 0 ]]; then
                echo "- 评分: ${score}/100"
            else
                echo "- 评分: 0/100"
            fi
            echo ""
            echo "## 错误详情"
            for error in "${ERROR_LOG[@]}"; do
                IFS='|' read -r type name msg <<< "$error"
                echo "- [$type] $name: $msg"
            done
        } > "$output_file"
        echo -e "${CYAN}报告已保存至: $output_file${NC}"
    fi
}

#===============================================================================
# 帮助信息
#===============================================================================

show_help() {
    cat << EOF
飞连CPE全面健康巡检脚本 v${SCRIPT_VERSION}

用法:
    $0 [选项]

选项:
    -h, --help          显示帮助信息
    --mode MODE         指定执行场景: cpe|ip|domain|optimize
    --target-ip IP      IP发布/调度排查目标IP，例如 203.0.113.10
    --domain DOMAIN     域名调度排查目标域名，例如 www.aliyun.com
    --iface IFACE       IP发布/调度排查接口，默认 tun0_master
    -j, --json          以JSON格式输出结果
    -q, --quiet         安静模式(减少输出)
    -f, --full          展示全部巡检项，不跳过官方健康检查已覆盖的重复项
    -o, --output FILE   将报告保存到指定文件
    --no-color          禁止彩色输出

示例:
    $0                          # 标准终端输出
    $0 --mode cpe              # 直接执行CPE巡检，不进入交互菜单
    $0 --mode ip --target-ip 203.0.113.10
                                # 执行CPE IP调度不生效排查
    $0 --mode domain --domain www.aliyun.com
                                # 执行CPE域名调度异常排查
    $0 --mode optimize         # 进入CPE常见优化脚本交互入口
    $0 --full                  # 展示全部巡检项
    $0 -j                     # JSON格式输出
    $0 -j -o report.json      # 保存JSON报告
    $0 -o report.txt          # 保存完整文本巡检报告
    $0 --no-color            # 无彩色输出(便于重定向)

兼容性:
    支持以下Linux发行版:
    - Debian 10/11/12
    - Ubuntu 18.04/20.04/22.04
    - CentOS 7/8/Stream
    - RHEL 8/9
    - Rocky Linux 8/9
    - Alpine Linux 3.15+

退出码:
    0   所有检查通过
    1   存在失败项
    2   存在警告项
    127 脚本执行错误

EOF
}

#===============================================================================
# 主程序入口
#===============================================================================

main() {
    # 参数解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --mode)
                if [[ $# -lt 2 || "${2:-}" == -* ]]; then
                    echo "参数错误: $1 需要指定执行场景(cpe|ip|domain|optimize)" >&2
                    exit 127
                fi
                case "$2" in
                    cpe|1)
                        INSPECTION_MODE="cpe"
                        ;;
                    ip|ip-publish|2)
                        INSPECTION_MODE="ip_publish"
                        ;;
                    domain|domain-schedule|3)
                        INSPECTION_MODE="domain_schedule"
                        ;;
                    optimize|optimizer|4)
                        INSPECTION_MODE="optimizer"
                        ;;
                    *)
                        echo "参数错误: 不支持的执行场景 '$2'，可选: cpe|ip|domain|optimize" >&2
                        exit 127
                        ;;
                esac
                shift 2
                ;;
            -j|--json)
                OUTPUT_JSON=true
                OUTPUT_TERMINAL=false
                shift
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -f|--full)
                FULL_MODE=true
                shift
                ;;
            --target-ip)
                if [[ $# -lt 2 || "${2:-}" == -* ]]; then
                    echo "参数错误: $1 需要指定目标IP" >&2
                    exit 127
                fi
                IP_PUBLISH_TARGET_IP=$(normalize_ipv4_input "$2")
                if ! validate_ipv4 "$IP_PUBLISH_TARGET_IP"; then
                    echo "参数错误: 目标IP格式无效: $2" >&2
                    exit 127
                fi
                shift 2
                ;;
            --target-ip=*)
                IP_PUBLISH_TARGET_IP=$(normalize_ipv4_input "${1#*=}")
                if ! validate_ipv4 "$IP_PUBLISH_TARGET_IP"; then
                    echo "参数错误: 目标IP格式无效: $IP_PUBLISH_TARGET_IP" >&2
                    exit 127
                fi
                shift
                ;;
            --domain)
                if [[ $# -lt 2 || "${2:-}" == -* ]]; then
                    echo "参数错误: $1 需要指定域名" >&2
                    exit 127
                fi
                DOMAIN_SCHEDULE_DOMAIN=$(normalize_domain_input "$2")
                if ! validate_domain_name "$DOMAIN_SCHEDULE_DOMAIN"; then
                    echo "参数错误: 域名格式无效: $2" >&2
                    exit 127
                fi
                shift 2
                ;;
            --domain=*)
                DOMAIN_SCHEDULE_DOMAIN=$(normalize_domain_input "${1#*=}")
                if ! validate_domain_name "$DOMAIN_SCHEDULE_DOMAIN"; then
                    echo "参数错误: 域名格式无效: ${1#*=}" >&2
                    exit 127
                fi
                shift
                ;;
            --iface)
                if [[ $# -lt 2 || "${2:-}" == -* ]]; then
                    echo "参数错误: $1 需要指定接口名" >&2
                    exit 127
                fi
                IP_PUBLISH_IFACE="$2"
                if ! validate_iface_name "$IP_PUBLISH_IFACE"; then
                    echo "参数错误: 接口名格式无效: $IP_PUBLISH_IFACE" >&2
                    exit 127
                fi
                shift 2
                ;;
            --iface=*)
                IP_PUBLISH_IFACE="${1#*=}"
                if ! validate_iface_name "$IP_PUBLISH_IFACE"; then
                    echo "参数错误: 接口名格式无效: $IP_PUBLISH_IFACE" >&2
                    exit 127
                fi
                shift
                ;;
            -o|--output)
                if [[ $# -lt 2 || "${2:-}" == -* ]]; then
                    echo "参数错误: $1 需要指定输出文件路径" >&2
                    exit 127
                fi
                OUTPUT_FILE=$(normalize_output_file_path "$2") || {
                    echo "参数错误: 输出文件路径不能为空" >&2
                    exit 127
                }
                shift 2
                ;;
            --output=*)
                OUTPUT_FILE=$(normalize_output_file_path "${1#*=}") || {
                    echo "参数错误: --output= 需要指定输出文件路径" >&2
                    exit 127
                }
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            *)
                echo "未知选项: $1"
                show_help
                exit 127
                ;;
        esac
    done

    configure_output_mode
    select_inspection_mode

    if [[ -n "$OUTPUT_FILE" ]]; then
        ensure_output_parent_dir "$OUTPUT_FILE"
    fi
    
    # 文本报告仅在显式指定 --output 且非 JSON 模式时保存；默认不落盘。
    local save_text_report=false
    local tmp_fifo=""
    local fifo_pid=""
    if [[ -n "$OUTPUT_FILE" && "$OUTPUT_JSON" != "true" ]]; then
        save_text_report=true
        tmp_fifo="/tmp/cpe_inspect_$$"
        if mkfifo "$tmp_fifo" 2>/dev/null; then
            sed 's/\x1b\[[0-9;]*m//g' < "$tmp_fifo" > "$OUTPUT_FILE" &
            fifo_pid=$!
            exec > >(tee "$tmp_fifo")
            exec 2>&1
        else
            echo "无法创建临时管道，将仅输出到终端: $tmp_fifo" >&2
            save_text_report=false
        fi
    fi

    case "$INSPECTION_MODE" in
        cpe)
            # 开始检查
            if [[ "$OUTPUT_TERMINAL" == "true" ]]; then
                echo -e "${BOLD}${WHITE}>>> 飞连CPE全面健康巡检 v${SCRIPT_VERSION}${NC}"
                echo -e "${WHITE}  设备: ${CYAN}$HOSTNAME${NC} (${YELLOW}$IP_ADDRESS${NC})"
                echo -e "${WHITE}  时间: ${CYAN}$TIMESTAMP${NC}"
            fi

            # 执行全面检查（实时显示每个检查项）
            run_all_checks
            ;;
        ip_publish)
            run_ip_publish_checks || {
                finish_text_report_capture "$save_text_report" "$tmp_fifo" "$fifo_pid"
                exit 127
            }
            ;;
        domain_schedule)
            run_domain_schedule_checks || {
                finish_text_report_capture "$save_text_report" "$tmp_fifo" "$fifo_pid"
                exit 127
            }
            ;;
        optimizer)
            run_optimizer_menu
            optimizer_code=$?
            finish_text_report_capture "$save_text_report" "$tmp_fifo" "$fifo_pid"
            exit "$optimizer_code"
            ;;
        *)
            echo "未知执行场景: ${INSPECTION_MODE:-空}" >&2
            exit 127
            ;;
    esac

    # 生成摘要；JSON模式下由generate_report负责输出或保存JSON。
    local report_output_file=""
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        report_output_file="$OUTPUT_FILE"
    fi
    generate_report "$report_output_file"

    finish_text_report_capture "$save_text_report" "$tmp_fifo" "$fifo_pid"
    
    # 返回退出码
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        exit 1
    elif [[ $WARNING_CHECKS -gt 0 ]]; then
        exit 2
    else
        exit 0
    fi
}

# 启动主程序
main "$@"
