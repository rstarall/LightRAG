#!/usr/bin/env python3
"""
GraphML to Neo4J Migration Script
将 NetworkX GraphML 格式的图数据迁移到 Neo4J 数据库中
"""

import os
import sys
import asyncio
import argparse
from pathlib import Path
from typing import Dict, Any, List, Optional
import json

# Add the parent directory to the path to import lightrag modules
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

try:
    import networkx as nx
    from neo4j import AsyncGraphDatabase
    from tqdm import tqdm
except ImportError as e:
    print(f"Error importing required modules: {e}")
    print("Please install required packages:")
    print("pip install networkx neo4j tqdm")
    sys.exit(1)

# Migration script uses only environment variables and defaults
# No config.ini dependency to stay independent from container configuration


class GraphMLToNeo4jMigrator:
    def __init__(self, graphml_file: str, workspace: str = "base"):
        self.graphml_file = graphml_file
        self.workspace = workspace
        self.driver = None
        self.database = None
        
        # Neo4J connection settings with defaults (ignore config.ini for migration)
        self.neo4j_uri = os.environ.get("NEO4J_URI", "neo4j://localhost:7687")
        self.neo4j_username = os.environ.get("NEO4J_USERNAME", "neo4j")
        self.neo4j_password = os.environ.get("NEO4J_PASSWORD", "12345678")
        
        # Use namespace as database name (similar to Neo4JStorage implementation)
        self.database = os.environ.get("NEO4J_DATABASE", "neo4j")
        
        print(f"Migration Configuration:")
        print(f"  GraphML File: {self.graphml_file}")
        print(f"  Workspace: {self.workspace}")
        print(f"  Neo4J URI: {self.neo4j_uri}")
        print(f"  Neo4J Database: {self.database}")
        print(f"  Neo4J Username: {self.neo4j_username}")
        print(f"  Neo4J Password: {'*' * len(self.neo4j_password)}")
        print()

    async def connect(self):
        """建立 Neo4J 连接"""
        try:
            self.driver = AsyncGraphDatabase.driver(
                self.neo4j_uri,
                auth=(self.neo4j_username, self.neo4j_password),
                max_connection_pool_size=50,
                connection_timeout=30.0
            )
            
            # Test connection
            async with self.driver.session(database=self.database) as session:
                result = await session.run("RETURN 1 as test")
                await result.consume()
                print("✓ Successfully connected to Neo4J")
                
        except Exception as e:
            print(f"✗ Failed to connect to Neo4J: {e}")
            raise

    async def disconnect(self):
        """关闭 Neo4J 连接"""
        if self.driver:
            await self.driver.close()
            print("✓ Disconnected from Neo4J")

    def load_graphml(self) -> nx.Graph:
        """加载 GraphML 文件"""
        print(f"Loading GraphML file: {self.graphml_file}")
        
        if not os.path.exists(self.graphml_file):
            raise FileNotFoundError(f"GraphML file not found: {self.graphml_file}")
            
        try:
            graph = nx.read_graphml(self.graphml_file)
            print(f"✓ Loaded graph with {graph.number_of_nodes()} nodes and {graph.number_of_edges()} edges")
            return graph
        except Exception as e:
            print(f"✗ Failed to load GraphML file: {e}")
            raise

    def prepare_node_data(self, node_id: str, node_attrs: Dict[str, Any]) -> Dict[str, Any]:
        """准备节点数据，确保符合 Neo4J 格式"""
        node_data = dict(node_attrs)
        node_data["entity_id"] = node_id
        
        # 确保所有值都是可序列化的
        for key, value in node_data.items():
            if isinstance(value, (list, dict)):
                node_data[key] = json.dumps(value)
            elif value is None:
                node_data[key] = ""
            else:
                node_data[key] = str(value)
        
        return node_data

    def prepare_edge_data(self, edge_attrs: Dict[str, Any]) -> Dict[str, Any]:
        """准备边数据，确保符合 Neo4J 格式"""
        edge_data = dict(edge_attrs)
        
        # 确保所有值都是可序列化的
        for key, value in edge_data.items():
            if isinstance(value, (list, dict)):
                edge_data[key] = json.dumps(value)
            elif value is None:
                edge_data[key] = ""
            else:
                edge_data[key] = str(value)
        
        # 确保权重是浮点数
        if "weight" in edge_data:
            try:
                edge_data["weight"] = float(edge_data["weight"])
            except (ValueError, TypeError):
                edge_data["weight"] = 1.0
        else:
            edge_data["weight"] = 1.0
            
        return edge_data

    async def clear_workspace(self):
        """清空指定工作空间的所有数据"""
        print(f"Clearing workspace '{self.workspace}' in Neo4J...")
        
        async with self.driver.session(database=self.database) as session:
            # Delete all relationships first
            query = f"MATCH (n:`{self.workspace}`)-[r]-() DELETE r"
            await session.run(query)
            
            # Then delete all nodes
            query = f"MATCH (n:`{self.workspace}`) DELETE n"
            result = await session.run(query)
            await result.consume()
            
        print(f"✓ Cleared workspace '{self.workspace}'")

    async def cleanup_duplicates(self):
        """清理重复的节点和边"""
        print("Cleaning up duplicate data...")
        
        async with self.driver.session(database=self.database) as session:
            # Remove duplicate nodes (keep the first one)
            query = f"""
            MATCH (n:`{self.workspace}`)
            WITH n.entity_id as id, collect(n) as nodes
            WHERE size(nodes) > 1
            UNWIND tail(nodes) as duplicate
            DETACH DELETE duplicate
            """
            result = await session.run(query)
            await result.consume()
            
            # Remove duplicate relationships
            query = f"""
            MATCH (a:`{self.workspace}`)-[r:DIRECTED]->(b:`{self.workspace}`)
            WITH a, b, type(r) as rel_type, collect(r) as rels
            WHERE size(rels) > 1
            UNWIND tail(rels) as duplicate_rel
            DELETE duplicate_rel
            """
            result = await session.run(query)
            await result.consume()
            
        print("✓ Cleaned up duplicates")

    async def migrate_nodes(self, graph: nx.Graph):
        """迁移节点数据"""
        print(f"Migrating {graph.number_of_nodes()} nodes...")
        
        # Reduce batch size to avoid stack overflow
        batch_size = 100
        nodes = list(graph.nodes(data=True))
        
        async with self.driver.session(database=self.database) as session:
            for i in tqdm(range(0, len(nodes), batch_size), desc="Node batches"):
                batch = nodes[i:i + batch_size]
                
                # Use UNWIND for more efficient batch processing
                batch_data = []
                for node_id, node_attrs in batch:
                    node_data = self.prepare_node_data(node_id, node_attrs)
                    entity_type = node_data.get("entity_type", "Entity")
                    node_data["_entity_type"] = entity_type  # Store entity type for later use
                    batch_data.append(node_data)
                
                if batch_data:
                    query = f"""
                    UNWIND $batch_data AS node_data
                    MERGE (n:`{self.workspace}` {{entity_id: node_data.entity_id}})
                    SET n += node_data
                    SET n:`{{node_data._entity_type}}`
                    REMOVE n._entity_type
                    """.replace("{node_data._entity_type}", "\" + node_data._entity_type + \"")
                    
                    # Simplified query to avoid stack overflow
                    query = f"""
                    UNWIND $batch_data AS node_data
                    MERGE (n:`{self.workspace}` {{entity_id: node_data.entity_id}})
                    SET n += node_data
                    """
                    
                    await session.run(query, batch_data=batch_data)
        
        print(f"✓ Migrated {graph.number_of_nodes()} nodes")

    async def migrate_edges(self, graph: nx.Graph):
        """迁移边数据"""
        print(f"Migrating {graph.number_of_edges()} edges...")
        
        # Reduce batch size to avoid stack overflow
        batch_size = 50
        edges = list(graph.edges(data=True))
        
        # For undirected graphs, ensure we don't create duplicate edges
        is_undirected = not graph.is_directed()
        if is_undirected:
            print("  Detected undirected graph, normalizing edge directions...")
            # Normalize edge directions to avoid duplicates (always source < target lexicographically)
            normalized_edges = []
            for source, target, edge_attrs in edges:
                if str(source) <= str(target):
                    normalized_edges.append((source, target, edge_attrs))
                else:
                    normalized_edges.append((target, source, edge_attrs))
            
            # Remove duplicates by converting to set and back (can't hash dict, so use tuple)
            unique_edges = {}
            for source, target, edge_attrs in normalized_edges:
                edge_key = (source, target)
                if edge_key not in unique_edges:
                    unique_edges[edge_key] = edge_attrs
            
            # Convert back to edge list
            edges = [(source, target, attrs) for (source, target), attrs in unique_edges.items()]
            print(f"  Normalized to {len(edges)} unique edges")
        
        async with self.driver.session(database=self.database) as session:
            for i in tqdm(range(0, len(edges), batch_size), desc="Edge batches"):
                batch = edges[i:i + batch_size]
                
                # Use UNWIND for more efficient batch processing
                batch_data = []
                for source, target, edge_attrs in batch:
                    edge_data = self.prepare_edge_data(edge_attrs)
                    batch_data.append({
                        "source": source,
                        "target": target,
                        "properties": edge_data
                    })
                
                if batch_data:
                    query = f"""
                    UNWIND $batch_data AS edge_data
                    MATCH (a:`{self.workspace}` {{entity_id: edge_data.source}})
                    MATCH (b:`{self.workspace}` {{entity_id: edge_data.target}})
                    MERGE (a)-[r:DIRECTED]->(b)
                    SET r += edge_data.properties
                    """
                    
                    await session.run(query, batch_data=batch_data)
        
        print(f"✓ Migrated {len(edges)} edges")

    async def create_indexes(self):
        """创建必要的索引以提高查询性能"""
        print("Creating indexes...")
        
        async with self.driver.session(database=self.database) as session:
            # Create index on entity_id for the workspace
            try:
                query = f"CREATE INDEX entity_id_index_{self.workspace} IF NOT EXISTS FOR (n:`{self.workspace}`) ON (n.entity_id)"
                await session.run(query)
                print(f"✓ Created index on entity_id for workspace '{self.workspace}'")
            except Exception as e:
                print(f"⚠ Index creation warning: {e}")

    async def verify_migration(self, original_graph: nx.Graph):
        """验证迁移结果"""
        print("Verifying migration...")
        
        async with self.driver.session(database=self.database) as session:
            # Check node count
            result = await session.run(f"MATCH (n:`{self.workspace}`) RETURN count(n) as node_count")
            record = await result.single()
            neo4j_node_count = record["node_count"]
            await result.consume()
            
            # Check edge count (count relationships, not relationship instances)
            # For undirected graphs, each edge should be counted once
            result = await session.run(f"MATCH (a:`{self.workspace}`)-[r:DIRECTED]->(b:`{self.workspace}`) RETURN count(r) as edge_count")
            record = await result.single()
            neo4j_edge_count = record["edge_count"]
            await result.consume()
            
            # Check for duplicate nodes
            result = await session.run(f"""
                MATCH (n:`{self.workspace}`) 
                WITH n.entity_id as id, count(n) as cnt 
                WHERE cnt > 1 
                RETURN count(id) as duplicate_nodes
            """)
            record = await result.single()
            duplicate_nodes = record["duplicate_nodes"]
            await result.consume()
            
            print(f"Migration verification:")
            print(f"  Original nodes: {original_graph.number_of_nodes()}")
            print(f"  Neo4J nodes: {neo4j_node_count}")
            print(f"  Duplicate nodes: {duplicate_nodes}")
            print(f"  Original edges: {original_graph.number_of_edges()}")
            print(f"  Neo4J directed edges: {neo4j_edge_count}")
            
            # NetworkX graph might be undirected, so we need to check
            is_undirected = not original_graph.is_directed()
            print(f"  Original graph type: {'undirected' if is_undirected else 'directed'}")
            
            # For undirected graphs, we expect the same number of edges
            # For directed graphs, we also expect the same number
            expected_edges = original_graph.number_of_edges()
            
            node_match = neo4j_node_count == original_graph.number_of_nodes()
            edge_match = neo4j_edge_count == expected_edges
            no_duplicates = duplicate_nodes == 0
            
            if node_match and edge_match and no_duplicates:
                print("✓ Migration verification successful!")
                return True
            else:
                print("✗ Migration verification failed!")
                if not node_match:
                    print(f"  ❌ Node count mismatch: expected {original_graph.number_of_nodes()}, got {neo4j_node_count}")
                if not edge_match:
                    print(f"  ❌ Edge count mismatch: expected {expected_edges}, got {neo4j_edge_count}")
                if not no_duplicates:
                    print(f"  ❌ Found {duplicate_nodes} duplicate nodes")
                return False

    async def migrate_nodes_single(self, graph: nx.Graph):
        """使用单个插入模式迁移节点数据（更慢但更稳定）"""
        print(f"Migrating {graph.number_of_nodes()} nodes (single mode)...")
        
        nodes = list(graph.nodes(data=True))
        
        async with self.driver.session(database=self.database) as session:
            for node_id, node_attrs in tqdm(nodes, desc="Nodes"):
                node_data = self.prepare_node_data(node_id, node_attrs)
                
                query = f"""
                MERGE (n:`{self.workspace}` {{entity_id: $entity_id}})
                SET n += $properties
                """
                
                await session.run(query, entity_id=node_id, properties=node_data)
        
        print(f"✓ Migrated {graph.number_of_nodes()} nodes")

    async def migrate_edges_single(self, graph: nx.Graph):
        """使用单个插入模式迁移边数据（更慢但更稳定）"""
        print(f"Migrating {graph.number_of_edges()} edges (single mode)...")
        
        edges = list(graph.edges(data=True))
        
        # For undirected graphs, ensure we don't create duplicate edges
        is_undirected = not graph.is_directed()
        if is_undirected:
            print("  Detected undirected graph, normalizing edge directions...")
            # Normalize edge directions to avoid duplicates (always source < target lexicographically)
            normalized_edges = []
            for source, target, edge_attrs in edges:
                if str(source) <= str(target):
                    normalized_edges.append((source, target, edge_attrs))
                else:
                    normalized_edges.append((target, source, edge_attrs))
            
            # Remove duplicates by converting to set and back (can't hash dict, so use tuple)
            unique_edges = {}
            for source, target, edge_attrs in normalized_edges:
                edge_key = (source, target)
                if edge_key not in unique_edges:
                    unique_edges[edge_key] = edge_attrs
            
            # Convert back to edge list
            edges = [(source, target, attrs) for (source, target), attrs in unique_edges.items()]
            print(f"  Normalized to {len(edges)} unique edges")
        
        async with self.driver.session(database=self.database) as session:
            for source, target, edge_attrs in tqdm(edges, desc="Edges"):
                edge_data = self.prepare_edge_data(edge_attrs)
                
                query = f"""
                MATCH (a:`{self.workspace}` {{entity_id: $source}})
                MATCH (b:`{self.workspace}` {{entity_id: $target}})
                MERGE (a)-[r:DIRECTED]->(b)
                SET r += $properties
                """
                
                await session.run(query, source=source, target=target, properties=edge_data)
        
        print(f"✓ Migrated {len(edges)} edges")

    async def migrate(self, clear_existing: bool = False, single_mode: bool = False):
        """执行完整的迁移过程"""
        print("Starting GraphML to Neo4J migration...")
        print("=" * 50)
        
        try:
            # 1. 连接到 Neo4J
            await self.connect()
            
            # 2. 加载 GraphML 文件
            graph = self.load_graphml()
            
            # 3. 清空现有数据（如果需要）
            if clear_existing:
                await self.clear_workspace()
            
            # 4. 迁移节点
            if single_mode:
                await self.migrate_nodes_single(graph)
            else:
                await self.migrate_nodes(graph)
            
            # 5. 迁移边
            if single_mode:
                await self.migrate_edges_single(graph)
            else:
                await self.migrate_edges(graph)
            
            # 6. 清理重复数据
            await self.cleanup_duplicates()
            
            # 7. 创建索引
            await self.create_indexes()
            
            # 8. 验证迁移
            success = await self.verify_migration(graph)
            
            if success:
                print("\n" + "=" * 50)
                print("✓ Migration completed successfully!")
            else:
                print("\n" + "=" * 50)
                print("✗ Migration completed with errors!")
                
        except Exception as e:
            print(f"\n✗ Migration failed: {e}")
            if not single_mode:
                print("\n💡 Tip: Try using --single-mode for large datasets to avoid stack overflow")
            raise
        finally:
            await self.disconnect()


