#!/bin/bash

# --------------------------
# 通用函数模块
# --------------------------
init_colors() {
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
}

# 日志函数
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }
log_success() { echo -e "${BLUE}[成功]${NC} $1"; }

# 环境变量更新
update_env() {
    local key=$1
    local value=$2
    local env_file=".env"
    
    # 创建文件（如果不存在）
    [ ! -f "$env_file" ] && touch "$env_file"
    add_trailing_newline "$env_file"

    # 使用awk进行原子性更新
    awk -v key="$key" -v value="$value" '
        BEGIN { FS=OFS="="; updated=0 }
        $1 == key { $2=value; updated=1 }
        { print }
        END { if (!updated) print key "=" value }
    ' "$env_file" > "${env_file}.tmp" && mv "${env_file}.tmp" "$env_file"

    add_trailing_newline "$env_file"
}

add_trailing_newline() {
    local file=$1
    [ -s "$file" ] && sed -i'' -e '$a\' "$file" || echo -n "" > "$file"
}

# --------------------------
# Docker 模块
# --------------------------
init_docker_compose() {
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        log_info "使用 docker compose 命令"
    elif docker-compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        log_info "使用 docker-compose 命令"
    else
        log_error "未找到 docker compose 命令，请先安装 Docker 和 Docker Compose"
        exit 1
    fi
}

check_compose_version() {
    local compose_file=$1
    if ! $DOCKER_COMPOSE_CMD -f "$compose_file" config >/dev/null 2>&1; then
        log_error "Docker Compose 版本过低，请升级到 v2.23.3 或更高版本"
        log_info "可执行 'docker-compose -v' 或 'docker compose version' 查看当前版本"
        exit 1
    fi
}

# --------------------------
# 用户输入模块
# --------------------------
validate_device_id() {
    [[ $1 =~ ^[0-9]+$ ]] && [ $1 -ge 0 ] && [ $1 -le 9 ] || [ "$1" == "-1" ]
}

get_user_input() {
    local prompt=$1
    local default=$2
    read -p "$prompt" answer
    echo "${answer:-$default}"
}

get_server_ip() {
    ip=$(get_user_input "请输入服务器公网IP地址: " "")
    if [ -z "$ip" ]; then
        log_error "IP地址不能为空"
        get_server_ip
    else
        log_info "服务将在 http://$ip:8777/qanything/ 上运行"
    fi
}

handle_existing_ip() {
    local use_previous=$(get_user_input "是否使用上次的IP: $USER_IP? (yes/no): " "yes")
    if [[ $use_previous != "yes" && $use_previous != "是" ]]; then
        local answer=$(get_user_input "运行环境 (remote/local): " "local")
        if [[ $answer == "local" || $answer == "本地" ]]; then
            ip="localhost"
            log_info "服务将在本地运行: http://localhost:8777/qanything/"
        else
            get_server_ip
        fi
        update_env "USER_IP" "$ip"
    else
        ip=$USER_IP
        log_info "使用已保存的IP地址: $ip"
    fi
}

# --------------------------
# 服务管理模块
# --------------------------
start_services() {
    local os_type=$1
    local compose_file="docker-compose-${os_type}.yaml"
    
    # 检查文件是否存在
    if [ ! -f "$compose_file" ]; then
        log_error "找不到配置文件: $compose_file"
        exit 1
    fi
    
    check_compose_version "$compose_file"
    prepare_volumes
    
    log_info "启动 QAnything 服务..."
    $DOCKER_COMPOSE_CMD -f "$compose_file" up -d
    
    if [ $? -eq 0 ]; then
        log_success "服务启动成功，正在查看日志..."
        $DOCKER_COMPOSE_CMD -f "$compose_file" logs -f qanything_local
    else
        log_error "服务启动失败，请检查错误信息"
        exit 1
    fi
}

prepare_volumes() {
    if [ ! -d "volumes/es/data" ]; then
        log_info "创建数据目录..."
        mkdir -p volumes/es/data
        chmod 777 -R volumes/es/data
    fi
}

detect_os() {
    case "$(uname -s)" in
        Linux*)  
            log_info "检测到 Linux 操作系统"
            echo "linux" 
            ;;
        Darwin*) 
            log_info "检测到 macOS 操作系统"
            echo "mac" 
            ;;
        MINGW*|MSYS*|CYGWIN*) 
            log_info "检测到 Windows 操作系统"
            echo "win" 
            ;;
        *) 
            log_error "不支持的操作系统: $(uname -s)"
            exit 1 
            ;;
    esac
}

# --------------------------
# 主逻辑
# --------------------------
main() {
    init_colors
    log_info "初始化 QAnything 启动脚本..."
    init_docker_compose

    # 解析设备ID参数
    local device_id="-1"
    while getopts "i:h" opt; do
        case $opt in
            i) device_id=$OPTARG ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    # 验证设备ID
    if ! validate_device_id "$device_id"; then
        log_error "device_id 必须是 0-9 或 -1"
        usage
    fi

    # 显示设备信息
    if [ "$device_id" == "-1" ]; then
        log_info "将在 CPU 上启动服务"
    else
        log_info "将在 GPU $device_id 上启动服务"
    fi

    # 更新环境配置
    update_env "GPUID" "$device_id"
    [ -f ".env" ] && source .env

    # 配置IP地址
    configure_ip_address

    # 检测操作系统并启动服务
    local os_type=$(detect_os)
    if [ "$os_type" == "win" ]; then
        log_warn "Windows 环境下请使用 docker-compose-win.yaml 手动启动服务"
        log_info "命令: docker-compose -f docker-compose-win.yaml up -d"
        exit 0
    else
        start_services "$os_type"
    fi
}

configure_ip_address() {
    if [ -z "${USER_IP}" ]; then
        local answer=$(get_user_input "运行环境 (remote/local): " "local")
        if [[ $answer == "local" || $answer == "本地" ]]; then
            ip="localhost"
            log_info "服务将在本地运行: http://localhost:8777/qanything/"
        else
            get_server_ip
        fi
        update_env "USER_IP" "$ip"
    else
        handle_existing_ip
    fi
}

# --------------------------
# 帮助信息
# --------------------------
usage() {
    echo "用法: $0 [-i <device_id>] [-h]"
    echo "选项:"
    echo "  -i <device_id>  指定GPU设备ID (0-9 或 -1 表示CPU)"
    echo "  -h              显示帮助信息"
    exit 1
}

# 执行主函数
main "$@"
