#!/bin/bash

################################################################################
# GPUStack 端口诊断脚本
# 基于官方文档: https://docs.gpustack.ai/latest/installation/requirements/#port-requirements
# 用法: ./check_ports.sh [server|worker|all] [--verbose]
################################################################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 全局变量
VERBOSE=false
CONTAINER_NAME=""

################################################################################
# 端口定义（基于官方文档）
################################################################################

# Server 专用端口
declare -A SERVER_PORTS=(
    [80]="GPUStack UI and API endpoints (HTTP)"
    [443]="GPUStack UI and API endpoints (TLS enabled)"
    [10161]="Server metrics endpoint"
    [30080]="GPUStack server internal API"
    [5432]="Embedded Postgres Database"
)

# Worker 专用端口
declare -A WORKER_PORTS=(
    [10150]="GPUStack worker"
    [10151]="Worker metrics endpoint"
)

# Worker 端口范围
declare -A WORKER_PORT_RANGES=(
    ["40000-40063"]="Inference services"
    ["41000-41999"]="Ray services (vLLM distributed deployment)"
)

# Embedded Gateway 端口（Server 和 Worker 共用）
# 格式: port=host:description
declare -A GATEWAY_PORTS=(
    [18443]="127.0.0.1:File-based APIServer serving via HTTPS"
    [15000]="127.0.0.1:Management port for the Envoy gateway"
    [15021]="0.0.0.0:Health check port for the Envoy gateway"
    [15090]="0.0.0.0:Metrics port for the Envoy gateway"
    [9876]="127.0.0.1:Introspection port for the Pilot-discovery"
    [15010]="127.0.0.1:Pilot-discovery serving XDS via HTTP/gRPC"
    [15012]="127.0.0.1:Pilot-discovery serving XDS via secure gRPC"
    [15020]="0.0.0.0:Metrics port for Pilot-agent"
    [8888]="127.0.0.1:Controller serving XDS via HTTP"
    [15051]="127.0.0.1:Controller serving XDS via gRPC"
)

################################################################################
# 工具函数
################################################################################

print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}${BOLD}▶ $1${NC}"
    echo -e "${CYAN}─────────────────────────────────────────────${NC}"
}

print_subsection() {
    echo -e "${YELLOW}  • $1${NC}"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "    ${NC}$1${NC}"
    fi
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}❌ 命令 '$1' 未找到，请安装后再试${NC}"
        return 1
    fi
    return 0
}

# 获取端口监听信息
get_port_info() {
    local port=$1

    # 优先使用 ss，其次 netstat
    if command -v ss &> /dev/null; then
        ss -tuln 2>/dev/null | grep ":$port "
    elif command -v netstat &> /dev/null; then
        netstat -tuln 2>/dev/null | grep ":$port "
    else
        return 1
    fi
}

# 获取占用端口的进程信息
get_process_info() {
    local port=$1
    local pid=""

    if command -v lsof &> /dev/null; then
        pid=$(lsof -t -i:$port 2>/dev/null | head -1)
    elif command -v fuser &> /dev/null; then
        pid=$(fuser $port/tcp 2>/dev/null | awk '{print $1}')
    fi

    if [ -n "$pid" ]; then
        local process=$(ps -p $pid -o comm= 2>/dev/null || echo "unknown")
        local cmdline=$(ps -p $pid -o args= 2>/dev/null | head -c 80 || echo "unknown")
        echo "$pid|$process|$cmdline"
    fi
}

################################################################################
# 端口检查函数
################################################################################

