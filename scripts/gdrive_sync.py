#!/usr/bin/env python3
"""
Google Drive Sync Script - 使用Service Account上传
适用于GitHub Actions自动上传分析结果到Google Drive
"""

import os
import sys
import json
import base64
from pathlib import Path
from datetime import datetime

# 设置日志
import logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

def get_drive_service():
    """初始化Google Drive服务"""
    try:
        from google.oauth2 import service_account
        from googleapiclient.discovery import build
        from googleapiclient.http import MediaFileUpload
        
        # 从环境变量获取Service Account JSON（Base64编码）
        credentials_b64 = os.environ.get('GOOGLE_CREDENTIALS_B64')
        if not credentials_b64:
            logger.error("GOOGLE_CREDENTIALS_B64 not set!")
            logger.info("Please create a Service Account and encode the JSON key with base64")
            return None
        
        # 解码凭证
        credentials_json = base64.b64decode(credentials_b64).decode('utf-8')
        credentials_info = json.loads(credentials_json)
        
        # 创建凭证
        credentials = service_account.Credentials.from_service_account_info(
            credentials_info,
            scopes=['https://www.googleapis.com/auth/drive']
        )
        
        # 构建服务
        service = build('drive', 'v3', credentials=credentials)
        logger.info("Successfully connected to Google Drive")
        return service
        
    except ImportError:
        logger.info("Installing Google API client...")
        os.system("pip install google-api-python-client google-auth-httplib2 google-auth-oauthlib")
        return get_drive_service()
    except Exception as e:
        logger.error(f"Failed to initialize Google Drive service: {e}")
        return None

def get_or_create_folder(service, folder_name, parent_id=None):
    """获取或创建文件夹"""
    try:
        # 查询文件夹是否存在
        query = f"mimeType='application/vnd.google-apps.folder' and name='{folder_name}' and trashed=false"
        if parent_id:
            query += f" and '{parent_id}' in parents"
        
        results = service.files().list(q=query, spaces='drive', fields='files(id, name)').execute()
        items = results.get('files', [])
        
        if items:
            logger.info(f"Found existing folder: {folder_name}")
            return items[0]['id']
        
        # 创建新文件夹
        metadata = {
            'name': folder_name,
            'mimeType': 'application/vnd.google-apps.folder'
        }
        if parent_id:
            metadata['parents'] = [parent_id]
        
        folder = service.files().create(body=metadata, fields='id').execute()
        logger.info(f"Created folder: {folder_name}")
        return folder['id']
        
    except Exception as e:
        logger.error(f"Failed to get/create folder {folder_name}: {e}")
        return None

def upload_file(service, local_path, folder_id, max_retries=3):
    """上传文件到Google Drive"""
    from googleapiclient.http import MediaFileUpload
    
    for attempt in range(max_retries):
        try:
            file_name = Path(local_path).name
            
            # 检查文件是否已存在
            query = f"name='{file_name}' and '{folder_id}' in parents and trashed=false"
            results = service.files().list(q=query, spaces='drive', fields='files(id)').execute()
            items = results.get('files', [])
            
            # 准备上传
            media = MediaFileUpload(local_path, resumable=True)
            
            if items:
                # 更新现有文件
                file_id = items[0]['id']
                service.files().update(
                    fileId=file_id,
                    media_body=media
                ).execute()
                logger.info(f"Updated: {file_name}")
            else:
                # 创建新文件
                metadata = {
                    'name': file_name,
                    'parents': [folder_id]
                }
                service.files().create(
                    body=metadata,
                    media_body=media
                ).execute()
                logger.info(f"Uploaded: {file_name}")
            
            return True
            
        except Exception as e:
            logger.warning(f"Upload attempt {attempt + 1} failed: {e}")
            if attempt < max_retries - 1:
                import time
                time.sleep(2)
    
    logger.error(f"Failed to upload {local_path} after {max_retries} attempts")
    return False

def sync_to_google_drive():
    """主同步函数"""
    
    # 配置
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    # 文件夹名称（带日期）
    today = datetime.now().strftime('%Y-%m-%d')
    parent_folder_name = os.environ.get('GDRIVE_FOLDER_NAME', 'R-Analysis-Output')
    
    logger.info("=" * 60)
    logger.info("Google Drive Sync Started")
    logger.info(f"Local: {output_dir}")
    logger.info("=" * 60)
    
    # 检查本地目录
    if not output_dir.exists():
        logger.error(f"Output directory not found: {output_dir}")
        return False
    
    # 初始化服务
    service = get_drive_service()
    if not service:
        logger.error("Failed to initialize Google Drive service")
        return False
    
    # 获取或创建父文件夹
    parent_folder_id = get_or_create_folder(service, parent_folder_name)
    if not parent_folder_id:
        logger.error("Failed to create parent folder")
        return False
    
    # 创建日期子文件夹
    date_folder_id = get_or_create_folder(service, today, parent_folder_id)
    if not date_folder_id:
        logger.error("Failed to create date folder")
        return False
    
    # 上传文件
    files_uploaded = 0
    files_failed = 0
    
    # 上传主输出文件
    for file_path in output_dir.glob('*'):
        if file_path.is_file():
            if upload_file(service, str(file_path), date_folder_id):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # 上传dataAnalysis文件
    data_analysis_dir = output_dir / 'dataAnalysis'
    if data_analysis_dir.exists():
        data_folder_id = get_or_create_folder(service, 'dataAnalysis', date_folder_id)
        if data_folder_id:
            for file_path in data_analysis_dir.glob('*.xlsx'):
                if upload_file(service, str(file_path), data_folder_id):
                    files_uploaded += 1
                else:
                    files_failed += 1
    
    # 上传charting文件
    charting_dir = output_dir / 'charting'
    if charting_dir.exists():
        charts_folder_id = get_or_create_folder(service, 'charts', date_folder_id)
        if charts_folder_id:
            for file_path in charting_dir.glob('*.png'):
                if upload_file(service, str(file_path), charts_folder_id):
                    files_uploaded += 1
                else:
                    files_failed += 1
            for file_path in charting_dir.glob('*.pdf'):
                if upload_file(service, str(file_path), charts_folder_id):
                    files_uploaded += 1
                else:
                    files_failed += 1
    
    # 摘要
    logger.info("=" * 60)
    logger.info(f"Sync Summary:")
    logger.info(f"  Files Uploaded: {files_uploaded}")
    logger.info(f"  Files Failed: {files_failed}")
    logger.info("=" * 60)
    
    return files_failed == 0

if __name__ == '__main__':
    try:
        success = sync_to_google_drive()
        sys.exit(0 if success else 1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)
