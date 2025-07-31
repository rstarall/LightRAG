#!/usr/bin/env python3
"""
快速检查 Neo4J 数据状态
用于验证迁移结果和检查重复数据
"""

import os
import sys
import asyncio
from typing import Dict, Any

try:
    from neo4j import AsyncGraphDatabase
except ImportError:
    print("Error: neo4j package not found. Please install: pip install neo4j")
    sys.exit(1)


class Neo4JDataChecker:
    def __init__(self, workspace: str = "base"):
        self.workspace = workspace
        self.driver = None
        
        # Neo4J connection settings with defaults
        self.neo4j_uri = os.environ.get("NEO4J_URI", "neo4j://localhost:7687")
        self.neo4j_username = os.environ.get("NEO4J_USERNAME", "neo4j")
        self.neo4j_password = os.environ.get("NEO4J_PASSWORD", "12345678")
        self.database = os.environ.get("NEO4J_DATABASE", "neo4j")
        
        print(f"Checking workspace: {self.workspace}")
        print(f"Connecting to: {self.neo4j_uri}")

    async def connect(self):
        """连接到 Neo4J"""
        try:
            self.driver = AsyncGraphDatabase.driver(
                self.neo4j_uri,
                auth=(self.neo4j_username, self.neo4j_password),
                max_connection_pool_size=10,
                connection_timeout=30.0
            )
            
            # Test connection
            async with self.driver.session(database=self.database) as session:
                result = await session.run("RETURN 1 as test")
                await result.consume()
                print("✓ Connected to Neo4J")
                
        except Exception as e:
            print(f"✗ Failed to connect to Neo4J: {e}")
            raise

    async def disconnect(self):
        """断开 Neo4J 连接"""
        if self.driver:
            await self.driver.close()

    async def check_basic_counts(self):
        """检查基本统计信息"""
        print("\n📊 Basic Statistics:")
        
        async with self.driver.session(database=self.database) as session:
            # Node count
            result = await session.run(f"MATCH (n:`{self.workspace}`) RETURN count(n) as count")
            record = await result.single()
            node_count = record["count"]
            await result.consume()
            
            # Edge count
            result = await session.run(f"MATCH (:`{self.workspace}`)-[r:DIRECTED]->(:`{self.workspace}`) RETURN count(r) as count")
            record = await result.single()
            edge_count = record["count"]
            await result.consume()
            
            print(f"  Nodes: {node_count:,}")
            print(f"  Edges: {edge_count:,}")

    async def check_duplicates(self):
        """检查重复数据"""
        print("\n🔍 Duplicate Check:")
        
        async with self.driver.session(database=self.database) as session:
            # Duplicate nodes
            result = await session.run(f"""
                MATCH (n:`{self.workspace}`) 
                WITH n.entity_id as id, count(n) as cnt 
                WHERE cnt > 1 
                RETURN count(id) as duplicate_nodes, collect({{id: id, count: cnt}}) as details
            """)
            record = await result.single()
            duplicate_nodes = record["duplicate_nodes"]
            node_details = record["details"]
            await result.consume()
            
            # Duplicate edges
            result = await session.run(f"""
                MATCH (a:`{self.workspace}`)-[r:DIRECTED]->(b:`{self.workspace}`)
                WITH a.entity_id as source, b.entity_id as target, count(r) as cnt
                WHERE cnt > 1
                RETURN count(*) as duplicate_edges, collect({{source: source, target: target, count: cnt}}) as details
            """)
            record = await result.single()
            duplicate_edges = record["duplicate_edges"]
            edge_details = record["details"]
            await result.consume()
            
            print(f"  Duplicate nodes: {duplicate_nodes}")
            if duplicate_nodes > 0:
                print("  📝 Duplicate node details:")
                for detail in node_details[:5]:  # Show first 5
                    print(f"    - {detail['id']}: {detail['count']} copies")
                if len(node_details) > 5:
                    print(f"    ... and {len(node_details) - 5} more")
            
            print(f"  Duplicate edges: {duplicate_edges}")
            if duplicate_edges > 0:
                print("  📝 Duplicate edge details:")
                for detail in edge_details[:5]:  # Show first 5
                    print(f"    - {detail['source']} -> {detail['target']}: {detail['count']} copies")
                if len(edge_details) > 5:
                    print(f"    ... and {len(edge_details) - 5} more")

    async def check_entity_types(self):
        """检查实体类型分布"""
        print("\n📋 Entity Types:")
        
        async with self.driver.session(database=self.database) as session:
            result = await session.run(f"""
                MATCH (n:`{self.workspace}`)
                WITH n.entity_type as type, count(n) as count
                ORDER BY count DESC
                RETURN type, count
                LIMIT 10
            """)
            
            records = await result.fetch(10)
            await result.consume()
            
            for record in records:
                entity_type = record["type"] or "Unknown"
                count = record["count"]
                print(f"  {entity_type}: {count:,}")

    async def check_connectivity(self):
        """检查图连通性"""
        print("\n🔗 Graph Connectivity:")
        
        async with self.driver.session(database=self.database) as session:
            # Nodes with no connections
            result = await session.run(f"""
                MATCH (n:`{self.workspace}`)
                WHERE NOT (n)--()
                RETURN count(n) as isolated_nodes
            """)
            record = await result.single()
            isolated_nodes = record["isolated_nodes"]
            await result.consume()
            
            # Average degree
            result = await session.run(f"""
                MATCH (n:`{self.workspace}`)
                OPTIONAL MATCH (n)-[r]-()
                WITH n, count(r) as degree
                RETURN avg(degree) as avg_degree, max(degree) as max_degree
            """)
            record = await result.single()
            avg_degree = record["avg_degree"] or 0
            max_degree = record["max_degree"] or 0
            await result.consume()
            
            print(f"  Isolated nodes: {isolated_nodes:,}")
            print(f"  Average degree: {avg_degree:.2f}")
            print(f"  Maximum degree: {max_degree}")

    async def run_check(self):
        """运行完整检查"""
        try:
            await self.connect()
            await self.check_basic_counts()
            await self.check_duplicates()
            await self.check_entity_types()
            await self.check_connectivity()
            
            print("\n✅ Data check completed!")
            
        except Exception as e:
            print(f"\n❌ Check failed: {e}")
            raise
        finally:
            await self.disconnect()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description="Check Neo4J data status")
    parser.add_argument("--workspace", default="base", help="Neo4J workspace to check (default: base)")
    
    args = parser.parse_args()
    
    checker = Neo4JDataChecker(args.workspace)
    
    try:
        asyncio.run(checker.run_check())
    except KeyboardInterrupt:
        print("\n⚠ Check interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Check failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main() 