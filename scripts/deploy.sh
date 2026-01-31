#!/bin/bash
# deploy.sh
# CARLA Agent CoreをEC2にデプロイするスクリプト

set -e

# 引数チェック
if [ -z "$1" ]; then
    echo "Usage: $0 <ec2-instance-ip> [ssh-key-path]"
    echo "Example: $0 54.123.45.67 ~/.ssh/carla-ec2.pem"
    exit 1
fi

EC2_IP=$1
SSH_KEY=${2:-~/.ssh/id_rsa}
SSH_USER=${SSH_USER:-ubuntu}

echo "========================================="
echo "CARLA Agent Core Deployment"
echo "========================================="
echo "Target: $SSH_USER@$EC2_IP"
echo "SSH Key: $SSH_KEY"
echo ""

# SSH接続テスト
echo "[1/5] Testing SSH connection..."
ssh -i $SSH_KEY -o StrictHostKeyChecking=no $SSH_USER@$EC2_IP "echo 'SSH connection successful'"

# リポジトリの同期
echo "[2/5] Syncing repository to EC2..."
rsync -avz --exclude '.git' --exclude 'venv' --exclude '__pycache__' \
    -e "ssh -i $SSH_KEY" \
    . $SSH_USER@$EC2_IP:~/carla-vad-agent/

# 環境変数ファイルの転送
echo "[3/5] Transferring environment variables..."
if [ -f ".env" ]; then
    scp -i $SSH_KEY .env $SSH_USER@$EC2_IP:~/carla-vad-agent/.env
else
    echo "WARNING: .env file not found. Please create it manually on EC2."
fi

# セットアップスクリプト実行
echo "[4/5] Running setup script on EC2..."
ssh -i $SSH_KEY $SSH_USER@$EC2_IP << 'EOF'
    cd ~/carla-vad-agent
    chmod +x scripts/setup_ec2.sh
    
    # 環境変数を読み込んでセットアップ実行
    if [ -f .env ]; then
        export $(cat .env | xargs)
    fi
    
    ./scripts/setup_ec2.sh
EOF

# Dockerビルドと起動
echo "[5/5] Building and starting Docker containers..."
ssh -i $SSH_KEY $SSH_USER@$EC2_IP << 'EOF'
    cd ~/carla-vad-agent/docker
    
    # 既存コンテナを停止
    docker-compose down || true
    
    # イメージビルド
    docker-compose build
    
    # コンテナ起動
    docker-compose up -d
    
    # 起動待機
    sleep 10
    
    # 状態確認
    docker-compose ps
    
    echo ""
    echo "Checking CARLA server logs:"
    docker-compose logs --tail=20 carla-server
    
    echo ""
    echo "Checking Agent Core logs:"
    docker-compose logs --tail=20 carla-agentcore
EOF

echo ""
echo "========================================="
echo "Deployment completed!"
echo "========================================="
echo ""
echo "To check logs:"
echo "  ssh -i $SSH_KEY $SSH_USER@$EC2_IP 'cd ~/carla-vad-agent/docker && docker-compose logs -f'"
echo ""
echo "To stop:"
echo "  ssh -i $SSH_KEY $SSH_USER@$EC2_IP 'cd ~/carla-vad-agent/docker && docker-compose down'"
echo ""
echo "To restart:"
echo "  ssh -i $SSH_KEY $SSH_USER@$EC2_IP 'cd ~/carla-vad-agent/docker && docker-compose restart'"
echo ""
