#!/bin/bash
# Build Lambda deployment package

set -e

echo "Building Lambda deployment package..."

# Create temporary directory
rm -rf package
mkdir -p package

# Install dependencies
if [ -f requirements.txt ]; then
    pip install -r requirements.txt -t package/
fi

# Copy Lambda function code
cp index.py package/

# Create ZIP file
cd package
zip -r ../lambda-mcp-bridge.zip .
cd ..

# Clean up
rm -rf package

echo "Lambda deployment package created: lambda-mcp-bridge.zip"
echo "Upload this file to S3 or use it with CloudFormation"
