#!/bin/bash
#
# AWS側のリソースを設定するヘルパースクリプト
#
# 既存CARLA+VAD環境用
# CloudFormationを使わずに、AWS CLIで直接リソースを作成します
#
# 前提条件:
# - AWS CLI インストール済み（aws configure 実行済み）
# - 既存のVPC、サブネット、セキュリティグループ
# - EC2インスタンスのプライベートIP
#

set -e

# 色設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CARLA Agent Core AWS設定${NC}"
echo -e "${BLUE}既存環境用${NC}"
echo -e "${BLUE}========================================${NC}"

# ===============================
# 前提条件チェック
# ===============================

echo -e "\n${GREEN}[1/6] 前提条件チェック...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI がインストールされていません${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: jq がインストールされていません（オプション）${NC}"
    echo -e "${YELLOW}  インストール: sudo apt-get install jq (Linux) または brew install jq (Mac)${NC}"
fi

# AWS認証情報チェック
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS認証情報が設定されていません${NC}"
    echo -e "${YELLOW}aws configure を実行してください${NC}"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}✓ AWS アカウント: $ACCOUNT_ID${NC}"

# ===============================
# 設定値の入力
# ===============================

echo -e "\n${GREEN}[2/6] 設定値の入力...${NC}"

read -p "AWS リージョン (default: us-east-1): " AWS_REGION
AWS_REGION=${AWS_REGION:-us-east-1}

read -p "プロジェクト名 (default: carla-vad): " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-carla-vad}

echo -e "${BLUE}既存のEC2インスタンス情報を入力してください${NC}"
read -p "EC2 インスタンスID: " EC2_INSTANCE_ID

if [ -z "$EC2_INSTANCE_ID" ]; then
    echo -e "${RED}Error: EC2インスタンスIDは必須です${NC}"
    exit 1
fi

