#!/bin/bash

# LightRAG 数据备份脚本
# 使用方法: ./backup_data.sh [backup_name]

set -e

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认备份名称
BACKUP_NAME=${1:-"lightrag-backup-$(date +%Y%m%d_%H%M%S)"}
BACKUP_DIR="./backups/${BACKUP_NAME}"
COMPOSE_FILE="docker-compose.dev.yml"

# 检查Docker Compose文件是否存在
if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}错误: 找不到 $COMPOSE_FILE 文件${NC}"
    exit 1
fi

# 创建备份目录
mkdir -p "$BACKUP_DIR"

echo -e "${GREEN}开始备份 LightRAG 数据...${NC}"
echo -e "${YELLOW}备份名称: $BACKUP_NAME${NC}"
echo -e "${YELLOW}备份目录: $BACKUP_DIR${NC}"

# 1. 备份配置文件
echo -e "${GREEN}[1/7] 备份配置文件...${NC}"
cp .env "$BACKUP_DIR/" 2>/dev/null || echo -e "${YELLOW}警告: .env 文件不存在${NC}"
cp config.ini "$BACKUP_DIR/" 2>/dev/null || echo -e "${YELLOW}警告: config.ini 文件不存在${NC}"
cp docker-compose.dev.yml "$BACKUP_DIR/" 2>/dev/null || echo -e "${YELLOW}警告: docker-compose.dev.yml 文件不存在${NC}"

