# CARLA-VAD Agent CloudFormation デプロイメント

このディレクトリには、CARLA-VAD AgentをAWS CloudFormationを使用してデプロイするためのテンプレートとスクリプトが含まれています。

## 📁 ディレクトリ構造

```
cloudformation/
├── README.md                      # このファイル
├── carla-master.yaml              # マスタースタック（全体を統合）
├── carla-network.yaml             # ネットワークリソース（VPC、サブネット）
├── carla-iam.yaml                 # IAMロールとポリシー
├── carla-compute.yaml             # EC2インスタンス
├── carla-lambda.yaml              # Lambda関数（MCPブリッジ）
├── carla-bedrock-agent.yaml       # Bedrock Agent設定
├── carla-openapi-schema.json      # Bedrock Agent用OpenAPIスキーマ
├── parameters.json.example        # パラメータテンプレート
├── deploy.sh                      # デプロイスクリプト
├── delete.sh                      # 削除スクリプト
└── lambda-code/
    ├── index.py                   # Lambda関数コード
    ├── requirements.txt           # Python依存関係
    ├── build.sh                   # Lambda パッケージビルドスクリプト
    └── lambda-mcp-bridge.zip      # Lambda デプロイパッケージ（ビルド後）
```

## 🚀 クイックスタート

### 1. 前提条件

- AWS CLI インストール済み（`aws configure` 実行済み）
- EC2キーペアの作成（SSHアクセス用）
- AWS Bedrock へのアクセス権限
- 十分なサービスクォータ（GPU EC2、Bedrock Agentなど）

### 2. パラメータファイルの作成

```bash
cd cloudformation
cp parameters.json.example parameters.json
```

`parameters.json` を編集して、以下の値を設定：

```json
[
  {
    "ParameterKey": "ProjectName",
    "ParameterValue": "carla-vad"
  },
  {
    "ParameterKey": "KeyName",
    "ParameterValue": "your-ec2-key-pair-name"  // 実際のキーペア名に変更
  },
  {
    "ParameterKey": "InstanceType",
    "ParameterValue": "g5.xlarge"
  },
  {
    "ParameterKey": "AllowedSshCidr",
    "ParameterValue": "0.0.0.0/0"  // 本番環境では制限を推奨
  }
]
```

### 3. デプロイ

```bash
./deploy.sh
```

デプロイには10-15分かかります。完了後、以下の情報が出力されます：

- EC2インスタンスのパブリックIP
- SSHコマンド
- Bedrock Agent ID と Alias ID

### 4. デプロイ後の設定

#### EC2インスタンスにSSH接続

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<EC2-PUBLIC-IP>
```

#### リポジトリのクローン（EC2上）

```bash
cd /opt/carla-vad-agent
git clone https://github.com/YOUR_USERNAME/carla-vad-agent.git .
```

#### Docker Composeでサービス起動

```bash
cd docker
docker-compose up -d
```

#### ローカル環境の.env更新

CloudFormationの出力から取得した値を`.env`に設定：

```bash
# .env ファイル
CARLA_AGENT_ID=<BedrockAgentId from CloudFormation output>
CARLA_AGENT_ALIAS_ID=<BedrockAgentAliasId from CloudFormation output>
AWS_REGION=us-east-1
```

## 📦 個別スタックのデプロイ

マスタースタックではなく、個別にスタックをデプロイする場合：

### ネットワークスタック

```bash
aws cloudformation create-stack \
  --stack-name carla-vad-network \
  --template-body file://carla-network.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=carla-vad
```

### IAMスタック

```bash
aws cloudformation create-stack \
  --stack-name carla-vad-iam \
  --template-body file://carla-iam.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=ProjectName,ParameterValue=carla-vad
```

### コンピュートスタック

```bash
aws cloudformation create-stack \
  --stack-name carla-vad-compute \
  --template-body file://carla-compute.yaml \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=carla-vad \
    ParameterKey=NetworkStackName,ParameterValue=carla-vad-network \
    ParameterKey=IAMStackName,ParameterValue=carla-vad-iam \
    ParameterKey=KeyName,ParameterValue=your-key-name
