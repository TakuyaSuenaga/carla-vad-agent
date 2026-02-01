# 既存CARLA+VAD環境をAgent Core化する

既にGPU付きEC2インスタンスにCARLA+VAD環境を構築している場合の、Agent Core化手順です。

## 📋 前提条件

既存環境に以下が必要です：

- ✅ GPU付きEC2インスタンス（g4dn.xlarge, g5.xlargeなど）
- ✅ CARLA Simulator 0.9.15
- ✅ VAD Framework（オプション）
- ✅ Python 3.8以上
- ✅ Ubuntu 22.04（推奨）

## 🚀 クイックスタート

### ステップ1: EC2上でセットアップスクリプトを実行

```bash
# EC2インスタンスにSSH接続
ssh -i your-key.pem ubuntu@<EC2-IP>

# リポジトリをクローン（またはファイルをアップロード）
cd /tmp
git clone https://github.com/YOUR_USERNAME/carla-vad-agent.git
cd carla-vad-agent

# セットアップスクリプトを実行
bash scripts/setup_existing_carla.sh
```

**このスクリプトが実行すること:**
- Python依存関係のインストール（mcp, fastmcp, aiohttp, boto3）
- ローカルMCPサーバーのセットアップ
- systemdサービスの作成
- 設定ファイル（.env）の作成

### ステップ2: 環境検証

```bash
# 検証スクリプトを実行
bash scripts/validate_environment.sh
```

**チェック項目:**
- システム要件（Python, pip, curl）
- GPU/ドライバー（NVIDIA Driver, CUDA）
- CARLA環境（プロセス、ポート、Python API）
- Python依存関係
- インストールディレクトリ
- systemdサービス
- ネットワーク/ポート

### ステップ3: AWS側のリソース設定

ローカルマシンで実行：

```bash
# AWS設定スクリプトを実行
bash scripts/configure_aws.sh
```

**このスクリプトが実行すること:**
- IAMロールの作成（Lambda用、Bedrock Agent用）
- Lambda関数の作成（MCPブリッジ）
- Lambdaパッケージのビルドとデプロイ
- セキュリティグループの設定

**注意:** Bedrock Agentの作成は手動で行う必要があります（AWSコンソールで実行）

## 📚 詳細手順

### 1. ローカルMCPサーバーのセットアップ

#### 手動セットアップの場合:

```bash
# 依存関係のインストール
pip3 install mcp fastmcp carla aiohttp boto3

# リポジトリクローン
cd /opt
sudo git clone https://github.com/YOUR_USERNAME/carla-vad-agent.git
cd carla-vad-agent

# MCPサーバー起動テスト
cd mcp-servers/carla_local
python3 mcp_carla_server.py
```

#### systemdサービスとして起動:

```bash
# サービスファイル作成
sudo tee /etc/systemd/system/carla-mcp.service <<EOF
[Unit]
Description=CARLA Local MCP Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/carla-vad-agent/mcp-servers/carla_local
EnvironmentFile=/opt/carla-vad-agent/.env
ExecStart=/usr/bin/python3 mcp_carla_server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# サービス有効化・起動
sudo systemctl daemon-reload
sudo systemctl enable carla-mcp
sudo systemctl start carla-mcp

# 状態確認
sudo systemctl status carla-mcp
```

### 2. ヘルスチェックエンドポイントの起動

```bash
# Agent Coreサービス起動
sudo systemctl enable carla-agentcore
sudo systemctl start carla-agentcore

# ヘルスチェック確認
curl http://localhost:8000/health
```

**期待される出力:**
```json
{
  "status": "healthy",
  "carla_running": true,
  "service": "carla-agentcore"
}
```

### 3. AWS Lambda関数の作成

#### Lambdaパッケージのビルド:

```bash
# ローカルマシンで実行
cd cloudformation/lambda-code
bash build.sh
```

これにより `lambda-mcp-bridge.zip` が作成されます。

#### Lambda関数の作成（AWS CLI）:

```bash
# IAMロールの作成
aws iam create-role \
  --role-name carla-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Lambda関数の作成
aws lambda create-function \
  --function-name carla-mcp-bridge \
  --runtime python3.11 \
  --role arn:aws:iam::ACCOUNT_ID:role/carla-lambda-role \
  --handler index.lambda_handler \
  --timeout 300 \
  --zip-file fileb://lambda-mcp-bridge.zip \
  --environment Variables={CARLA_EC2_ENDPOINT=http://EC2_PRIVATE_IP:8000} \
  --vpc-config SubnetIds=subnet-xxx,SecurityGroupIds=sg-xxx
```

### 4. Bedrock Agentの作成

AWSコンソールで実行：

1. **AWS Console > Bedrock > Agents**
2. **Create Agent** をクリック
3. **設定:**
   - Agent name: `carla-vad-agent`
   - Model: `Claude Sonnet 4.5`
   - Instruction: [cloudformation/carla-bedrock-agent.yaml](../cloudformation/carla-bedrock-agent.yaml) の Instruction セクションをコピー
4. **Action Group を追加:**
   - Name: `carla-control`
   - Lambda function: `carla-mcp-bridge`
   - OpenAPI Schema: [carla-openapi-schema.json](../cloudformation/carla-openapi-schema.json) をアップロード
5. **Prepare Agent** をクリック
6. **Create Alias** (`production`)

### 5. セキュリティグループの設定

EC2のセキュリティグループに、Lambdaからのアクセスを許可：

