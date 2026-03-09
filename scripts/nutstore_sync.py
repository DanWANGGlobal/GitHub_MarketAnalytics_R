#!/usr/bin/env python3
"""
Nutstore WebDAV Sync Script - 终极修复版
彻底解决409 Conflict和父目录问题
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
    """初始化WebDAV客户端"""
    try:
        from webdav4.client import Client
        
        user = os.environ.get('NUTSTORE_USER')
        password = os.environ.get('NUTSTORE_PASSWORD')
        webdav_url = os.environ.get('NUTSTORE_WEBDAV_URL', 'https://dav.jianguoyun.com/dav/')
        
        if not user or not password:
            logger.error("NUTSTORE_USER or NUTSTORE_PASSWORD not set!")
            return None
        
        logger.info(f"Connecting to WebDAV as user: {user}")
        
        if not webdav_url.endswith('/'):
            webdav_url += '/'
        
        client = Client(
            base_url=webdav_url,
            auth=(user, password),
            timeout=30
        )
        
        # 测试连接
        for attempt in range(3):
            try:
                root_info = client.info('/')
                if root_info:
                    logger.info("Successfully connected to Nutstore WebDAV")
                    return client
            except Exception as e:
                logger.warning(f"Connection attempt {attempt + 1} failed: {e}")
                if attempt < 2:
                    time.sleep(2)
        
        logger.error("Failed to connect to WebDAV after 3 attempts")
        return None
        
    except ImportError:
        logger.error("webdav4 not installed. Installing...")
        os.system("pip install webdav4")
        return get_webdav_client()

def ensure_directory_exists(client, path):
    """
    确保目录存在，逐级创建
    路径格式: /R-Analysis-Output/2026-03-09/
    """
    # 去除首尾斜杠，分割路径
    path = path.strip('/')
    if not path:
        return '/'
    
    parts = path.split('/')
    current_path = ''
    
    for part in parts:
        if not part:
            continue
        
        current_path = f"{current_path}/{part}".replace('//', '/')
        
        try:
            # 检查是否存在
            try:
                info = client.info(current_path)
                if info:
                    logger.info(f"Directory exists: {current_path}")
                    continue
            except Exception:
                pass  # 不存在，需要创建
            
            # 创建目录
            logger.info(f"Creating directory: {current_path}")
            try:
                client.mkdir(current_path)
                logger.info(f"Created: {current_path}")
            except Exception as e:
                error_str = str(e).lower()
                # 409或已存在是正常情况
                if any(x in error_str for x in ['409', 'conflict', 'already exists', 'method not allowed']):
                    logger.info(f"Directory already exists: {current_path}")
                else:
                    logger.warning(f"Create warning for {current_path}: {e}")
                    # 再检查一次是否真的存在
                    try:
                        client.info(current_path)
                        logger.info(f"Directory exists after check: {current_path}")
                    except:
                        raise e
                        
        except Exception as e:
            logger.error(f"Failed to ensure directory {current_path}: {e}")
            raise
    
    return f"/{path}".replace('//', '/')

def upload_file_with_retry(client, local_path, remote_path, max_retries=3):
    """上传文件，带重试"""
    for attempt in range(max_retries):
        try:
            logger.info(f"Uploading: {Path(local_path).name} -> {remote_path}")
            
            # 检查远程是否已存在
            try:
                existing = client.info(remote_path)
                if existing:
                    logger.info(f"File exists, overwriting: {remote_path}")
            except:
                pass
            
            # 上传（覆盖模式）
            client.upload_file(local_path, remote_path, overwrite=True)
            logger.info(f"Success: {Path(local_path).name}")
            return True
            
        except Exception as e:
            error_str = str(e).lower()
            if '409' in error_str or 'conflict' in error_str:
                logger.warning(f"409 Conflict on attempt {attempt + 1}, retrying...")
                time.sleep(2)
                continue
            else:
                logger.error(f"Upload error: {e}")
                if attempt < max_retries - 1:
                    time.sleep(2)
    
    logger.error(f"Failed after {max_retries} attempts: {Path(local_path).name}")
    return False

def sync_to_nutstore():
    """主同步函数"""
    
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    # 远程路径配置
    remote_base = os.environ.get('NUTSTORE_REMOTE_PATH', 'R-Analysis-Output').strip('/')
    today = datetime.now().strftime('%Y-%m-%d')
    
    logger.info("=" * 60)
    logger.info("Nutstore WebDAV Sync - Ultimate Fix")
    logger.info(f"Local: {output_dir}")
    logger.info(f"Remote: /{remote_base}/{today}/")
    logger.info("=" * 60)
    
    if not output_dir.exists():
        logger.error(f"Output directory not found: {output_dir}")
        return False
    
    # 初始化客户端
    client = get_webdav_client()
    if not client:
        logger.error("Failed to initialize WebDAV client")
        return False
    
    # 创建目录结构
    try:
        remote_path = ensure_directory_exists(client, f"{remote_base}/{today}")
        logger.info(f"Target path ready: {remote_path}")
    except Exception as e:
        logger.error(f"Failed to create directory structure: {e}")
        return False
    
    files_uploaded = 0
    files_failed = 0
    
    # 上传主文件
    logger.info("Uploading main files...")
    for file_path in output_dir.glob('*'):
        if file_path.is_file() and not file_path.name.startswith('.'):
            remote_file = f"{remote_path}/{file_path.name}"
            if upload_file_with_retry(client, str(file_path), remote_file):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # 上传dataAnalysis
    data_analysis_dir = output_dir / 'dataAnalysis'
    if data_analysis_dir.exists():
        logger.info("Uploading dataAnalysis files...")
        try:
            data_remote = ensure_directory_exists(client, f"{remote_base}/{today}/dataAnalysis")
            for file_path in data_analysis_dir.glob('*.xlsx'):
                remote_file = f"{data_remote}/{file_path.name}"
                if upload_file_with_retry(client, str(file_path), remote_file):
                    files_uploaded += 1
                else:
                    files_failed += 1
        except Exception as e:
            logger.error(f"dataAnalysis upload failed: {e}")
    
    # 上传charts
    charting_dir = output_dir / 'charting'
    if charting_dir.exists():
        logger.info("Uploading chart files...")
        try:
            charts_remote = ensure_directory_exists(client, f"{remote_base}/{today}/charts")
            for ext in ['*.png', '*.pdf']:
                for file_path in charting_dir.glob(ext):
                    remote_file = f"{charts_remote}/{file_path.name}"
                    if upload_file_with_retry(client, str(file_path), remote_file):
                        files_uploaded += 1
                    else:
                        files_failed += 1
        except Exception as e:
            logger.error(f"charting upload failed: {e}")
    
    logger.info("=" * 60)
    logger.info(f"Sync complete: {files_uploaded} uploaded, {files_failed} failed")
    logger.info("=" * 60)
    
    return files_failed == 0

if __name__ == '__main__':
    try:
        success = sync_to_nutstore()
        sys.exit(0 if success else 1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