```

## 🔧 Lambda パッケージのビルド

Lambda関数を更新する場合：

```bash
cd lambda-code
./build.sh
```

これにより `lambda-mcp-bridge.zip` が作成されます。S3にアップロード後、スタックを更新：

```bash
aws s3 cp lambda-mcp-bridge.zip s3://your-bucket/
aws cloudformation update-stack \
  --stack-name carla-vad-lambda \
  --use-previous-template \
  --parameters ParameterKey=LambdaS3Bucket,ParameterValue=your-bucket
```

## 🧪 デプロイのテスト

### AWS CLI でBedrock Agentを直接呼び出し

```bash
aws bedrock-agent-runtime invoke-agent \
  --agent-id <AGENT-ID> \
  --agent-alias-id <ALIAS-ID> \
  --session-id test-session \
  --input-text "Town05マップで60秒のVAD評価を実行してください" \
  --region us-east-1 \
  output.txt

cat output.txt
```

### Claude Code CLI から呼び出し

```bash
# リモートMCPサーバーの設定（既存のremote_mcp_server.pyを使用）
claude -p "invoke_carla_agent ツールを使用して、Town05マップでVAD評価を実行してください" \
  --allowedTools "mcp__remote-orchestrator__invoke_carla_agent"
```

## 🗑️ スタックの削除

```bash
./delete.sh
```

または、AWS CLIで直接削除：

```bash
aws cloudformation delete-stack --stack-name carla-vad-master
```

**注意**: 削除には時間がかかります。ネストされたスタックがすべて削除されるまで待つ必要があります。

## 📊 コスト見積もり

以下は月間1,000シミュレーション（各30分）実行した場合の見積もり：

| リソース | 料金/月 |
|---------|---------|
| EC2 g5.xlarge (500時間) | $500 |
| Bedrock Agent Runtime | $300 |
| Bedrock Agent Memory | $50 |
| Claude API (Bedrock経由) | $150 |
| Lambda (少量実行) | $5 |
| データ転送 | $20 |
| NAT Gateway (730時間) | $32 |
| **合計** | **約$1,057/月** |

開発・テスト環境では、使用しない時はEC2インスタンスを停止することでコスト削減できます。

## 🔍 トラブルシューティング

### スタック作成が失敗する

#### エラー: "No export named..."

ネストされたスタックの依存関係エラーです。個別スタックを順番にデプロイしてください：

1. Network
2. IAM
3. Compute
4. Lambda
5. Bedrock Agent

#### エラー: "Service: AmazonEC2, Message: Instance type g5.xlarge is not available"

リージョンでg5.xlargeが利用できない可能性があります。以下のいずれかを試してください：

- リージョンを変更（`us-east-1`, `us-west-2`など）
- インスタンスタイプを変更（`g4dn.xlarge`など）
- サービスクォータの引き上げをリクエスト

#### エラー: "User: ... is not authorized to perform: bedrock:CreateAgent"

Bedrock Agentへのアクセス権限が不足しています。以下を確認：

1. Bedrock サービスへのアクセスが有効か
2. IAMユーザー/ロールに適切なポリシーがアタッチされているか
3. リージョンでBedrock Agentが利用可能か

### Lambda関数が失敗する

#### エラー: "Task timed out after 300.00 seconds"

CARLA EC2インスタンスが起動していないか、ネットワーク接続に問題があります：

1. EC2インスタンスにSSH接続して、CARLAとMCPサーバーが動作しているか確認
2. セキュリティグループでポート8000が開いているか確認
3. Lambdaがプライベートサブネットに配置されているか確認

```bash
# EC2上で確認
docker ps
curl http://localhost:8000/health
```

### Bedrock Agent呼び出しが失敗する

#### エラー: "Agent is not prepared"

Agentの準備が完了していません：

```bash
aws bedrock-agent prepare-agent --agent-id <AGENT-ID>
```

CloudFormationテンプレートには自動的にこれを実行するカスタムリソースが含まれていますが、失敗している可能性があります。

## 📚 参考リンク

- [AWS CloudFormation ドキュメント](https://docs.aws.amazon.com/cloudformation/)
- [AWS Bedrock Agent ドキュメント](https://docs.aws.amazon.com/bedrock/latest/userguide/agents.html)
- [CARLA Simulator](https://carla.org/)
- [VAD Framework](https://github.com/hustvl/VAD)

## 🤝 サポート

問題が発生した場合：

1. CloudFormationイベントログを確認
2. CloudWatch Logsでエラー詳細を確認
3. GitHubでIssueを作成

## 📝 ライセンス

MIT License
