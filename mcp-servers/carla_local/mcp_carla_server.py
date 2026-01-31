#!/usr/bin/env python3
"""
CARLA/VAD制御用ローカルMCPサーバー
CARLA Agent Core内で動作し、シミュレーション制御ツールを提供
"""

from mcp.server.fastmcp import FastMCP
import carla
import subprocess
import json
import asyncio
from typing import Dict, List, Optional

mcp = FastMCP(name="carla-vad-local")

# グローバル状態管理
carla_client: Optional[carla.Client] = None
current_world: Optional[carla.World] = None
vad_process: Optional[subprocess.Popen] = None

@mcp.tool(
    name="start_carla_scenario",
    description="CARLAシミュレーションシナリオを開始する"
)
async def start_carla_scenario(
    map_name: str,
    weather: str = "ClearNoon",
    num_vehicles: int = 50,
    num_pedestrians: int = 30
) -> Dict:
    """
    CARLAシミュレーションを初期化して開始
    
    Args:
        map_name: マップ名（Town01-Town12, Town10HD）
        weather: 天候プリセット（ClearNoon, CloudyNoon, WetNoon, WetCloudyNoon, 
                 MidRainyNoon, HardRainNoon, SoftRainNoon, ClearSunset, CloudySunset）
        num_vehicles: 交通車両数
        num_pedestrians: 歩行者数
    
    Returns:
        シナリオ開始結果とメタデータ
    """
    global carla_client, current_world
    
    try:
        # CARLAサーバー接続
        carla_client = carla.Client('localhost', 2000)
        carla_client.set_timeout(10.0)
        
        # マップロード
        current_world = carla_client.load_world(map_name)
        
        # 天候設定
        weather_presets = {
            'ClearNoon': carla.WeatherParameters.ClearNoon,
            'CloudyNoon': carla.WeatherParameters.CloudyNoon,
            'WetNoon': carla.WeatherParameters.WetNoon,
            'WetCloudyNoon': carla.WeatherParameters.WetCloudyNoon,
            'MidRainyNoon': carla.WeatherParameters.MidRainyNoon,
            'HardRainNoon': carla.WeatherParameters.HardRainNoon,
            'SoftRainNoon': carla.WeatherParameters.SoftRainNoon,
            'ClearSunset': carla.WeatherParameters.ClearSunset,
            'CloudySunset': carla.WeatherParameters.CloudySunset,
        }
        current_world.set_weather(weather_presets.get(weather, carla.WeatherParameters.ClearNoon))
        
        # トラフィック生成
        blueprint_library = current_world.get_blueprint_library()
        spawn_points = current_world.get_map().get_spawn_points()
        
        # 車両スポーン
        vehicle_bps = blueprint_library.filter('vehicle.*')
        spawned_vehicles = 0
        for i in range(min(num_vehicles, len(spawn_points))):
            bp = vehicle_bps[i % len(vehicle_bps)]
            if current_world.try_spawn_actor(bp, spawn_points[i]):
                spawned_vehicles += 1
        
        # 歩行者スポーン（簡略化）
        walker_bps = blueprint_library.filter('walker.pedestrian.*')
        spawned_walkers = 0
        walker_spawn_points = spawn_points[:num_pedestrians]
        for i, spawn_point in enumerate(walker_spawn_points):
            bp = walker_bps[i % len(walker_bps)]
            if current_world.try_spawn_actor(bp, spawn_point):
                spawned_walkers += 1
        
        return {
            "status": "success",
            "map": map_name,
            "weather": weather,
            "spawned_vehicles": spawned_vehicles,
            "spawned_pedestrians": spawned_walkers,
            "total_spawn_points": len(spawn_points),
            "server_version": carla_client.get_server_version()
        }
        
    except Exception as e:
        return {
            "status": "error",
            "message": str(e),
            "error_type": type(e).__name__
        }

