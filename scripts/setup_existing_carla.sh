#!/bin/bash
#
# 既存CARLA+VAD環境をAgent Core化するセットアップスクリプト
#
# 前提条件:
# - GPU付きEC2インスタンス
# - CARLAとVADが既にインストール済み
# - Python 3.8以上
# - Docker（オプション）
#
# 使い方:
#   bash setup_existing_carla.sh
#

set -e

# 色設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 設定
INSTALL_DIR="${INSTALL_DIR:-/opt/carla-vad-agent}"
CARLA_HOST="${CARLA_HOST:-localhost}"
CARLA_PORT="${CARLA_PORT:-2000}"
MCP_PORT="${MCP_PORT:-8000}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CARLA Agent Core セットアップ${NC}"
echo -e "${BLUE}既存環境用${NC}"
echo -e "${BLUE}========================================${NC}"

# ===============================
# 環境チェック
# ===============================

echo -e "\n${GREEN}[1/7] 環境チェック...${NC}"

# Pythonバージョンチェック
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 がインストールされていません${NC}"
    exit 1
fi

PYTHON_VERSION=$(python3 --version | awk '{print $2}')
echo -e "${GREEN}✓ Python ${PYTHON_VERSION} 検出${NC}"

# pipチェック
if ! command -v pip3 &> /dev/null; then
    echo -e "${YELLOW}Warning: pip3 がインストールされていません。インストールします...${NC}"
    sudo apt-get update
    sudo apt-get install -y python3-pip
fi

# CARLAチェック
if pgrep -x "CarlaUE4" > /dev/null; then
    echo -e "${GREEN}✓ CARLA が実行中です${NC}"
    CARLA_RUNNING=true
else
    echo -e "${YELLOW}⚠ CARLA が実行されていません（後で起動してください）${NC}"
    CARLA_RUNNING=false
fi

# GPUチェック
if command -v nvidia-smi &> /dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    echo -e "${GREEN}✓ GPU 検出: ${GPU_INFO}${NC}"
else
    echo -e "${YELLOW}⚠ nvidia-smi が見つかりません（GPUドライバーを確認してください）${NC}"
fi

# ===============================
# リポジトリクローン
# ===============================

echo -e "\n${GREEN}[2/7] リポジトリのセットアップ...${NC}"

if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}⚠ $INSTALL_DIR は既に存在します${NC}"
    read -p "上書きしますか? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo rm -rf "$INSTALL_DIR"
    else
        echo -e "${YELLOW}既存ディレクトリを使用します${NC}"
    fi
