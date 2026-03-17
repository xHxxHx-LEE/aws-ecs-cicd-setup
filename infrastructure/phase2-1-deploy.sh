#!/bin/bash

# Deploy ECS Service using CloudFormation
STACK_NAME="ci-cd-demo-ecs-service"
TEMPLATE_FILE="phase2-1-ecs-service.yaml"
REGION="us-east-1"

echo "Deploying ECS Service stack: $STACK_NAME"

aws cloudformation create-stack \
  --stack-name $STACK_NAME \
  --template-body file://$TEMPLATE_FILE \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=ci-cd-demo \
  --region $REGION

if [ $? -eq 0 ]; then
  echo "Stack creation initiated. Waiting for completion..."
  aws cloudformation wait stack-create-complete \
    --stack-name $STACK_NAME \
    --region $REGION

  if [ $? -eq 0 ]; then
    echo "ECS Service deployment completed successfully!"

    # Get outputs
    echo "Getting stack outputs..."
    aws cloudformation describe-stacks \
      --stack-name $STACK_NAME \
      --region $REGION \
      --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
      --output table
  else
    echo "ECS Service deployment failed!"
    exit 1
  fi
else
  echo "Stack creation request failed!"
  exit 1
fi
