# Phase 1: 기본 인프라 구성

## 생성되는 리소스

### 1. 네트워킹
- **VPC**: 10.0.0.0/16 (ci-cd-demo-vpc)
- **Public Subnets**: 2개 Multi-AZ (ci-cd-demo-public-subnet-1/2)
- **Internet Gateway**: ci-cd-demo-igw
- **Route Table**: ci-cd-demo-public-rt
- **Security Groups**:
  - ALB Security Group (ci-cd-demo-alb-sg): HTTP/HTTPS 허용
  - ECS Security Group (ci-cd-demo-ecs-sg): ALB에서 8080 포트 허용

### 2. 컨테이너 인프라
- **ECR Repository**: ci-cd-demo-app (이미지 스캔 활성화, 10개 이미지 보관)
- **ECS Cluster**: ci-cd-demo-cluster (Fargate/Fargate Spot, Container Insights 활성화)
- **Application Load Balancer**: ci-cd-demo-alb (인터넷 연결)

### 3. Blue/Green 배포 준비
- **Blue Target Group**: ci-cd-demo-blue-tg (포트 8080, /health 헬스체크)
- **Green Target Group**: ci-cd-demo-green-tg (포트 8080, /health 헬스체크)
- **ALB Listener**: HTTP 80포트, Weighted Forward (Blue 100%, Green 0%)

### 4. IAM 역할
- **ECS Task Execution Role**: ci-cd-demo-ecs-task-execution-role (ECR 접근, CloudWatch 로그)
- **ECS Task Role**: ci-cd-demo-ecs-task-role (애플리케이션 실행)
- **ECS Infrastructure Role**: ecsInfrastructureRoleForLoadBalancers (Blue/Green 배포용 ALB 관리)

> 참고: CloudFormation 템플릿에 GitHub Actions 관련 리소스(IAM User, Access Key)도 포함되어 있지만, CodePipeline을 사용하는 경우 무시해도 됩니다.

### 5. 모니터링
- **CloudWatch Log Group**: /ecs/ci-cd-demo (7일 보관)
- **Container Insights**: ECS 클러스터 메트릭 수집

## 배포 방법

```bash
cd ~/aws-ecs-cicd-setup/infrastructure
chmod +x phase1-deploy.sh
./phase1-deploy.sh
```

> `create-stack` 명령 후 스택 생성 완료까지 약 3~5분 소요됩니다.

## 배포 완료 후 출력값

인프라 배포 완료 후 다음 정보들이 출력됩니다:

```bash
aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs' \
  --region us-east-1 \
  --output table
```

### 메모할 출력값:

| 출력 키 | 용도 |
|---------|------|
| `ECRRepositoryURI` | 이미지 저장소 주소 |
| `ALBDNSName` | 애플리케이션 접속 주소 |
| `ECSBlueGreenRoleArn` | Blue/Green 설정 시 필요 |

### Phase 2에서 사용할 정보:
- **ECSClusterName** - ECS 클러스터 이름
- **ALBDNSName** - 로드밸런서 주소
- **ALBListenerArn** - Blue/Green 배포 설정용 리스너 ARN
- **BlueTargetGroupArn** / **GreenTargetGroupArn** - Blue/Green 배포용
- **VPCId**, **PublicSubnet1Id**, **PublicSubnet2Id** - 네트워크 정보
- **ECSSecurityGroupId** - 보안 그룹
- **ECSTaskExecutionRoleArn**, **ECSTaskRoleArn** - IAM 역할
- **ECSBlueGreenRoleArn** - ECS Blue/Green 배포용 인프라 역할

## 다음 단계

Phase 2: CodeBuild로 첫 번째 이미지 빌드 → `readme_cloudshell.md` Phase 2 참조
