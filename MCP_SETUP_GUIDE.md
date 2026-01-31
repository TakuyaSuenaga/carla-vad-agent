# MCP設定ガイド

このガイドでは、CARLA-VAD AgentでMCPサーバー（GitHub MCPを含む）を正しく設定する方法を説明します。

## 1. 環境変数の準備

まず、`.env`ファイルを作成します：

```bash
cp .env.example .env
```

エディタで`.env`を開き、以下の値を設定します：

```bash
# AWS Configuration
AWS_REGION=us-east-1

# Bedrock Agent Configuration
CARLA_AGENT_ID=your-bedrock-agent-id-here
CARLA_AGENT_ALIAS_ID=your-agent-alias-id-here

# Anthropic API Key
ANTHROPIC_API_KEY=your-anthropic-api-key-here

# GitHub Personal Access Token (for GitHub MCP)
GITHUB_PAT=ghp_your_github_personal_access_token_here

# Remote MCP Configuration
REMOTE_MCP_URL=https://your-mcp-server.example.com/mcp
MCP_API_TOKEN=your-mcp-api-token-here
```

## 2. GitHub MCPサーバーの追加

### 方法A: Claude CLIコマンド（推奨）

この方法は、`.env`ファイルから自動的にトークンを読み取ります：

```bash
claude mcp add-json github '{"type":"http","url":"https://api.githubcopilot.com/mcp","headers":{"Authorization":"Bearer '"$(grep GITHUB_PAT .env | cut -d '=' -f2)"'"}}'
```

**コマンドの動作説明**:
- `$(grep GITHUB_PAT .env | cut -d '=' -f2)`: `.env`ファイルから`GITHUB_PAT`の値を抽出
- シェル展開により、実際のトークン値が`Authorization`ヘッダーに埋め込まれます

### 方法B: 手動設定

1. Claude Code CLIの設定ファイルを編集：

```bash
# 設定ファイルの場所を確認
claude config-path

# 通常は ~/.claude/.mcp.json
nano ~/.claude/.mcp.json
```

2. 以下の内容を追加（既存の`mcpServers`に追加）：

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp",
      "headers": {
        "Authorization": "Bearer ghp_YOUR_ACTUAL_GITHUB_PAT_HERE"
      }
    }
  }
}
```

**注意**: `ghp_YOUR_ACTUAL_GITHUB_PAT_HERE`を実際のGitHub Personal Access Tokenに置き換えてください。

## 3. リモートMCPオーケストレーターの設定

リモートMCPサーバーを使用する場合は、以下を追加：

```bash
# .mcp.json.example を参考に設定
cp .mcp.json.example ~/.claude/.mcp.json

# 環境変数を手動で置き換え
# エディタで ~/.claude/.mcp.json を開き、${REMOTE_MCP_URL} や ${MCP_API_TOKEN} を実際の値に置換
```

または、直接編集：

```json
{
  "mcpServers": {
    "remote-orchestrator": {
      "type": "streamable-http",
      "url": "https://your-actual-mcp-server.example.com/mcp",
      "headers": {
        "Authorization": "Bearer your-actual-mcp-api-token"
      }
    }
  }
}
```

## 4. 設定の確認

MCP設定が正しく追加されたか確認：

```bash
# MCP設定ファイルを表示
cat ~/.claude/.mcp.json

# または、Claude CLIで確認
claude mcp list
```

期待される出力例：
```
Available MCP servers:
- github (http)
- remote-orchestrator (streamable-http)
```

## 5. テスト実行

GitHub MCPが正しく動作するかテスト：

```bash
# GitHubリポジトリ一覧を取得
claude -p "mcp__github__list_repositories ツールを使用して、自分のGitHubリポジトリを一覧表示してください" \
  --allowedTools "mcp__github__list_repositories"
```

CARLA Agent呼び出しとGitHub MCPの組み合わせテスト：

```bash
claude -p "Town05マップでCARLA評価を実行し、結果をGitHub Issueとして作成してください" \
  --allowedTools "mcp__remote-orchestrator__invoke_carla_agent,mcp__github__create_issue"
```

## 6. トラブルシューティング

### GitHub MCP接続エラー

エラー: `401 Unauthorized`

**解決方法**:
1. GitHub PATが正しいか確認
2. PATに必要な権限（`repo`, `write:discussion`など）があるか確認
3. トークンの有効期限が切れていないか確認

```bash
# GitHub PATをテスト
curl -H "Authorization: Bearer $(grep GITHUB_PAT .env | cut -d '=' -f2)" \
  https://api.github.com/user
```

### MCP設定ファイルが見つからない

```bash
# Claude Code CLIの設定ディレクトリを確認
claude config-path

# ディレクトリが存在しない場合は作成
mkdir -p ~/.claude
```

### 環境変数が展開されない

`.mcp.json`ファイル内で`${VARIABLE}`形式を使用している場合、Claude CLIは自動的に環境変数を展開しません。代わりに：

1. 実際の値を直接記載する
2. `claude mcp add-json`コマンドでシェル展開を利用する

## 7. セキュリティのベストプラクティス

### トークンの保護

1. `.env`ファイルは**絶対に**Gitにコミットしない（`.gitignore`に含まれています）
2. `.mcp.json`も`.gitignore`に含まれています
3. GitHub PATは最小限の権限で作成する

### 推奨されるGitHub PAT権限

CARLA-VAD Agentで必要な最小限の権限：

- `repo` (リポジトリへのフルアクセス)
  - プライベートリポジトリにアクセスする場合のみ必要
- `write:discussion` (Discussionの作成)
- `workflow` (GitHub Actions関連、必要に応じて)

### トークンのローテーション

定期的にトークンを更新することを推奨します：

```bash
# 新しいPATを生成後、.env を更新
nano .env

# MCP設定を再追加
claude mcp remove github
claude mcp add-json github '{"type":"http","url":"https://api.githubcopilot.com/mcp","headers":{"Authorization":"Bearer '"$(grep GITHUB_PAT .env | cut -d '=' -f2)"'"}}'
```

## 8. 複数環境での使用

開発環境と本番環境で異なる設定を使用する場合：

```bash
# 開発環境
cp .env.development .env
claude mcp add-json github '...'

# 本番環境
cp .env.production .env
claude mcp add-json github '...'
```

## まとめ

正しいMCP設定手順：

1. ✅ `.env`ファイルに`GITHUB_PAT`を設定
2. ✅ `claude mcp add-json`コマンドでGitHub MCPを追加
3. ✅ 必要に応じてリモートMCPオーケストレーターを設定
4. ✅ `claude mcp list`で確認
5. ✅ テスト実行で動作確認

この手順により、CARLA Agent CoreとGitHub MCPを統合したワークフローが利用可能になります！
