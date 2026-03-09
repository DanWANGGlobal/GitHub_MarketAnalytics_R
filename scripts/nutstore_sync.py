#!/usr/bin/env python3
"""
Nutstore WebDAV Sync - 保守稳定版
解决400 Bad Request：严格路径格式、最小化操作
"""

import os
import sys
import time
from pathlib import Path
from datetime import datetime
import logging

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

def get_client():
    """连接坚果云"""
    try:
        from webdav4.client import Client
        
        user = os.environ.get('NUTSTORE_USER')
        password = os.environ.get('NUTSTORE_PASSWORD')
        
        if not user or not password:
            logger.error("Missing credentials")
            return None
        
        client = Client(
            base_url='https://dav.jianguoyun.com/dav/',
            auth=(user, password)
        )
        
        # 简单测试
        try:
            client.ls('/')
            logger.info("Connected to Nutstore")
            return client
        except Exception as e:
            logger.error(f"Connection failed: {e}")
            return None
            
    except ImportError:
        os.system("pip install webdav4")
        return get_client()

def ensure_dir(client, path):
    """确保目录存在"""
    try:
        client.mkdir(path)
        logger.info(f"Created: {path}")
        return True
    except Exception as e:
        if '409' in str(e) or 'exists' in str(e).lower():
            return True  # 已存在不算错误
        logger.warning(f"Create dir warning: {e}")
        return False

def upload_one(client, local, remote):
    """上传单个文件"""
    name = Path(local).name
    for i in range(3):
        try:
            if i > 0:
                time.sleep(3)
            client.upload_file(local, remote, overwrite=True)
            logger.info(f"✓ {name}")
            time.sleep(0.5)  # 间隔
            return True
        except Exception as e:
            logger.warning(f"Retry {i+1} for {name}: {e}")
    logger.error(f"✗ Failed: {name}")
    return False

def main():
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    if not output_dir.exists():
        logger.error(f"No output dir: {output_dir}")
        return False
    
    folder = os.environ.get('NUTSTORE_REMOTE_PATH', 'GitHub_MarketAnalytics_R_Output')
    today = datetime.now().strftime('%Y-%m-%d')
    
    logger.info(f"Target: /{folder}/{today}/")
    
    client = get_client()
    if not client:
        return False
    
    # 创建目录（简单路径）
    base_path = f"/{folder}".replace('//', '/')
    date_path = f"{base_path}/{today}".replace('//', '/')
    
    logger.info("Creating directories...")
    ensure_dir(client, base_path)
    ensure_dir(client, date_path)
    
    # 收集文件
    files = []
    for f in output_dir.rglob('*'):
        if f.is_file() and not f.name.startswith('.'):
            rel = f.relative_to(output_dir)
            remote = f"{date_path}/{rel}".replace('//', '/')
            files.append((f, remote))
    
    logger.info(f"Files: {len(files)}")
    
    # 上传
    ok = 0
    fail = 0
    for local, remote in files:
        if upload_one(client, str(local), remote):
            ok += 1
        else:
            fail += 1
    
    logger.info(f"Done: {ok} OK, {fail} Fail")
    return fail == 0

if __name__ == '__main__':
    try:
        sys.exit(0 if main() else 1)
    except Exception as e:
        logger.error(f"Error: {e}")
        sys.exit(1)
