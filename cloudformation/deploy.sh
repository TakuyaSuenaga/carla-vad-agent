#!/bin/bash
# Deploy CARLA-VAD Agent using CloudFormation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="${STACK_NAME:-carla-vad-master}"
REGION="${AWS_REGION:-us-east-1}"
PARAMETERS_FILE="${PARAMETERS_FILE:-parameters.json}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}CARLA-VAD Agent CloudFormation Deployment${NC}"
echo -e "${GREEN}========================================${NC}"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not installed${NC}"
    exit 1
fi

# Check if parameters file exists
if [ ! -f "$PARAMETERS_FILE" ]; then
    echo -e "${YELLOW}Warning: $PARAMETERS_FILE not found${NC}"
    echo -e "${YELLOW}Creating from example...${NC}"

    if [ ! -f "parameters.json.example" ]; then
        echo -e "${RED}Error: parameters.json.example not found${NC}"
        exit 1
    fi

    cp parameters.json.example "$PARAMETERS_FILE"
    echo -e "${YELLOW}Please edit $PARAMETERS_FILE with your values${NC}"
    echo -e "${YELLOW}Especially update KeyName parameter!${NC}"
    exit 1
fi

# Validate parameters
echo -e "${GREEN}Validating parameters...${NC}"
KEY_NAME=$(jq -r '.[] | select(.ParameterKey=="KeyName") | .ParameterValue' "$PARAMETERS_FILE")
if [ "$KEY_NAME" == "your-ec2-key-pair-name" ] || [ -z "$KEY_NAME" ]; then
    echo -e "${RED}Error: Please set a valid KeyName in $PARAMETERS_FILE${NC}"
    exit 1
fi

# Build Lambda package if needed
echo -e "${GREEN}Building Lambda deployment package...${NC}"
cd lambda-code
if [ -f "build.sh" ]; then
    bash build.sh

    if [ ! -f "lambda-mcp-bridge.zip" ]; then
        echo -e "${RED}Error: Lambda package build failed${NC}"
        exit 1
    fi

    echo -e "${GREEN}Lambda package built successfully${NC}"
else
    echo -e "${YELLOW}Warning: build.sh not found, skipping Lambda build${NC}"
fi
cd ..

# Option to upload to S3
read -p "Do you want to upload templates and Lambda to S3? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter S3 bucket name: " S3_BUCKET
    read -p "Enter S3 prefix (default: cloudformation/): " S3_PREFIX
    S3_PREFIX=${S3_PREFIX:-cloudformation/}

    echo -e "${GREEN}Uploading templates to s3://${S3_BUCKET}/${S3_PREFIX}${NC}"
    aws s3 cp carla-network.yaml "s3://${S3_BUCKET}/${S3_PREFIX}carla-network.yaml"
    aws s3 cp carla-iam.yaml "s3://${S3_BUCKET}/${S3_PREFIX}carla-iam.yaml"
    aws s3 cp carla-compute.yaml "s3://${S3_BUCKET}/${S3_PREFIX}carla-compute.yaml"
    aws s3 cp carla-lambda.yaml "s3://${S3_BUCKET}/${S3_PREFIX}carla-lambda.yaml"
    aws s3 cp carla-bedrock-agent.yaml "s3://${S3_BUCKET}/${S3_PREFIX}carla-bedrock-agent.yaml"
    aws s3 cp carla-master.yaml "s3://${S3_BUCKET}/${S3_PREFIX}carla-master.yaml"

    if [ -f "lambda-code/lambda-mcp-bridge.zip" ]; then
        echo -e "${GREEN}Uploading Lambda package to s3://${S3_BUCKET}/${NC}"
        aws s3 cp lambda-code/lambda-mcp-bridge.zip "s3://${S3_BUCKET}/lambda-mcp-bridge.zip"
    fi

    # Update parameters file
    jq --arg bucket "$S3_BUCKET" --arg prefix "$S3_PREFIX" \
        'map(if .ParameterKey == "TemplateS3Bucket" then .ParameterValue = $bucket
             elif .ParameterKey == "TemplateS3Prefix" then .ParameterValue = $prefix
             elif .ParameterKey == "LambdaS3Bucket" then .ParameterValue = $bucket
             else . end)' \
        "$PARAMETERS_FILE" > "${PARAMETERS_FILE}.tmp"
    mv "${PARAMETERS_FILE}.tmp" "$PARAMETERS_FILE"
fi

# Validate CloudFormation template
echo -e "${GREEN}Validating CloudFormation template...${NC}"
aws cloudformation validate-template \
    --template-body file://carla-master.yaml \
    --region "$REGION" > /dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Template validation successful${NC}"
else
    echo -e "${RED}Template validation failed${NC}"
    exit 1
fi

# Check if stack exists
STACK_EXISTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" 2>&1 || true)

if echo "$STACK_EXISTS" | grep -q "does not exist"; then
    echo -e "${GREEN}Creating new stack: $STACK_NAME${NC}"
    OPERATION="create-stack"
else
    echo -e "${YELLOW}Stack $STACK_NAME already exists${NC}"
    read -p "Do you want to update it? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Deployment cancelled${NC}"
        exit 0
    fi
    OPERATION="update-stack"
fi

# Deploy stack
echo -e "${GREEN}Deploying stack...${NC}"
if [ "$OPERATION" == "create-stack" ]; then
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://carla-master.yaml \
        --parameters file://"$PARAMETERS_FILE" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
else
    aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://carla-master.yaml \
        --parameters file://"$PARAMETERS_FILE" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" || {
            if echo "$?" | grep -q "No updates"; then
                echo -e "${YELLOW}No updates to be performed${NC}"
                exit 0
            else
                exit 1
            fi
        }
fi

# Wait for stack completion
echo -e "${GREEN}Waiting for stack $OPERATION to complete...${NC}"
echo -e "${YELLOW}This may take 10-15 minutes...${NC}"

if [ "$OPERATION" == "create-stack" ]; then
    aws cloudformation wait stack-create-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
else
    aws cloudformation wait stack-update-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
fi

# Get outputs
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"

aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output table

echo -e "${GREEN}Stack outputs saved to outputs.json${NC}"
aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' > outputs.json

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Next Steps:${NC}"
echo -e "1. SSH to EC2 instance (see SSHCommand output above)"
echo -e "2. Update .env file with BedrockAgentId and BedrockAgentAliasId"
echo -e "3. Test with Claude Code CLI"
echo -e "${GREEN}========================================${NC}"