@mcp.tool(
    name="run_vad_inference",
    description="VAD推論を実行してシーン理解・軌道計画を取得"
)
async def run_vad_inference(
    duration_seconds: int = 10,
    save_results: bool = True,
    output_path: str = "/tmp/vad_results.json"
) -> Dict:
    """
    VADフレームワークで自動運転推論を実行
    
    Args:
        duration_seconds: 推論実行時間（秒）
        save_results: 結果をファイルに保存するか
        output_path: 結果の保存パス
    
    Returns:
        VAD推論結果（FPS、Planning L2エラー、衝突率など）
    """
    global vad_process
    
    try:
        # VAD推論スクリプト実行
        cmd = [
            'python', '/opt/vad/tools/test.py',
            '--config', '/opt/vad/configs/VAD/VAD_tiny_stage2.py',
            '--checkpoint', '/opt/vad/checkpoints/VAD_tiny.pth',
            '--duration', str(duration_seconds),
            '--eval', 'bbox'
        ]
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=duration_seconds + 60
        )
        
        # 結果パース
        output = result.stdout
        metrics = {
            "fps": 0.0,
            "planning_l2_error": 0.0,
            "collision_rate": 0.0,
            "map_mAP": 0.0,
            "motion_mAP": 0.0
        }
        
        # 出力から主要メトリクスを抽出
        for line in output.split('\n'):
            if 'FPS:' in line:
                try:
                    metrics['fps'] = float(line.split(':')[1].strip())
                except:
                    pass
            elif 'Planning L2 Error:' in line:
                try:
                    metrics['planning_l2_error'] = float(line.split(':')[1].strip())
                except:
                    pass
            elif 'Collision Rate:' in line:
                try:
                    metrics['collision_rate'] = float(line.split(':')[1].strip())
                except:
                    pass
        
        if save_results:
            with open(output_path, 'w') as f:
                json.dump({
                    "metrics": metrics,
                    "full_output": output,
                    "stderr": result.stderr
                }, f, indent=2)
        
        return {
            "status": "success",
            "duration": duration_seconds,
            "metrics": metrics,
            "saved_path": output_path if save_results else None,
            "return_code": result.returncode
        }
        
    except subprocess.TimeoutExpired:
        return {
            "status": "error",
            "message": f"VAD inference timeout after {duration_seconds + 60} seconds"
        }
    except FileNotFoundError:
        return {
            "status": "error",
            "message": "VAD test script not found. Please ensure VAD is properly installed."
        }
    except Exception as e:
        return {
            "status": "error",
            "message": str(e),
            "error_type": type(e).__name__
        }

@mcp.tool(
    name="get_simulation_metrics",
    description="現在のシミュレーション状態とメトリクスを取得"
)
async def get_simulation_metrics() -> Dict:
    """
    シミュレーション状態の詳細情報を取得
    
    Returns:
        アクター数、フレーム番号、マップ情報など
    """
    global current_world
    
    if not current_world:
        return {
            "status": "error",
            "message": "No active simulation. Call start_carla_scenario first."
        }
    
    try:
        actors = current_world.get_actors()
        vehicles = actors.filter('vehicle.*')
        pedestrians = actors.filter('walker.*')
        traffic_lights = actors.filter('traffic.traffic_light')
        
        snapshot = current_world.get_snapshot()
        
        return {
            "status": "success",
            "total_actors": len(actors),
            "vehicles": len(vehicles),
            "pedestrians": len(pedestrians),
            "traffic_lights": len(traffic_lights),
            "map_name": current_world.get_map().name,
            "frame": snapshot.frame,
            "timestamp": snapshot.timestamp.elapsed_seconds,
            "weather": {
                "cloudiness": current_world.get_weather().cloudiness,
                "precipitation": current_world.get_weather().precipitation,
                "sun_altitude_angle": current_world.get_weather().sun_altitude_angle
            }
        }
    except Exception as e:
        return {
            "status": "error",
            "message": str(e),
            "error_type": type(e).__name__
        }

@mcp.tool(
    name="stop_scenario",
    description="シミュレーションを停止してリソースをクリーンアップ"
)
async def stop_scenario() -> Dict:
    """
    シミュレーション終了とクリーンアップ
    
    Returns:
        停止結果
    """
    global carla_client, current_world, vad_process
    
    try:
        destroyed_count = 0
        
        if current_world:
            # すべてのアクターを削除
            actors = current_world.get_actors()
            for actor in actors:
                if actor.is_alive:
                    actor.destroy()
                    destroyed_count += 1
        
        if vad_process and vad_process.poll() is None:
            vad_process.terminate()
            vad_process.wait(timeout=5)
        
        carla_client = None
        current_world = None
        vad_process = None
        
        return {
            "status": "success",
            "message": "Simulation stopped and cleaned up",
            "destroyed_actors": destroyed_count
        }
    except Exception as e:
        return {
            "status": "error",
            "message": str(e),
            "error_type": type(e).__name__
        }

if __name__ == "__main__":
    # MCPサーバー起動
    mcp.run(transport="stdio")
