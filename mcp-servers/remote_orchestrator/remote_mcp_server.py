#!/usr/bin/env python3
"""
リモートMCPサーバー（オーケストレーター）
Claude Code CLI / GitHub ActionsからCARLA Agent Coreを呼び出す
"""

import os
import uuid
import boto3
from mcp.server.fastmcp import FastMCP
from typing import Dict, Optional

mcp = FastMCP(name="remote-orchestrator")
bedrock_agent = boto3.client('bedrock-agent-runtime')

@mcp.tool(
    name="invoke_carla_agent",
    description="CARLA/VAD専用Agent Coreを呼び出して自動運転シミュレーションタスクを実行"
)
async def invoke_carla_agent(
    task_description: str,
    map_name: str = "Town05",
    weather: str = "ClearNoon",
    duration_seconds: int = 60,
    session_id: Optional[str] = None
) -> Dict:
    """
    CARLA Agent Coreを呼び出して自動運転シミュレーションタスクを実行
    
    Args:
        task_description: 実行するタスクの自然言語記述
        map_name: CARLAマップ名（Town01-Town12, Town10HD）
        weather: 天候設定
        duration_seconds: シミュレーション時間（秒）
        session_id: セッションID（省略時は自動生成）
    
    Returns:
        Agent Coreの実行結果
    """
    try:
        # セッションID生成
        if not session_id:
            session_id = f"carla-session-{uuid.uuid4()}"
        
        # Agent IDとAlias IDを環境変数から取得
        agent_id = os.environ.get('CARLA_AGENT_ID')
        agent_alias_id = os.environ.get('CARLA_AGENT_ALIAS_ID')
        
        if not agent_id or not agent_alias_id:
            return {
                "status": "error",
                "message": "CARLA_AGENT_ID or CARLA_AGENT_ALIAS_ID not set in environment"
            }
        
        # タスク記述を拡張
        full_prompt = f"""
以下の自動運転シミュレーションタスクを実行してください：

{task_description}

シナリオ設定:
- マップ: {map_name}
- 天候: {weather}
- 実行時間: {duration_seconds}秒

手順:
1. start_carla_scenario ツールでシミュレーション環境を初期化
2. run_vad_inference ツールでVAD推論を実行
3. get_simulation_metrics ツールで結果を取得
4. stop_scenario ツールでクリーンアップ

最終的に、以下を含むレポートを作成してください:
- シミュレーション概要
- VADメトリクス（FPS、Planning L2エラー、衝突率）
- 発生した問題や注意点
"""
        
        # Bedrock Agent RuntimeでCARLA Agent Coreを呼び出し
        response = bedrock_agent.invoke_agent(
            agentId=agent_id,
            agentAliasId=agent_alias_id,
            sessionId=session_id,
            inputText=full_prompt,
            enableTrace=True
        )
        
        # ストリーミングレスポンス処理
        result_text = ""
        trace_data = []
        
        for event in response['completion']:
            if 'chunk' in event:
                chunk = event['chunk']
                if 'bytes' in chunk:
                    result_text += chunk['bytes'].decode('utf-8')
            elif 'trace' in event:
                trace_data.append(event['trace'])
        
        return {
            "status": "success",
            "session_id": session_id,
            "result": result_text,
            "agent_id": agent_id,
            "map_name": map_name,
            "duration": duration_seconds,
            "trace_available": len(trace_data) > 0
        }
        
    except Exception as e:
        return {
            "status": "error",
            "message": str(e),
            "error_type": type(e).__name__
        }

@mcp.tool(
    name="list_carla_maps",
    description="利用可能なCARLAマップの一覧を取得"
)
async def list_carla_maps() -> Dict:
    """
    CARLA 0.9.15で利用可能なマップ一覧
    
    Returns:
        マップ情報のリスト
    """
    maps = [
        {"name": "Town01", "description": "基本的な町（小規模）"},
        {"name": "Town02", "description": "住宅街"},
        {"name": "Town03", "description": "大規模都市"},
        {"name": "Town04", "description": "高速道路"},
        {"name": "Town05", "description": "複雑な交差点（評価用）"},
        {"name": "Town06", "description": "高速道路と市街地"},
        {"name": "Town07", "description": "農村地帯"},
        {"name": "Town10HD", "description": "高精細都市マップ"},
        {"name": "Town11", "description": "大規模複雑都市"},
        {"name": "Town12", "description": "多様な道路形状"}
    ]
    
    return {
        "status": "success",
        "maps": maps,
        "total_count": len(maps)
    }

@mcp.tool(
    name="get_weather_presets",
    description="利用可能な天候プリセットの一覧を取得"
)
async def get_weather_presets() -> Dict:
    """
    CARLAの天候プリセット一覧
    
    Returns:
        天候プリセット情報
    """
    presets = [
        {"name": "ClearNoon", "description": "晴天・正午"},
        {"name": "CloudyNoon", "description": "曇り・正午"},
        {"name": "WetNoon", "description": "雨上がり・正午"},
        {"name": "WetCloudyNoon", "description": "曇り・雨上がり・正午"},
        {"name": "MidRainyNoon", "description": "中程度の雨・正午"},
        {"name": "HardRainNoon", "description": "強い雨・正午"},
        {"name": "SoftRainNoon", "description": "弱い雨・正午"},
        {"name": "ClearSunset", "description": "晴天・夕方"},
        {"name": "CloudySunset", "description": "曇り・夕方"}
    ]
    
    return {
        "status": "success",
        "presets": presets,
        "total_count": len(presets)
    }

if __name__ == "__main__":
    # HTTPサーバーとして起動（Streamable HTTP）
    import sys
    
    if "--transport" in sys.argv:
        transport_idx = sys.argv.index("--transport")
        transport = sys.argv[transport_idx + 1]
    else:
        transport = "streamable-http"
    
    if transport == "streamable-http":
        mcp.run(
            transport="streamable-http",
            host="0.0.0.0",
            port=8080,
            mount_path="/mcp"
        )
    else:
        # STDIO モード
        mcp.run(transport="stdio")