async def cleanup_only(workspace: str = "base"):
    """只执行清理操作"""
    migrator = GraphMLToNeo4jMigrator("", workspace)  # 不需要文件路径
    try:
        await migrator.connect()
        await migrator.cleanup_duplicates()
        print("✓ Cleanup completed successfully!")
    except Exception as e:
        print(f"✗ Cleanup failed: {e}")
        raise
    finally:
        await migrator.disconnect()

def main():
    parser = argparse.ArgumentParser(description="Migrate GraphML data to Neo4J")
    parser.add_argument("graphml_file", nargs="?", help="Path to the GraphML file (not required for --cleanup-only)")
    parser.add_argument("--workspace", default="base", help="Neo4J workspace/label (default: base)")
    parser.add_argument("--clear", action="store_true", help="Clear existing data before migration")
    parser.add_argument("--single-mode", action="store_true", help="Use single insert mode (slower but more stable for large datasets)")
    parser.add_argument("--cleanup-only", action="store_true", help="Only cleanup duplicates, don't migrate")
    
    args = parser.parse_args()
    
    # Handle cleanup-only mode
    if args.cleanup_only:
        try:
            asyncio.run(cleanup_only(args.workspace))
        except KeyboardInterrupt:
            print("\n⚠ Cleanup interrupted by user")
            sys.exit(1)
        except Exception as e:
            print(f"\n✗ Cleanup failed: {e}")
            sys.exit(1)
        return
    
    # Validate input file for migration
    if not args.graphml_file:
        print("Error: GraphML file is required for migration (use --cleanup-only if you only want to cleanup)")
        sys.exit(1)
        
    if not os.path.exists(args.graphml_file):
        print(f"Error: GraphML file not found: {args.graphml_file}")
        sys.exit(1)
    
    # Create migrator and run
    migrator = GraphMLToNeo4jMigrator(args.graphml_file, args.workspace)
    
    try:
        asyncio.run(migrator.migrate(clear_existing=args.clear, single_mode=getattr(args, 'single_mode', False)))
    except KeyboardInterrupt:
        print("\n⚠ Migration interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Migration failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main() 