```bash
# EC2のセキュリティグループIDを取得
EC2_SG_ID=$(aws ec2 describe-instances \
  --instance-ids i-xxxxx \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text)

# Lambdaのセキュリティグループから ポート8000 へのアクセスを許可
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG_ID \
  --protocol tcp \
  --port 8000 \
  --source-group sg-lambda-sg-id
```

## 🧪 動作確認

### 1. ローカルMCPサーバーのテスト

```bash
# EC2上で実行
curl -X POST http://localhost:8000/mcp/start_carla_scenario \
  -H "Content-Type: application/json" \
  -d '{
    "map_name": "Town05",
    "weather": "ClearNoon",
    "num_vehicles": 10,
    "num_pedestrians": 5
  }'
```

### 2. Lambda関数のテスト

```bash
# ローカルマシンで実行
aws lambda invoke \
  --function-name carla-mcp-bridge \
  --payload '{
    "actionGroup": "carla-control",
    "function": "startCarlaScenario",
    "parameters": [
      {"name": "map_name", "value": "Town05"},
      {"name": "weather", "value": "ClearNoon"}
    ]
  }' \
  response.json

cat response.json
```

### 3. Bedrock Agentのテスト

```bash
aws bedrock-agent-runtime invoke-agent \
  --agent-id YOUR_AGENT_ID \
  --agent-alias-id YOUR_ALIAS_ID \
  --session-id test-session \
  --input-text "Town05マップで60秒のVAD評価を実行してください" \
  --region us-east-1 \
  output.txt

cat output.txt
```

### 4. Claude Code CLIから呼び出し

```bash
# リモートMCPサーバーを設定後
claude -p "invoke_carla_agent ツールを使用して、Town05マップでVAD評価を実行してください" \
  --allowedTools "mcp__remote-orchestrator__invoke_carla_agent"
```

## 📊 アーキテクチャ

```
Claude Code CLI
  ↓
リモートMCPサーバー
  ↓
AWS Bedrock Agent
  ↓
Lambda関数（MCPブリッジ）
  ↓ (VPC内部通信)
EC2 (既存CARLA+VAD環境)
  ├─ CARLA Simulator
  ├─ VAD Framework
  └─ ローカルMCPサーバー (:8000)
```

## 🔧 トラブルシューティング

### MCPサーバーが起動しない

```bash
# ログ確認
sudo journalctl -u carla-mcp -n 50 -f

# 手動起動でエラー確認
cd /opt/carla-vad-agent/mcp-servers/carla_local
python3 mcp_carla_server.py
```

### Lambda がタイムアウトする

**原因:** EC2との通信ができない

**確認:**
1. LambdaがVPC内のプライベートサブネットに配置されているか
2. セキュリティグループでポート8000が開いているか
3. EC2のMCPサーバーが起動しているか

```bash
# EC2上で確認
curl http://localhost:8000/health

# LambdaのCloudWatch Logsを確認
aws logs tail /aws/lambda/carla-mcp-bridge --follow
```

### Bedrock Agentが応答しない

**確認:**
1. Agent が Prepared 状態か
2. Action Group が有効化されているか
3. Lambda の権限が正しく設定されているか

```bash
# Agent状態確認
aws bedrock-agent get-agent --agent-id YOUR_AGENT_ID

# Agentを再Prepare
aws bedrock-agent prepare-agent --agent-id YOUR_AGENT_ID
```

## 📝 サービス管理コマンド

### systemdサービス

```bash
# 状態確認
sudo systemctl status carla-mcp
sudo systemctl status carla-agentcore

# 起動
sudo systemctl start carla-mcp
sudo systemctl start carla-agentcore

# 停止
sudo systemctl stop carla-mcp
sudo systemctl stop carla-agentcore

# 再起動
sudo systemctl restart carla-mcp
sudo systemctl restart carla-agentcore

# ログ確認
sudo journalctl -u carla-mcp -f
sudo journalctl -u carla-agentcore -f
```

### CARLA起動

```bash
# Dockerで起動（推奨）
docker run --runtime=nvidia --net=host \
  carlasim/carla:0.9.15 bash CarlaUE4.sh -RenderOffScreen -nosound

# または、直接起動
cd /path/to/carla
./CarlaUE4.sh -RenderOffScreen -nosound
```

## 🔗 関連ドキュメント

- [CloudFormation デプロイガイド](../cloudformation/README.md)
- [メインREADME](../README.md)
- [MCP設定ガイド](../MCP_SETUP_GUIDE.md)

## 💡 よくある質問

### Q: Dockerを使わずにCARLAを起動できますか？

はい、CARLAを直接起動することも可能です。ただし、Dockerを使った方が環境の一貫性が保たれます。

### Q: VADは必須ですか？

いいえ、VADはオプションです。CARLAの制御だけであればVADは不要です。

### Q: 複数のEC2インスタンスでスケールできますか？

現在の構成は単一EC2インスタンス向けです。複数インスタンスでスケールする場合は、ロードバランサーとECRを使った構成が必要です。

### Q: コストを削減するには？

- 使用しない時はEC2インスタンスを停止
- Spot Instancesの利用
- より小さいインスタンスタイプ（g4dn.xlargeなど）の使用

## 📞 サポート

問題が発生した場合：

1. [validate_environment.sh](validate_environment.sh) を実行
2. サービスログを確認
3. GitHubでIssueを作成
