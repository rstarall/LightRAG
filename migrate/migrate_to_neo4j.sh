#!/bin/bash

# GraphML to Neo4J Migration Script
# 简化迁移过程的便捷脚本

set -e

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." &> /dev/null && pwd )"

# 默认值
GRAPHML_FILE="$PROJECT_DIR/data/rag_storage/graph_chunk_entity_relation.graphml"
WORKSPACE="base"
CLEAR_DATA=""
SINGLE_MODE=""
PYTHON_CMD="python3"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示帮助信息
show_help() {
    cat << EOF
GraphML to Neo4J Migration Tool

用法: $0 [选项]

选项:
    -f, --file FILE          GraphML 文件路径 (默认: data/rag_storage/graph_chunk_entity_relation.graphml)
    -w, --workspace WORKSPACE  Neo4J 工作空间名称 (默认: base)
    -c, --clear              清空现有数据后迁移
    -s, --single-mode        使用单个插入模式 (更慢但更稳定，适合大数据集)
    -p, --python PYTHON      Python 命令 (默认: python3)
    -h, --help               显示此帮助信息

示例:
    $0                                          # 使用默认设置
    $0 -w my_workspace                          # 指定工作空间
    $0 -f /path/to/graph.graphml -c             # 指定文件并清空数据
    $0 --workspace test --clear --single-mode   # 使用单个插入模式

环境要求:
    - Python 3.x
    - 必需的 Python 包: networkx, neo4j, tqdm
    - 运行中的 Neo4J 服务 (默认 localhost:7687)
    - 可选的环境变量配置 (NEO4J_URI, NEO4J_USERNAME, NEO4J_PASSWORD)

EOF
}

# 检查 Python 环境
check_python() {
    if ! command -v "$PYTHON_CMD" &> /dev/null; then
        print_error "Python 未找到: $PYTHON_CMD"
        print_info "请安装 Python 3.x 或指定正确的 Python 命令"
        exit 1
    fi
    
    local python_version
    python_version=$($PYTHON_CMD --version 2>&1 | cut -d' ' -f2)
    print_info "使用 Python: $python_version"
}

# 检查依赖包
check_dependencies() {
    print_info "检查 Python 依赖包..."
    
    local required_packages=("networkx" "neo4j" "tqdm")
    local missing_packages=()
    
    for package in "${required_packages[@]}"; do
        if ! $PYTHON_CMD -c "import $package" &> /dev/null; then
            missing_packages+=("$package")
        fi
    done
    
    if [ ${#missing_packages[@]} -ne 0 ]; then
        print_error "缺少以下依赖包: ${missing_packages[*]}"
        print_info "请运行以下命令安装:"
        print_info "pip install ${missing_packages[*]}"
        exit 1
    fi
    
    print_success "所有依赖包已安装"
}

# 检查文件存在性
check_files() {
    if [ ! -f "$GRAPHML_FILE" ]; then
        print_error "GraphML 文件不存在: $GRAPHML_FILE"
        print_info "请检查文件路径或先生成 GraphML 文件"
        exit 1
    fi
    
    print_success "GraphML 文件存在: $GRAPHML_FILE"
    
    # 显示文件信息
    local file_size
    file_size=$(du -h "$GRAPHML_FILE" | cut -f1)
    print_info "文件大小: $file_size"
}

# 检查 Neo4J 连接
check_neo4j_connection() {
    print_info "检查 Neo4J 连接..."
    
    # 使用 Python 快速检查连接
    local check_script="
import os
import sys

try:
    from neo4j import GraphDatabase
    
    # Use environment variables or defaults (ignore config.ini for migration)
    uri = os.environ.get('NEO4J_URI', 'neo4j://localhost:7687')
    username = os.environ.get('NEO4J_USERNAME', 'neo4j')
    password = os.environ.get('NEO4J_PASSWORD', '12345678')
    
    driver = GraphDatabase.driver(uri, auth=(username, password))
    
    with driver.session() as session:
        result = session.run('RETURN 1 as test')
        result.single()
    
    driver.close()
    print('CONNECTION_OK')
    
except Exception as e:
    print(f'CONNECTION_ERROR: {e}')
"
    
    cd "$PROJECT_DIR"
    local result
    result=$($PYTHON_CMD -c "$check_script" 2>&1)
    
    if [[ $result == *"CONNECTION_OK"* ]]; then
        print_success "Neo4J 连接正常"
    else
        print_error "Neo4J 连接失败: $result"
        print_info "请检查:"
        print_info "1. Neo4J 服务是否运行 (默认端口 7687)"
        print_info "2. 连接地址是否正确 (默认 localhost:7687)"
        print_info "3. 用户名密码是否正确 (默认 neo4j/12345678)"
        print_info "4. 网络连接和防火墙设置"
        exit 1
    fi
}

# 执行迁移
execute_migration() {
    print_info "开始迁移过程..."
    
    local migration_script="$SCRIPT_DIR/graphml_to_neo4j.py"
    local cmd_args=("$PYTHON_CMD" "$migration_script" "$GRAPHML_FILE")
    
    # 添加工作空间参数
    if [ -n "$WORKSPACE" ]; then
        cmd_args+=("--workspace" "$WORKSPACE")
    fi
    
    # 添加清空数据参数
    if [ -n "$CLEAR_DATA" ]; then
        cmd_args+=("--clear")
    fi
    
    # 添加单个插入模式参数
    if [ -n "$SINGLE_MODE" ]; then
        cmd_args+=("--single-mode")
    fi
    
    print_info "执行命令: ${cmd_args[*]}"
    
    cd "$PROJECT_DIR"
    if "${cmd_args[@]}"; then
        print_success "迁移完成！"
    else
        print_error "迁移失败"
        exit 1
    fi
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--file)
                GRAPHML_FILE="$2"
                shift 2
                ;;
            -w|--workspace)
                WORKSPACE="$2"
                shift 2
                ;;
            -c|--clear)
                CLEAR_DATA="true"
                shift
                ;;
            -s|--single-mode)
                SINGLE_MODE="true"
                shift
                ;;
            -p|--python)
                PYTHON_CMD="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 主函数
main() {
    echo "=========================================="
    echo "  GraphML to Neo4J Migration Tool"
    echo "=========================================="
    echo
    
    # 解析参数
    parse_arguments "$@"
    
    # 显示配置
    print_info "迁移配置:"
    print_info "  GraphML 文件: $GRAPHML_FILE"
    print_info "  工作空间: $WORKSPACE"
    print_info "  清空数据: ${CLEAR_DATA:-false}"
    print_info "  单个插入模式: ${SINGLE_MODE:-false}"
    print_info "  Python 命令: $PYTHON_CMD"
    echo
    
    # 预检查
    check_python
    check_dependencies
    check_files
    check_neo4j_connection
    
    echo
    print_info "所有预检查通过，开始迁移..."
    echo
    
    # 执行迁移
    execute_migration
    
    echo
    print_success "迁移脚本执行完成！"
    print_info "您可以通过 Neo4J Browser (http://localhost:7474) 查看结果"
    print_info "或使用 Cypher 查询验证数据"
}

# 执行主函数
main "$@" 