# 检查单个端口
check_single_port() {
    local port=$1
    local desc=$2
    local expected_host=${3:-"0.0.0.0"}

    local port_info=$(get_port_info $port)

    if [ -n "$port_info" ]; then
        echo -e "${GREEN}✅ 端口 ${BOLD}$port${NC}${GREEN} ($expected_host)${NC}"
        echo -e "   ${desc}"

        # 获取进程信息
        local proc_info=$(get_process_info $port)
        if [ -n "$proc_info" ]; then
            IFS='|' read -r pid process cmdline <<< "$proc_info"
            log_verbose "PID: $pid | 进程: $process"
            log_verbose "命令: $cmdline"
        fi
    else
        echo -e "${RED}❌ 端口 ${BOLD}$port${NC}${RED} ($expected_host)${NC}"
        echo -e "   ${desc}"

        # 检查端口是否被占用（非监听状态）
        if command -v lsof &> /dev/null; then
            local occupied=$(lsof -i :$port 2>/dev/null | grep -v "COMMAND")
            if [ -n "$occupied" ]; then
                echo -e "   ${YELLOW}⚠️  端口被占用但未处于监听状态${NC}"
                log_verbose "$occupied"
            fi
        fi
    fi
}

# 检查端口范围
check_port_range() {
    local range=$1
    local desc=$2

    IFS='-' read -r start_port end_port <<< "$range"

    echo -e "${BLUE}📊 端口范围 ${BOLD}$range${NC}${BLUE} - $desc${NC}"

    # 收集正在使用的端口
    local listening_ports=()
    local total_ports=$((end_port - start_port + 1))

    for port in $(seq $start_port $end_port); do
        if get_port_info $port &> /dev/null; then
            listening_ports+=($port)
        fi
    done

    local listening_count=${#listening_ports[@]}
    local available_count=$((total_ports - listening_count))
    local usage_percent=0

    if [ $total_ports -gt 0 ]; then
        usage_percent=$((listening_count * 100 / total_ports))
    fi

    # 显示统计信息
    echo "   ├─ 总端口数: $total_ports"
    echo "   ├─ 使用中: $listening_count ($usage_percent%)"
    echo "   └─ 可用: $available_count"

    # 显示使用的端口（最多显示前 20 个）
    if [ $listening_count -gt 0 ]; then
        local display_ports="${listening_ports[@]:0:20}"
        echo "      使用的端口: $display_ports"
        if [ $listening_count -gt 20 ]; then
            echo "      ... 还有 $((listening_count - 20)) 个端口正在使用"
        fi
    fi

    # 警告
    if [ $usage_percent -gt 90 ]; then
        echo -e "   ${RED}⚠️  严重警告: 端口使用率过高 ($usage_percent%)，可能需要扩大端口范围${NC}"
    elif [ $usage_percent -gt 70 ]; then
        echo -e "   ${YELLOW}⚠️  警告: 端口使用率较高 ($usage_percent%)${NC}"
    fi

    # 详细模式下显示每个端口的进程信息
    if [ "$VERBOSE" = true ] && [ $listening_count -gt 0 ]; then
        echo ""
        echo "   详细端口占用信息:"
        for port in "${listening_ports[@]:0:10}"; do
            local proc_info=$(get_process_info $port)
            if [ -n "$proc_info" ]; then
                IFS='|' read -r pid process cmdline <<< "$proc_info"
                echo "   - 端口 $port: $process (PID: $pid)"
            fi
        done
        if [ $listening_count -gt 10 ]; then
            echo "   ... 省略其余 $((listening_count - 10)) 个端口的详细信息"
        fi
    fi
}

################################################################################
# Docker 容器检查
################################################################################

check_docker_container() {
    local container_name=$1

    print_section "Docker 容器检查: $container_name"

    # 检查 Docker 是否可用
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}⚠️  Docker 命令未找到，跳过容器检查${NC}"
        return
    fi

    # 检查容器是否运行
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${RED}❌ 容器 '$container_name' 未运行${NC}"
        echo ""

        # 检查容器是否存在但已停止
        if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            echo "容器存在但已停止，状态信息:"
            docker ps -a --filter "name=${container_name}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        else
            echo "容器不存在"
        fi

        # 列出所有 GPUStack 相关容器
        echo ""
        echo "所有 GPUStack 相关容器:"
        docker ps -a --filter "name=gpustack" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  无"
        return
    fi

    echo -e "${GREEN}✅ 容器正在运行${NC}"
    echo ""

    # 容器基本信息
    print_subsection "容器基本信息"
    docker ps --filter "name=${container_name}" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
    echo ""

    # 容器内进程
    print_subsection "容器内进程 (前 20 行)"
    docker exec $container_name ps aux 2>/dev/null | head -20 | sed 's/^/  /' || echo "  无法获取进程信息"
    echo ""

    # 容器内监听端口
    print_subsection "容器内监听端口"
    docker exec $container_name sh -c "netstat -tuln 2>/dev/null || ss -tuln 2>/dev/null" | grep LISTEN | sed 's/^/  /' || echo "  无法获取端口信息"
    echo ""

    # S6 服务状态
    print_subsection "S6 Overlay 服务状态"
    if docker exec $container_name test -d /run/service 2>/dev/null; then
        local services=$(docker exec $container_name ls -1 /run/service 2>/dev/null)
        if [ -n "$services" ]; then
            echo "$services" | while read service; do
                # 检查服务是否在运行（有 run 进程）
                if docker exec $container_name test -d "/run/service/$service/supervise" 2>/dev/null; then
                    echo -e "  ${GREEN}✅${NC} $service"
                else
                    echo -e "  ${RED}❌${NC} $service"
                fi
            done
        else
            echo "  无 S6 服务"
        fi
    else
        echo "  未使用 S6 Overlay"
    fi
    echo ""

    # Gateway 相关服务检查
    print_subsection "Gateway 组件服务"
    local gateway_services=("apiserver" "pilot" "controller" "gateway")
    for svc in "${gateway_services[@]}"; do
        if docker exec $container_name test -d "/run/service/$svc" 2>/dev/null; then
            if docker exec $container_name test -d "/run/service/$svc/supervise" 2>/dev/null; then
                echo -e "  ${GREEN}✅${NC} $svc 服务运行中"
            else
                echo -e "  ${RED}❌${NC} $svc 服务未运行"
            fi
        else
            echo -e "  ${YELLOW}⊘${NC} $svc 服务未配置"
        fi
    done
    echo ""

    # 最近日志
    if [ "$VERBOSE" = true ]; then
        print_subsection "最近日志 (最后 20 行)"
        docker logs --tail 20 $container_name 2>&1 | sed 's/^/  /'
        echo ""
    fi
}

