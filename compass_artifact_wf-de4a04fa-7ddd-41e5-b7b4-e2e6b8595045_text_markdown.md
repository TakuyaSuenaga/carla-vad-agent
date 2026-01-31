# CARLA + VAD環境をClaude Codeエージェントとして運用する3つのアーキテクチャ

AWS EC2上で自動運転シミュレーターCARLAとVAD（Vectorized Autonomous Driving）を実行し、Claude Codeインスタンスからエージェントとして制御するには、**MCPサーバー方式**、**SSH実行方式**、**Bedrock AgentCore方式**の3パターンが有効です。コスト効率と実装の容易さでは**パターンB（SSH + 直接実行）**が最適、本番環境のスケーラビリティでは**パターンC（Bedrock AgentCore）**が優れています。本レポートでは各アーキテクチャの詳細設計、実装手順、トレードオフを解説します。

---

## EC2インスタンスとGPU環境の選定指針

CARLA実行には**GPUインスタンス**が必須です。コスト効率と性能のバランスを考慮すると、以下の選択が推奨されます。

| インスタンス | GPU | VRAM | 料金/時間 | 用途 |
|-------------|-----|------|----------|------|
| **g4dn.xlarge** | NVIDIA T4 | 16GB | $0.52 | 開発・テスト（最もコスト効率良好） |
| **g5.xlarge** | NVIDIA A10G | 24GB | $1.00 | 本番運用（T4の約3倍性能） |
| **g5.2xlarge** | NVIDIA A10G | 24GB | $1.21 | VAD推論+CARLA同時実行 |

VADフレームワークはGPUメモリを相当量消費するため、**g5.xlarge以上**を推奨します。VAD-Baseは約4.5 FPS、VAD-Tinyは約16.8 FPSで動作し、リアルタイム制御には**VAD-Tiny**が適しています。

AMIは**AWS Deep Learning AMI（Ubuntu 22.04 + NVIDIA Driver）** を使用すれば、NVIDIA Driver 550、CUDA 12.4、Docker + NVIDIA Container Toolkitが事前設定済みです。CARLAはDocker経由のヘッドレス実行が最も安定します。

```bash
# CARLAヘッドレス起動（EC2上）
docker run --runtime=nvidia --net=host \
  -e NVIDIA_VISIBLE_DEVICES=all \
  carlasim/carla:0.9.15 bash CarlaUE4.sh -RenderOffScreen -nosound
```

---

## VAD環境の構築要件とCARLA統合

VADはHUSTVL（華中科技大学）が開発したエンドツーエンド自動運転フレームワークで、ベクトル化されたシーン表現により**UniADの約2.5倍の速度**を実現しています。

**必須環境**:
- Python 3.8 + PyTorch 1.9.1（CUDA 11.1）
- mmcv-full 1.4.0、mmdet 2.14.0、mmdet3d 0.17.1
- nuScenes-devkit 1.1.9

CARLA統合には**Bench2DriveZoo**リポジトリを使用します。これはVADをCARLA 0.9.15でクローズドループ評価可能にした公式実装です。

```bash
# VAD + Bench2Drive環境構築
conda create -n vad python=3.8 -y && conda activate vad
pip install torch==1.9.1+cu111 torchvision==0.10.1+cu111 \
  -f https://download.pytorch.org/whl/torch_stable.html
pip install mmcv-full==1.4.0 mmdet==2.14.0 mmsegmentation==0.14.1

git clone https://github.com/Thinklab-SJTU/Bench2DriveZoo.git
# 詳細セットアップは同リポジトリのREADME参照
```

---

## パターンA: MCPサーバー + HTTPエンドポイント方式

### アーキテクチャ概要

EC2インスタンス上にMCP（Model Context Protocol）サーバーを配置し、CARLA/VAD制御用のツールをHTTPエンドポイントとして公開します。リモートのClaude Agentはこのエンドポイントに接続してシミュレーションを操作します。

