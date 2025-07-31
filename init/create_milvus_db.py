#!/usr/bin/env python3
"""
LightRAG Milvus Database Creator
在宿主机上创建 LightRAG 所需的 Milvus 数据库
"""

import sys
import time
import argparse
import subprocess
from typing import Optional

def install_pymilvus():
    """安装 pymilvus 依赖"""
    try:
        import pymilvus
        print("✅ pymilvus 已安装")
        return True
    except ImportError:
        print("📦 正在安装 pymilvus...")
        try:
            subprocess.check_call([sys.executable, "-m", "pip", "install", "pymilvus"])
            print("✅ pymilvus 安装成功")
            
            # 重新导入模块以确保可用
            try:
                import pymilvus
                print("✅ pymilvus 导入验证成功")
                return True
            except ImportError as e:
                print(f"❌ pymilvus 导入验证失败: {e}")
                print("💡 请重新运行脚本或重启Python环境")
                return False
                
        except subprocess.CalledProcessError as e:
            print(f"❌ pymilvus 安装失败: {e}")
            return False

def wait_for_milvus(host: str, port: int, timeout: int = 60) -> bool:
    """等待 Milvus 服务启动"""
    import socket
    
    print(f"⏳ 等待 Milvus 服务启动 ({host}:{port})...")
    
    for i in range(timeout):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result = sock.connect_ex((host, port))
            sock.close()
            
            if result == 0:
                print("✅ Milvus 服务已启动")
                return True
                
        except Exception as e:
            pass
            
        print(f"⏳ 等待中... ({i+1}/{timeout})")
        time.sleep(1)
    
    print("❌ Milvus 服务启动超时")
    return False

def create_database(host: str, port: int, db_name: str, max_retries: int = 30) -> bool:
    """创建 Milvus 数据库"""
    try:
        import pymilvus
    except ImportError as e:
        print(f"❌ 无法导入 pymilvus: {e}")
        print("💡 请重新运行脚本或手动安装: pip install pymilvus")
        return False
    
    uri = f"http://{host}:{port}"
    print(f"🔄 连接到 Milvus ({uri})...")
    
    for i in range(max_retries):
        try:
            client = pymilvus.MilvusClient(uri=uri)
            
            # 检查数据库是否已存在
            databases = client.list_databases()
            print(f"📋 现有数据库: {databases}")
            
            if db_name in databases:
                print(f"✅ 数据库 '{db_name}' 已存在")
                return True
            
            # 创建数据库
            client.create_database(db_name=db_name)
            print(f"✅ 数据库 '{db_name}' 创建成功")
            
            # 验证创建结果
            databases = client.list_databases()
            if db_name in databases:
                print(f"✅ 数据库创建验证成功")
                return True
            else:
                print(f"❌ 数据库创建验证失败")
                return False
                
        except Exception as e:
            print(f"⏳ 尝试 {i+1}/{max_retries}: {e}")
            time.sleep(2)
    
    print(f"❌ 创建数据库失败，已尝试 {max_retries} 次")
    return False

def main():
    parser = argparse.ArgumentParser(description="创建 LightRAG Milvus 数据库")
    parser.add_argument("--host", default="localhost", help="Milvus 主机地址")
    parser.add_argument("--port", type=int, default=19530, help="Milvus 端口")
    parser.add_argument("--db-name", default="lightrag", help="数据库名称")
    parser.add_argument("--timeout", type=int, default=60, help="等待服务启动超时时间")
    parser.add_argument("--max-retries", type=int, default=30, help="最大重试次数")
    
    args = parser.parse_args()
    
    print("🚀 LightRAG Milvus 数据库创建工具")
    print("=" * 50)
    
    # 1. 安装依赖
    if not install_pymilvus():
        sys.exit(1)
    
    # 2. 等待 Milvus 服务
    if not wait_for_milvus(args.host, args.port, args.timeout):
        sys.exit(1)
    
    # 3. 创建数据库
    if not create_database(args.host, args.port, args.db_name, args.max_retries):
        sys.exit(1)
    
    print("=" * 50)
    print("🎉 数据库创建完成！")
    print(f"📊 数据库名称: {args.db_name}")
    print(f"🔗 连接地址: http://{args.host}:{args.port}")

if __name__ == "__main__":
    main()