# EC2情報を取得
EC2_INFO=$(aws ec2 describe-instances \
    --instance-ids "$EC2_INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0]' \
    2>/dev/null || echo "")

if [ -z "$EC2_INFO" ]; then
    echo -e "${RED}Error: EC2インスタンス $EC2_INSTANCE_ID が見つかりません${NC}"
    exit 1
fi

EC2_PRIVATE_IP=$(echo "$EC2_INFO" | jq -r '.PrivateIpAddress // empty' 2>/dev/null || \
    aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

VPC_ID=$(echo "$EC2_INFO" | jq -r '.VpcId // empty' 2>/dev/null || \
    aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].VpcId' --output text)

SUBNET_ID=$(echo "$EC2_INFO" | jq -r '.SubnetId // empty' 2>/dev/null || \
    aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].SubnetId' --output text)

echo -e "${GREEN}✓ EC2 プライベートIP: $EC2_PRIVATE_IP${NC}"
echo -e "${GREEN}✓ VPC ID: $VPC_ID${NC}"
echo -e "${GREEN}✓ サブネットID: $SUBNET_ID${NC}"

# ===============================
# IAMロールの作成
# ===============================

echo -e "\n${GREEN}[3/6] IAMロールの作成...${NC}"

LAMBDA_ROLE_NAME="${PROJECT_NAME}-lambda-role"
BEDROCK_ROLE_NAME="${PROJECT_NAME}-bedrock-role"

# Lambda用IAMロール
echo -e "${BLUE}Lambda用IAMロールを作成...${NC}"

LAMBDA_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

LAMBDA_ROLE_ARN=$(aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "$LAMBDA_TRUST_POLICY" \
    --query 'Role.Arn' \
    --output text 2>/dev/null || \
    aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)

echo -e "${GREEN}✓ Lambda IAMロール: $LAMBDA_ROLE_ARN${NC}"

# Lambda用ポリシーをアタッチ
aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole \
    2>/dev/null || true

# Bedrock Agent用IAMロール
echo -e "${BLUE}Bedrock Agent用IAMロールを作成...${NC}"

BEDROCK_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "bedrock.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

BEDROCK_ROLE_ARN=$(aws iam create-role \
    --role-name "$BEDROCK_ROLE_NAME" \
    --assume-role-policy-document "$BEDROCK_TRUST_POLICY" \
    --query 'Role.Arn' \
    --output text 2>/dev/null || \
    aws iam get-role --role-name "$BEDROCK_ROLE_NAME" --query 'Role.Arn' --output text)

echo -e "${GREEN}✓ Bedrock IAMロール: $BEDROCK_ROLE_ARN${NC}"

# IAMロールが反映されるまで待機
echo -e "${YELLOW}IAMロールの反映を待っています（10秒）...${NC}"
sleep 10

# ===============================
# Lambda関数の作成
# ===============================

echo -e "\n${GREEN}[4/6] Lambda関数の作成...${NC}"

# Lambda パッケージをビルド
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="$SCRIPT_DIR/../cloudformation/lambda-code"

if [ ! -f "$LAMBDA_DIR/lambda-mcp-bridge.zip" ]; then
    echo -e "${BLUE}Lambda パッケージをビルド...${NC}"
    cd "$LAMBDA_DIR"
    bash build.sh
    cd -
fi

if [ ! -f "$LAMBDA_DIR/lambda-mcp-bridge.zip" ]; then
    echo -e "${RED}Error: Lambda パッケージが見つかりません${NC}"
    exit 1
fi

# セキュリティグループの作成（Lambda用）
LAMBDA_SG_NAME="${PROJECT_NAME}-lambda-sg"
LAMBDA_SG_ID=$(aws ec2 create-security-group \
    --group-name "$LAMBDA_SG_NAME" \
    --description "Security group for CARLA Lambda function" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$LAMBDA_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)

echo -e "${GREEN}✓ Lambda セキュリティグループ: $LAMBDA_SG_ID${NC}"

# Lambda関数を作成
LAMBDA_FUNCTION_NAME="${PROJECT_NAME}-mcp-bridge"

echo -e "${BLUE}Lambda関数を作成中...${NC}"

LAMBDA_ARN=$(aws lambda create-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --runtime python3.11 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler index.lambda_handler \
    --timeout 300 \
    --memory-size 512 \
    --zip-file "fileb://$LAMBDA_DIR/lambda-mcp-bridge.zip" \
    --environment "Variables={CARLA_EC2_ENDPOINT=http://${EC2_PRIVATE_IP}:8000}" \
    --vpc-config "SubnetIds=$SUBNET_ID,SecurityGroupIds=$LAMBDA_SG_ID" \
    --region "$AWS_REGION" \
    --query 'FunctionArn' \
    --output text 2>/dev/null || \
    aws lambda get-function \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" \
        --query 'Configuration.FunctionArn' \
        --output text)

echo -e "${GREEN}✓ Lambda関数: $LAMBDA_ARN${NC}"

# ===============================
# Bedrock Agentの作成
# ===============================

echo -e "\n${GREEN}[5/6] Bedrock Agentの作成...${NC}"

echo -e "${YELLOW}注意: Bedrock Agentの作成はAWS CLIで完全にはサポートされていません${NC}"
echo -e "${YELLOW}AWSコンソールで以下の手順で作成してください:${NC}"
echo ""
echo -e "1. ${BLUE}AWS Console > Bedrock > Agents${NC}"
echo -e "2. ${BLUE}Create Agent${NC}"
echo -e "3. ${BLUE}設定:${NC}"
echo -e "   - Agent name: ${PROJECT_NAME}-agent"
echo -e "   - Model: Claude Sonnet 4.5"
echo -e "   - Role: $BEDROCK_ROLE_ARN"
echo -e "   - Instruction: (cloudformation/carla-bedrock-agent.yaml を参照)"
echo -e "4. ${BLUE}Action Group を追加:${NC}"
echo -e "   - Name: carla-control"
echo -e "   - Lambda: $LAMBDA_ARN"
echo -e "   - OpenAPI Schema: cloudformation/carla-openapi-schema.json をアップロード"
echo -e "5. ${BLUE}Prepare Agent${NC}"
echo -e "6. ${BLUE}Create Alias (production)${NC}"
echo ""

read -p "Bedrock Agentを作成したら、Agent IDを入力してください: " BEDROCK_AGENT_ID
read -p "Agent Alias IDを入力してください: " BEDROCK_AGENT_ALIAS_ID

# ===============================
# 設定ファイルの更新
# ===============================

echo -e "\n${GREEN}[6/6] 設定ファイルの更新...${NC}"

# .env ファイルを更新
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
    # 既存の.envファイルを更新
    sed -i.bak "s/AWS_REGION=.*/AWS_REGION=$AWS_REGION/" "$ENV_FILE"
    sed -i.bak "s/CARLA_AGENT_ID=.*/CARLA_AGENT_ID=$BEDROCK_AGENT_ID/" "$ENV_FILE"
    sed -i.bak "s/CARLA_AGENT_ALIAS_ID=.*/CARLA_AGENT_ALIAS_ID=$BEDROCK_AGENT_ALIAS_ID/" "$ENV_FILE"
    echo -e "${GREEN}✓ .env ファイル更新: $ENV_FILE${NC}"
else
    echo -e "${YELLOW}⚠ .env ファイルが見つかりません${NC}"
fi

# 設定サマリーを出力
CONFIG_FILE="$SCRIPT_DIR/../aws-config.json"
cat > "$CONFIG_FILE" <<EOF
{
  "project_name": "$PROJECT_NAME",
  "region": "$AWS_REGION",
  "account_id": "$ACCOUNT_ID",
  "ec2": {
    "instance_id": "$EC2_INSTANCE_ID",
    "private_ip": "$EC2_PRIVATE_IP",
    "vpc_id": "$VPC_ID",
    "subnet_id": "$SUBNET_ID"
  },
  "lambda": {
    "function_name": "$LAMBDA_FUNCTION_NAME",
    "function_arn": "$LAMBDA_ARN",
    "security_group_id": "$LAMBDA_SG_ID"
  },
  "bedrock": {
    "agent_id": "$BEDROCK_AGENT_ID",
    "agent_alias_id": "$BEDROCK_AGENT_ALIAS_ID",
    "role_arn": "$BEDROCK_ROLE_ARN"
  }
}
EOF

echo -e "${GREEN}✓ 設定保存: $CONFIG_FILE${NC}"

# ===============================
# 完了メッセージ
# ===============================

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}AWS設定完了！${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "\n${BLUE}作成されたリソース:${NC}"
echo -e "  Lambda: $LAMBDA_FUNCTION_NAME"
echo -e "  Bedrock Agent ID: $BEDROCK_AGENT_ID"
echo -e "  Bedrock Agent Alias ID: $BEDROCK_AGENT_ALIAS_ID"
echo ""

echo -e "${BLUE}次のステップ:${NC}"
echo -e "1. ${YELLOW}セキュリティグループの設定${NC}"
echo -e "   EC2のセキュリティグループにポート8000を開放:"
echo -e "   aws ec2 authorize-security-group-ingress \\"
echo -e "     --group-id <EC2-SG-ID> \\"
echo -e "     --protocol tcp --port 8000 \\"
echo -e "     --source-group $LAMBDA_SG_ID"
echo ""
echo -e "2. ${YELLOW}動作確認${NC}"
echo -e "   aws bedrock-agent-runtime invoke-agent \\"
echo -e "     --agent-id $BEDROCK_AGENT_ID \\"
echo -e "     --agent-alias-id $BEDROCK_AGENT_ALIAS_ID \\"
echo -e "     --session-id test \\"
echo -e "     --input-text 'Town05でシミュレーション実行' \\"
echo -e "     output.txt"
echo ""
echo -e "3. ${YELLOW}Claude Code CLIから呼び出し${NC}"
echo -e "   リモートMCPサーバーを設定後、Claude Code CLIで使用可能"
echo ""

echo -e "${GREEN}========================================${NC}"
