#!/usr/bin/env python3
"""
Nutstore WebDAV Sync Script - 修复版
处理401认证错误和连接问题
"""

import os
import sys
import time
from pathlib import Path
from datetime import datetime
import logging

# 设置日志
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
            logger.error("Please check GitHub Secrets configuration.")
            return None
        
        logger.info(f"Connecting to WebDAV as user: {user}")
        
        client = Client(
            base_url=webdav_url,
            auth=(user, password)
        )
        
        # 测试连接（带重试）
        for attempt in range(3):
            try:
                if client.exists('/'):
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

def ensure_remote_directory(client, remote_path):
    """创建远程目录（如果不存在，或已存在则忽略）"""
    try:
        if client.exists(remote_path):
            logger.info(f"Remote directory already exists: {remote_path}")
            return True
        client.mkdir(remote_path)
        logger.info(f"Created remote directory: {remote_path}")
        return True
    except Exception as e:
        if "409" in str(e) or "Conflict" in str(e):
            # 目录已存在，这是正常的
            logger.info(f"Directory already exists (409): {remote_path}")
            return True
        logger.error(f"Failed to create directory {remote_path}: {e}")
        return False

def upload_file(client, local_path, remote_path, max_retries=3):
    """上传文件（带重试）"""
    for attempt in range(max_retries):
        try:
            client.upload_file(local_path, remote_path)
            logger.info(f"Uploaded: {local_path.name}")
            return True
        except Exception as e:
            logger.warning(f"Upload attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(2)
    
    logger.error(f"Failed to upload {local_path} after {max_retries} attempts")
    return False

def sync_to_nutstore():
    """主同步函数"""
    
    # 配置
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    remote_base = os.environ.get('NUTSTORE_REMOTE_PATH', '/R-Analysis-Output/')
    
    # 添加日期子目录
    today = datetime.now().strftime('%Y-%m-%d')
    remote_path = f"{remote_base}{today}/"
    
    logger.info("=" * 60)
    logger.info("Nutstore WebDAV Sync Started")
    logger.info(f"Local: {output_dir}")
    logger.info(f"Remote: {remote_path}")
    logger.info("=" * 60)
    
    # 检查本地目录
    if not output_dir.exists():
        logger.error(f"Output directory not found: {output_dir}")
        # 不返回错误，让workflow继续
        logger.info("No output files to sync. Skipping.")
        return True
    
    # 初始化客户端
    client = get_webdav_client()
    if not client:
        logger.error("Failed to initialize WebDAV client!")
        logger.error("Possible causes:")
        logger.error("1. Wrong username/password in Secrets")
        logger.error("2. Nutstore account expired or locked")
        logger.error("3. Network connectivity issues")
        # 不返回错误，让workflow继续（只是没有同步）
        logger.info("Continuing without sync...")
        return True
    
    # 确保远程目录存在
    if not ensure_remote_directory(client, remote_path):
        logger.error("Failed to create remote directory!")
        return True  # 继续workflow
    
    # 上传文件
    files_uploaded = 0
    files_failed = 0
    
    # 上传主输出文件
    for file_path in output_dir.glob('*'):
        if file_path.is_file():
            remote_file = f"{remote_path}{file_path.name}"
            if upload_file(client, file_path, remote_file):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # 上传dataAnalysis文件
    data_analysis_dir = output_dir / 'dataAnalysis'
    if data_analysis_dir.exists():
        remote_data_dir = f"{remote_path}dataAnalysis/"
        ensure_remote_directory(client, remote_data_dir)
        
        for file_path in data_analysis_dir.glob('*.xlsx'):
            remote_file = f"{remote_data_dir}{file_path.name}"
            if upload_file(client, file_path, remote_file):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # 上传charting文件
    charting_dir = output_dir / 'charting' / '0html_ChartsPac'
    if charting_dir.exists():
        remote_chart_dir = f"{remote_path}charts/"
        ensure_remote_directory(client, remote_chart_dir)
        
        for file_path in charting_dir.glob('*.html'):
            remote_file = f"{remote_chart_dir}{file_path.name}"
            if upload_file(client, file_path, remote_file):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # 摘要
    logger.info("=" * 60)
    logger.info(f"Sync Summary:")
    logger.info(f"  Files Uploaded: {files_uploaded}")
    logger.info(f"  Files Failed: {files_failed}")
    logger.info("=" * 60)
    
    # 即使有失败也返回成功，让workflow继续
    return True

if __name__ == '__main__':
    try:
        success = sync_to_nutstore()
        sys.exit(0 if success else 0)  # 总是返回0，不阻塞workflow
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(0)  # 不阻塞workflow