fi

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${BLUE}リポジトリをクローンします...${NC}"
    sudo mkdir -p $(dirname "$INSTALL_DIR")

    # GitHubリポジトリURL（必要に応じて変更）
    REPO_URL="${REPO_URL:-https://github.com/YOUR_USERNAME/carla-vad-agent.git}"

    if [[ "$REPO_URL" == *"YOUR_USERNAME"* ]]; then
        echo -e "${YELLOW}⚠ リポジトリURLが設定されていません${NC}"
        read -p "GitHubリポジトリURL（またはスキップするにはEnter）: " INPUT_REPO_URL

        if [ -n "$INPUT_REPO_URL" ]; then
            REPO_URL="$INPUT_REPO_URL"
            sudo git clone "$REPO_URL" "$INSTALL_DIR"
        else
            echo -e "${YELLOW}手動でファイルをコピーしてください${NC}"
            sudo mkdir -p "$INSTALL_DIR"
            sudo cp -r "$(pwd)"/* "$INSTALL_DIR/" 2>/dev/null || true
        fi
    else
        sudo git clone "$REPO_URL" "$INSTALL_DIR"
    fi
fi

cd "$INSTALL_DIR"
echo -e "${GREEN}✓ インストールディレクトリ: $INSTALL_DIR${NC}"

# ===============================
# Python依存関係のインストール
# ===============================

echo -e "\n${GREEN}[3/7] Python依存関係のインストール...${NC}"

# MCPサーバー用
echo -e "${BLUE}MCP関連パッケージをインストール...${NC}"
pip3 install --user mcp fastmcp aiohttp || {
    echo -e "${YELLOW}一部のパッケージインストールに失敗しました。続行します...${NC}"
}

# CARLA Python API
echo -e "${BLUE}CARLA Python APIをインストール...${NC}"
pip3 install --user carla || {
    echo -e "${YELLOW}CARLA Python APIのインストールに失敗しました${NC}"
    echo -e "${YELLOW}手動でインストールが必要な場合があります${NC}"
}

# AWS SDK
echo -e "${BLUE}AWS SDKをインストール...${NC}"
pip3 install --user boto3

echo -e "${GREEN}✓ 依存関係のインストール完了${NC}"

# ===============================
# 設定ファイルの作成
# ===============================

echo -e "\n${GREEN}[4/7] 設定ファイルの作成...${NC}"

# .env ファイル作成
if [ ! -f "$INSTALL_DIR/.env" ]; then
    cat > "$INSTALL_DIR/.env" <<EOF
# CARLA設定
CARLA_HOST=$CARLA_HOST
CARLA_PORT=$CARLA_PORT

# MCP設定
MCP_PORT=$MCP_PORT

# AWS設定（後で設定してください）
AWS_REGION=us-east-1
CARLA_AGENT_ID=your-bedrock-agent-id
CARLA_AGENT_ALIAS_ID=your-agent-alias-id

# Anthropic API Key（オプション）
ANTHROPIC_API_KEY=your-api-key
EOF
    echo -e "${GREEN}✓ .env ファイル作成: $INSTALL_DIR/.env${NC}"
    echo -e "${YELLOW}⚠ .env ファイルを編集してAWS設定を追加してください${NC}"
else
    echo -e "${YELLOW}⚠ .env ファイルは既に存在します${NC}"
fi

# ===============================
# systemdサービスの作成
# ===============================

echo -e "\n${GREEN}[5/7] systemdサービスの作成...${NC}"

# ローカルMCPサーバー用サービス
sudo tee /etc/systemd/system/carla-mcp.service > /dev/null <<EOF
[Unit]
Description=CARLA Local MCP Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR/mcp-servers/carla_local
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=/usr/bin/python3 $INSTALL_DIR/mcp-servers/carla_local/mcp_carla_server.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Agent Coreサービス
sudo tee /etc/systemd/system/carla-agentcore.service > /dev/null <<EOF
[Unit]
Description=CARLA Agent Core
After=network.target carla-mcp.service
Wants=carla-mcp.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR/agent-core
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=/usr/bin/python3 $INSTALL_DIR/agent-core/start_agentcore.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# systemdをリロード
sudo systemctl daemon-reload

echo -e "${GREEN}✓ systemdサービス作成完了${NC}"

# ===============================
# ファイアウォール設定
# ===============================

echo -e "\n${GREEN}[6/7] ファイアウォール設定（オプション）...${NC}"

if command -v ufw &> /dev/null; then
    echo -e "${BLUE}UFWが検出されました。ポート$MCP_PORTを開きますか?${NC}"
    read -p "開く場合は 'y' を入力: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo ufw allow $MCP_PORT/tcp
        echo -e "${GREEN}✓ ポート $MCP_PORT を開きました${NC}"
    fi
else
    echo -e "${YELLOW}⚠ UFWが見つかりません。手動でポート$MCP_PORTを開いてください${NC}"
fi

# ===============================
# サービス起動
# ===============================

echo -e "\n${GREEN}[7/7] サービスの起動...${NC}"

read -p "サービスを今すぐ起動しますか? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}MCPサーバーを起動...${NC}"
    sudo systemctl enable carla-mcp
    sudo systemctl start carla-mcp

    echo -e "${BLUE}Agent Coreを起動...${NC}"
    sudo systemctl enable carla-agentcore
    sudo systemctl start carla-agentcore

    sleep 3

    # サービス状態確認
    if systemctl is-active --quiet carla-mcp; then
        echo -e "${GREEN}✓ CARLA MCP サーバー: 起動中${NC}"
    else
        echo -e "${RED}✗ CARLA MCP サーバー: 起動失敗${NC}"
        echo -e "${YELLOW}ログ確認: sudo journalctl -u carla-mcp -n 50${NC}"
    fi

    if systemctl is-active --quiet carla-agentcore; then
        echo -e "${GREEN}✓ CARLA Agent Core: 起動中${NC}"
    else
        echo -e "${RED}✗ CARLA Agent Core: 起動失敗${NC}"
        echo -e "${YELLOW}ログ確認: sudo journalctl -u carla-agentcore -n 50${NC}"
    fi
else
    echo -e "${YELLOW}後で起動する場合:${NC}"
    echo -e "  sudo systemctl enable carla-mcp"
    echo -e "  sudo systemctl start carla-mcp"
    echo -e "  sudo systemctl enable carla-agentcore"
    echo -e "  sudo systemctl start carla-agentcore"
fi

# ===============================
# 完了メッセージ
# ===============================

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}セットアップ完了！${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "\n${BLUE}次のステップ:${NC}"
echo -e "1. ${YELLOW}.env ファイルを編集${NC}"
echo -e "   vi $INSTALL_DIR/.env"
echo -e ""
echo -e "2. ${YELLOW}ヘルスチェック確認${NC}"
echo -e "   curl http://localhost:$MCP_PORT/health"
echo -e ""
echo -e "3. ${YELLOW}AWS側の設定${NC}"
echo -e "   - Lambda関数の作成（cloudformation/lambda-code/ を使用）"
echo -e "   - Bedrock Agentの作成"
echo -e "   - セキュリティグループでポート$MCP_PORTを開放"
echo -e ""
echo -e "4. ${YELLOW}サービス管理コマンド${NC}"
echo -e "   状態確認: sudo systemctl status carla-mcp"
echo -e "   再起動:   sudo systemctl restart carla-mcp"
echo -e "   ログ:     sudo journalctl -u carla-mcp -f"
echo -e ""
echo -e "5. ${YELLOW}AWS設定ヘルパースクリプト${NC}"
echo -e "   bash $INSTALL_DIR/scripts/configure_aws.sh"
echo -e ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}詳細なドキュメント:${NC}"
echo -e "  - cloudformation/README.md"
echo -e "  - scripts/EXISTING_ENVIRONMENT.md"
echo -e "${GREEN}========================================${NC}"
