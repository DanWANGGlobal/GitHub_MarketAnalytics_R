#!/usr/bin/env python3
"""
Nutstore WebDAV Sync Script - 终极稳定版
修复404/400错误，简化路径处理
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
        logger.info(f"WebDAV URL: {webdav_url}")
        
        client = Client(
            base_url=webdav_url,
            auth=(user, password),
            timeout=30
        )
        
        # 测试连接
        try:
            client.ls('/')
            logger.info("Successfully connected to Nutstore WebDAV")
            return client
        except Exception as e:
            logger.error(f"Connection test failed: {e}")
            return None
        
    except ImportError:
        logger.error("webdav4 not installed. Installing...")
        os.system("pip install webdav4")
        return get_webdav_client()

def sync_to_nutstore():
    """主同步函数 - 简化版"""
    
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    # 从环境变量读取，如果没有则用默认值
    remote_folder = os.environ.get('NUTSTORE_REMOTE_PATH', 'GitHub_MarketAnalytics_R_Output')
    today = datetime.now().strftime('%Y-%m-%d')
    
    logger.info("=" * 60)
    logger.info("Nutstore WebDAV Sync")
    logger.info(f"Local: {output_dir}")
    logger.info(f"Remote folder: {remote_folder}")
    logger.info(f"Date: {today}")
    logger.info("=" * 60)
    
    if not output_dir.exists():
        logger.error(f"Output directory not found: {output_dir}")
        return False
    
    client = get_webdav_client()
    if not client:
        return False
    
    files_uploaded = 0
    files_failed = 0
    
    # 创建目标路径（直接使用，不逐级创建）
    target_path = f"{remote_folder}/{today}"
    logger.info(f"Target path: {target_path}")
    
    # 尝试创建目标目录（如果不存在）
    try:
        # 先尝试创建父目录
        try:
            client.mkdir(remote_folder)
            logger.info(f"Created folder: {remote_folder}")
        except Exception as e:
            if "409" in str(e) or "already exists" in str(e).lower():
                logger.info(f"Folder exists: {remote_folder}")
            else:
                logger.warning(f"Create folder warning: {e}")
        
        # 创建日期子目录
        try:
            client.mkdir(target_path)
            logger.info(f"Created folder: {target_path}")
        except Exception as e:
            if "409" in str(e) or "already exists" in str(e).lower():
                logger.info(f"Folder exists: {target_path}")
            else:
                logger.warning(f"Create subfolder warning: {e}")
    except Exception as e:
        logger.error(f"Failed to create directories: {e}")
    
    # 上传主文件
    logger.info("Uploading main files...")
    for file_path in output_dir.glob('*'):
        if file_path.is_file() and not file_path.name.startswith('.'):
            remote_file = f"{target_path}/{file_path.name}"
            for attempt in range(3):
                try:
                    logger.info(f"Uploading: {file_path.name}")
                    client.upload_file(str(file_path), remote_file, overwrite=True)
                    logger.info(f"Success: {file_path.name}")
                    files_uploaded += 1
                    break
                except Exception as e:
                    logger.warning(f"Attempt {attempt + 1} failed: {e}")
                    if attempt < 2:
                        time.sleep(2)
                    else:
                        logger.error(f"Failed: {file_path.name}")
                        files_failed += 1
    
    # 上传dataAnalysis
    data_dir = output_dir / 'dataAnalysis'
    if data_dir.exists():
        logger.info("Uploading dataAnalysis files...")
        data_target = f"{target_path}/dataAnalysis"
        try:
            client.mkdir(data_target)
        except:
            pass
        
        for file_path in data_dir.glob('*.xlsx'):
            remote_file = f"{data_target}/{file_path.name}"
            for attempt in range(3):
                try:
                    client.upload_file(str(file_path), remote_file, overwrite=True)
                    logger.info(f"Success: {file_path.name}")
                    files_uploaded += 1
                    break
                except Exception as e:
                    if attempt < 2:
                        time.sleep(2)
                    else:
                        logger.error(f"Failed: {file_path.name}")
                        files_failed += 1
    
    # 上传charts
    chart_dir = output_dir / 'charting'
    if chart_dir.exists():
        logger.info("Uploading chart files...")
        chart_target = f"{target_path}/charts"
        try:
            client.mkdir(chart_target)
        except:
            pass
        
        for ext in ['*.png', '*.pdf']:
            for file_path in chart_dir.glob(ext):
                remote_file = f"{chart_target}/{file_path.name}"
                for attempt in range(3):
                    try:
                        client.upload_file(str(file_path), remote_file, overwrite=True)
                        logger.info(f"Success: {file_path.name}")
                        files_uploaded += 1
                        break
                    except Exception as e:
                        if attempt < 2:
                            time.sleep(2)
                        else:
                            logger.error(f"Failed: {file_path.name}")
                            files_failed += 1
    
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
