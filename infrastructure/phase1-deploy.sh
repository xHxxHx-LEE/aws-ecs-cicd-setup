#!/bin/bash

# Deploy infrastructure using CloudFormation
STACK_NAME="ci-cd-demo-infrastructure"
TEMPLATE_FILE="phase1-infrastructure.yaml"
REGION="us-east-1"

echo "Deploying infrastructure stack: $STACK_NAME"

aws cloudformation create-stack \
  --stack-name $STACK_NAME \
  --template-body file://$TEMPLATE_FILE \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=ci-cd-demo \
    ParameterKey=Environment,ParameterValue=dev \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

if [ $? -eq 0 ]; then
  echo "Stack creation initiated. Waiting for completion..."
  aws cloudformation wait stack-create-complete \
    --stack-name $STACK_NAME \
    --region $REGION

  if [ $? -eq 0 ]; then
    echo "Infrastructure deployment completed successfully!"

    # Get outputs
    echo "Getting stack outputs..."
    aws cloudformation describe-stacks \
      --stack-name $STACK_NAME \
      --region $REGION \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
      --output table
  else
    echo "Infrastructure deployment failed!"
    exit 1
  fi
else
  echo "Stack creation request failed!"
  exit 1
fi
