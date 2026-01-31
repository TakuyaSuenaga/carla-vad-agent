#!/usr/bin/env python3
"""
CARLA Agent Core起動スクリプト
CARLAサーバーとローカルMCPサーバーを起動し、Agent Coreとして動作
"""

import os
import sys
import asyncio
import subprocess
import signal
from pathlib import Path

# CARLAサーバープロセス
carla_process = None

def signal_handler(sig, frame):
    """シグナルハンドラー（クリーンシャットダウン）"""
    print("\n\nShutdown signal received. Cleaning up...")
    if carla_process:
        carla_process.terminate()
        carla_process.wait(timeout=10)
    sys.exit(0)

async def start_carla_server():
    """CARLAサーバーをバックグラウンドで起動"""
    global carla_process
    
    print("Starting CARLA server...")
    
    carla_path = os.environ.get('CARLA_ROOT', '/opt/carla')
    carla_exec = Path(carla_path) / 'CarlaUE4.sh'
    
    if not carla_exec.exists():
        print(f"ERROR: CARLA executable not found at {carla_exec}")
        sys.exit(1)
    
    # CARLAサーバー起動コマンド
    cmd = [
        str(carla_exec),
        '-RenderOffScreen',
        '-nosound',
        '-carla-rpc-port=2000',
        '-quality-level=Low'  # 低品質モードで高速化
    ]
    
    carla_process = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        cwd=carla_path
    )
    
    # CARLAの初期化を待機（約10-15秒）
    print("Waiting for CARLA server to initialize...")
    await asyncio.sleep(15)
    
    # CARLAサーバーが起動しているか確認
    if carla_process.poll() is not None:
        stderr = carla_process.stderr.read().decode('utf-8')
        print(f"ERROR: CARLA server failed to start:\n{stderr}")
        sys.exit(1)
    
    print("CARLA server started successfully")
    return carla_process

async def start_mcp_server():
    """ローカルMCPサーバーを起動"""
    print("Starting local MCP server...")
    
    mcp_script = Path('/opt/mcp/mcp_carla_server.py')
    
    if not mcp_script.exists():
        print(f"ERROR: MCP server script not found at {mcp_script}")
        sys.exit(1)
    
    # MCPサーバーをSTDIOモードで起動
    # 実際の運用では、ここでBedrock Agent Coreとの統合を行う
    mcp_process = subprocess.Popen(
        ['python3', str(mcp_script)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    
    print("Local MCP server started successfully")
    return mcp_process

async def health_check_server():
    """ヘルスチェック用HTTPサーバー（Docker healthcheck用）"""
    from aiohttp import web
    
    async def health(request):
        return web.json_response({
            "status": "healthy",
            "carla_running": carla_process and carla_process.poll() is None,
            "service": "carla-agentcore"
        })
    
    app = web.Application()
    app.router.add_get('/health', health)
    
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, '0.0.0.0', 8000)
    await site.start()
    
    print("Health check server started on port 8000")

async def main():
    """メインエントリーポイント"""
    # シグナルハンドラー登録
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    print("=" * 60)
    print("CARLA Agent Core Initialization")
    print("=" * 60)
    
    # 環境変数確認
    required_env_vars = ['AWS_REGION']
    for var in required_env_vars:
        if var not in os.environ:
            print(f"WARNING: {var} not set in environment")
    
    # CARLAサーバー起動
    await start_carla_server()
    
    # ヘルスチェックサーバー起動
    await health_check_server()
    
    # MCPサーバー起動
    mcp_process = await start_mcp_server()
    
    print("=" * 60)
    print("CARLA Agent Core is ready")
    print("Waiting for tasks from Bedrock Agent Runtime...")
    print("=" * 60)
    
    # プロセス監視ループ
    while True:
        await asyncio.sleep(5)
        
        # CARLAサーバーの状態確認
        if carla_process.poll() is not None:
            print("ERROR: CARLA server has stopped unexpectedly")
            sys.exit(1)
        
        # MCPサーバーの状態確認
        if mcp_process.poll() is not None:
            print("WARNING: MCP server has stopped, restarting...")
            mcp_process = await start_mcp_server()

if __name__ == "__main__":
    # aiohttp インストール確認
    try:
        import aiohttp
    except ImportError:
        print("Installing aiohttp for health check server...")
        subprocess.run([sys.executable, '-m', 'pip', 'install', 'aiohttp'])
    
    # メイン実行
    asyncio.run(main())