# 2. 备份本地数据目录
echo -e "${GREEN}[2/7] 备份本地数据目录...${NC}"
if [ -d "./data" ]; then
    mkdir -p "$BACKUP_DIR/data"
    cp -r ./data/* "$BACKUP_DIR/data/" || echo -e "${YELLOW}警告: 复制 data 目录时出现错误${NC}"
else
    echo -e "${YELLOW}警告: ./data 目录不存在${NC}"
fi

# 3. 备份日志文件
echo -e "${GREEN}[3/7] 备份日志文件...${NC}"
if [ -d "./logs" ]; then
    mkdir -p "$BACKUP_DIR/logs"
    cp -r ./logs/* "$BACKUP_DIR/logs/" || echo -e "${YELLOW}警告: 复制 logs 目录时出现错误${NC}"
else
    echo -e "${YELLOW}警告: ./logs 目录不存在${NC}"
fi

# 4. 备份Redis数据
echo -e "${GREEN}[4/7] 备份Redis数据...${NC}"
if docker-compose -f "$COMPOSE_FILE" ps redis | grep -q "Up"; then
    mkdir -p "$BACKUP_DIR/redis"
    # 触发Redis保存数据到磁盘
    docker-compose -f "$COMPOSE_FILE" exec -T redis redis-cli BGSAVE
    sleep 2
    # 备份Redis数据文件
    docker-compose -f "$COMPOSE_FILE" exec -T redis sh -c "tar -czf /tmp/redis-backup.tar.gz -C /data ." 
    docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q redis):/tmp/redis-backup.tar.gz "$BACKUP_DIR/redis/"
    docker-compose -f "$COMPOSE_FILE" exec -T redis rm -f /tmp/redis-backup.tar.gz
    echo -e "${GREEN}Redis数据备份完成${NC}"
else
    echo -e "${YELLOW}警告: Redis 容器未运行，跳过Redis数据备份${NC}"
fi

# 5. 备份Neo4J数据
echo -e "${GREEN}[5/7] 备份Neo4J数据...${NC}"
if docker-compose -f "$COMPOSE_FILE" ps neo4j | grep -q "Up"; then
    mkdir -p "$BACKUP_DIR/neo4j"
    
    # 方法1: 直接备份数据目录
    echo -e "${YELLOW}备份Neo4J数据目录...${NC}"
    docker-compose -f "$COMPOSE_FILE" exec -T neo4j sh -c "tar -czf /tmp/neo4j-data-backup.tar.gz -C /data ."
    docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q neo4j):/tmp/neo4j-data-backup.tar.gz "$BACKUP_DIR/neo4j/"
    docker-compose -f "$COMPOSE_FILE" exec -T neo4j rm -f /tmp/neo4j-data-backup.tar.gz
    
    # 方法2: 使用 neo4j-admin dump 命令备份数据库
    echo -e "${YELLOW}使用 neo4j-admin dump 导出数据库...${NC}"
    docker-compose -f "$COMPOSE_FILE" exec -T neo4j neo4j-admin database dump --to-path=/tmp neo4j 2>/dev/null || echo -e "${YELLOW}警告: neo4j-admin dump 失败，使用数据目录备份${NC}"
    if docker-compose -f "$COMPOSE_FILE" exec -T neo4j test -f /tmp/neo4j.dump; then
        docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q neo4j):/tmp/neo4j.dump "$BACKUP_DIR/neo4j/"
        docker-compose -f "$COMPOSE_FILE" exec -T neo4j rm -f /tmp/neo4j.dump
        echo -e "${GREEN}Neo4J数据库导出完成${NC}"
    fi
    
    # 方法3: 使用 APOC 导出 Cypher 脚本
    echo -e "${YELLOW}使用 APOC 导出 Cypher 脚本...${NC}"
    docker-compose -f "$COMPOSE_FILE" exec -T neo4j cypher-shell -u neo4j -p 12345678 "CALL apoc.export.cypher.all('/tmp/neo4j-export.cypher', {});" 2>/dev/null || echo -e "${YELLOW}警告: APOC 导出失败${NC}"
    if docker-compose -f "$COMPOSE_FILE" exec -T neo4j test -f /tmp/neo4j-export.cypher; then
        docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q neo4j):/tmp/neo4j-export.cypher "$BACKUP_DIR/neo4j/"
        docker-compose -f "$COMPOSE_FILE" exec -T neo4j rm -f /tmp/neo4j-export.cypher
        echo -e "${GREEN}Neo4J Cypher 脚本导出完成${NC}"
    fi
    
    echo -e "${GREEN}Neo4J数据备份完成${NC}"
else
    echo -e "${YELLOW}警告: Neo4J 容器未运行，跳过Neo4J数据备份${NC}"
fi

# 6. 备份Milvus相关数据
echo -e "${GREEN}[6/7] 备份Milvus相关数据...${NC}"

# 备份etcd数据
if docker-compose -f "$COMPOSE_FILE" ps etcd | grep -q "Up"; then
    mkdir -p "$BACKUP_DIR/etcd"
    docker-compose -f "$COMPOSE_FILE" exec -T etcd sh -c "tar -czf /tmp/etcd-backup.tar.gz -C /etcd ."
    docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q etcd):/tmp/etcd-backup.tar.gz "$BACKUP_DIR/etcd/"
    docker-compose -f "$COMPOSE_FILE" exec -T etcd rm -f /tmp/etcd-backup.tar.gz
    echo -e "${GREEN}etcd数据备份完成${NC}"
else
    echo -e "${YELLOW}警告: etcd 容器未运行，跳过etcd数据备份${NC}"
fi

# 备份MinIO数据
if docker-compose -f "$COMPOSE_FILE" ps minio | grep -q "Up"; then
    mkdir -p "$BACKUP_DIR/minio"
    docker-compose -f "$COMPOSE_FILE" exec -T minio sh -c "tar -czf /tmp/minio-backup.tar.gz -C /minio_data ."
    docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q minio):/tmp/minio-backup.tar.gz "$BACKUP_DIR/minio/"
    docker-compose -f "$COMPOSE_FILE" exec -T minio rm -f /tmp/minio-backup.tar.gz
    echo -e "${GREEN}MinIO数据备份完成${NC}"
else
    echo -e "${YELLOW}警告: MinIO 容器未运行，跳过MinIO数据备份${NC}"
fi

# 备份Milvus数据
if docker-compose -f "$COMPOSE_FILE" ps milvus-standalone | grep -q "Up"; then
    mkdir -p "$BACKUP_DIR/milvus"
    docker-compose -f "$COMPOSE_FILE" exec -T milvus-standalone sh -c "tar -czf /tmp/milvus-backup.tar.gz -C /var/lib/milvus ."
    docker cp $(docker-compose -f "$COMPOSE_FILE" ps -q milvus-standalone):/tmp/milvus-backup.tar.gz "$BACKUP_DIR/milvus/"
    docker-compose -f "$COMPOSE_FILE" exec -T milvus-standalone rm -f /tmp/milvus-backup.tar.gz
    echo -e "${GREEN}Milvus数据备份完成${NC}"
else
    echo -e "${YELLOW}警告: Milvus 容器未运行，跳过Milvus数据备份${NC}"
fi

# 7. 创建备份信息文件
echo -e "${GREEN}[7/7] 创建备份信息文件...${NC}"
cat > "$BACKUP_DIR/backup_info.txt" << EOF
LightRAG 数据备份信息
=====================

备份时间: $(date)
备份名称: $BACKUP_NAME
备份版本: 1.0

存储配置:
- KV存储: RedisKVStorage
- 文档状态存储: RedisDocStatusStorage  
- 图存储: Neo4jStorage
- 向量存储: MilvusVectorDBStorage

备份内容:
- 配置文件: .env, config.ini, docker-compose.dev.yml
- 本地数据: ./data/rag_storage, ./data/inputs
- 日志文件: ./logs
- Redis数据: redis_data volume
- Neo4J数据: neo4j_data volume (包含数据目录备份、数据库导出文件、Cypher脚本)
- etcd数据: etcd_data volume
- MinIO数据: minio_data volume
- Milvus数据: milvus_data volume

服务状态:
$(docker-compose -f "$COMPOSE_FILE" ps)

环境变量:
$(grep -E "^[A-Z_]+" .env | head -20)

注意事项:
1. 恢复数据前请确保所有容器都已停止
2. 恢复时需要使用相同的存储配置
3. 建议在恢复前备份现有数据
4. Neo4J数据包含多种格式：数据目录、数据库导出、Cypher脚本
5. 推荐使用数据库导出文件进行恢复，它更加可靠
EOF

# 创建压缩包
echo -e "${GREEN}创建压缩包...${NC}"
cd backups
tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME"
cd ..

echo -e "${GREEN}备份完成！${NC}"
echo -e "${YELLOW}备份文件位置: ./backups/${BACKUP_NAME}.tar.gz${NC}"
echo -e "${YELLOW}备份目录大小: $(du -sh $BACKUP_DIR | cut -f1)${NC}"
echo -e "${YELLOW}压缩包大小: $(du -sh ./backups/${BACKUP_NAME}.tar.gz | cut -f1)${NC}"
