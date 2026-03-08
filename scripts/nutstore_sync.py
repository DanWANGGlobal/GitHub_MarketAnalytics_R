#!/usr/bin/env python3
"""
Nutstore WebDAV Sync Script
Uploads analysis results to Nutstore Cloud via WebDAV
"""

import os
import sys
from pathlib import Path
from datetime import datetime
import logging

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

def get_webdav_client():
    """Initialize WebDAV client"""
    try:
        from webdav4.client import Client
        
        user = os.environ.get('NUTSTORE_USER')
        password = os.environ.get('NUTSTORE_PASSWORD')
        webdav_url = os.environ.get('NUTSTORE_WEBDAV_URL', 'https://dav.jianguoyun.com/dav/')
        
        if not user or not password:
            logger.error("NUTSTORE_USER or NUTSTORE_PASSWORD not set!")
            return None
        
        client = Client(
            base_url=webdav_url,
            auth=(user, password)
        )
        
        # Test connection
        try:
            client.exists('/')
            logger.info("Successfully connected to Nutstore WebDAV")
            return client
        except Exception as e:
            logger.error(f"Failed to connect to WebDAV: {e}")
            return None
            
    except ImportError:
        logger.error("webdav4 not installed. Installing...")
        os.system("pip install webdav4")
        return get_webdav_client()

def ensure_remote_directory(client, remote_path):
    """Create remote directory if not exists"""
    try:
        if not client.exists(remote_path):
            client.mkdir(remote_path)
            logger.info(f"Created remote directory: {remote_path}")
        return True
    except Exception as e:
        logger.error(f"Failed to create directory {remote_path}: {e}")
        return False

def upload_file(client, local_path, remote_path):
    """Upload a single file"""
    try:
        client.upload_file(local_path, remote_path)
        logger.info(f"Uploaded: {local_path} -> {remote_path}")
        return True
    except Exception as e:
        logger.error(f"Failed to upload {local_path}: {e}")
        return False

def sync_to_nutstore():
    """Main sync function"""
    
    # Configuration
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    remote_base = os.environ.get('NUTSTORE_REMOTE_PATH', '/R-Analysis-Output/')
    
    # Add date subdirectory
    today = datetime.now().strftime('%Y-%m-%d')
    remote_path = f"{remote_base}{today}/"
    
    logger.info("=" * 60)
    logger.info("Nutstore WebDAV Sync Started")
    logger.info(f"Local Directory: {output_dir}")
    logger.info(f"Remote Path: {remote_path}")
    logger.info("=" * 60)
    
    # Initialize WebDAV client
    client = get_webdav_client()
    if not client:
        logger.error("Failed to initialize WebDAV client!")
        sys.exit(1)
    
    # Ensure remote directory exists
    if not ensure_remote_directory(client, remote_path):
        logger.error("Failed to create remote directory!")
        sys.exit(1)
    
    # Find and upload files
    files_uploaded = 0
    files_failed = 0
    
    if not output_dir.exists():
        logger.error(f"Output directory not found: {output_dir}")
        sys.exit(1)
    
    # Upload main output files
    for file_path in output_dir.glob('*'):
        if file_path.is_file():
            remote_file = f"{remote_path}{file_path.name}"
            if upload_file(client, str(file_path), remote_file):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # Upload dataAnalysis files
    data_analysis_dir = output_dir / 'dataAnalysis'
    if data_analysis_dir.exists():
        remote_data_dir = f"{remote_path}dataAnalysis/"
        ensure_remote_directory(client, remote_data_dir)
        
        for file_path in data_analysis_dir.glob('*.xlsx'):
            remote_file = f"{remote_data_dir}{file_path.name}"
            if upload_file(client, str(file_path), remote_file):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # Upload charting files
    charting_dir = output_dir / 'charting' / '0html_ChartsPac'
    if charting_dir.exists():
        remote_chart_dir = f"{remote_path}charts/"
        ensure_remote_directory(client, remote_chart_dir)
        
        for file_path in charting_dir.glob('*.html'):
            remote_file = f"{remote_chart_dir}{file_path.name}"
            if upload_file(client, str(file_path), remote_file):
                files_uploaded += 1
            else:
                files_failed += 1
    
    # Summary
    logger.info("=" * 60)
    logger.info(f"Sync Summary:")
    logger.info(f"  Files Uploaded: {files_uploaded}")
    logger.info(f"  Files Failed: {files_failed}")
    logger.info("=" * 60)
    
    if files_failed > 0:
        sys.exit(1)
    
    logger.info("Sync completed successfully!")

# Alternative implementation using requests (if webdav4 is not available)
def sync_with_requests():
    """Alternative sync using raw requests"""
    import requests
    from requests.auth import HTTPBasicAuth
    import base64
    
    user = os.environ.get('NUTSTORE_USER')
    password = os.environ.get('NUTSTORE_PASSWORD')
    webdav_url = os.environ.get('NUTSTORE_WEBDAV_URL', 'https://dav.jianguoyun.com/dav/')
    
    if not user or not password:
        logger.error("Credentials not set!")
        return False
    
    work_dir = os.environ.get('WORK_DIR', os.getcwd())
    output_dir = Path(work_dir) / 'output'
    
    today = datetime.now().strftime('%Y-%m-%d')
    remote_base = os.environ.get('NUTSTORE_REMOTE_PATH', '/R-Analysis-Output/')
    remote_path = f"{remote_base}{today}/"
    
    auth = HTTPBasicAuth(user, password)
    
    # Create directory
    mkdir_url = f"{webdav_url.rstrip('/')}{remote_path}"
    try:
        response = requests.request('MKCOL', mkdir_url, auth=auth)
        if response.status_code in [201, 204, 405]:  # 405 = already exists
            logger.info(f"Directory ready: {remote_path}")
        else:
            logger.warning(f"MKCOL response: {response.status_code}")
    except Exception as e:
        logger.error(f"Failed to create directory: {e}")
        return False
    
    # Upload files
    files_uploaded = 0
    for file_path in output_dir.glob('**/*'):
        if file_path.is_file():
            relative_path = file_path.relative_to(output_dir)
            remote_file_path = f"{remote_path}{relative_path}"
            upload_url = f"{webdav_url.rstrip('/')}{remote_file_path}"
            
            try:
                with open(file_path, 'rb') as f:
                    response = requests.put(upload_url, data=f, auth=auth)
                    if response.status_code in [201, 204]:
                        logger.info(f"Uploaded: {relative_path}")
                        files_uploaded += 1
                    else:
                        logger.error(f"Failed to upload {relative_path}: {response.status_code}")
            except Exception as e:
                logger.error(f"Error uploading {relative_path}: {e}")
    
    logger.info(f"Total files uploaded: {files_uploaded}")
    return True

if __name__ == '__main__':
    try:
        # Try webdav4 first
        sync_to_nutstore()
    except Exception as e:
        logger.error(f"webdav4 sync failed: {e}")
        logger.info("Trying alternative sync method...")
        try:
            sync_with_requests()
        except Exception as e2:
            logger.error(f"Alternative sync also failed: {e2}")
            sys.exit(1)
