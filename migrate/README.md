# GraphML to Neo4J Migration Tool

这个工具用于将 LightRAG 的 NetworkX GraphML 格式数据迁移到 Neo4J 图数据库中。

## 功能特性

- ✅ 从 GraphML 文件读取图数据
- ✅ 批量迁移节点和边到 Neo4J
- ✅ 自动创建必要的索引
- ✅ 支持工作空间隔离
- ✅ 迁移结果验证
- ✅ 进度条显示
- ✅ 错误处理和恢复

## 使用方法

### 1. 基本使用

```bash
# 迁移默认的 GraphML 文件
python migrate/graphml_to_neo4j.py data/rag_storage/graph_chunk_entity_relation.graphml

# 指定工作空间
python migrate/graphml_to_neo4j.py data/rag_storage/graph_chunk_entity_relation.graphml --workspace my_workspace

# 清空现有数据后迁移
python migrate/graphml_to_neo4j.py data/rag_storage/graph_chunk_entity_relation.graphml --clear

# 使用单个插入模式（适合大数据集）
python migrate/graphml_to_neo4j.py data/rag_storage/graph_chunk_entity_relation.graphml --single-mode

# 只清理现有数据中的重复项
python migrate/graphml_to_neo4j.py --cleanup-only
```

### 2. 使用便捷脚本

```bash
# 使用提供的便捷脚本
./migrate/migrate_to_neo4j.sh

# 带参数
./migrate/migrate_to_neo4j.sh --workspace my_workspace --clear
```

## 参数说明

- `graphml_file`: GraphML 文件路径（必需）
- `--workspace`: Neo4J 工作空间/标签名（默认：base）
- `--clear`: 迁移前清空现有数据
- `--single-mode`: 使用单个插入模式（更慢但更稳定，适合大数据集或避免栈溢出）
- `--cleanup-only`: 只清理重复数据，不执行迁移

## 配置要求

### 1. 环境变量

脚本会自动读取以下环境变量（如果未设置则使用默认值）：

```bash
NEO4J_URI=neo4j://localhost:7687     # 默认值
NEO4J_USERNAME=neo4j                 # 默认值
NEO4J_PASSWORD=12345678              # 默认值
NEO4J_DATABASE=neo4j                 # 默认值
```

### 2. 默认配置

**注意**: 迁移脚本为了保持独立性，不会读取 `config.ini` 文件，只使用环境变量或以下默认值：
- URI: `neo4j://localhost:7687`
- 用户名: `neo4j`
- 密码: `12345678`
- 数据库: `neo4j`

如需自定义连接，请设置对应的环境变量：
```bash
export NEO4J_URI="neo4j://your-host:7687"
export NEO4J_USERNAME="your-username"
export NEO4J_PASSWORD="your-password"
```

## 依赖包

确保已安装以下 Python 包：

```bash
pip install networkx neo4j tqdm
```

## 迁移过程

1. **连接验证** - 测试 Neo4J 连接
2. **加载数据** - 从 GraphML 文件加载图数据
3. **清空数据** - 清空现有工作空间数据（可选）
4. **迁移节点** - 批量迁移节点数据
5. **迁移边** - 批量迁移边数据（自动处理无向图去重）
6. **清理重复** - 清理迁移过程中的重复数据
7. **创建索引** - 创建性能优化索引
8. **验证结果** - 验证迁移完整性和数据一致性

## 数据映射

### 节点映射
- GraphML 节点 → Neo4J 节点
- 节点属性 → 节点属性
- `entity_type` → 额外的节点标签
- 工作空间 → 主要节点标签

### 边映射
- GraphML 边 → Neo4J 关系（类型：DIRECTED）
- 边属性 → 关系属性
- 权重默认值：1.0

## 示例输出

```
Migration Configuration:
  GraphML File: data/rag_storage/graph_chunk_entity_relation.graphml
  Workspace: base
  Neo4J URI: neo4j://neo4j:7687
  Neo4J Database: lightrag
  Neo4J Username: neo4j
  Neo4J Password: ********

==================================================
✓ Successfully connected to Neo4J
✓ Loaded graph with 1234 nodes and 5678 edges
✓ Cleared workspace 'base'
Migrating 1234 nodes...
Node batches: 100%|████████| 2/2 [00:05<00:00, 2.5it/s]
✓ Migrated 1234 nodes
Migrating 5678 edges...
Edge batches: 100%|████████| 6/6 [00:15<00:00, 2.5it/s]
✓ Migrated 5678 edges
Creating indexes...
✓ Created index on entity_id for workspace 'base'
Verifying migration...
Migration verification:
  Original nodes: 1234
  Neo4J nodes: 1234
  Original edges: 5678
  Neo4J edges: 5678
✓ Migration verification successful!

==================================================
✓ Migration completed successfully!
```

## 故障排除

### 1. 连接问题
- 确保 Neo4J 服务正在运行
- 检查连接配置（URI、用户名、密码）
- 确认网络连接和防火墙设置

### 2. 内存/栈溢出问题
- 对于大型图（如 30k+ 节点），使用 `--single-mode` 参数
- 单个插入模式虽然较慢，但避免栈溢出错误
- 确保有足够的内存处理数据

### 3. 权限问题
- 确保 Neo4J 用户有创建数据库和索引的权限
- 检查文件读取权限

## 注意事项

1. **数据备份** - 迁移前请备份重要数据
2. **工作空间隔离** - 使用不同的工作空间名称避免数据冲突
3. **性能优化** - 大型数据集迁移可能需要时间，请耐心等待
4. **清空数据** - 使用 `--clear` 参数会删除工作空间中的所有现有数据

## 验证迁移结果

迁移完成后，可以通过 Neo4J Browser 或者 Cypher 查询验证：

```cypher
// 查看节点数量
MATCH (n:base) RETURN count(n) as node_count

// 查看边数量
MATCH (:base)-[r]-() RETURN count(r) as edge_count

// 查看节点类型分布
MATCH (n:base) RETURN n.entity_type, count(n) as count ORDER BY count DESC

// 查看节点示例
MATCH (n:base) RETURN n LIMIT 10
``` 