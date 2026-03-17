# ECS Blue/Green 배포   가이드

> Flask 앱을 AWS ECS에 배포하고, Blue/Green 무중단 배포와 자동 롤백을 구성하는 핸즈온 가이드

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [사전 준비](#2-사전-준비)
3. [Phase 1: 인프라 구성](#3-phase-1-인프라-구성)
4. [IAM 역할 및 정책 상세](#4-iam-역할-및-정책-상세)
5. [Phase 2: 첫 번째 배포](#5-phase-2-첫-번째-배포)
6. [Phase 3: Blue/Green 배포 설정](#6-phase-3-bluegreen-배포-설정)
7. [CI/CD 파이프라인](#7-cicd-파이프라인)
8. [자동 롤백 테스트](#8-자동-롤백-테스트)
9. [Auto Scaling 설정](#9-auto-scaling-설정)
10. [FAQ](#10-faq)

---

## 1. 아키텍처 개요

### 전체 구성도

```
┌─────────────────────────────────────────────────────────────────┐
│                         AWS Cloud                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │   GitLab/   │───▶│     ECR     │───▶│    ECS Cluster      │  │
│  │   GitHub    │    │  (이미지저장) │     │  ┌───────────────┐  │  │
│  └─────────────┘    └─────────────┘    │  │  ECS Service  │  │  │
│                                        │  │  (Blue/Green) │  │  │
│  ┌─────────────┐    ┌─────────────┐    │  └───────┬───────┘  │  │
│  │    User     │───▶│     ALB     │───▶│          │          │  │
│  └─────────────┘    │  (HTTP:80)  │    │  ┌───────▼───────┐  │  │
│                     └──────┬──────┘    │  │ Fargate Tasks │  │  │
│                            │           │  └───────────────┘  │  │
│                     ┌──────▼──────┐    └─────────────────────┘  │
│                     │ Target Groups│                            │
│                     │ Blue / Green │                            │
│                     └─────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

### Blue/Green 배포 흐름

```
1. 현재 상태 (Blue 운영 중)
   ALB ──[100%]──▶ Blue TG ──▶ 기존 Tasks

2. 새 버전 배포 시작
   ALB ──[100%]──▶ Blue TG ──▶ 기존 Tasks
                   Green TG ──▶ 새 Tasks (헬스체크 중)

3. 트래픽 전환
   ALB ──[100%]──▶ Green TG ──▶ 새 Tasks
                   Blue TG ──▶ 기존 Tasks (대기)

4. Bake Time 후 완료
   ALB ──[100%]──▶ Green TG ──▶ 새 Tasks
                   Blue TG ──▶ (정리됨)
```
  
## 2. 사전 준비

### 필수 도구

```bash
# AWS CLI 설치 확인
aws --version

# Docker 설치 확인
docker --version

# AWS 자격 증명 설정
aws configure
```

### 프로젝트 구조

```
ci-cd-demo/
├── app.py                 # Flask/Streamlit 애플리케이션
├── requirements.txt       # Python 의존성
├── Dockerfile            # 컨테이너 이미지 정의
├── .github/
│   └── workflows/
│       └── ci-cd.yml     # GitHub Actions 파이프라인
└── infrastructure/
    ├── phase1-infrastructure.yaml    # 기본 인프라
    ├── phase1-deploy.sh
    ├── phase2-1-ecs-service.yaml     # ECS 서비스
    ├── phase2-1-deploy.sh
    └── *.md                          # 가이드 문서들
```

### 애플리케이션 요구사항

**필수**: `/health` 엔드포인트 구현

```python
# app.py
@app.route('/health')
def health():
    return "OK", 200
```

> ⚠️ 헬스체크 실패 시 배포가 롤백됩니다. 반드시 구현하세요.

---

## 3. Phase 1: 인프라 구성

### 생성되는 리소스

| 카테고리 | 리소스 | 용도 |
|----------|--------|------|
| 네트워크 | VPC, Subnets, IGW | 네트워크 격리 |
| 로드밸런서 | ALB, Target Groups (Blue/Green) | 트래픽 분산 |
| 컨테이너 | ECR Repository, ECS Cluster | 이미지 저장 및 실행 |
| IAM | Task Execution Role, Task Role | 권한 관리 |
| IAM | ecsInfrastructureRoleForLoadBalancers | Blue/Green ALB 관리 |
| 모니터링 | CloudWatch Log Group | 로그 수집 |

### 핵심 IAM Role 설명

```yaml
# ECS가 Blue/Green 배포 시 ALB 리스너를 수정하기 위한 역할
ecsInfrastructureRoleForLoadBalancers:
  - Trust: ecs.amazonaws.com
  - Policy: AmazonECSInfrastructureRolePolicyForLoadBalancers (AWS 관리형)
```

> 💡 콘솔에서 Blue/Green 설정 시 "로드 밸런서 역할"로 표시됩니다.

### ALB Listener 설정 (Weighted Forward)

```yaml
# Blue/Green을 위해 두 Target Group을 weighted forward로 설정
ALBListener:
  DefaultActions:
    - Type: forward
      ForwardConfig:
        TargetGroups:
          - TargetGroupArn: !Ref BlueTargetGroup
            Weight: 100    # 초기에는 Blue로 100%
          - TargetGroupArn: !Ref GreenTargetGroup
            Weight: 0      # Green은 0%
```

### 헬스체크 설정

```yaml
# Target Group 헬스체크 (Blue/Green 모두 동일)
HealthCheckPath: /health              # 체크 경로
HealthCheckProtocol: HTTP
HealthCheckIntervalSeconds: 30        # 30초마다 체크
HealthCheckTimeoutSeconds: 5          # 5초 타임아웃
HealthyThresholdCount: 2              # 2번 성공 → 정상
UnhealthyThresholdCount: 3            # 3번 실패 → 비정상 → 롤백
```

**콘솔 확인 위치**: `EC2 → 대상 그룹 → 상태 검사 탭`

### 배포 명령

```bash
cd infrastructure
./phase1-deploy.sh
```

### 배포 후 확인

```bash
# 스택 출력값 확인
aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs' \
  --region us-east-1
```

**중요 출력값**:
- `ECRRepositoryURI`: 이미지 푸시 주소
- `ALBDNSName`: 애플리케이션 접속 주소
- `ECSBlueGreenRoleArn`: Blue/Green 설정 시 필요

---

## 4. IAM 역할 및 정책 상세

이 프로젝트에서 생성되는 모든 IAM 역할과 정책에 대한 상세 설명입니다.

### 4.1 IAM 역할 개요

| 역할 이름 | 용도 | Trust Entity |
|-----------|------|--------------|
| `ci-cd-demo-ecs-task-execution-role` | ECS 태스크 시작 시 필요한 권한 (ECR 풀, CloudWatch 로그) | `ecs-tasks.amazonaws.com` |
| `ci-cd-demo-ecs-task-role` | 컨테이너 내부에서 AWS 서비스 호출 시 사용 | `ecs-tasks.amazonaws.com` |
| `ecsInfrastructureRoleForLoadBalancers` | Blue/Green 배포 시 ALB 리스너/규칙 수정 | `ecs.amazonaws.com` |

### 4.2 ECS Task Execution Role

**역할 이름**: `ci-cd-demo-ecs-task-execution-role`

ECS 에이전트가 태스크를 시작할 때 사용하는 역할입니다. ECR에서 이미지를 풀링하고 CloudWatch Logs에 로그를 기록합니다.

#### Trust Policy (신뢰 관계)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

#### 연결된 정책

**1. AWS 관리형 정책: `AmazonECSTaskExecutionRolePolicy`**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

**2. 인라인 정책: `ECRAccess`**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
```

> 💡 ECR 접근 권한이 관리형 정책과 중복되지만, 명시적으로 추가하여 권한을 명확히 합니다.

### 4.3 ECS Task Role

**역할 이름**: `ci-cd-demo-ecs-task-role`

컨테이너 내부의 애플리케이션이 AWS 서비스를 호출할 때 사용하는 역할입니다.

#### Trust Policy (신뢰 관계)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

#### 연결된 정책

현재 추가 정책 없음. 애플리케이션이 S3, DynamoDB 등 AWS 서비스에 접근해야 할 경우 이 역할에 필요한 정책을 추가합니다.

**예시 - S3 접근 권한 추가 시**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::my-bucket/*"
    }
  ]
}
```

### 4.4 ECS Infrastructure Role for Load Balancers

**역할 이름**: `ecsInfrastructureRoleForLoadBalancers`

ECS가 Blue/Green 배포 시 ALB 리스너와 규칙을 수정하기 위해 사용하는 역할입니다.

#### Trust Policy (신뢰 관계)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccessToECSForInfrastructureManagement",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

#### 연결된 정책

**AWS 관리형 정책: `AmazonECSInfrastructureRolePolicyForLoadBalancers`**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ELBReadOperations",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeRules"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ALBModifyListeners",
      "Effect": "Allow",
      "Action": "elasticloadbalancing:ModifyListener",
      "Resource": "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*"
    },
    {
      "Sid": "NLBModifyListeners",
      "Effect": "Allow",
      "Action": "elasticloadbalancing:ModifyListener",
      "Resource": "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*"
    },
    {
      "Sid": "ALBModifyRules",
      "Effect": "Allow",
      "Action": "elasticloadbalancing:ModifyRule",
      "Resource": "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*/*"
    }
  ]
}
```

> 💡 이 역할은 콘솔에서 Blue/Green 배포 설정 시 "로드 밸런서 역할"로 선택합니다.

### 4.5 GitHub Actions IAM User

**사용자 이름**: `ci-cd-demo-github-actions-user`

GitHub Actions CI/CD 파이프라인에서 사용하는 IAM 사용자입니다.

#### 인라인 정책: `GitHubActionsPolicy`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAccess",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECSAccess",
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:RegisterTaskDefinition",
        "ecs:ListTasks",
        "ecs:DescribeTasks"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::<ACCOUNT_ID>:role/ci-cd-demo-ecs-task-execution-role",
        "arn:aws:iam::<ACCOUNT_ID>:role/ci-cd-demo-ecs-task-role"
      ]
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:us-east-1:<ACCOUNT_ID>:log-group:/ecs/ci-cd-demo:*"
    }
  ]
}
```

#### 권한 설명

| 권한 그룹 | 용도 |
|-----------|------|
| **ECR** | Docker 이미지 빌드 및 푸시 (`PutImage`, `UploadLayerPart` 등) |
| **ECS** | Task Definition 등록 및 서비스 업데이트 |
| **PassRole** | ECS 서비스가 Task Execution Role과 Task Role을 사용할 수 있도록 허용 |
| **CloudWatch Logs** | 빌드/배포 로그 기록 |

> ⚠️ **보안 권장사항**: 프로덕션 환경에서는 IAM User 대신 **OIDC**를 사용하여 GitHub Actions와 AWS를 연동하는 것을 권장합니다.

### 4.6 권한 흐름도

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         배포 권한 흐름                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  GitHub Actions                                                         │
│       │                                                                 │
│       │ (GitHubActionsPolicy)                                          │
│       ▼                                                                 │
│  ┌─────────┐    Push Image    ┌─────────┐                              │
│  │   ECR   │◀────────────────│ Docker  │                              │
│  └────┬────┘                  │  Build  │                              │
│       │                       └─────────┘                              │
│       │ Pull Image                                                      │
│       │ (Task Execution Role)                                          │
│       ▼                                                                 │
│  ┌─────────────────────────────────────────────────────┐               │
│  │                    ECS Service                       │               │
│  │  ┌─────────────────┐    ┌─────────────────────────┐ │               │
│  │  │ Task Execution  │    │      Task Role          │ │               │
│  │  │     Role        │    │  (App AWS API calls)   │ │               │
│  │  │ - ECR Pull      │    │  - S3, DynamoDB 등     │ │               │
│  │  │ - CW Logs       │    │    (필요시 추가)        │ │               │
│  │  └─────────────────┘    └─────────────────────────┘ │               │
│  └─────────────────────────────────────────────────────┘               │
│                                                                         │
│  Blue/Green 배포 시:                                                    │
│  ┌────────────────────────────────────────┐                            │
│  │  ecsInfrastructureRoleForLoadBalancers │                            │
│  │  - ALB Listener 수정                    │                            │
│  │  - Target Group 트래픽 전환             │                            │
│  └────────────────────────────────────────┘                            │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.7 최소 권한 원칙 적용 가이드

프로덕션 환경에서는 `Resource: "*"` 대신 특정 리소스 ARN을 지정하는 것을 권장합니다.

**ECR 권한 제한 예시**:
```json
{
  "Effect": "Allow",
  "Action": [
    "ecr:BatchCheckLayerAvailability",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchGetImage"
  ],
  "Resource": "arn:aws:ecr:us-east-1:<ACCOUNT_ID>:repository/ci-cd-demo-app"
}
```

**ECS 권한 제한 예시**:
```json
{
  "Effect": "Allow",
  "Action": [
    "ecs:UpdateService",
    "ecs:DescribeServices"
  ],
  "Resource": "arn:aws:ecs:us-east-1:<ACCOUNT_ID>:service/ci-cd-demo-cluster/ci-cd-demo-service"
}
```

---

## 5. Phase 2: 첫 번째 배포

### Step 1: Docker 이미지 빌드 및 푸시

```bash
# 변수 설정
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
ECR_URI=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/ci-cd-demo-app

# ECR 로그인
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# 이미지 빌드 (ARM Mac 사용 시 --platform 필수)
docker build --platform linux/amd64 -t ci-cd-demo-app .

# 태그 및 푸시
docker tag ci-cd-demo-app:latest $ECR_URI:latest
docker push $ECR_URI:latest
```

> ⚠️ Apple Silicon Mac에서는 `--platform linux/amd64` 필수!

### Step 2: ECS 서비스 생성

```bash
cd infrastructure
./phase2-1-deploy.sh
```

### Step 3: 배포 확인

```bash
# 서비스 상태 확인
aws ecs describe-services \
  --cluster ci-cd-demo-cluster \
  --services ci-cd-demo-service \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
  --region us-east-1

# 애플리케이션 접속 테스트
curl http://$(aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
  --output text --region us-east-1)
```

---

## 6. Phase 3: Blue/Green 배포 설정

> 📌 ECS 네이티브 Blue/Green은 **콘솔에서 설정**합니다. (CloudFormation 불필요)

### 콘솔 설정 단계

1. **ECS 콘솔 접속**
   ```
   ECS → 클러스터 → ci-cd-demo-cluster → 서비스 탭
   ```

2. **서비스 선택 및 편집**
   ```
   ci-cd-demo-service 선택 → (서비스 변경 화면 접근: 서비스 업데이트 버튼 클릭) ->   배포 옵션 영역 찾기  → 편집
   ```

3. **배포 전략 설정**

   | 설정 항목 | 값 |
   |----------|-----|
   | 배포 전략 | **블루/그린** |
   | Bake time | 5분 (권장) |

4. **로드 밸런싱 설정**

   | 설정 항목 | 값 |
   |----------|-----|
   | 컨테이너 | `app 8080:8080` |
   | 로드 밸런서 | `ci-cd-demo-alb` |
   | 리스너 | `HTTP:80` |
   | 프로덕션 리스너 규칙 | `우선순위: default` |
   | 블루 대상 그룹 | `ci-cd-demo-blue-tg` |
   | 그린 대상 그룹 | `ci-cd-demo-green-tg` |
   | **로드 밸런서 역할** | `ecsInfrastructureRoleForLoadBalancers` |

5. **업데이트 클릭**
 
### Blue/Green 배포 라이프사이클 참고.

```
RECONCILE_SERVICE     서비스 상태 확인
       ↓
PRE_SCALE_UP         스케일업 전 훅 (선택)
       ↓
SCALE_UP             Green 환경 생성
       ↓
POST_SCALE_UP        스케일업 후 훅 (선택)
       ↓
TEST_TRAFFIC_SHIFT   테스트 트래픽 전환 (선택)
       ↓
PRODUCTION_TRAFFIC_SHIFT  프로덕션 트래픽 전환
       ↓
BAKE_TIME            안정화 대기 (5분)  * 배포 전략에 따라 BAKE_TIME을 조정하십시오.
       ↓
CLEAN_UP             Blue 환경 정리
```

---

## 7. CI/CD 파이프라인

### GitHub Actions 예시

```yaml
# .github/workflows/ci-cd.yml
name: CI/CD Pipeline

on:
  push:
    branches: [main]

env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: ci-cd-demo-app
  ECS_CLUSTER: ci-cd-demo-cluster
  ECS_SERVICE: ci-cd-demo-service

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG

      - name: Deploy to ECS (triggers Blue/Green)
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          # Task Definition 업데이트
          TASK_DEF=$(aws ecs describe-task-definition \
            --task-definition $ECS_SERVICE \
            --query 'taskDefinition' --output json)
          
          NEW_TASK_DEF=$(echo $TASK_DEF | jq \
            --arg IMAGE "$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" \
            '.containerDefinitions[0].image = $IMAGE |
             del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')
          
          NEW_REVISION=$(aws ecs register-task-definition \
            --cli-input-json "$NEW_TASK_DEF" \
            --query 'taskDefinition.taskDefinitionArn' --output text)
          
          # 서비스 업데이트 → Blue/Green 자동 실행
          aws ecs update-service \
            --cluster $ECS_CLUSTER \
            --service $ECS_SERVICE \
            --task-definition $NEW_REVISION
```

### GitLab CI 예시

```yaml
# .gitlab-ci.yml
stages:
  - build
  - deploy

variables:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: ci-cd-demo-app
  ECS_CLUSTER: ci-cd-demo-cluster
  ECS_SERVICE: ci-cd-demo-service

build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URI
    - docker build -t $ECR_URI:$CI_COMMIT_SHA .
    - docker push $ECR_URI:$CI_COMMIT_SHA

deploy:
  stage: deploy
  script:
    - aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --force-new-deployment
```

### 배포 트리거 조건

| 트리거 | 설명 |
|--------|------|
| Task Definition 변경 | 새 이미지, 환경변수, 리소스 변경 |
| `--force-new-deployment` | 동일 Task Definition으로 재배포 |
| 콘솔에서 "새 배포 강제 실행" | 수동 트리거 |

---

## 8. 자동 롤백 테스트

> ⚠️ **중요**: 롤백은 **배포 중**에만 발생합니다. 배포 완료 후 크래시는 롤백이 아닌 **태스크 재시작**으로 처리됩니다. 블루<>그린간 전환 조건은 BAKE TIME 동안 유효합니다.

### 롤백이 발생하는 조건

1. **헬스체크 실패** - ALB가 `/health`에서 비정상 응답 감지
2. **태스크 시작 실패** - 컨테이너 시작 중 크래시
3. **CloudWatch 알람** - 사용자 정의 메트릭 임계값 초과 (설정 시)
4. **수동 중단** - 콘솔에서 배포 중단

### 테스트 방법 1: 헬스체크 실패 

```python
# app.py 수정
@app.route('/health')
def health():
    return "FAIL", 500  # 200 → 500으로 변경
```

**예상 결과**:
1. 이미지 빌드 ✅
2. Green 태스크 시작 ✅
3. 헬스체크 ❌ (3회 실패)
4. **자동 롤백** → Blue 유지

### 테스트 방법 2: CloudWatch 알람 기반 롤백

#### Step 1: CloudWatch 알람 생성

```
CloudWatch → 알람 → 알람 생성
```

| 항목 | 값 |
|------|-----|
| 지표 | `ApplicationELB → Per AppELB Metrics → HTTPCode_Target_5XX_Count` |
| 로드 밸런서 | `ci-cd-demo-alb` |
| 통계 | 합계 (Sum) |
| 기간 | 1분 |
| 조건 | 보다 큼 > **10** |
| 알람 이름 | `ci-cd-demo-5xx-alarm` |

> ⚠️ **주의**: `HTTPCode_ELB_5XX_Count`가 아닌 `HTTPCode_Target_5XX_Count` 사용!
> - `ELB_5XX`: ALB 자체 오류 (502, 503)
> - `Target_5XX`: **앱에서 반환하는 500** ← 이것 사용

**CLI로 생성**:
```bash
ALB_SUFFIX=$(aws elbv2 describe-load-balancers \
  --names ci-cd-demo-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text --region us-east-1 | cut -d: -f6 | cut -d/ -f2-)

aws cloudwatch put-metric-alarm \
  --alarm-name ci-cd-demo-5xx-alarm \
  --metric-name HTTPCode_Target_5XX_Count \
  --namespace AWS/ApplicationELB \
  --statistic Sum \
  --period 60 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --dimensions Name=LoadBalancer,Value=$ALB_SUFFIX \
  --region us-east-1
```

#### Step 2: ECS 서비스에 알람 연결

```
ECS → 서비스 → 배포 탭 → 편집 → "CloudWatch 알람 사용" 활성화 → 알람 선택
```

#### Step 3: 테스트 코드

```python
import random

@app.route('/')
def home():
    if random.random() < 0.5:  # 50% 에러
        return "Error", 500
    return "OK", 200

@app.route('/health')
def health():
    return "OK", 200  # 헬스체크는 통과
```

#### Step 4: 트래픽 발생

```bash
for i in {1..100}; do
  curl -s http://ALB_DNS_NAME/
  sleep 0.5
done
```

**예상 결과**: 5xx 에러 증가 → 알람 트리거 → 자동 롤백

### 롤백 확인 방법

**콘솔**:
```
ECS → 클러스터 → 서비스 → 배포 탭 → 배포 기록
```

---

## 9. Auto Scaling 설정

### 스케일링 기준

| 지표 | 설명 | 권장 목표값 |
|------|------|------------|
| CPU 사용률 | 평균 CPU | 70% |
| 메모리 사용률 | 평균 메모리 | 80% |
| ALB 요청 수 | 태스크당 요청 | 1000 req/min |

### 콘솔 설정

```
ECS → 클러스터 → 서비스 → 서비스 Auto Scaling 탭 → 구성
```

| 설정 | 값 |
|------|-----|
| 최소 태스크 | 1 |
| 최대 태스크 | 10 |
| 정책 유형 | Target Tracking |
| 대상 지표 | ECSServiceAverageCPUUtilization |
| 대상 값 | 70 |

### CloudFormation으로 설정

```yaml
ScalableTarget:
  Type: AWS::ApplicationAutoScaling::ScalableTarget
  Properties:
    ServiceNamespace: ecs
    ResourceId: !Sub service/${ECSCluster}/${ECSService}
    ScalableDimension: ecs:service:DesiredCount
    MinCapacity: 1
    MaxCapacity: 10
    RoleARN: !Sub arn:aws:iam::${AWS::AccountId}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService

ScalingPolicy:
  Type: AWS::ApplicationAutoScaling::ScalingPolicy
  Properties:
    PolicyName: cpu-scaling
    PolicyType: TargetTrackingScaling
    ScalingTargetId: !Ref ScalableTarget
    TargetTrackingScalingPolicyConfiguration:
      TargetValue: 70.0
      PredefinedMetricSpecification:
        PredefinedMetricType: ECSServiceAverageCPUUtilization
      ScaleInCooldown: 300
      ScaleOutCooldown: 60
```

---

## 10. FAQ

### Q: CodeDeploy는 더 이상 필요 없나요?

**A**: ECS Blue/Green 배포의 경우 **불필요**합니다. 2025년 AWS가 ECS 네이티브 Blue/Green을 출시하면서 CodeDeploy 없이 ECS 자체에서 Blue/Green을 지원하며 이를 따르도록 본 레포지토리를 구성하였습니다. 

### Q: Blue/Green 전환은 언제 일어나나요?

**A**: ECS Service가 업데이트될 때 자동으로 실행됩니다: (본 레포지토리에서는 github에 master 브랜치가 변경될때 github action에 의해 실행되도록 구성 하였습니다.
- 새 Task Definition 등록 후 서비스 업데이트
- `--force-new-deployment` 옵션 사용
- 콘솔에서 "새 배포 강제 실행"

### Q: 롤백은 자동인가요?

**A**: 네, 다음 조건에서 자동 롤백됩니다:
- 헬스체크 실패 (3회 연속)
- 태스크 시작 실패
- CloudWatch 알람 트리거 (설정 시)

### Q: Bake Time이란?

**A**: 트래픽 전환 후 Blue 환경을 유지하는 시간입니다. 이 시간 동안 문제가 발생하면 즉시 롤백할 수 있습니다. 권장값: 5분

### Q: 헬스체크 설정은 어디서 하나요?

**A**: `EC2 → 대상 그룹 → 상태 검사 탭`에서 확인/수정할 수 있습니다. CloudFormation에서는 Target Group의 `HealthCheckPath` 속성입니다.

### Q: 비용은 얼마나 드나요?

**A**: ⚠️ **주의** 테스트가 완료되었다면 실행계정의 cloudformation으로 돌아가 ci-cd-demo 관련 스택을 모두 삭제해 리소스를 제거하시기 바랍니다.

아래의 요소에서 비용이 발생할 수 있습니다. 
- ECS Blue/Green 자체는 **무료**
- 배포 중 일시적 (BAKE_TIME) 으로 태스크가 2배 발생, (Blue + Green)
- Fargate 비용: 태스크 수 × 실행 시간 × (vCPU + 메모리) 

---

## 참고 자료

- [AWS 공식: ECS Blue/Green 배포](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-blue-green.html)
- [AWS 공식: ALB 리소스 설정](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/alb-resources-for-blue-green.html)
- [AWS 공식: ECS Infrastructure Role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AmazonECSInfrastructureRolePolicyForLoadBalancers.html)
- [AWS 블로그: Amazon ECS 내장 새로운 블루/그린 배포 기반 안전한 소프트웨어 출시 가속하기](https://aws.amazon.com/ko/blogs/korea/accelerate-safe-software-releases-with-new-built-in-blue-green-deployments-in-amazon-ecs/)