```
┌─────────────────────────────────────────────────────────┐
│                     EC2 Instance                        │
│  ┌─────────────────┐      ┌─────────────────────────┐  │
│  │   MCP Server    │◄────►│    CARLA + VAD          │  │
│  │  (Port 8080)    │      │    (Port 2000-2002)     │  │
│  │  Streamable HTTP│      └─────────────────────────┘  │
│  └────────┬────────┘                                   │
└───────────┼─────────────────────────────────────────────┘
            │ HTTPS (Port 443)
┌───────────┴─────────────────────────────────────────────┐
│              Claude Agent SDK Client                    │
│  mcp_servers: [{"url": "https://ec2-ip:443/mcp"}]      │
└─────────────────────────────────────────────────────────┘
```

### 実装詳細

**MCPサーバー（Python FastMCP）**:
```python
from mcp.server.fastmcp import FastMCP
import carla

mcp = FastMCP(name="carla-vad-controller", host="0.0.0.0", port=8080)
carla_client = None

@mcp.tool(name="start_scenario", description="CARLAシナリオを開始")
async def start_scenario(map_name: str, weather: str = "Clear") -> dict:
    global carla_client
    carla_client = carla.Client('localhost', 2000)
    world = carla_client.load_world(map_name)
    return {"status": "running", "map": map_name}

@mcp.tool(name="run_vad_inference", description="VAD推論を実行")
async def run_vad_inference(frames: int = 100) -> dict:
    # VAD推論パイプライン呼び出し
    return {"detections": [...], "trajectory": [...]}

if __name__ == "__main__":
    mcp.run(transport="streamable-http", mount_path="/mcp")
```

**クライアント設定（.mcp.json）**:
```json
{
  "mcpServers": {
    "carla-remote": {
      "type": "streamable-http",
      "url": "https://ec2-xx-xx.compute.amazonaws.com:443/mcp",
      "headers": {"Authorization": "Bearer ${CARLA_API_TOKEN}"}
    }
  }
}
```

### メリット・デメリット

| 観点 | 評価 |
|------|------|
| **メリット** | MCP標準プロトコル準拠、リアルタイム双方向通信、セッション管理内蔵 |
| **デメリット** | MCPサーバー開発・運用が必要、HTTPS証明書管理、ファイアウォール設定の複雑さ |
| **実装難易度** | 中〜高（MCP SDKの習熟が必要） |
| **コスト効率** | 高（EC2コストのみ、追加サービス不要） |
| **スケーラビリティ** | 中（ロードバランサー追加で対応可能） |

---

## パターンB: Agent SDK + SSH直接実行方式

### アーキテクチャ概要

EC2インスタンス上でClaude Codeをヘッドレスモードで直接実行し、ローカルのSTDIO MCPサーバー経由でCARLA/VADを制御します。リモートからはSSHでClaude Codeプロセスを起動・管理します。

```
┌─────────────────────────────────────────────────────────┐
│                   Local Machine                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  ssh user@ec2 'claude -p "Run scenario" ...'   │   │
│  └────────────────────┬────────────────────────────┘   │
└───────────────────────┼─────────────────────────────────┘
                        │ SSH (Port 22)
┌───────────────────────┼─────────────────────────────────┐
│                   EC2 Instance                          │
│  ┌────────────────────┴────────────────────────────┐   │
│  │  tmux session                                   │   │
│  │  ┌──────────────────────────────────────────┐  │   │
│  │  │ claude -p "自動運転シナリオを実行"        │  │   │
│  │  │   --allowedTools "Bash,mcp__carla"       │  │   │
│  │  │   --mcp-config carla-local.json          │  │   │
│  │  └───────────┬──────────────────────────────┘  │   │
│  │              │ STDIO                           │   │
│  │  ┌───────────┴──────────────────────────────┐  │   │
│  │  │ Local MCP Server (CARLA/VAD Control)     │  │   │
│  │  └───────────┬──────────────────────────────┘  │   │
│  │              │                                 │   │
│  │  ┌───────────┴──────────────────────────────┐  │   │
│  │  │ CARLA Simulator + VAD System             │  │   │
│  │  └──────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 実装詳細

**EC2セットアップスクリプト**:
```bash
#!/bin/bash
# setup_carla_vad_claude.sh

