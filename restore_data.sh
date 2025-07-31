#!/bin/bash

# LightRAG 数据导入脚本
# 使用方法: ./restore_data.sh <backup_name_or_path>

set -e

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查参数
if [ $# -eq 0 ]; then
    echo -e "${RED}错误: 请提供备份名称或路径${NC}"
    echo -e "${YELLOW}使用方法: ./restore_data.sh <backup_name_or_path>${NC}"
    echo -e "${YELLOW}例如: ./restore_data.sh lightrag-backup-20240101_120000${NC}"
    echo -e "${YELLOW}或者: ./restore_data.sh /path/to/backup.tar.gz${NC}"
    exit 1
fi

BACKUP_INPUT="$1"
COMPOSE_FILE="docker-compose.dev.yml"
RESTORE_DIR="./restore_temp"

# 确定备份文件路径
if [ -f "$BACKUP_INPUT" ]; then
    # 如果输入是文件路径
    BACKUP_FILE="$BACKUP_INPUT"
elif [ -f "./backups/${BACKUP_INPUT}.tar.gz" ]; then
    # 如果是备份名称
    BACKUP_FILE="./backups/${BACKUP_INPUT}.tar.gz"
elif [ -d "./backups/${BACKUP_INPUT}" ]; then
    # 如果是解压后的目录
    BACKUP_DIR="./backups/${BACKUP_INPUT}"
else
    echo -e "${RED}错误: 找不到备份文件 $BACKUP_INPUT${NC}"
    exit 1
fi

# 检查Docker Compose文件
if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}错误: 找不到 $COMPOSE_FILE 文件${NC}"
    exit 1
fi

echo -e "${GREEN}开始恢复 LightRAG 数据...${NC}"

# 确认操作
echo -e "${YELLOW}警告: 此操作将覆盖现有数据！${NC}"
read -p "确定要继续吗？(y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}操作已取消${NC}"
    exit 0
fi

# 如果需要解压
if [ -n "$BACKUP_FILE" ]; then
    echo -e "${GREEN}解压备份文件...${NC}"
    rm -rf "$RESTORE_DIR"
    mkdir -p "$RESTORE_DIR"
    tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"
    
    # 找到备份目录
    BACKUP_DIR=$(find "$RESTORE_DIR" -maxdepth 1 -type d | grep -v "^$RESTORE_DIR$" | head -1)
    
    if [ -z "$BACKUP_DIR" ]; then
        echo -e "${RED}错误: 备份文件格式无效${NC}"
        exit 1
    fi
fi

# 检查备份信息
if [ -f "$BACKUP_DIR/backup_info.txt" ]; then
    echo -e "${GREEN}备份信息:${NC}"
    cat "$BACKUP_DIR/backup_info.txt"
    echo
fi

# 停止所有容器
echo -e "${GREEN}[1/8] 停止所有容器...${NC}"
docker-compose -f "$COMPOSE_FILE" down

# 2. 恢复配置文件
echo -e "${GREEN}[2/8] 恢复配置文件...${NC}"
if [ -f "$BACKUP_DIR/.env" ]; then
    cp "$BACKUP_DIR/.env" ./ 
    echo -e "${GREEN}已恢复 .env 文件${NC}"
fi

if [ -f "$BACKUP_DIR/config.ini" ]; then
    cp "$BACKUP_DIR/config.ini" ./
    echo -e "${GREEN}已恢复 config.ini 文件${NC}"
fi

# 3. 恢复本地数据目录
echo -e "${GREEN}[3/8] 恢复本地数据目录...${NC}"
if [ -d "$BACKUP_DIR/data" ]; then
    rm -rf ./data
    mkdir -p ./data
    cp -r "$BACKUP_DIR/data/"* ./data/
    echo -e "${GREEN}已恢复 data 目录${NC}"
fi

# 4. 恢复日志文件
echo -e "${GREEN}[4/8] 恢复日志文件...${NC}"
if [ -d "$BACKUP_DIR/logs" ]; then
    rm -rf ./logs
    mkdir -p ./logs
    cp -r "$BACKUP_DIR/logs/"* ./logs/
    echo -e "${GREEN}已恢复 logs 目录${NC}"
fi

# 5. 启动基础服务
echo -e "${GREEN}[5/8] 启动基础服务...${NC}"
docker-compose -f "$COMPOSE_FILE" up -d redis etcd minio neo4j
echo -e "${YELLOW}等待服务启动...${NC}"
sleep 15

