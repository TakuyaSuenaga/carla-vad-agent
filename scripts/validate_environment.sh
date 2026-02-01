#!/bin/bash
#
# CARLA Agent Core 環境検証スクリプト
#
# セットアップが正しく完了したか確認します
#

set -e

# 色設定
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# カウンター
PASSED=0
FAILED=0
WARNINGS=0

# テスト関数
test_check() {
    local test_name="$1"
    local test_command="$2"
    local required="${3:-true}"

    echo -n "  [$test_name] ... "

    if eval "$test_command" &> /dev/null; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((PASSED++))
        return 0
    else
        if [ "$required" = "true" ]; then
            echo -e "${RED}✗ FAIL${NC}"
            ((FAILED++))
        else
            echo -e "${YELLOW}⚠ WARNING${NC}"
            ((WARNINGS++))
        fi
        return 1
    fi
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}CARLA Agent Core 環境検証${NC}"
echo -e "${BLUE}========================================${NC}"

# ===============================
# 1. システム要件チェック
# ===============================

echo -e "\n${GREEN}[1] システム要件${NC}"

test_check "Python 3.8+" "python3 -c 'import sys; assert sys.version_info >= (3, 8)'" true
test_check "pip3" "command -v pip3" true
test_check "git" "command -v git" false
test_check "curl" "command -v curl" true

# ===============================
# 2. GPU/ドライバーチェック
# ===============================

echo -e "\n${GREEN}[2] GPU/ドライバー${NC}"

test_check "NVIDIA Driver" "command -v nvidia-smi" true

if command -v nvidia-smi &> /dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    echo -e "    ${BLUE}検出されたGPU: $GPU_NAME${NC}"

    test_check "CUDA" "nvidia-smi | grep -q CUDA" true
    test_check "GPU Memory > 8GB" "nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{if(\$1>8000) exit 0; else exit 1}'" false
fi

test_check "Docker" "command -v docker" false
if command -v docker &> /dev/null; then
    test_check "NVIDIA Docker Runtime" "docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi" false
fi

# ===============================
# 3. CARLA環境チェック
# ===============================

echo -e "\n${GREEN}[3] CARLA環境${NC}"

test_check "CARLA プロセス" "pgrep -x CarlaUE4" false

if ! pgrep -x "CarlaUE4" > /dev/null; then
    echo -e "    ${YELLOW}⚠ CARLAが起動していません${NC}"
    echo -e "    ${YELLOW}  起動方法: docker run --runtime=nvidia --net=host carlasim/carla:0.9.15${NC}"
else
    echo -e "    ${BLUE}CARLAプロセスID: $(pgrep -x CarlaUE4)${NC}"
    test_check "CARLA ポート2000" "timeout 2 bash -c '</dev/tcp/localhost/2000'" true
fi

test_check "CARLA Python API" "python3 -c 'import carla'" true

# ===============================
# 4. Python依存関係チェック
# ===============================

echo -e "\n${GREEN}[4] Python依存関係${NC}"

test_check "mcp" "python3 -c 'import mcp'" true
test_check "fastmcp" "python3 -c 'from mcp.server.fastmcp import FastMCP'" true
test_check "aiohttp" "python3 -c 'import aiohttp'" true
test_check "boto3" "python3 -c 'import boto3'" true
test_check "carla (Python)" "python3 -c 'import carla'" true

# ===============================
# 5. インストールディレクトリチェック
# ===============================

echo -e "\n${GREEN}[5] インストールディレクトリ${NC}"

INSTALL_DIR="${INSTALL_DIR:-/opt/carla-vad-agent}"

test_check "インストールディレクトリ" "[ -d '$INSTALL_DIR' ]" true
test_check "mcp-servers/" "[ -d '$INSTALL_DIR/mcp-servers/carla_local' ]" true
test_check "agent-core/" "[ -d '$INSTALL_DIR/agent-core' ]" true
test_check "cloudformation/" "[ -d '$INSTALL_DIR/cloudformation' ]" true

if [ -d "$INSTALL_DIR" ]; then
    test_check ".env ファイル" "[ -f '$INSTALL_DIR/.env' ]" true
    test_check "mcp_carla_server.py" "[ -f '$INSTALL_DIR/mcp-servers/carla_local/mcp_carla_server.py' ]" true
    test_check "start_agentcore.py" "[ -f '$INSTALL_DIR/agent-core/start_agentcore.py' ]" true
fi

# ===============================
# 6. systemdサービスチェック
# ===============================

echo -e "\n${GREEN}[6] systemdサービス${NC}"

test_check "carla-mcp.service" "systemctl list-unit-files | grep -q carla-mcp.service" false
test_check "carla-agentcore.service" "systemctl list-unit-files | grep -q carla-agentcore.service" false

