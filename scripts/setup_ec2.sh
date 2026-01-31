#!/bin/bash
# setup_ec2.sh
# CARLA Agent Core EC2インスタンスのセットアップスクリプト

set -e

echo "========================================="
echo "CARLA Agent Core EC2 Setup"
echo "========================================="

# システムアップデート
echo "[1/7] Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y

# NVIDIA Driverインストール確認
echo "[2/7] Checking NVIDIA drivers..."
if ! command -v nvidia-smi &> /dev/null; then
    echo "Installing NVIDIA drivers..."
    sudo apt-get install -y nvidia-driver-550
    echo "Please reboot the instance and re-run this script"
    exit 0
fi

nvidia-smi

# Dockerインストール
echo "[3/7] Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
fi

# NVIDIA Container Toolkitインストール
echo "[4/7] Installing NVIDIA Container Toolkit..."
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
    sudo tee /etc/apt/sources.list.d/nvidia-docker.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker

# Docker Composeインストール
echo "[5/7] Installing Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# リポジトリクローン
echo "[6/7] Cloning repository..."
cd ~
if [ ! -d "carla-vad-agent" ]; then
    git clone https://github.com/TakuyaSuenaga/carla-vad-agent.git
fi

cd carla-vad-agent

# 環境変数設定
echo "[7/7] Setting up environment variables..."
cat > .env << EOF
AWS_REGION=${AWS_REGION:-us-east-1}
CARLA_AGENT_ID=${CARLA_AGENT_ID}
CARLA_AGENT_ALIAS_ID=${CARLA_AGENT_ALIAS_ID}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
EOF

echo "========================================="
echo "Setup completed successfully!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. If NVIDIA drivers were just installed, reboot the instance:"
echo "   sudo reboot"
echo ""
echo "2. Build and start CARLA Agent Core:"
echo "   cd ~/carla-vad-agent/docker"
echo "   docker-compose build"
echo "   docker-compose up -d"
echo ""
echo "3. Check status:"
echo "   docker-compose ps"
echo "   docker-compose logs -f carla-agentcore"
echo ""
