#!/bin/bash
# Helper script to initialize Terraform with bucket from config.yaml

set -e

ENVIRONMENT=${1:-dev}


if [ "$ENVIRONMENT" = "dev" ]; then
    echo "Initializing Terraform for dev environment (local state)"
    terraform init -backend-config=backend-dev.hcl
else
    # Extract bucket name from config.yaml
    if [ ! -f "config/config.yaml" ]; then
        echo "Error: config/config.yaml not found!"
        echo "Please copy config/example.config.yaml to config/config.yaml and customize it."
        exit 1
    fi

    BUCKET_NAME=$(grep "^bucket_name:" config/config.yaml | awk '{print $2}' | tr -d '"' | head -n 1)
    REGION=$(grep -A 5 "^app:" config/config.yaml | grep "^  region:" | awk '{print $2}' | tr -d '"' | head -n 1)

    if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "YOUR-UNIQUE-SUFFIX" ]; then
        echo "Error: Please set a valid bucket_name in config/config.yaml"
        exit 1
    fi

    if [ -z "$REGION" ]; then
        echo "Error: Please set a valid region in config/config.yaml"
        exit 1
    fi

    echo "Initializing Terraform for $ENVIRONMENT environment"
    echo "Using S3 bucket: $BUCKET_NAME"
    echo "Using region: $REGION"

    terraform init \
        -backend-config=backend-${ENVIRONMENT}.hcl \
        -backend-config="bucket=$BUCKET_NAME" \
        -backend-config="region=$REGION"
fi

echo "Terraform initialized successfully!"
