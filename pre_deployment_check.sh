#!/bin/bash

################################################################################
# GPUStack 部署前端口检查脚本
# 用途: 在部署 GPUStack 之前检查所需端口是否被占用
# 用法: ./pre_deployment_check.sh [server|worker|all]
################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

################################################################################
# 端口定义
################################################################################

# Server 专用端口
SERVER_PORTS=(
    "80:GPUStack UI and API (HTTP)"
    "443:GPUStack UI and API (HTTPS/TLS)"
    "10161:Server metrics endpoint"
    "8080:GPUStack server internal API"
    "5432:Embedded Postgres Database"
)

# Worker 专用端口
WORKER_PORTS=(
    "10150:GPUStack worker API"
    "10151:Worker metrics endpoint"
    "8080:GPUStack worker internal API"
)

# Worker 端口范围
WORKER_PORT_RANGES=(
    "40000-40063:Inference services"
    "41000-41999:Ray distributed services (vLLM)"
)

# Embedded Gateway 端口 (Server 和 Worker 共用)
GATEWAY_PORTS=(
    "18443:127.0.0.1:Gateway APIServer (HTTPS)"
    "15000:127.0.0.1:Envoy gateway management"
    "15021:0.0.0.0:Envoy health check"
    "15090:0.0.0.0:Envoy metrics"
    "9876:127.0.0.1:Pilot-discovery introspection"
    "15010:127.0.0.1:Pilot-discovery XDS (HTTP/gRPC)"
    "15012:127.0.0.1:Pilot-discovery XDS (secure gRPC)"
    "15020:0.0.0.0:Pilot-agent metrics"
    "8888:127.0.0.1:Higress Controller XDS (HTTP)"
    "15051:127.0.0.1:Higress Controller XDS (gRPC)"
)

################################################################################
# 全局变量
################################################################################

TOTAL_PORTS=0
OCCUPIED_PORTS=0
OCCUPIED_DETAILS=()

################################################################################
# 辅助函数
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
    echo -e "${YELLOW}${BOLD}▶ $1${NC}"
    echo "─────────────────────────────────────────────"
}

# 检查端口是否被占用
check_port() {
    local port=$1
    local desc=$2

    TOTAL_PORTS=$((TOTAL_PORTS + 1))

    # 使用 netstat 检查端口
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        echo -e "${RED}❌ 端口 $port${NC} - $desc"

        # 获取占用进程
        local process_info=$(lsof -i :$port 2>/dev/null | grep LISTEN | head -1)
        if [ -n "$process_info" ]; then
            local process=$(echo "$process_info" | awk '{print $1}')
            local pid=$(echo "$process_info" | awk '{print $2}')
            echo "   占用进程: $process (PID: $pid)"
        fi

        OCCUPIED_PORTS=$((OCCUPIED_PORTS + 1))
        OCCUPIED_DETAILS+=("端口 $port: $desc")
        return 1
    else
        echo -e "${GREEN}✅ 端口 $port${NC} - $desc"
        return 0
    fi
}