################################################################################
# 端口冲突检查
################################################################################

check_port_conflicts() {
    print_section "常见端口冲突检查"

    local conflicts_found=false

    # 定义常见冲突服务
    declare -A common_conflicts=(
        [80]="Nginx/Apache/其他 Web 服务器"
        [443]="Nginx/Apache/其他 HTTPS 服务"
        [5432]="PostgreSQL 数据库"
        [8888]="Jupyter Notebook"
        [9876]="其他服务"
    )

    for port in "${!common_conflicts[@]}"; do
        local proc_info=$(get_process_info $port)
        if [ -n "$proc_info" ]; then
            IFS='|' read -r pid process cmdline <<< "$proc_info"

            # 检查是否是 GPUStack 进程
            if echo "$cmdline" | grep -q "gpustack"; then
                continue
            fi

            conflicts_found=true
            echo -e "${YELLOW}⚠️  端口 $port 被非 GPUStack 进程占用${NC}"
            echo "   可能的服务: ${common_conflicts[$port]}"
            echo "   进程: $process (PID: $pid)"
            log_verbose "命令: $cmdline"
            echo ""
        fi
    done

    # 检查 Envoy/Istio 端口范围
    if command -v lsof &> /dev/null; then
        local envoy_ports=$(lsof -i :15000-16000 2>/dev/null | grep LISTEN | grep -v gpustack | awk '{print $9}' | cut -d: -f2 | sort -u)
        if [ -n "$envoy_ports" ]; then
            conflicts_found=true
            echo -e "${YELLOW}⚠️  检测到其他 Envoy/Istio 服务占用 15xxx 端口${NC}"
            echo "   占用的端口: $(echo $envoy_ports | tr '\n' ' ')"
            echo "   建议: 停止这些服务或使用 --gateway-mode disabled"
            echo ""
        fi
    fi

    if [ "$conflicts_found" = false ]; then
        echo -e "${GREEN}✅ 未检测到常见端口冲突${NC}"
    fi
}

################################################################################
# 网络环境检查
################################################################################

