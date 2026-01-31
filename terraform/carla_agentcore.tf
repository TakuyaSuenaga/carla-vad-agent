terraform {
  required_version = ">= 1.6"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = merge(var.tags, {
    Name = "carla-vad-vpc"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = merge(var.tags, {
    Name = "carla-vad-igw"
  })
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  
  tags = merge(var.tags, {
    Name = "carla-vad-public-subnet"
  })
}

# Private Subnet (for Lambda)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 2)
  availability_zone = data.aws_availability_zones.available.names[0]
  
  tags = merge(var.tags, {
    Name = "carla-vad-private-subnet"
  })
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = merge(var.tags, {
    Name = "carla-vad-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group for EC2 (CARLA)
resource "aws_security_group" "carla_ec2" {
  name        = "carla-vad-ec2-sg"
  description = "Security group for CARLA EC2 instance"
  vpc_id      = aws_vpc.main.id
  
  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
    description = "SSH access"
  }
  
  # CARLA RPC
  ingress {
    from_port   = 2000
    to_port     = 2002
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "CARLA RPC ports (internal)"
  }
  
  # Health check
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Health check endpoint"
  }
  
  # Outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = merge(var.tags, {
    Name = "carla-vad-ec2-sg"
  })
}

# Security Group for Lambda
resource "aws_security_group" "lambda" {
  name        = "carla-vad-lambda-sg"
  description = "Security group for Lambda functions"
  vpc_id      = aws_vpc.main.id
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = merge(var.tags, {
    Name = "carla-vad-lambda-sg"
  })
}

# Data source for latest Deep Learning AMI
data "aws_ami" "deep_learning" {
  most_recent = true
  owners      = ["amazon"]
  
  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"]
  }
  
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# EC2 Instance for CARLA
resource "aws_instance" "carla" {
  ami           = var.ami_id != "" ? var.ami_id : data.aws_ami.deep_learning.id
  instance_type = var.instance_type
  key_name      = var.key_name
  
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.carla_ec2.id]
  associate_public_ip_address = true
  
  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }
  
  user_data = <<-EOF
              #!/bin/bash
              echo "CARLA Agent Core EC2 initialized"
              EOF
  
  tags = merge(var.tags, {
    Name = "carla-vad-ec2"
  })
}

# IAM Role for Bedrock Agent
resource "aws_iam_role" "carla_agent" {
  name = "carla-vad-agent-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "bedrock.amazonaws.com"
      }
    }]
  })
  
  tags = var.tags
}

resource "aws_iam_role_policy" "carla_agent" {
  name = "carla-agent-policy"
  role = aws_iam_role.carla_agent.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.anthropic_model}"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.carla_mcp_bridge.arn
      }
    ]
  })
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda" {
  name = "carla-lambda-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
  
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Lambda Function (MCP Bridge)
resource "aws_lambda_function" "carla_mcp_bridge" {
  filename      = "lambda_placeholder.zip"  # Create this file separately
  function_name = "carla-mcp-bridge"
  role          = aws_iam_role.lambda.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.11"
  timeout       = 300
  
  environment {
    variables = {
      CARLA_EC2_ENDPOINT = "http://${aws_instance.carla.private_ip}:8000"
    }
  }
  
  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda.id]
  }
  
  tags = var.tags
}

# Bedrock Agent
resource "aws_bedrockagent_agent" "carla" {
  agent_name              = var.carla_agent_name
  agent_resource_role_arn = aws_iam_role.carla_agent.arn
  foundation_model        = var.anthropic_model
  
  instruction = <<-EOT
    あなたはCARLAシミュレーターとVAD（Vectorized Autonomous Driving）を制御する
    専門エージェントです。以下のツールを使用してシミュレーションを実行します：
    
    - start_carla_scenario: シミュレーション環境の初期化
    - run_vad_inference: VAD推論の実行
    - get_simulation_metrics: 状態確認
    - stop_scenario: クリーンアップ
    
    ユーザーからの指示に基づいて、適切な順序でツールを呼び出し、
    結果を分析してレポートを作成してください。
  EOT
  
  idle_session_ttl_in_seconds = 28800  # 8 hours
  
  tags = var.tags
}

# Note: Bedrock Agent Action Group and OpenAPI schema would be added here
# This requires creating the schema file separately
