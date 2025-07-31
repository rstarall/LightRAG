#!/usr/bin/env python3
from pymilvus import connections, list_collections, Collection
import json

def check_milvus_data():
    """检查 Milvus 数据库中的所有数据"""
    try:
        # 连接到 Milvus
        print("正在连接到 Milvus...")
        connections.connect(
            alias="default",
            host="localhost",
            port=19530
        )
        print("成功连接到 Milvus\n")
        
        # 获取所有 collections
        collections = list_collections()
        print(f"找到 {len(collections)} 个 collections:")
        
        if not collections:
            print("数据库中没有任何 collections")
            return
        
        # 遍历每个 collection
        for collection_name in collections:
            print(f"\n{'='*50}")
            print(f"Collection: {collection_name}")
            print('='*50)
            
            try:
                # 加载 collection
                collection = Collection(collection_name)
                
                # 获取 collection 信息
                print(f"描述: {collection.description}")
                print(f"Schema: {collection.schema}")
                
                # 加载 collection（如果尚未加载）
                collection.load()
                
                # 获取实体数量
                num_entities = collection.num_entities
                print(f"实体数量: {num_entities}")
                
                # 如果有数据，尝试查询一些样本
                if num_entities > 0:
                    print("\n查询前 5 条数据样本:")
                    # 查询前 5 条数据
                    results = collection.query(
                        expr="",  # 空表达式表示查询所有
                        limit=5,
                        output_fields=["*"]  # 返回所有字段
                    )
                    
                    for i, result in enumerate(results, 1):
                        print(f"\n样本 {i}:")
                        print(json.dumps(result, indent=2, ensure_ascii=False))
                
                # 获取索引信息
                indexes = collection.indexes
                if indexes:
                    print(f"\n索引信息:")
                    for index in indexes:
                        print(f"  - 字段: {index.field_name}")
                        print(f"    参数: {index.params}")
                
            except Exception as e:
                print(f"处理 collection {collection_name} 时出错: {str(e)}")
        
        # 断开连接
        connections.disconnect("default")
        print("\n\n检查完成！")
        
    except Exception as e:
        print(f"错误: {str(e)}")

if __name__ == "__main__":
    check_milvus_data()