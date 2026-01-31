# GitHubへの手動プッシュ手順

このプロジェクトは完全にセットアップされましたが、ネットワーク制限により自動プッシュができませんでした。
以下の手順で手動でGitHubリポジトリにプッシュしてください。

## オプション1: ローカルマシンから直接プッシュ

1. このディレクトリをローカルマシンにコピー:
```bash
# アーカイブをダウンロード
scp user@host:/home/claude/carla-vad-agent.tar.gz .

# 展開
tar -xzf carla-vad-agent.tar.gz
cd carla-vad-agent
```

2. GitHubにプッシュ:
```bash
# リモートリポジトリを確認
git remote -v

# プッシュ
git push -u origin main
```

## オプション2: GitHub CLIを使用

```bash
cd carla-vad-agent

# GitHub CLIで認証
gh auth login

# リポジトリにプッシュ
git push -u origin main
```

## オプション3: GitHub Personal Access Tokenを使用

```bash
cd carla-vad-agent

# トークンを環境変数に設定
export GITHUB_TOKEN="your_token_here"

# プッシュ（トークンを使用）
git push https://TakuyaSuenaga:${GITHUB_TOKEN}@github.com/TakuyaSuenaga/carla-vad-agent.git main
```

## 確認

プッシュ後、以下で確認できます:
https://github.com/TakuyaSuenaga/carla-vad-agent

## 次のステップ

1. `.env.example`を`.env`にコピーして環境変数を設定
2. GitHubリポジトリのSecretsに以下を追加:
   - `ANTHROPIC_API_KEY`
   - `GITHUB_TOKEN` (GitHub Actions用)
   - `AWS_REGION`
   - `CARLA_AGENT_ID`
   - `CARLA_AGENT_ALIAS_ID`
   - `REMOTE_MCP_URL`
   - `MCP_API_TOKEN`

3. Terraformでインフラをデプロイ:
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

4. EC2にCARLA Agent Coreをデプロイ:
```bash
./scripts/deploy.sh <ec2-ip> <ssh-key-path>
```