# 6. 恢复数据库数据
echo -e "${GREEN}[6/8] 恢复数据库数据...${NC}"

# 恢复Redis数据
if [ -f "$BACKUP_DIR/redis/redis-backup.tar.gz" ]; then
    echo -e "${GREEN}恢复Redis数据...${NC}"
    # 停止Redis写入
    docker-compose -f "$COMPOSE_FILE" exec -T redis redis-cli FLUSHALL
    # 恢复数据
    docker cp "$BACKUP_DIR/redis/redis-backup.tar.gz" $(docker-compose -f "$COMPOSE_FILE" ps -q redis):/tmp/
    docker-compose -f "$COMPOSE_FILE" exec -T redis sh -c "cd /data && tar -xzf /tmp/redis-backup.tar.gz"
    docker-compose -f "$COMPOSE_FILE" exec -T redis rm -f /tmp/redis-backup.tar.gz
    # 重启Redis以加载数据
    docker-compose -f "$COMPOSE_FILE" restart redis
    echo -e "${GREEN}Redis数据恢复完成${NC}"
fi

# 恢复Neo4J数据
if [ -d "$BACKUP_DIR/neo4j" ]; then
    echo -e "${GREEN}恢复Neo4J数据...${NC}"
    
    # 停止Neo4J服务
    docker-compose -f "$COMPOSE_FILE" stop neo4j
    
    # 优先尝试恢复数据库导出文件
    if [ -f "$BACKUP_DIR/neo4j/neo4j.dump" ]; then
        echo -e "${YELLOW}使用 neo4j-admin load 恢复数据库...${NC}"
        # 清空现有数据
        docker-compose -f "$COMPOSE_FILE" run --rm neo4j sh -c "rm -rf /data/databases/neo4j/*" 2>/dev/null || true
        # 复制导出文件到容器
        docker cp "$BACKUP_DIR/neo4j/neo4j.dump" $(docker-compose -f "$COMPOSE_FILE" ps -q neo4j):/tmp/
        # 恢复数据库
        docker-compose -f "$COMPOSE_FILE" run --rm neo4j neo4j-admin database load --from-path=/tmp --overwrite-destination=true neo4j
        echo -e "${GREEN}Neo4J数据库恢复完成${NC}"
    elif [ -f "$BACKUP_DIR/neo4j/neo4j-data-backup.tar.gz" ]; then
        echo -e "${YELLOW}使用数据目录备份恢复...${NC}"
        # 清空现有数据
        docker-compose -f "$COMPOSE_FILE" run --rm neo4j sh -c "rm -rf /data/*" 2>/dev/null || true
        # 复制并解压数据目录
        docker cp "$BACKUP_DIR/neo4j/neo4j-data-backup.tar.gz" $(docker-compose -f "$COMPOSE_FILE" ps -q neo4j):/tmp/
        docker-compose -f "$COMPOSE_FILE" run --rm neo4j sh -c "cd /data && tar -xzf /tmp/neo4j-data-backup.tar.gz"
        docker-compose -f "$COMPOSE_FILE" run --rm neo4j rm -f /tmp/neo4j-data-backup.tar.gz
        echo -e "${GREEN}Neo4J数据目录恢复完成${NC}"
    fi
    
    # 启动Neo4J服务
    docker-compose -f "$COMPOSE_FILE" start neo4j
    echo -e "${YELLOW}等待Neo4J启动...${NC}"
    sleep 10
    
    # 如果有Cypher脚本，尝试执行
    if [ -f "$BACKUP_DIR/neo4j/neo4j-export.cypher" ]; then
        echo -e "${YELLOW}尝试执行Cypher脚本...${NC}"
        docker cp "$BACKUP_DIR/neo4j/neo4j-export.cypher" $(docker-compose -f "$COMPOSE_FILE" ps -q neo4j):/tmp/
        docker-compose -f "$COMPOSE_FILE" exec -T neo4j cypher-shell -u neo4j -p 12345678 -f /tmp/neo4j-export.cypher 2>/dev/null || echo -e "${YELLOW}警告: Cypher脚本执行失败${NC}"
        docker-compose -f "$COMPOSE_FILE" exec -T neo4j rm -f /tmp/neo4j-export.cypher
        echo -e "${GREEN}Cypher脚本执行完成${NC}"
    fi
    
    echo -e "${GREEN}Neo4J数据恢复完成${NC}"
