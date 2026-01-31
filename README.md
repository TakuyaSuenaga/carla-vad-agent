# CARLA-VAD Agent: AWS Bedrock AgentCore Integration

CARLA Simulator と VAD (Vectorized Autonomous Driving) を AWS Bedrock AgentCore と統合し、Claude Code CLI / GitHub Actions から自動運転シミュレーションを実行できる環境です。

## アーキテクチャ概要

```
Claude Code CLI / GitHub Actions
  ↓
リモートMCPサーバー (オーケストレーター)
  ├─→ 既存Agent Core (汎用タスク)
  └─→ CARLA Agent Core (GPU EC2)
       └─→ ローカルMCP (CARLA/VAD制御)
            └─→ CARLA Simulator + VAD Framework
```

## 主要コンポーネント

### 1. CARLA Agent Core (GPU EC2)
- **インスタンスタイプ**: g5.xlarge (NVIDIA A10G, 24GB VRAM)
- **環境**: CARLA 0.9.15 + VAD Framework (Docker)
- **ローカルMCP**: CARLA制御用ツール群

### 2. リモートMCPサーバー
- CARLA Agent Coreへの呼び出しを仲介
- GitHub公式MCPサーバーと統合
- Claude Code CLI / GitHub Actionsから利用可能

### 3. Bedrock AgentCore設定
- **モデル**: Claude Sonnet 4.5
- **セッションタイムアウト**: 8時間 (長時間シミュレーション対応)
- **ツール**: CARLA制御、VAD推論、メトリクス取得

## クイックスタート

### 前提条件
- AWS アカウント (Bedrock AgentCore 有効化済み)
- GitHub Personal Access Token
- Claude Code CLI インストール済み

### 1. 環境変数の設定

```bash
export GITHUB_PAT="your_github_pat_here"
export ANTHROPIC_API_KEY="your_anthropic_api_key"
export AWS_REGION="us-east-1"
export CARLA_AGENT_ID="your_bedrock_agent_id"
export CARLA_AGENT_ALIAS_ID="your_agent_alias_id"
```

### 2. MCP設定ファイルのセットアップ

```bash
# .env ファイルを作成
cp .env.example .env
# エディタで .env を編集し、GITHUB_PAT などの実際の値を設定

# GitHub MCP サーバーを追加
claude mcp add-json github '{"type":"http","url":"https://api.githubcopilot.com/mcp","headers":{"Authorization":"Bearer '"$(grep GITHUB_PAT .env | cut -d '=' -f2)"'"}}'

# または、手動で設定する場合
cp .mcp.json.example ~/.claude/.mcp.json
# エディタで ~/.claude/.mcp.json を編集し、実際のトークン値を設定
```

### 3. EC2インスタンスのセットアップ

```bash
# Terraformで環境構築
cd terraform
terraform init
terraform plan
terraform apply
```

または、手動セットアップ:

```bash
# EC2にSSH接続後
./scripts/setup_ec2.sh
```

### 4. CARLA Agent Coreのデプロイ

```bash
# Dockerイメージビルド
cd docker
docker build -t carla-agentcore:latest -f Dockerfile.carla-agentcore .

# コンテナ起動
docker-compose up -d
```

## 使用例

### Claude Code CLIから実行

```bash
claude -p "invoke_carla_agent ツールを使用して、Town05マップで60秒のVAD評価を実行し、衝突率とPlanning L2エラーを報告してください" \
  --allowedTools "mcp__remote-orchestrator__invoke_carla_agent"
```

### GitHub Actionsから実行

```yaml
# .github/workflows/carla_evaluation.yml を配置後
name: CARLA Simulation
on: workflow_dispatch

jobs:
  simulate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Simulation
        run: |
          claude -p "Town05で自動運転評価を実行" \
            --allowedTools "mcp__remote-orchestrator__invoke_carla_agent"
```

### Python SDKから直接呼び出し

