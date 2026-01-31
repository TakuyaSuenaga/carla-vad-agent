variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (GPU required)"
  type        = string
  default     = "g5.xlarge"
}

variable "ami_id" {
  description = "AMI ID (AWS Deep Learning AMI recommended)"
  type        = string
  default     = ""  # Set to specific AMI ID or use data source
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"  # SECURITY: Restrict this in production
}

variable "carla_agent_name" {
  description = "Name for the Bedrock Agent"
  type        = string
  default     = "carla-vad-simulation-agent"
}

variable "anthropic_model" {
  description = "Anthropic model ID for Bedrock"
  type        = string
  default     = "anthropic.claude-sonnet-4-5-v2:0"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "CARLA-VAD-Agent"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