# Claude Code CLI インストール
npm install -g @anthropic-ai/claude-code

# MCP設定ファイル作成
cat > ~/.claude/mcp.json << 'EOF'
{
  "mcpServers": {
    "carla": {
      "command": "python",
      "args": ["/opt/carla-mcp/server.py"]
    }
  }
}
EOF

# CARLA Docker起動（バックグラウンド）
docker run -d --name carla --runtime=nvidia --net=host \
  carlasim/carla:0.9.15 bash CarlaUE4.sh -RenderOffScreen -nosound
```

**リモート実行スクリプト**:
```bash
#!/bin/bash
# run_claude_agent.sh
PROMPT="$1"
ssh -i ~/.ssh/ec2_key ubuntu@$EC2_HOST << EOF
  export ANTHROPIC_API_KEY='$ANTHROPIC_API_KEY'
  tmux new-session -d -s claude 'claude -p "$PROMPT" \
    --allowedTools "Bash,Read,Write,mcp__carla__start_scenario,mcp__carla__run_vad" \
    --permission-mode bypassPermissions \
    --output-format stream-json'
EOF
```

**Claude Codeヘッドレス実行オプション**:
```bash
claude -p "Town05マップでVAD評価を100フレーム実行し、衝突率を計測" \
  --allowedTools "Bash,mcp__carla" \
  --mcp-config ~/.claude/mcp.json \
  --permission-mode bypassPermissions \
  --output-format json
```

### メリット・デメリット

| 観点 | 評価 |
|------|------|
| **メリット** | Claude Code全機能利用可能、セットアップ最小限、ネットワーク遅延なし（ローカル通信） |
| **デメリット** | SSH接続管理の複雑さ、長時間タスクでの接続断リスク、APIキー管理の注意 |
| **実装難易度** | 低〜中（既存CLIツール活用） |
| **コスト効率** | 最高（EC2 + Anthropic API料金のみ） |
| **スケーラビリティ** | 低（複数エージェント同時実行に制限） |

---

## パターンC: AWS Bedrock AgentCore + カスタムアクション方式

### アーキテクチャ概要

AWS Bedrock AgentCoreを使用し、VPC経由でEC2のCARLA/VADと通信します。AgentCore Gatewayでツールを定義し、Claudeモデルがシミュレーションを自律制御します。

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS VPC (Private)                        │
│  ┌──────────────────┐     ┌──────────────────────────────┐ │
│  │ AgentCore Runtime│     │       EC2 Instance           │ │
│  │  (Claude Sonnet) │────▶│  - CARLA Simulator           │ │
│  │  VPC Enabled     │◀────│  - VAD System                │ │
│  │                  │     │  - Control API (Port 8000)   │ │
│  └────────┬─────────┘     └──────────────────────────────┘ │
│           │                                                 │
│  ┌────────┴─────────┐     ┌──────────────────────────────┐ │
│  │AgentCore Gateway │     │    AgentCore Memory          │ │
│  │  - CARLA Tools   │     │  - Session state             │ │
│  │  - MCP Interface │     │  - Simulation history        │ │
│  └──────────────────┘     └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 実装詳細

**Lambda関数（CARLAアクショングループ）**:
```python
import json
import boto3
import requests

def lambda_handler(event, context):
    action = event.get('function')
    params = {p['name']: p['value'] for p in event.get('parameters', [])}
    
    # EC2内のCARLA制御APIを呼び出し
    ec2_api = "http://10.0.1.100:8000"  # VPC内部IP
    
    if action == 'start_scenario':
        response = requests.post(
            f"{ec2_api}/scenario/start",
            json={"map": params.get("map_name"), "weather": params.get("weather")}
        )
        result = response.json()
    elif action == 'get_vad_metrics':
        response = requests.get(f"{ec2_api}/vad/metrics")
        result = response.json()
    
    return {
        'messageVersion': '1.0',
        'response': {
            'actionGroup': event['actionGroup'],
            'function': action,
            'functionResponse': {
                'responseBody': {'TEXT': {'body': json.dumps(result)}}
            }
        }
    }