```python
import boto3

bedrock = boto3.client('bedrock-agent-runtime', region_name='us-east-1')

response = bedrock.invoke_agent(
    agentId=os.environ['CARLA_AGENT_ID'],
    agentAliasId=os.environ['CARLA_AGENT_ALIAS_ID'],
    sessionId='my-session',
    inputText='Town10HDマップで100フレームのVAD推論を実行してください'
)

for event in response['completion']:
    if 'chunk' in event:
        print(event['chunk']['bytes'].decode('utf-8'))
```

## 利用可能なツール

### CARLA制御ツール

| ツール名 | 説明 |
|---------|------|
| `start_carla_scenario` | シミュレーション環境の初期化 |
| `run_vad_inference` | VAD推論の実行 |
| `get_simulation_metrics` | 現在の状態とメトリクス取得 |
| `stop_scenario` | シミュレーション停止とクリーンアップ |

### GitHub統合ツール (GitHub MCP)

| ツール名 | 説明 |
|---------|------|
| `create_issue` | GitHubイシューの作成 |
| `create_pull_request` | プルリクエストの作成 |
| `list_repositories` | リポジトリ一覧取得 |

## ディレクトリ構造

```
carla-vad-agent/
├── README.md                       # このファイル
├── .gitignore                      # Git無視設定
├── .mcp.json.example              # MCP設定テンプレート
├── docker/
│   ├── Dockerfile.carla-agentcore # CARLA Agent CoreのDockerfile
│   └── docker-compose.yml         # Docker Compose設定
├── mcp-servers/
│   ├── carla_local/               # CARLA制御用ローカルMCP
│   │   ├── mcp_carla_server.py
│   │   └── requirements.txt
│   └── remote_orchestrator/       # リモートMCPサーバー
│       ├── remote_mcp_server.py
│       └── requirements.txt
├── agent-core/
│   ├── start_agentcore.py         # Agent Core起動スクリプト
│   └── requirements.txt
├── terraform/
│   ├── carla_agentcore.tf         # インフラ定義
│   ├── variables.tf
│   └── outputs.tf
├── github-actions/
│   └── carla_evaluation.yml       # GitHub Actionsワークフロー
└── scripts/
    ├── setup_ec2.sh               # EC2セットアップスクリプト
    └── deploy.sh                  # デプロイスクリプト
```

## コスト見積もり

**月間1,000シミュレーション実行 (各30分) の場合**:

| 項目 | 料金/月 |
|------|---------|
| EC2 g5.xlarge (500時間) | $500 |
| Bedrock AgentCore Runtime | $300 |
| Bedrock AgentCore Memory | $50 |
| Claude API (Bedrock経由) | $150 |
| データ転送 | $20 |
| **合計** | **約$1,020** |

## トラブルシューティング

### CARLA起動エラー

```bash
# CARLAログ確認
docker logs carla-agentcore

# GPU確認
nvidia-smi
```

### MCP接続エラー

```bash
# MCP設定確認
cat ~/.claude/.mcp.json

# ログ確認
tail -f ~/.claude/logs/mcp.log
```

### Bedrock Agent呼び出しエラー

```bash
# IAMロール確認
aws iam get-role --role-name carla-agent-role

# Agent状態確認
aws bedrock-agent get-agent --agent-id $CARLA_AGENT_ID
```

## セキュリティ

- **トークン管理**: GitHub Token、API Keyは環境変数で管理
- **VPC設定**: CARLA EC2はプライベートサブネットに配置
- **IAMロール**: 最小権限の原則に基づいた設定
- **セキュリティグループ**: 必要なポートのみ開放

## ライセンス

MIT License

## 参考リンク

- [CARLA Simulator](https://carla.org/)
- [VAD Framework](https://github.com/hustvl/VAD)
- [AWS Bedrock AgentCore](https://aws.amazon.com/bedrock/agentcore/)
- [Claude Code CLI](https://docs.anthropic.com/claude-code)
- [MCP (Model Context Protocol)](https://modelcontextprotocol.io/)
