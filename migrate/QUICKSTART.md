# 快速开始 - GraphML 到 Neo4J 迁移

## 🚀 快速执行

### 1. 安装依赖包
```bash
# 在项目根目录执行
pip install networkx neo4j tqdm
# 或者使用 requirements 文件
pip install -r migrate/requirements.txt
```

### 2. 启动 Neo4J 服务
```bash
# 启动 Docker 服务
docker-compose -f docker-compose.dev.yml up -d neo4j

# 等待服务启动
docker-compose -f docker-compose.dev.yml logs -f neo4j
```

### 3. 执行迁移
```bash
# 最简单的方式 - 使用便捷脚本
./migrate/migrate_to_neo4j.sh

# 对于大数据集，使用单个插入模式
./migrate/migrate_to_neo4j.sh --single-mode

# 或直接使用 Python 脚本
python migrate/graphml_to_neo4j.py data/rag_storage/graph_chunk_entity_relation.graphml

# 大数据集使用单个插入模式
python migrate/graphml_to_neo4j.py data/rag_storage/graph_chunk_entity_relation.graphml --single-mode
```

## 📋 预检查清单

- [ ] Neo4J 服务运行正常
- [ ] GraphML 文件存在且不为空
- [ ] 安装了必要的 Python 包
- [ ] 配置了正确的 Neo4J 连接信息（通过环境变量，默认使用 localhost:7687）

## 🔧 常见问题

### Q: 迁移失败，提示连接错误
**A:** 检查 Neo4J 服务状态和连接配置：
```bash
# 检查容器状态
docker ps | grep neo4j

# 检查 Neo4J 日志
docker logs lightrag-neo4j-dev

# 测试连接
curl -u neo4j:12345678 http://localhost:7474/db/data/
```

### Q: 提示缺少 Python 包
**A:** 安装迁移专用依赖：
```bash
pip install networkx neo4j tqdm
# 或者
pip install -r migrate/requirements.txt
```

### Q: 迁移很慢
**A:** 这是正常的，大型图数据迁移需要时间。可以查看进度条或调整批处理大小。

### Q: 想要清空现有数据
**A:** 使用 `--clear` 参数：
```bash
./migrate/migrate_to_neo4j.sh --clear
```

### Q: 出现栈溢出错误 (StackOverFlowError)
**A:** 对于大数据集（如 30k+ 节点），使用单个插入模式：
```bash
./migrate/migrate_to_neo4j.sh --single-mode
```
虽然较慢，但能避免栈溢出问题。

### Q: 迁移后发现重复数据
**A:** 运行清理命令：
```bash
python migrate/graphml_to_neo4j.py --cleanup-only --workspace base
```
这会清理重复的节点和边，不会重新迁移数据。

## 🎯 验证结果

### 1. 通过 Neo4J Browser
访问 http://localhost:7474，使用以下查询：
```cypher
// 查看节点总数
MATCH (n:base) RETURN count(n) as node_count

// 查看关系总数
MATCH (:base)-[r]-() RETURN count(r) as relation_count

// 查看节点类型分布
MATCH (n:base) RETURN n.entity_type, count(n) as count ORDER BY count DESC LIMIT 10
```

### 2. 通过命令行
```bash
# 进入 Neo4J 容器
docker exec -it lightrag-neo4j-dev cypher-shell -u neo4j -p 12345678

# 执行查询
MATCH (n:base) RETURN count(n) as node_count;
```

## 📊 数据结构

迁移后的 Neo4J 数据结构：
- **节点标签**: `base` (工作空间) + `entity_type` (实体类型)
- **关系类型**: `DIRECTED`
- **节点属性**: 保留原 GraphML 所有属性 + `entity_id`
- **关系属性**: 保留原 GraphML 所有属性 + `weight`

## 🎉 完成！

迁移完成后，您的 LightRAG 系统将使用 Neo4J 作为图数据库，享受更强大的图查询和分析能力！ 