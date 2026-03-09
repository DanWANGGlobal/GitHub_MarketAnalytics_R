#!/usr/bin/env python3
"""
Nutstore WebDAV Sync Script - 坚果云专用终极版
解决409 Conflict：串行上传、延迟重试、兼容模式
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

def get_webdav_client():
    """初始化WebDAV客户端 - 坚果云专用配置"""
    try:
        from webdav4.client import Client
        
        user = os.environ.get('NUTSTORE_USER')
        password = os.environ.get('NUTSTORE_PASSWORD')
        
        if not user or not password:
            logger.error("NUTSTORE_USER or NUTSTORE_PASSWORD not set!")
            return None
        
        # 坚果云WebDAV地址（固定）
        webdav_url = 'https://dav.jianguoyun.com/dav/'
        
        logger.info(f"Connecting to Nutstore as: {user}")
        logger.info(f"URL: {webdav_url}")
        
        # 创建客户端 - 使用保守配置
        client = Client(
            base_url=webdav_url,
            auth=(user, password),
            timeout=60  # 增加超时
        )
        
        # 简单连接测试
        try:
            # 尝试读取根目录
            root_items = client.ls('/')
            logger.info(f"Connected! Root has {len(root_items)} items")
            return client
        except Exception as e:
            logger.error(f"Connection test failed: {e}")
            return None
            
    except ImportError:
        logger.error("Installing webdav4...")
        os.system("pip install webdav4==0.10.0")  # 固定版本
        return get_webdav_client()

def safe_mkdir(client, path, max_retries=5):
    """安全创建目录，带重试"""
    for attempt in range(max_retries):
        try:
            client.mkdir(path)
            logger.info(f"Created directory: {path}")
            return True
        except Exception as e:
            error_str = str(e).lower()
            # 已存在不算错误
            if any(x in error_str for x in ['409', 'conflict', 'already exists', 'method not allowed']):
                logger.info(f"Directory exists: {path}")
                return True
            # 父目录不存在，尝试创建父目录
            elif 'parent' in error_str or '404' in error_str:
                if '/' in path.strip('/'):
                    parent = '/'.join(path.strip('/').split('/')[:-1])
                    if parent:
                        logger.info(f"Creating parent first: {parent}")
                        safe_mkdir(client, parent, max_retries)
                        time.sleep(1)
                        continue
            # 其他错误，等待重试
            logger.warning(f"Create dir attempt {attempt+1} failed: {e}")
            time.sleep(2 ** attempt)  # 指数退避
    
    logger.error(f"Failed to create directory: {path}")
    return False

def safe_upload(client, local_path, remote_path, max_retries=5):
    """安全上传文件，坚果云专用"""
    file_name = Path(local_path).name
    
    for attempt in range(max_retries):
        try:
            # 上传前等待，避免请求过快
            if attempt > 0:
                wait_time = 2 ** attempt  # 2, 4, 8, 16, 32秒
                logger.info(f"Waiting {wait_time}s before retry {attempt}...")
                time.sleep(wait_time)
            
            logger.info(f"Uploading: {file_name} (attempt {attempt+1})")
            
            # 先检查远程文件是否存在
            try:
                client.info(remote_path)
                logger.info(f"File exists, overwriting: {file_name}")
            except:
                pass
            
            # 执行上传
            client.upload_file(local_path, remote_path, overwrite=True)
            logger.info(f"✓ Success: {file_name}")
            
            # 上传成功后等待，避免下一个请求太快
            time.sleep(1)
            return True
            
        except Exception as e:
            error_str = str(e).lower()
            logger.warning(f"Upload error: {e}")
            
            # 409错误特别处理
            if '409' in error_str or 'conflict' in error_str:
                logger.info(f"Got 409, will retry with backoff...")
                continue
            # 其他错误也重试
            elif attempt < max_retries - 1:
                continue
    
    logger.error(f"✗ Failed after {max_retries} attempts: {file_name}")
    return False

def sync_to_nutstore():
    """主同步函数 - 坚果云终极版"""
    
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    remote_folder = os.environ.get('NUTSTORE_REMOTE_PATH', 'GitHub_MarketAnalytics_R_Output')
    today = datetime.now().strftime('%Y-%m-%d')
    
    logger.info("=" * 70)
    logger.info("Nutstore Sync - Ultimate Edition")
    logger.info(f"Local: {output_dir}")
    logger.info(f"Target: /{remote_folder}/{today}/")
    logger.info("=" * 70)
    
    if not output_dir.exists():
        logger.error(f"Output directory not found!")
        return False
    
    # 连接
    client = get_webdav_client()
    if not client:
        return False
    
    # 创建目录结构
    target_path = f"/{remote_folder}/{today}".replace('//', '/')
    charts_path = f"{target_path}/charts"
    data_path = f"{target_path}/dataAnalysis"
    
    logger.info("Creating directories...")
    safe_mkdir(client, target_path)
    safe_mkdir(client, charts_path)
    safe_mkdir(client, data_path)
    
    # 收集所有要上传的文件
    files_to_upload = []
    
    # 主文件
    for f in output_dir.glob('*'):
        if f.is_file() and not f.name.startswith('.'):
            files_to_upload.append((f, target_path))
    
    # dataAnalysis
    data_dir = output_dir / 'dataAnalysis'
    if data_dir.exists():
        for f in data_dir.glob('*.xlsx'):
            files_to_upload.append((f, data_path))
    
    # charts
    chart_dir = output_dir / 'charting'
    if chart_dir.exists():
        for ext in ['*.png', '*.pdf']:
            for f in chart_dir.glob(ext):
                files_to_upload.append((f, charts_path))
    
    total = len(files_to_upload)
    logger.info(f"Total files to upload: {total}")
    logger.info("=" * 70)
    
    # 串行上传（一个一个来，避免触发限制）
    success_count = 0
    fail_count = 0
    
    for i, (local_file, remote_dir) in enumerate(files_to_upload, 1):
        remote_file = f"{remote_dir}/{local_file.name}"
        
        logger.info(f"[{i}/{total}] Processing: {local_file.name}")
        
        if safe_upload(client, str(local_file), remote_file):
            success_count += 1
        else:
            fail_count += 1
        
        # 每10个文件额外休息，避免触发限流
        if i % 10 == 0:
            logger.info(f"Progress: {i}/{total}, resting 3s...")
            time.sleep(3)
    
    logger.info("=" * 70)
    logger.info(f"Sync Complete: {success_count} success, {fail_count} failed")
    if fail_count == 0:
        logger.info("🎉 All files uploaded successfully!")
    else:
        logger.warning(f"⚠️ {fail_count} files failed to upload")
    logger.info("=" * 70)
    
    return fail_count == 0

if __name__ == '__main__':
    try:
        success = sync_to_nutstore()
        sys.exit(0 if success else 1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