fi

# 恢复etcd数据
if [ -f "$BACKUP_DIR/etcd/etcd-backup.tar.gz" ]; then
    echo -e "${GREEN}恢复etcd数据...${NC}"
    docker-compose -f "$COMPOSE_FILE" stop etcd
    docker-compose -f "$COMPOSE_FILE" run --rm etcd sh -c "rm -rf /etcd/*" 2>/dev/null || true
    docker cp "$BACKUP_DIR/etcd/etcd-backup.tar.gz" $(docker-compose -f "$COMPOSE_FILE" ps -q etcd):/tmp/
    docker-compose -f "$COMPOSE_FILE" run --rm etcd sh -c "cd /etcd && tar -xzf /tmp/etcd-backup.tar.gz"
    docker-compose -f "$COMPOSE_FILE" run --rm etcd rm -f /tmp/etcd-backup.tar.gz
    docker-compose -f "$COMPOSE_FILE" start etcd
    echo -e "${GREEN}etcd数据恢复完成${NC}"
fi

# 恢复MinIO数据
if [ -f "$BACKUP_DIR/minio/minio-backup.tar.gz" ]; then
    echo -e "${GREEN}恢复MinIO数据...${NC}"
    docker-compose -f "$COMPOSE_FILE" stop minio
    docker-compose -f "$COMPOSE_FILE" run --rm minio sh -c "rm -rf /minio_data/*" 2>/dev/null || true
    docker cp "$BACKUP_DIR/minio/minio-backup.tar.gz" $(docker-compose -f "$COMPOSE_FILE" ps -q minio):/tmp/
    docker-compose -f "$COMPOSE_FILE" run --rm minio sh -c "cd /minio_data && tar -xzf /tmp/minio-backup.tar.gz"
    docker-compose -f "$COMPOSE_FILE" run --rm minio rm -f /tmp/minio-backup.tar.gz
    docker-compose -f "$COMPOSE_FILE" start minio
    echo -e "${GREEN}MinIO数据恢复完成${NC}"
fi

# 7. 启动Milvus并恢复数据
echo -e "${GREEN}[7/8] 启动Milvus并恢复数据...${NC}"
docker-compose -f "$COMPOSE_FILE" up -d milvus-standalone
echo -e "${YELLOW}等待Milvus启动...${NC}"
sleep 15

# 恢复Milvus数据
if [ -f "$BACKUP_DIR/milvus/milvus-backup.tar.gz" ]; then
    echo -e "${GREEN}恢复Milvus数据...${NC}"
    docker-compose -f "$COMPOSE_FILE" stop milvus-standalone
    docker-compose -f "$COMPOSE_FILE" run --rm milvus-standalone sh -c "rm -rf /var/lib/milvus/*" 2>/dev/null || true
    docker cp "$BACKUP_DIR/milvus/milvus-backup.tar.gz" $(docker-compose -f "$COMPOSE_FILE" ps -q milvus-standalone):/tmp/
    docker-compose -f "$COMPOSE_FILE" run --rm milvus-standalone sh -c "cd /var/lib/milvus && tar -xzf /tmp/milvus-backup.tar.gz"
    docker-compose -f "$COMPOSE_FILE" run --rm milvus-standalone rm -f /tmp/milvus-backup.tar.gz
    docker-compose -f "$COMPOSE_FILE" start milvus-standalone
    echo -e "${GREEN}Milvus数据恢复完成${NC}"
fi

# 8. 启动LightRAG服务
echo -e "${GREEN}[8/8] 启动LightRAG服务...${NC}"
docker-compose -f "$COMPOSE_FILE" up -d lightrag-dev

# 清理临时文件
if [ -d "$RESTORE_DIR" ]; then
    rm -rf "$RESTORE_DIR"
fi

echo -e "${GREEN}数据恢复完成！${NC}"
echo -e "${YELLOW}服务状态:${NC}"
docker-compose -f "$COMPOSE_FILE" ps

echo -e "${GREEN}数据恢复成功！${NC}"
echo -e "${YELLOW}请检查服务状态并验证数据完整性${NC}"
echo -e "${YELLOW}LightRAG API地址: http://localhost:9621${NC}"
echo -e "${YELLOW}Neo4J 浏览器地址: http://localhost:7474${NC}"
