#!/usr/bin/env python3
"""
Nutstore WebDAV Sync - 手动预创建根目录版
假设 GitHub_MarketAnalytics_R_Output 已手动创建在坚果云根目录
"""

import os
import sys
import time
import requests
from pathlib import Path
from datetime import datetime
import urllib.parse
import logging

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

class NutstoreClient:
    def __init__(self, user, pwd):
        self.auth = (user, pwd)
        self.base = "https://dav.jianguoyun.com/dav"
        self.s = requests.Session()
        self.s.headers.update({
            'User-Agent': 'Mozilla/5.0',
            'Accept': '*/*'
        })
    
    def url(self, path):
        # 确保路径以/开头
        if not path.startswith('/'):
            path = '/' + path
        encoded = urllib.parse.quote(path.encode('utf-8'))
        return f"{self.base}{encoded}"
    
    def mkdir(self, path):
        """创建目录 - 跳过409错误"""
        try:
            r = self.s.request('MKCOL', self.url(path), 
                              auth=self.auth, timeout=30)
            # 201=创建成功, 200=OK, 405=已存在, 409=父目录问题(这里不管)
            if r.status_code in [201, 200, 405]:
                return True
            # 409可能是已存在，也可能是父目录不存在
            # 因为根目录已手动创建，这里应该是子目录问题
            logger.warning(f"MKCOL {path}: {r.status_code}, continuing...")
            return True  # 继续执行，不中断
        except Exception as e:
            logger.error(f"mkdir error: {e}")
            return False
    
    def upload(self, local, remote):
        """上传文件"""
        try:
            with open(local, 'rb') as f:
                data = f.read()
            
            r = self.s.request('PUT', self.url(remote), 
                              data=data, auth=self.auth, timeout=60)
            
            if r.status_code in [201, 200, 204]:
                return True
            
            logger.warning(f"PUT {remote}: {r.status_code}")
            return False
        except Exception as e:
            logger.error(f"upload error: {e}")
            return False

def main():
    work = os.environ.get('WORK_DIR', os.getcwd())
    output = Path(work) / 'output'
    
    user = os.environ.get('NUTSTORE_USER')
    pwd = os.environ.get('NUTSTORE_PASSWORD')
    # 根目录文件夹（已手动创建）
    base_folder = os.environ.get('NUTSTORE_REMOTE_PATH', 'GH_Analytics_R')
    today = datetime.now().strftime('%Y-%m-%d')
    
    if not output.exists():
        logger.error("No output directory")
        return False
    
    if not user or not pwd:
        logger.error("No credentials")
        return False
    
    logger.info(f"Sync to: /{base_folder}/{today}/")
    logger.info("Note: Assuming {base_folder} already exists in Nutstore root")
    
    client = NutstoreClient(user, pwd)
    
    # 测试连接
    try:
        r = client.s.request('PROPFIND', client.base + '/', 
                            auth=client.auth, timeout=10)
        if r.status_code not in [207, 200]:
            logger.error(f"Connection failed: {r.status_code}")
            return False
        logger.info("Connected to Nutstore")
    except Exception as e:
        logger.error(f"Connection error: {e}")
        return False
    
    # 构建路径 - 根目录已存在，只创建子目录
    date_dir = f"{base_folder}/{today}"
    charts_dir = f"{date_dir}/charts"
    data_dir = f"{date_dir}/dataAnalysis"
    
    # 创建子目录（忽略409错误）
    logger.info("Creating subdirectories...")
    client.mkdir(date_dir)
    time.sleep(1)
    client.mkdir(charts_dir)
    time.sleep(1)
    client.mkdir(data_dir)
    time.sleep(1)
    
    # 收集文件
    files = []
    for f in output.glob('*'):
        if f.is_file() and not f.name.startswith('.'):
            files.append((f, date_dir))
    
    data_path = output / 'dataAnalysis'
    if data_path.exists():
        for f in data_path.glob('*.xlsx'):
            files.append((f, data_dir))
    
    chart_path = output / 'charting'
    if chart_path.exists():
        for ext in ['*.png', '*.pdf']:
            for f in chart_path.glob(ext):
                files.append((f, charts_dir))
    
    total = len(files)
    logger.info(f"Files: {total}")
    
    # 上传
    ok = fail = 0
    for i, (local, remote_dir) in enumerate(files, 1):
        remote = f"{remote_dir}/{local.name}"
        logger.info(f"[{i}/{total}] {local.name}")
        
        success = False
        for attempt in range(3):
            if attempt > 0:
                time.sleep(2)
            if client.upload(str(local), remote):
                success = True
                break
        
        if success:
            ok += 1
            time.sleep(0.5)
        else:
            fail += 1
            logger.error(f"Failed: {local.name}")
    
    logger.info(f"Done: {ok} OK, {fail} Fail")
    return fail == 0

if __name__ == '__main__':
    try:
        sys.exit(0 if main() else 1)
    except Exception as e:
        logger.error(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