if systemctl list-unit-files | grep -q carla-mcp.service; then
    if systemctl is-active --quiet carla-mcp; then
        echo -e "    ${GREEN}✓ carla-mcp サービス: 実行中${NC}"
        ((PASSED++))
    else
        echo -e "    ${YELLOW}⚠ carla-mcp サービス: 停止中${NC}"
        echo -e "    ${YELLOW}  起動方法: sudo systemctl start carla-mcp${NC}"
        ((WARNINGS++))
    fi
fi

if systemctl list-unit-files | grep -q carla-agentcore.service; then
    if systemctl is-active --quiet carla-agentcore; then
        echo -e "    ${GREEN}✓ carla-agentcore サービス: 実行中${NC}"
        ((PASSED++))
    else
        echo -e "    ${YELLOW}⚠ carla-agentcore サービス: 停止中${NC}"
        echo -e "    ${YELLOW}  起動方法: sudo systemctl start carla-agentcore${NC}"
        ((WARNINGS++))
    fi
fi

# ===============================
# 7. ネットワーク/ポートチェック
# ===============================

echo -e "\n${GREEN}[7] ネットワーク/ポート${NC}"

MCP_PORT="${MCP_PORT:-8000}"

test_check "ポート $MCP_PORT リスニング" "timeout 2 bash -c '</dev/tcp/localhost/$MCP_PORT'" false

if timeout 2 bash -c "</dev/tcp/localhost/$MCP_PORT" 2>/dev/null; then
    echo -e "    ${GREEN}✓ ヘルスチェックエンドポイントが利用可能${NC}"

    if command -v curl &> /dev/null; then
        HEALTH_RESPONSE=$(curl -s http://localhost:$MCP_PORT/health || echo "")
        if [ -n "$HEALTH_RESPONSE" ]; then
            echo -e "    ${BLUE}レスポンス: $HEALTH_RESPONSE${NC}"
        fi
    fi
fi

# ===============================
# 8. AWS設定チェック
# ===============================

echo -e "\n${GREEN}[8] AWS設定（オプション）${NC}"

if [ -f "$INSTALL_DIR/.env" ]; then
    source "$INSTALL_DIR/.env" 2>/dev/null || true

    if [ -n "$AWS_REGION" ] && [ "$AWS_REGION" != "us-east-1" ]; then
        echo -e "    ${BLUE}AWS リージョン: $AWS_REGION${NC}"
    fi

    if [ -n "$CARLA_AGENT_ID" ] && [ "$CARLA_AGENT_ID" != "your-bedrock-agent-id" ]; then
        echo -e "    ${GREEN}✓ Bedrock Agent ID 設定済み${NC}"
        ((PASSED++))
    else
        echo -e "    ${YELLOW}⚠ Bedrock Agent ID 未設定${NC}"
        ((WARNINGS++))
    fi

    if [ -n "$CARLA_AGENT_ALIAS_ID" ] && [ "$CARLA_AGENT_ALIAS_ID" != "your-agent-alias-id" ]; then
        echo -e "    ${GREEN}✓ Bedrock Agent Alias ID 設定済み${NC}"
        ((PASSED++))
    else
        echo -e "    ${YELLOW}⚠ Bedrock Agent Alias ID 未設定${NC}"
        ((WARNINGS++))
    fi
fi

test_check "AWS CLI" "command -v aws" false

if command -v aws &> /dev/null; then
    test_check "AWS認証情報" "aws sts get-caller-identity" false
fi

# ===============================
# 結果サマリー
# ===============================

echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}検証結果サマリー${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "${GREEN}成功: $PASSED${NC}"
echo -e "${YELLOW}警告: $WARNINGS${NC}"
echo -e "${RED}失敗: $FAILED${NC}"

echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ 環境は正常です！${NC}"
    EXIT_CODE=0
elif [ $FAILED -le 3 ]; then
    echo -e "${YELLOW}⚠ 一部のチェックに失敗しましたが、基本的な動作は可能です${NC}"
    echo -e "${YELLOW}  詳細を確認して、必要に応じて修正してください${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ 環境に重大な問題があります${NC}"
    echo -e "${RED}  セットアップスクリプトを再実行してください${NC}"
    EXIT_CODE=1
fi

echo ""
echo -e "${BLUE}次のステップ:${NC}"

if [ $FAILED -gt 0 ] || [ $WARNINGS -gt 0 ]; then
    echo -e "1. ${YELLOW}問題を修正${NC}"
    if ! pgrep -x "CarlaUE4" > /dev/null; then
        echo -e "   - CARLAを起動: docker run --runtime=nvidia --net=host carlasim/carla:0.9.15"
    fi
    if ! systemctl is-active --quiet carla-mcp 2>/dev/null; then
        echo -e "   - MCPサーバーを起動: sudo systemctl start carla-mcp"
    fi
fi

echo -e "2. ${YELLOW}AWS側の設定${NC}"
echo -e "   bash $INSTALL_DIR/scripts/configure_aws.sh"
echo -e ""
echo -e "3. ${YELLOW}テスト実行${NC}"
echo -e "   curl http://localhost:$MCP_PORT/health"
echo ""

exit $EXIT_CODE
