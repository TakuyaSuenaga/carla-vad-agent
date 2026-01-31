output "ec2_instance_id" {
  description = "CARLA EC2 instance ID"
  value       = aws_instance.carla.id
}

output "ec2_public_ip" {
  description = "CARLA EC2 public IP address"
  value       = aws_instance.carla.public_ip
}

output "ec2_private_ip" {
  description = "CARLA EC2 private IP address"
  value       = aws_instance.carla.private_ip
}

output "carla_agent_id" {
  description = "Bedrock Agent ID"
  value       = aws_bedrockagent_agent.carla.id
}

output "carla_agent_arn" {
  description = "Bedrock Agent ARN"
  value       = aws_bedrockagent_agent.carla.agent_arn
}

output "lambda_function_name" {
  description = "Lambda function name for MCP bridge"
  value       = aws_lambda_function.carla_mcp_bridge.function_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "ssh_command" {
  description = "SSH command to connect to EC2 instance"
  value       = "ssh -i /path/to/${var.key_name}.pem ubuntu@${aws_instance.carla.public_ip}"
}

output "deployment_commands" {
  description = "Commands to deploy CARLA Agent Core"
  value = <<-EOT
    # Deploy to EC2:
    ./scripts/deploy.sh ${aws_instance.carla.public_ip} /path/to/${var.key_name}.pem
    
    # Set environment variables for Claude Code CLI:
    export CARLA_AGENT_ID="${aws_bedrockagent_agent.carla.id}"
    export CARLA_AGENT_ALIAS_ID="<alias-id-after-creating-alias>"
    export AWS_REGION="${var.aws_region}"
  EOT
}