check_network_connectivity() {
    print_section "网络连通性检查"

    local worker_ip=$1

    if [ -z "$worker_ip" ]; then
        echo "未指定 Worker IP，跳过连通性测试"
        return
    fi

    # Ping 测试
    print_subsection "Ping 测试"
    if ping -c 3 -W 2 $worker_ip &> /dev/null; then
        echo -e "  ${GREEN}✅${NC} $worker_ip 可达"
    else
        echo -e "  ${RED}❌${NC} $worker_ip 不可达"
    fi

    # 端口连通性测试
    print_subsection "关键端口连通性测试"
    local test_ports=(10150 10151)

    for port in "${test_ports[@]}"; do
        if command -v nc &> /dev/null; then
            if nc -z -w 2 $worker_ip $port 2>/dev/null; then
                echo -e "  ${GREEN}✅${NC} $worker_ip:$port 可达"
            else
                echo -e "  ${RED}❌${NC} $worker_ip:$port 不可达"
            fi
        elif command -v telnet &> /dev/null; then
            if timeout 2 telnet $worker_ip $port 2>&1 | grep -q "Connected"; then
                echo -e "  ${GREEN}✅${NC} $worker_ip:$port 可达"
            else
                echo -e "  ${RED}❌${NC} $worker_ip:$port 不可达"
            fi
        else
            echo "  未找到 nc 或 telnet 命令，无法测试端口连通性"
            break
        fi
    done
}

################################################################################
# 诊断建议
################################################################################

generate_recommendations() {
    print_section "诊断建议"

    echo -e "${BOLD}根据检查结果，建议:${NC}"
    echo ""

    echo "1️⃣  如果 Worker 端口 10150 未监听:"
    echo "   • 检查 Embedded Gateway 是否启动失败"
    echo "   • 查看容器日志: docker logs gpustack-worker"
    echo "   • 尝试禁用 Gateway: --gateway-mode disabled --worker-port 10150"
    echo ""

    echo "2️⃣  如果 Embedded Gateway 端口被占用:"
    echo "   • 停止占用端口的其他服务 (Jupyter、Istio 等)"
    echo "   • 或使用: --gateway-mode disabled"
    echo ""

    echo "3️⃣  如果推理服务端口 (40000-40063) 使用率高 (>80%):"
    echo "   • 扩大端口范围: --service-port-range 40000-40200"
    echo "   • 清理未使用的模型实例"
    echo ""

    echo "4️⃣  如果 Ray 端口 (41000-41999) 使用率高:"
    echo "   • 扩大端口范围: --ray-port-range 41000-42999"
    echo "   • 检查并清理僵尸 Ray 进程: ps aux | grep ray"
    echo ""

    echo "5️⃣  防火墙配置:"
    echo "   • firewalld: firewall-cmd --zone=public --add-port=10150/tcp --permanent"
    echo "   • iptables: iptables -I INPUT -p tcp --dport 10150 -j ACCEPT"
    echo "   • ufw: ufw allow 10150/tcp"
    echo ""

    echo -e "${BOLD}更多帮助:${NC}"
    echo "   📖 官方文档: https://docs.gpustack.ai/latest/installation/requirements/"
    echo "   🐛 问题反馈: https://github.com/gpustack/gpustack/issues"
}

################################################################################
# 主检查函数
################################################################################

check_server_ports() {
    print_header "GPUStack Server 端口诊断"

    print_section "Server 专用端口"
    for port in $(echo "${!SERVER_PORTS[@]}" | tr ' ' '\n' | sort -n); do
        check_single_port "$port" "${SERVER_PORTS[$port]}"
    done

    print_section "Embedded Gateway 端口 (Server 模式)"
    for port in $(echo "${!GATEWAY_PORTS[@]}" | tr ' ' '\n' | sort -n); do
        IFS=':' read -r host desc <<< "${GATEWAY_PORTS[$port]}"
        check_single_port "$port" "$desc" "$host"
    done

    check_docker_container "gpustack"
    check_port_conflicts
    generate_recommendations
}