```

**OpenAPIスキーマ定義**:
```yaml
openapi: 3.0.0
info:
  title: CARLA VAD Control API
  version: 1.0.0
paths:
  /scenario/start:
    post:
      operationId: startScenario
      description: CARLAシミュレーションシナリオを開始
      parameters:
        - name: map_name
          in: query
          schema: { type: string, enum: [Town01, Town05, Town10] }
        - name: duration_seconds
          in: query
          schema: { type: integer, default: 300 }
      responses:
        '200':
          description: シナリオ開始成功
```

### メリット・デメリット

| 観点 | 評価 |
|------|------|
| **メリット** | フルマネージド、自動スケーリング、IAM統合、8時間セッション対応、CloudWatch監視 |
| **デメリット** | AWSロックイン、レイテンシ増加（Lambda経由）、学習コスト、AgentCore料金 |
| **実装難易度** | 中〜高（AWS知識、VPC設計が必要） |
| **コスト効率** | 中（AgentCore Runtime: $0.09/vCPU時間 + Memory料金） |
| **スケーラビリティ** | 最高（数千セッションまで自動スケール） |

---

## 3パターンの総合比較

| 評価軸 | パターンA (MCP+HTTP) | パターンB (SSH直接) | パターンC (AgentCore) |
|--------|---------------------|--------------------|-----------------------|
| **実装難易度** | ★★★☆☆ | ★★☆☆☆ | ★★★★☆ |
| **初期コスト** | 中（MCP開発） | 低（最小構成） | 高（AWS設計） |
| **運用コスト/月** | ~$400-600 | ~$400-500 | ~$1,000-1,200 |
| **レイテンシ** | 低〜中 | 最低 | 中〜高 |
| **スケーラビリティ** | 中 | 低 | 高 |
| **セキュリティ** | 中（HTTPS設定必要） | 高（SSHのみ） | 最高（IAM/VPC） |
| **保守性** | 中 | 高（シンプル） | 高（マネージド） |
| **推奨ユースケース** | マルチクライアント | 単一開発者/PoC | 本番/エンタープライズ |

**月額コスト内訳（1,000シミュレーションセッション×30分想定）**:
- **パターンA/B**: g5.xlarge ($1.00/h × 500h) ≈ $500 + Anthropic API ≈ $50-100
- **パターンC**: EC2 $500 + AgentCore Runtime $300 + Memory $50 + Claude Bedrock $150 ≈ $1,000

---

## ネットワークとセキュリティ設計

### セキュリティグループ設定

```hcl
# Terraform例
resource "aws_security_group" "carla_sg" {
  name = "carla-vad-sg"
  
  # SSH（管理用）
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["YOUR_IP/32"]
  }
  
  # CARLA ポート（VPC内部のみ）
  ingress {
    from_port   = 2000
    to_port     = 2002
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  
  # MCP Server（パターンA用）
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["YOUR_IP/32"]
  }
}
```

### 推奨モニタリング構成

- **CloudWatch Metrics**: GPU使用率、メモリ、ネットワークI/O
- **CloudWatch Logs**: CARLA stdout、VAD推論ログ、MCPサーバーログ
- **アラーム**: GPU温度85°C超過、メモリ90%超過、5分間の無応答

---

## 実装推奨と次のステップ

**開発・検証フェーズ**には**パターンB（SSH + 直接実行）** を推奨します。セットアップが最も単純で、Claude Codeの全機能を活用でき、コストも最小限です。

**本番運用・チーム利用**には**パターンC（Bedrock AgentCore）** を推奨します。スケーラビリティ、監視、セキュリティがマネージドで提供され、複数のClaude Codeインスタンスからの同時アクセスにも対応できます。

**パターンA（MCP + HTTP）** は、独自のツールエコシステムを構築したい場合や、AWS以外の環境との連携が必要な場合に選択してください。

いずれのパターンでも、まず**g4dn.xlargeインスタンス**でCARLA + VADの動作を確認し、パフォーマンス要件に応じて**g5系インスタンス**へのスケールアップを検討することを推奨します。