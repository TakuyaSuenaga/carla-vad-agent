import boto3
import time
from typing import Optional
from mcp.server.fastmcp import FastMCP

# FastMCPインスタンス
mcp = FastMCP("EC2-SSM-Agent-Manager")

# AWSクライアントの設定（リージョンは適宜変更してください）
REGION = "ap-northeast-1"
ec2_client = boto3.client("ec2", region_name=REGION)
ssm_client = boto3.client("ssm", region_name=REGION)

# 設定：対象のインスタンスID（固定または引数で渡す）
# 今回は汎用性を高めるため、引数で受け取る形にします。

@mcp.tool()
def manage_instance_power(instance_id: str, action: str) -> str:
    """
    EC2インスタンスの起動(start)または停止(stop)を管理します。
    """
    if action == "start":
        ec2_client.start_instances(InstanceIds=[instance_id])
        # 起動完了まで待機
        waiter = ec2_client.get_waiter('instance_running')
        waiter.wait(InstanceIds=[instance_id])
        # SSM Agentが通信可能になるまで少し猶予を持たせる
        time.sleep(10)
        return f"Instance {instance_id} is now running and ready."
    elif action == "stop":
        ec2_client.stop_instances(InstanceIds=[instance_id])
        return f"Instance {instance_id} stopping request sent."
    return "Invalid action. Use 'start' or 'stop'."

@mcp.tool()
def execute_ssm_command(instance_id: str, command: str) -> dict:
    """
    SSM経由でEC2上のDockerコンテナ内でコマンドを実行します。
    長時間タスクを考慮し、CommandIdを即座に返します。
    """
    # Dockerコンテナ内で実行するようにラップ（VAD/ScenarioRunner想定）
    docker_wrapped_command = f"docker exec -i test_bench bash -c '{command}'"
    
    try:
        response = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={'commands': [docker_wrapped_command]},
            TimeoutSeconds=28800 # 8時間まで許容
        )
        command_id = response['Command']['CommandId']
        return {
            "status": "Accepted",
            "command_id": command_id,
            "message": "Task started in background. Use check_execution_status to monitor."
        }
    except Exception as e:
        return {"status": "Error", "message": str(e)}

@mcp.tool()
def check_execution_status(instance_id: str, command_id: str) -> dict:
    """
    SSM Commandの進捗とログを確認します。
    """
    try:
        output = ssm_client.get_command_invocation(
            CommandId=command_id,
            InstanceId=instance_id
        )
        
        return {
            "status": output['Status'], # Success, InProgress, Failed等
            "is_finished": output['Status'] in ['Success', 'Failed', 'Cancelled', 'TimedOut'],
            "stdout": output['StandardOutputContent'][-2000:], # 最新2000文字
            "stderr": output['StandardErrorContent']
        }
    except ssm_client.exceptions.InvocationDoesNotExist:
        return {"status": "Waiting", "message": "Command output not yet available."}

if __name__ == "__main__":
    mcp.run()