check_worker_ports() {
    print_header "GPUStack Worker 端口诊断"

    print_section "Worker 专用端口"
    for port in $(echo "${!WORKER_PORTS[@]}" | tr ' ' '\n' | sort -n); do
        check_single_port "$port" "${WORKER_PORTS[$port]}"
    done

    print_section "Worker 端口范围"
    for range in "${!WORKER_PORT_RANGES[@]}"; do
        check_port_range "$range" "${WORKER_PORT_RANGES[$range]}"
    done

    print_section "Embedded Gateway 端口 (Worker 模式)"
    for port in $(echo "${!GATEWAY_PORTS[@]}" | tr ' ' '\n' | sort -n); do
        IFS=':' read -r host desc <<< "${GATEWAY_PORTS[$port]}"
        check_single_port "$port" "$desc" "$host"
    done

    check_docker_container "gpustack-worker"
    check_port_conflicts
    generate_recommendations
}

check_all_ports() {
    check_server_ports
    echo ""
    echo ""
    check_worker_ports
}

################################################################################
# 帮助信息
################################################################################

show_help() {
    cat << EOF
${BOLD}GPUStack 端口诊断脚本${NC}

基于官方文档: https://docs.gpustack.ai/latest/installation/requirements/

${BOLD}用法:${NC}
    $0 [COMMAND] [OPTIONS]

${BOLD}命令:${NC}
    server              检查 Server 端口
    worker              检查 Worker 端口
    all                 检查所有端口 (默认)
    help, -h, --help    显示帮助信息

${BOLD}选项:${NC}
    -v, --verbose       显示详细输出
    --ip <IP>          指定 Worker IP 进行连通性测试

${BOLD}示例:${NC}
    $0 worker                          # 检查 Worker 端口
    $0 worker --verbose                # 详细模式检查 Worker 端口
    $0 worker --ip 192.168.1.100      # 检查 Worker 端口并测试连通性
    $0 server                          # 检查 Server 端口
    $0 all                             # 检查所有端口

${BOLD}端口说明:${NC}
    Server 端口:
      • 80, 443      - UI 和 API
      • 10161        - Metrics
      • 30080        - 内部 API
      • 5432         - PostgreSQL

    Worker 端口:
      • 10150        - Worker API
      • 10151        - Metrics
      • 40000-40063  - 推理服务
      • 41000-41999  - Ray 分布式服务

    Gateway 端口 (Server/Worker 共用):
      • 18443, 15000, 15021, 15090, 9876, 15010, 15012, 15020, 8888, 15051

${BOLD}权限要求:${NC}
    建议使用 root 或 sudo 运行以获取完整信息

EOF
}

################################################################################
# 主函数
################################################################################

main() {
    local mode="all"
    local worker_ip=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            server|worker|all)
                mode=$1
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --ip)
                worker_ip=$2
                shift 2
                ;;
            -h|--help|help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}错误: 无效参数 '$1'${NC}"
                echo ""
                show_help
                exit 1
                ;;
        esac
    done

    # 权限检查
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠️  提示: 建议使用 root 权限运行以获取完整信息${NC}"
        echo ""
    fi

    # 工具检查
    local missing_tools=false
    for tool in netstat ss lsof docker; do
        if ! command -v $tool &> /dev/null; then
            if [ "$tool" = "netstat" ] || [ "$tool" = "ss" ]; then
                # netstat 和 ss 至少需要一个
                if ! command -v netstat &> /dev/null && ! command -v ss &> /dev/null; then
                    echo -e "${YELLOW}⚠️  未找到 netstat 或 ss 命令${NC}"
                    missing_tools=true
                fi
            else
                log_verbose "未找到命令: $tool"
            fi
        fi
    done

    if [ "$missing_tools" = true ]; then
        echo ""
    fi

    # 执行检查
    case $mode in
        server)
            check_server_ports
            ;;
        worker)
            check_worker_ports
            if [ -n "$worker_ip" ]; then
                echo ""
                check_network_connectivity "$worker_ip"
            fi
            ;;
        all)
            check_all_ports
            ;;
    esac

    echo ""
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  诊断完成${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# 运行主函数
main "$@"