# 检查端口范围
check_port_range() {
    local range=$1
    local desc=$2

    IFS='-' read -r start_port end_port <<< "$range"

    echo -e "${BLUE}检查端口范围 $range${NC} - $desc"

    local occupied_in_range=()
    local total_range=$((end_port - start_port + 1))

    TOTAL_PORTS=$((TOTAL_PORTS + total_range))

    for port in $(seq $start_port $end_port); do
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            occupied_in_range+=($port)
        fi
    done

    local occupied_count=${#occupied_in_range[@]}
    local available_count=$((total_range - occupied_count))

    if [ $occupied_count -eq 0 ]; then
        echo -e "${GREEN}✅ 范围内所有端口可用 ($total_range 个)${NC}"
    else
        echo -e "${YELLOW}⚠️  范围内有 $occupied_count 个端口被占用${NC}"
        echo "   占用的端口: ${occupied_in_range[@]:0:20}"
        if [ $occupied_count -gt 20 ]; then
            echo "   ... 还有 $((occupied_count - 20)) 个端口"
        fi

        OCCUPIED_PORTS=$((OCCUPIED_PORTS + occupied_count))
        OCCUPIED_DETAILS+=("端口范围 $range: $occupied_count/$total_range 被占用")
    fi
}

################################################################################
# 检查函数
################################################################################

check_server() {
    print_header "检查 Server 所需端口"

    print_section "Server 专用端口"
    for port_info in "${SERVER_PORTS[@]}"; do
        IFS=':' read -r port desc <<< "$port_info"
        check_port "$port" "$desc"
    done

    print_section "Embedded Gateway 端口"
    for port_info in "${GATEWAY_PORTS[@]}"; do
        IFS=':' read -r port host_desc <<< "$port_info"
        IFS=':' read -r host desc <<< "$host_desc"
        check_port "$port" "$desc ($host)"
    done
}

check_worker() {
    print_header "检查 Worker 所需端口"

    print_section "Worker 专用端口"
    for port_info in "${WORKER_PORTS[@]}"; do
        IFS=':' read -r port desc <<< "$port_info"
        check_port "$port" "$desc"
    done

    print_section "Worker 端口范围"
    for range_info in "${WORKER_PORT_RANGES[@]}"; do
        IFS=':' read -r range desc <<< "$range_info"
        check_port_range "$range" "$desc"
    done

    print_section "Embedded Gateway 端口"
    for port_info in "${GATEWAY_PORTS[@]}"; do
        IFS=':' read -r port host_desc <<< "$port_info"
        IFS=':' read -r host desc <<< "$host_desc"
        check_port "$port" "$desc ($host)"
    done
}

check_all() {
    check_server
    echo ""
    check_worker
}

################################################################################
# 生成报告
################################################################################

generate_report() {
    print_section "检查摘要"

    echo "检查的端口总数: $TOTAL_PORTS"
    echo "被占用的端口数: $OCCUPIED_PORTS"
    echo "可用的端口数: $((TOTAL_PORTS - OCCUPIED_PORTS))"
    echo ""

    if [ $OCCUPIED_PORTS -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✅ 所有端口均可用，可以安全部署 GPUStack！${NC}"
        return 0
    else
        echo -e "${RED}${BOLD}❌ 发现 $OCCUPIED_PORTS 个端口被占用${NC}"
        echo ""
        echo "被占用的端口详情:"
        for detail in "${OCCUPIED_DETAILS[@]}"; do
            echo "  • $detail"
        done
        echo ""

        print_section "解决建议"
        echo "1. 停止占用端口的服务"
        echo "   示例: 查看占用进程"
        echo "   lsof -i :端口号"
        echo ""
        echo "2. 修改 GPUStack 配置使用其他端口"
        echo "   示例: --worker-port 10160 (修改 Worker 端口)"
        echo ""
        echo "3. 如果 Embedded Gateway 端口被占用，可以禁用 Gateway"
        echo "   使用参数: --gateway-mode disabled"
        echo ""
        return 1
    fi
}

################################################################################
# 帮助信息
################################################################################

show_help() {
    cat << EOF
${BOLD}GPUStack 部署前端口检查脚本${NC}

${BOLD}用途:${NC}
    在部署 GPUStack 之前检查所需端口是否被占用

${BOLD}用法:${NC}
    $0 [COMMAND]

${BOLD}命令:${NC}
    server              检查 Server 所需端口
    worker              检查 Worker 所需端口
    all                 检查所有端口 (默认)
    help, -h, --help    显示帮助信息

${BOLD}示例:${NC}
    $0 server           # 部署 Server 前检查
    $0 worker           # 部署 Worker 前检查
    $0 all              # 检查所有端口

${BOLD}端口说明:${NC}
    Server 端口:
      • 80, 443      - UI 和 API
      • 10161        - Metrics
      • 8080         - 内部 API
      • 5432         - PostgreSQL

    Worker 端口:
      • 10150        - Worker API
      • 10151        - Metrics
      • 8080         - 内部 API
      • 40000-40063  - 推理服务端口范围
      • 41000-41999  - Ray 分布式服务端口范围

    Gateway 端口 (Server/Worker 共用):
      • 18443, 15000, 15021, 15090, 9876, 15010, 15012, 15020, 8888, 15051

${BOLD}返回值:${NC}
    0 - 所有端口可用
    1 - 有端口被占用

EOF
}

################################################################################
# 主函数
################################################################################

main() {
    local mode="all"

    # 解析参数
    case "${1:-all}" in
        server)
            mode="server"
            ;;
        worker)
            mode="worker"
            ;;
        all)
            mode="all"
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

    # 检查 netstat 命令
    if ! command -v netstat &> /dev/null; then
        echo -e "${RED}错误: 未找到 netstat 命令${NC}"
        echo "请安装 net-tools: sudo apt-get install net-tools"
        exit 1
    fi

    # 检查 lsof 命令（可选，用于显示进程信息）
    if ! command -v lsof &> /dev/null; then
        echo -e "${YELLOW}提示: 未找到 lsof 命令，无法显示占用进程详情${NC}"
        echo "建议安装: sudo apt-get install lsof"
        echo ""
    fi

    # 执行检查
    case $mode in
        server)
            check_server
            ;;
        worker)
            check_worker
            ;;
        all)
            check_all
            ;;
    esac

    echo ""
    generate_report

    local exit_code=$?

    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  检查完成${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    exit $exit_code
}

# 执行主函数
main "$@"
