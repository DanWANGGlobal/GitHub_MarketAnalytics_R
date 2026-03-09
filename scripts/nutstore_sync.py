#!/usr/bin/env python3
"""
Nutstore WebDAV Sync - 坚果云深度适配版
针对坚果云的400/409问题进行深度修复
"""

import os
import sys
import time
import requests
from pathlib import Path
from datetime import datetime
import xml.etree.ElementTree as ET
import logging

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

class NutstoreWebDAV:
    """专为坚果云优化的WebDAV客户端"""
    
    def __init__(self, username, password):
        self.username = username
        self.password = password
        self.base_url = "https://dav.jianguoyun.com/dav"
        self.session = requests.Session()
        self.session.auth = (username, password)
        # 坚果云要求的headers
        self.session.headers.update({
            'User-Agent': 'Jianguoyun-WebDAV-Client/1.0',
            'Accept': '*/*',
            'Connection': 'keep-alive'
        })
    
    def _url(self, path):
        """构建URL - 坚果云路径格式：/dav/路径"""
        # 确保路径以/开头
        if not path.startswith('/'):
            path = '/' + path
        return f"{self.base_url}{path}"
    
    def _check_response(self, response, expected=None):
        """检查响应"""
        if expected and response.status_code in expected:
            return True
        if response.status_code < 400:
            return True
        return False
    
    def exists(self, path):
        """检查路径是否存在"""
        try:
            resp = self.session.request('PROPFIND', self._url(path), 
                                       headers={'Depth': '0'}, timeout=10)
            return resp.status_code == 207  # Multi-Status 表示存在
        except Exception as e:
            logger.debug(f"exists check failed for {path}: {e}")
            return False
    
    def mkdir(self, path):
        """创建目录 - 坚果云专用"""
        try:
            # 检查是否已存在
            if self.exists(path):
                logger.debug(f"Directory exists: {path}")
                return True
            
            # 创建目录
            resp = self.session.request('MKCOL', self._url(path), timeout=30)
            
            # 201 Created = 成功创建
            # 200 OK = 已存在（某些服务器）
            # 405 Method Not Allowed = 已存在
            # 409 Conflict = 父目录不存在
            if resp.status_code in [201, 200]:
                logger.info(f"Created directory: {path}")
                return True
            elif resp.status_code in [405, 409]:
                # 可能是已存在，再检查一次
                if self.exists(path):
                    return True
                # 409可能是父目录不存在
                if resp.status_code == 409:
                    logger.warning(f"409 for {path}, parent may not exist")
                    # 尝试创建父目录
                    parent = '/'.join(path.rstrip('/').split('/')[:-1])
                    if parent and parent != '/':
                        logger.info(f"Trying to create parent: {parent}")
                        if self.mkdir(parent):
                            time.sleep(1)
                            # 重试创建当前目录
                            return self.mkdir(path)
                return False
            else:
                logger.warning(f"MKCOL {path} returned {resp.status_code}")
                return False
                
        except Exception as e:
            logger.error(f"mkdir error for {path}: {e}")
            return False
    
    def upload(self, local_path, remote_path):
        """上传文件 - 坚果云专用"""
        try:
            # 读取文件
            with open(local_path, 'rb') as f:
                data = f.read()
            
            # PUT上传
            resp = self.session.request('PUT', self._url(remote_path), 
                                       data=data, timeout=60)
            
            # 201 Created = 成功
            # 200 OK = 覆盖成功
            # 204 No Content = 成功
            if resp.status_code in [201, 200, 204]:
                return True
            elif resp.status_code == 409:
                # 目录不存在，尝试创建
                parent = '/'.join(remote_path.rstrip('/').split('/')[:-1])
                if parent and self.mkdir(parent):
                    time.sleep(1)
                    # 重试上传
                    return self.upload(local_path, remote_path)
                return False
            else:
                logger.warning(f"Upload {remote_path}: HTTP {resp.status_code}")
                return False
                
        except Exception as e:
            logger.error(f"Upload error: {e}")
            return False

def sync_to_nutstore():
    """同步到坚果云"""
    
    # 配置
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    username = os.environ.get('NUTSTORE_USER')
    password = os.environ.get('NUTSTORE_PASSWORD')
    remote_folder = os.environ.get('NUTSTORE_REMOTE_PATH', 'GitHub_MarketAnalytics_R_Output')
    today = datetime.now().strftime('%Y-%m-%d')
    
    # 检查
    if not output_dir.exists():
        logger.error(f"Output directory not found: {output_dir}")
        return False
    
    if not username or not password:
        logger.error("Missing NUTSTORE_USER or NUTSTORE_PASSWORD")
        return False
    
    logger.info("=" * 60)
    logger.info(f"Nutstore Sync - Deep Fix Edition")
    logger.info(f"User: {username}")
    logger.info(f"Target: /{remote_folder}/{today}/")
    logger.info("=" * 60)
    
    # 连接
    client = NutstoreWebDAV(username, password)
    
    # 测试连接
    try:
        test = client.session.request('PROPFIND', client.base_url + '/', 
                                     headers={'Depth': '0'}, timeout=10)
        if test.status_code not in [207, 200]:
            logger.error(f"Connection test failed: {test.status_code}")
            return False
        logger.info("Connection OK")
    except Exception as e:
        logger.error(f"Connection test error: {e}")
        return False
    
    # 创建目录 - 使用更保守的方式
    # 坚果云根目录是 /，我们直接在根下创建
    base_path = remote_folder  # 不带前导斜杠
    date_path = f"{base_path}/{today}"
    charts_path = f"{date_path}/charts"
    data_path = f"{date_path}/dataAnalysis"
    
    logger.info("Creating directories...")
    
    # 逐级创建，每步后等待
    if not client.mkdir(base_path):
        logger.warning(f"Failed to create base: {base_path}, continuing...")
    time.sleep(1)
    
    if not client.mkdir(date_path):
        logger.warning(f"Failed to create date dir: {date_path}, continuing...")
    time.sleep(1)
    
    if not client.mkdir(charts_path):
        logger.warning(f"Failed to create charts dir: {charts_path}, continuing...")
    time.sleep(1)
    
    if not client.mkdir(data_path):
        logger.warning(f"Failed to create data dir: {data_path}, continuing...")
    time.sleep(1)
    
    # 收集文件
    files_to_upload = []
    
    # 主目录文件
    for f in output_dir.glob('*'):
        if f.is_file() and not f.name.startswith('.'):
            files_to_upload.append((f, date_path))
    
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
    logger.info(f"Files to upload: {total}")
    logger.info("=" * 60)
    
    # 上传
    success_count = 0
    fail_count = 0
    
    for i, (local_file, remote_dir) in enumerate(files_to_upload, 1):
        remote_file = f"{remote_dir}/{local_file.name}"
        name = local_file.name
        
        logger.info(f"[{i}/{total}] {name}")
        
        # 重试上传
        uploaded = False
        for attempt in range(3):
            if attempt > 0:
                logger.info(f"  Retry {attempt}...")
                time.sleep(2)
            
            if client.upload(str(local_file), remote_file):
                uploaded = True
                break
        
        if uploaded:
            success_count += 1
            logger.info(f"  ✓ Success")
            time.sleep(0.5)  # 上传间隔
        else:
            fail_count += 1
            logger.error(f"  ✗ Failed after 3 attempts")
    
    logger.info("=" * 60)
    logger.info(f"Summary: {success_count} success, {fail_count} failed")
    logger.info("=" * 60)
    
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
