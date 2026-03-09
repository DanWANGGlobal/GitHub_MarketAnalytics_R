#!/usr/bin/env python3
"""
Nutstore WebDAV Sync - 坚果云原生兼容版
使用最保守的方式，兼容坚果云的特殊实现
"""

import os
import sys
import time
import requests
from pathlib import Path
from datetime import datetime
import logging

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

class NutstoreClient:
    """坚果云专用客户端"""
    
    def __init__(self, user, password):
        self.user = user
        self.password = password
        self.base_url = 'https://dav.jianguoyun.com/dav'
        self.session = requests.Session()
        self.session.auth = (user, password)
        self.session.headers.update({
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        })
    
    def _request(self, method, path, **kwargs):
        """发送请求"""
        # 确保路径格式正确: /path/to/file
        if not path.startswith('/'):
            path = '/' + path
        
        url = f"{self.base_url}{path}"
        
        try:
            response = self.session.request(method, url, timeout=30, **kwargs)
            return response
        except Exception as e:
            logger.error(f"Request failed: {e}")
            raise
    
    def exists(self, path):
        """检查路径是否存在"""
        try:
            response = self._request('PROPFIND', path)
            return response.status_code in [200, 207]
        except:
            return False
    
    def mkdir(self, path):
        """创建目录"""
        try:
            response = self._request('MKCOL', path)
            if response.status_code in [201, 200]:
                logger.info(f"Created dir: {path}")
                return True
            elif response.status_code == 405 or response.status_code == 409:
                # 已存在
                logger.info(f"Dir exists: {path}")
                return True
            else:
                logger.warning(f"MKCOL {path}: {response.status_code}")
                return False
        except Exception as e:
            logger.error(f"mkdir error: {e}")
            return False
    
    def upload(self, local_path, remote_path):
        """上传文件"""
        try:
            with open(local_path, 'rb') as f:
                data = f.read()
            
            response = self._request('PUT', remote_path, data=data)
            
            if response.status_code in [201, 200, 204]:
                return True
            else:
                logger.warning(f"Upload {remote_path}: HTTP {response.status_code}")
                return False
        except Exception as e:
            logger.error(f"Upload error: {e}")
            return False

def sync():
    """主同步函数"""
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    if not output_dir.exists():
        logger.error(f"Output directory not found: {output_dir}")
        return False
    
    user = os.environ.get('NUTSTORE_USER')
    password = os.environ.get('NUTSTORE_PASSWORD')
    folder = os.environ.get('NUTSTORE_REMOTE_PATH', 'GitHub_MarketAnalytics_R_Output')
    today = datetime.now().strftime('%Y-%m-%d')
    
    if not user or not password:
        logger.error("Missing credentials")
        return False
    
    logger.info(f"Connecting to Nutstore as: {user}")
    client = NutstoreClient(user, password)
    
    # 测试连接
    if not client.exists('/'):
        logger.error("Connection test failed")
        return False
    
    logger.info("Connected!")
    
    # 创建目录
    base_dir = f"/{folder}"
    date_dir = f"{base_dir}/{today}"
    charts_dir = f"{date_dir}/charts"
    data_dir = f"{date_dir}/dataAnalysis"
    
    logger.info(f"Target: {date_dir}")
    
    # 逐级创建
    client.mkdir(base_dir)
    time.sleep(1)
    client.mkdir(date_dir)
    time.sleep(1)
    client.mkdir(charts_dir)
    time.sleep(1)
    client.mkdir(data_dir)
    time.sleep(1)
    
    # 收集文件
    files = []
    
    # 根目录文件
    for f in output_dir.glob('*'):
        if f.is_file() and not f.name.startswith('.'):
            files.append((f, date_dir))
    
    # dataAnalysis
    data_path = output_dir / 'dataAnalysis'
    if data_path.exists():
        for f in data_path.glob('*.xlsx'):
            files.append((f, data_dir))
    
    # charts
    charts_path = output_dir / 'charting'
    if charts_path.exists():
        for ext in ['*.png', '*.pdf']:
            for f in charts_path.glob(ext):
                files.append((f, charts_dir))
    
    total = len(files)
    logger.info(f"Files to upload: {total}")
    
    # 上传
    ok = 0
    fail = 0
    
    for i, (local, remote_dir) in enumerate(files, 1):
        remote = f"{remote_dir}/{local.name}"
        name = local.name
        
        logger.info(f"[{i}/{total}] {name}")
        
        # 重试3次
        success = False
        for attempt in range(3):
            if attempt > 0:
                time.sleep(2)
            if client.upload(str(local), remote):
                success = True
                break
        
        if success:
            ok += 1
            time.sleep(0.5)  # 间隔
        else:
            fail += 1
            logger.error(f"Failed: {name}")
    
    logger.info(f"Done: {ok} success, {fail} failed")
    return fail == 0

if __name__ == '__main__':
    try:
        sys.exit(0 if sync() else 1)
    except Exception as e:
        logger.error(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
