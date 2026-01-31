#!/bin/bash
# Delete CARLA-VAD Agent CloudFormation stack

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="${STACK_NAME:-carla-vad-master}"
REGION="${AWS_REGION:-us-east-1}"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}CARLA-VAD Agent Stack Deletion${NC}"
echo -e "${YELLOW}========================================${NC}"
echo -e "${RED}WARNING: This will delete all resources!${NC}"
echo -e "${RED}Stack: $STACK_NAME${NC}"
echo -e "${RED}Region: $REGION${NC}"
echo -e "${YELLOW}========================================${NC}"

read -p "Are you sure you want to delete this stack? (type 'yes' to confirm) " -r
echo
if [[ ! $REPLY == "yes" ]]; then
    echo -e "${GREEN}Deletion cancelled${NC}"
    exit 0
fi

# Check if stack exists
STACK_EXISTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" 2>&1 || true)

if echo "$STACK_EXISTS" | grep -q "does not exist"; then
    echo -e "${YELLOW}Stack $STACK_NAME does not exist${NC}"
    exit 0
fi

# Delete stack
echo -e "${YELLOW}Deleting stack $STACK_NAME...${NC}"
aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

# Wait for deletion
echo -e "${YELLOW}Waiting for stack deletion to complete...${NC}"
echo -e "${YELLOW}This may take several minutes...${NC}"

aws cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Stack deleted successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
