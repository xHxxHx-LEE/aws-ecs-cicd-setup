# Phase 2-1: ECS 서비스 생성

## 생성되는 리소스

### 1. ECS Task Definition
- **Family**: ci-cd-demo-service
- **CPU/Memory**: 256 CPU, 512 MB Memory
- **Network Mode**: awsvpc (Fargate)
- **Container**: app (포트 8080)

### 2. ECS Service
- **Service Name**: ci-cd-demo-service
- **Desired Count**: 1개 컨테이너
- **Launch Type**: Fargate
- **Deployment Controller**: ECS
- **Load Balancer**: Blue Target Group에 연결

## 배포 전 필수 작업: 첫 번째 이미지 푸시

> CloudShell 환경에서는 Docker를 사용할 수 없으므로 **CodeBuild**를 사용하여 첫 번째 이미지를 빌드합니다.
> 자세한 절차는 `readme_cloudshell.md` Phase 2를 참조하세요.

### CodeBuild를 통한 이미지 빌드 (요약)

1. CodeBuild에 GitHub 인증 등록 (`import-source-credentials`)
2. CodeBuild 서비스 역할 생성
3. CodeBuild 프로젝트 생성
4. 수동 빌드 실행
5. ECR에 이미지 확인

```bash
# ECR에 이미지가 있는지 확인
aws ecr describe-images \
  --repository-name ci-cd-demo-app \
  --region us-east-1 \
  --query 'imageDetails[*].{Tag:imageTags[0],PushedAt:imagePushedAt}' \
  --output table
```

## 배포 방법

```bash
cd ~/aws-ecs-cicd-setup/infrastructure
chmod +x phase2-1-deploy.sh
./phase2-1-deploy.sh
```

> `create-stack` 명령 후 스택 생성 완료까지 약 2~3분 소요됩니다.

## 배포 후 확인사항

### 1. ECS 서비스 상태

```bash
aws ecs describe-services \
  --cluster ci-cd-demo-cluster \
  --services ci-cd-demo-service \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
  --region us-east-1
```

- **Running tasks**: 1/1 (정상)
- **Service status**: ACTIVE

### 2. 애플리케이션 접근

```bash
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
  --output text --region us-east-1)

curl http://$ALB_DNS
curl http://$ALB_DNS/health
```

### 3. Target Group 상태

```bash
BLUE_TG_ARN=$(aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`BlueTargetGroupArn`].OutputValue' \
  --output text --region us-east-1)

aws elbv2 describe-target-health \
  --target-group-arn $BLUE_TG_ARN \
  --region us-east-1
```

- **Health status**: healthy

## 다음 단계

Phase 3: Blue/Green 배포 설정 → `phase3-blue-green-README.md` 참조
