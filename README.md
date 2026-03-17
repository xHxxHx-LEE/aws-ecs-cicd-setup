# ECS Blue/Green 배포 핸즈온 가이드 (CloudShell + CodePipeline 버전)

> Flask 앱을 AWS ECS에 배포하고, GitHub + CodePipeline으로 CI/CD와 Blue/Green 무중단 배포를 구성하는 핸즈온 가이드
>
> **실행 환경: AWS CloudShell**  

github+ 로컬환경으로 핸즈온 환경은 readme_github_old.md 파일 참조. 
## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [사전 준비](#2-사전-준비)
3. [Phase 1: 인프라 구성](#3-phase-1-인프라-구성)
4. [Phase 2: CodeBuild로 첫 번째 이미지 빌드](#4-phase-2-codebuild로-첫-번째-이미지-빌드)
5. [Phase 3: ECS 서비스 생성](#5-phase-3-ecs-서비스-생성)
6. [Phase 4: Blue/Green 배포 설정](#6-phase-4-bluegreen-배포-설정)
7. [Phase 5: CodePipeline 구성 (GitHub 연동)](#7-phase-5-codepipeline-구성-github-연동)
8. [Phase 6: CI/CD 자동 배포 테스트](#8-phase-6-cicd-자동-배포-테스트)
9. [Phase 7: 자동 롤백 테스트](#9-phase-7-자동-롤백-테스트)
10. [리소스 정리](#10-리소스-정리)
11. [FAQ](#11-faq)

---

## 1. 아키텍처 개요

### 전체 구성도

![Architecture](https://raw.githubusercontent.com/jikang-jeong/aws-ecs-cicd-setup/refs/heads/main/architecture.png)

### 배포 플로우

```
코드 수정 → Git Push → CodePipeline 자동 트리거
                              │
                    ┌─────────▼─────────┐
                    │   Source Stage     │  GitHub에서 소스 가져오기
                    │  (CodeStar 연동)   │
                    └─────────┬─────────┘
                              │
                    ┌─────────▼─────────┐
                    │   Build Stage     │  CodeBuild: Docker 빌드 + ECR 푸시
                    │  (CodeBuild)      │  + Task Def 등록 + ECS 배포 트리거
                    └─────────┬─────────┘
                              │ Pipeline 완료 (2~3분)
                              │
                    ┌─────────▼─────────────────────┐
                    │   ECS (백그라운드)              │
                    │   Blue/Green 배포 + Bake Time  │
                    │   (Pipeline과 독립적으로 진행)   │
                    └───────────────────────────────┘
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

---

## 2. 사전 준비

### 필요한 것

| 항목 | 설명 | CloudShell 제공 |
|------|------|:---:|
| AWS CLI | 인프라 구축 | O (기본 설치) |
| Git | 코드 관리 | O (기본 설치) |
| Python | 코드 확인/수정 | O (기본 설치) |
| AWS 자격증명 | AWS 리소스 접근 | O (자동 설정) | 
| GitHub 계정 | 소스 저장소 | 별도 준비 필요 |
| GitHub PAT | Git push / CodeBuild 인증 | 별도 생성 필요 |

### CloudShell 접속

1. AWS Console 로그인
2. 우측 상단 **CloudShell 아이콘** 클릭 (또는 서비스 검색에서 "CloudShell")
3. 리전이 **버지니아 북부 (us-east-1)** 인지 확인

### 환경 확인

```bash
# AWS CLI 확인
aws --version

# Git 확인
git --version

# AWS 자격증명 확인 (CloudShell은 자동 설정)
aws sts get-caller-identity

# Account ID 메모 (이후 단계에서 사용)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $ACCOUNT_ID"
```

### ECS Service-Linked Role 확인

> ECS를 **처음 사용하는 계정**에서는 Service-Linked Role이 없어 Phase 1에서 ECS 클러스터 생성이 실패할 수 있습니다. 아래 두 가지 방법 중 하나를 수행하세요.

**방법 1: CLI로 생성**
```bash
aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com 2>/dev/null || true
```

**방법 2: ECS 콘솔 접속**
```
AWS Console → ECS 서비스 페이지에 한 번 접속하면 자동으로 생성됩니다.
```

> 이미 ECS를 사용한 적 있는 계정이라면 이 단계를 건너뛰어도 됩니다.

### GitHub Personal Access Token (PAT) 생성

CloudShell에서 `git push` 및 CodeBuild GitHub 인증에 PAT이 필요합니다.

1. GitHub 로그인 → 우측 상단 프로필 → **Settings**
2. 좌측 하단 **Developer settings** → **Personal access tokens** → **Tokens (classic)**
3. **Generate new token (classic)** 클릭
4. 설정:

| 항목 | 값 |
|------|-----|
| Note | `ecs-cicd-workshop` |
| Expiration | 7 days (워크샵용) |
| Scopes | `repo` (전체 체크) |

5. **Generate token** 클릭
6. **토큰을 반드시 복사하여 메모** (페이지를 벗어나면 다시 볼 수 없음)

### GitHub 저장소 준비

1. GitHub에서 **본인 저장소**에 이 프로젝트를 Fork 또는 새로 생성
2. 저장소에 `buildspec.yml`이 포함되어 있는지 확인

### CloudShell Git 인증 설정

```bash
# Git 사용자 설정
git config --global user.email "your-email@example.com"
git config --global user.name "Your Name"

# Git credential 캐싱 (세션 동안 PAT 재입력 방지)
git config --global credential.helper 'cache --timeout=86400'
```

> 이후 `git push` 시 Username에 GitHub ID, Password에 PAT을 입력하면 세션 동안 재입력 없이 사용됩니다.

### 프로젝트 구조

```
aws-ecs-cicd-setup/
├── app.py                 # Flask 애플리케이션
├── requirements.txt       # Python 의존성
├── Dockerfile            # 컨테이너 이미지 정의 (CodeBuild에서 사용)
├── buildspec.yml         # CodeBuild 빌드 스펙
├── task-definition.json  # ECS Task Definition 템플릿
└── infrastructure/
    ├── phase1-infrastructure.yaml    # 기본 인프라 (CloudFormation)
    ├── phase1-deploy.sh
    ├── phase2-1-ecs-service.yaml     # ECS 서비스 (CloudFormation)
    └── phase2-1-deploy.sh
```

---

## 3. Phase 1: 인프라 구성

### 생성되는 리소스

| 카테고리 | 리소스 | 용도 |
|----------|--------|------|
| 네트워크 | VPC, Subnets, IGW | 네트워크 격리 |
| 로드밸런서 | ALB, Target Groups (Blue/Green) | 트래픽 분산 |
| 컨테이너 | ECR Repository, ECS Cluster | 이미지 저장 및 실행 |
| IAM | Task Execution Role, Task Role | ECS 태스크 권한 |
| IAM | ecsInfrastructureRoleForLoadBalancers | Blue/Green ALB 관리 |
| 모니터링 | CloudWatch Log Group | 로그 수집 |

> 참고: CloudFormation 템플릿에 GitHub Actions 관련 리소스(IAM User, Access Key)도 포함되어 있지만, 이 워크샵에서는 **CodePipeline을 사용하므로 무시**해도 됩니다.

### Step 1: 저장소 클론

```bash
git clone https://github.com/<본인-GitHub-ID>/aws-ecs-cicd-setup.git
cd aws-ecs-cicd-setup
```

### Step 2: 인프라 배포

```bash
cd infrastructure
chmod +x phase1-deploy.sh
./phase1-deploy.sh
```

> `create-stack` 명령 후 스택 생성 완료까지 약 3~5분 소요됩니다.
>
> 워크샵 계정에서 `cloudformation deploy`(CreateChangeSet)가 차단될 경우, 스크립트가 `create-stack`을 사용하도록 이미 설정되어 있습니다.

### Step 3: 배포 결과 확인

```bash
aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs' \
  --region us-east-1 \
  --output table
```

**메모할 출력값**:

| 출력 키 | 용도 |
|---------|------|
| `ECRRepositoryURI` | 이미지 저장소 주소 |
| `ALBDNSName` | 애플리케이션 접속 주소 |
| `ECSBlueGreenRoleArn` | Blue/Green 설정 시 필요 |

### Step 4: 자주 사용하는 변수 설정

```bash
# 이후 Phase에서 계속 사용하는 변수 (CloudShell 세션이 끊어지면 다시 실행)
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
  --output text --region us-east-1)

echo "Account ID: $ACCOUNT_ID"
echo "ALB DNS: $ALB_DNS"
```

> CloudShell 세션이 끊어지면 위 변수가 초기화됩니다. 재접속 시 이 블록을 다시 실행하세요.

---

## 4. Phase 2: CodeBuild로 첫 번째 이미지 빌드

> ECS 서비스를 생성하려면 ECR에 이미지가 있어야 합니다.
> CodeBuild 프로젝트를 만들고 수동 빌드를 실행하여 첫 번째 이미지를 생성합니다.

### Step 1: CodeBuild에 GitHub 인증 등록

> CodeBuild는 GitHub에서 소스 코드를 가져와 Docker 이미지를 빌드하는 서비스입니다.
> GitHub의 private 저장소에 접근하려면 인증(PAT)이 필요합니다.

```bash
# 사전 준비에서 생성한 GitHub PAT 사용
aws codebuild import-source-credentials \
  --server-type GITHUB \
  --auth-type PERSONAL_ACCESS_TOKEN \
  --token <여기에-GitHub-PAT-입력> \
  --region us-east-1
```

> `<여기에-GitHub-PAT-입력>` 을 실제 PAT으로 교체하세요.

등록 확인:
```bash
aws codebuild list-source-credentials --region us-east-1
```

### Step 2: CodeBuild 서비스 역할 생성

> CodeBuild가 ECR에 이미지를 푸시하고, CloudWatch에 로그를 기록하기 위한 IAM 역할입니다.

```bash
# CodeBuild 서비스 역할 생성
aws iam create-role \
  --role-name ci-cd-demo-codebuild-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "codebuild.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }' \
  --region us-east-1

# 필요한 정책 연결
aws iam put-role-policy \
  --role-name ci-cd-demo-codebuild-role \
  --policy-name CodeBuildPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
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
        "Effect": "Allow",
        "Action": [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "sts:GetCallerIdentity"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "codestar-connections:UseConnection"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeServices"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "iam:PassRole"
        ],
        "Resource": [
          "arn:aws:iam::'$ACCOUNT_ID':role/ci-cd-demo-ecs-task-execution-role",
          "arn:aws:iam::'$ACCOUNT_ID':role/ci-cd-demo-ecs-task-role"
        ]
      }
    ]
  }'
```

### Step 3: CodeBuild 프로젝트 생성

> `buildspec.yml`을 읽고 Docker 이미지를 빌드하는 CodeBuild 프로젝트를 생성합니다.
> `privilegedMode: true`는 CodeBuild 컨테이너 안에서 Docker를 실행하기 위해 필수입니다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws codebuild create-project \
  --name ci-cd-demo-build \
  --source '{
    "type": "GITHUB",
    "location": "https://github.com/<본인-GitHub-ID>/aws-ecs-cicd-setup.git",
    "buildspec": "buildspec.yml"
  }' \
  --artifacts '{"type": "NO_ARTIFACTS"}' \
  --environment '{
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/amazonlinux2-x86_64-standard:5.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      {"name": "AWS_DEFAULT_REGION", "value": "us-east-1", "type": "PLAINTEXT"},
      {"name": "ECR_REPO_NAME", "value": "ci-cd-demo-app"}
    ]
  }' \
  --service-role "arn:aws:iam::${ACCOUNT_ID}:role/ci-cd-demo-codebuild-role" \
  --region us-east-1
```

> `<본인-GitHub-ID>`를 실제 GitHub ID로 교체하세요.

### Step 4: 수동 빌드 실행

```bash
BUILD_ID=$(aws codebuild start-build \
  --project-name ci-cd-demo-build \
  --region us-east-1 \
  --query 'build.id' --output text)

echo "Build started: $BUILD_ID"
```

### Step 5: 빌드 상태 확인

```bash
# 빌드 상태 확인 (SUCCEEDED가 될 때까지 반복)
aws codebuild batch-get-builds \
  --ids $BUILD_ID \
  --query 'builds[0].{Status:buildStatus,Phase:currentPhase}' \
  --region us-east-1
```

또는 **CodeBuild 콘솔**에서 빌드 로그를 실시간으로 확인:
```
CodeBuild → 빌드 프로젝트 → ci-cd-demo-build → 빌드 기록
```

> 빌드에 약 2~3분 소요됩니다.

### Step 6: ECR에 이미지 확인

```bash
aws ecr describe-images \
  --repository-name ci-cd-demo-app \
  --region us-east-1 \
  --query 'imageDetails[*].{Tag:imageTags[0],PushedAt:imagePushedAt}' \
  --output table
```

**기대 결과**: `latest` 태그의 이미지가 보여야 합니다.

---

## 5. Phase 3: ECS 서비스 생성

ECR에 이미지가 준비되었으므로 ECS 서비스를 생성합니다.

### Step 1: ECS 서비스 배포

```bash
cd ~/aws-ecs-cicd-setup/infrastructure
chmod +x phase2-1-deploy.sh
./phase2-1-deploy.sh
```

> 배포에 약 2~3분 소요됩니다.

### Step 2: 서비스 상태 확인

```bash
aws ecs describe-services \
  --cluster ci-cd-demo-cluster \
  --services ci-cd-demo-service \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
  --region us-east-1
```

**기대 결과**: `Running: 1, Desired: 1, Status: ACTIVE`

### Step 3: 애플리케이션 접속 테스트

```bash
# 변수가 설정되어 있지 않다면 다시 설정
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
  --output text --region us-east-1)

echo "애플리케이션 주소: http://$ALB_DNS"

# 접속 테스트
curl http://$ALB_DNS

# 헬스체크 확인
curl http://$ALB_DNS/health
```

**기대 결과**: 웹 페이지 응답 + `/health`에서 `SUCCESS` 반환

---

## 6. Phase 4: Blue/Green 배포 설정

> ECS 네이티브 Blue/Green은 **콘솔에서 설정**합니다. (2025년 출시, CodeDeploy 불필요)

### Step 1: ECS 콘솔 접속

```
ECS 콘솔 → 클러스터 → ci-cd-demo-cluster → 서비스 탭 → ci-cd-demo-service 선택
```

### Step 2: 배포 전략 변경

1. **서비스 업데이트** 버튼 클릭
2. **배포 옵션** 영역에서 **편집** 클릭
3. 아래 값으로 설정:

| 설정 항목 | 값 |
|----------|-----|
| 배포 전략 | **블루/그린** |
| Bake time | **10분** |

### Step 3: 로드 밸런싱 설정

| 설정 항목 | 값 |
|----------|-----|
| 컨테이너 | `app 8080:8080` |
| 로드 밸런서 | `ci-cd-demo-alb` |
| 리스너 | `HTTP:80` |
| 프로덕션 리스너 규칙 | `우선순위: default` |
| 블루 대상 그룹 | `ci-cd-demo-blue-tg` |
| 그린 대상 그룹 | `ci-cd-demo-green-tg` |
| **로드 밸런서 역할** | `ecsInfrastructureRoleForLoadBalancers` |

### Step 4: 배포 실패 감지 설정

> 헬스체크가 계속 실패하면 ECS가 새 Task를 무한 재시도합니다.
> **배포 회로 차단기(Circuit Breaker)**를 활성화하면 일정 횟수 실패 후 자동으로 롤백됩니다.

같은 서비스 업데이트 화면에서:

| 설정 항목 | 값 |
|----------|-----|
| 배포 실패 감지 | **배포 회로 차단기 사용** 활성화 |
| 롤백 | **체크** |

### Step 5: 업데이트 클릭

### Blue/Green 배포 라이프사이클

```
RECONCILE_SERVICE        서비스 상태 확인
       ↓
SCALE_UP                 Green 환경 생성
       ↓
PRODUCTION_TRAFFIC_SHIFT 프로덕션 트래픽 전환
       ↓
BAKE_TIME                안정화 대기 (10분)
       ↓
CLEAN_UP                 Blue 환경 정리
```

---

## 7. Phase 5: CodePipeline 구성 (GitHub 연동)

### Step 1: CodeStar Connections에서 GitHub 연결 생성

> CodeStar Connections는 AWS와 GitHub를 연결하는 서비스입니다.
> 이 연결을 통해 CodePipeline이 GitHub의 코드 변경을 감지하고 자동으로 파이프라인을 트리거합니다.

**콘솔에서 설정**:

```
AWS 콘솔 → 개발자 도구 → 설정 → 연결 → 연결 생성
```

| 설정 항목 | 값 |
|----------|-----|
| 공급자 선택 | **GitHub** |
| 연결 이름 | `ci-cd-demo-github` |

1. **GitHub에 연결** 클릭
2. **"새 앱 설치(Install new app)"** 클릭
3. GitHub 페이지로 이동 → **AWS Connector for GitHub** 를 **Enable** 클릭
4. Repository access에서 **All repositories** 또는 `aws-ecs-cicd-setup` 저장소 선택
5. **Save/Install** 클릭
6. AWS 콘솔로 돌아와서 **연결** 클릭

> 연결 상태가 **사용 가능(Available)** 이 되어야 합니다.
>
> **중요**: "새 앱 설치" 단계를 반드시 거쳐야 합니다. 이 단계를 건너뛰면 GitHub App이 "Authorized"만 되고 "Installed"가 되지 않아, push 시 자동 트리거가 동작하지 않습니다.
>
> 설치 확인: GitHub → Settings → Applications → **Installed GitHub Apps** 탭에 **AWS Connector for GitHub**가 있어야 합니다.

연결 ARN 확인:
```bash
aws codestar-connections list-connections \
  --region us-east-1 \
  --query 'Connections[?ConnectionName==`ci-cd-demo-github`].ConnectionArn' \
  --output text
```

### Step 2: CodePipeline 서비스 역할 생성

> CodePipeline이 CodeBuild 실행, ECS 서비스 업데이트, S3 접근 등을 수행하기 위한 IAM 역할입니다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# CodePipeline 서비스 역할 생성
aws iam create-role \
  --role-name ci-cd-demo-codepipeline-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "codepipeline.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# CodePipeline 정책 연결
aws iam put-role-policy \
  --role-name ci-cd-demo-codepipeline-role \
  --policy-name CodePipelinePolicy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"s3:GetObject\",
          \"s3:PutObject\",
          \"s3:GetBucketVersioning\"
        ],
        \"Resource\": \"*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"codebuild:BatchGetBuilds\",
          \"codebuild:StartBuild\"
        ],
        \"Resource\": \"*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"ecs:DescribeServices\",
          \"ecs:DescribeTaskDefinition\",
          \"ecs:DescribeTasks\",
          \"ecs:ListTasks\",
          \"ecs:RegisterTaskDefinition\",
          \"ecs:UpdateService\"
        ],
        \"Resource\": \"*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"iam:PassRole\",
        \"Resource\": [
          \"arn:aws:iam::${ACCOUNT_ID}:role/ci-cd-demo-ecs-task-execution-role\",
          \"arn:aws:iam::${ACCOUNT_ID}:role/ci-cd-demo-ecs-task-role\"
        ]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"codestar-connections:UseConnection\"
        ],
        \"Resource\": \"*\"
      }
    ]
  }"
```

### Step 3: Artifact Store용 S3 버킷 생성

> CodePipeline은 각 Stage 사이에 데이터를 직접 전달하지 못합니다.
> 이 S3 버킷이 중간 저장소 역할을 합니다 (소스코드 zip, imagedefinitions.json 등).
> ECR의 Docker 이미지와는 별개입니다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws s3 mb s3://ci-cd-demo-pipeline-artifacts-${ACCOUNT_ID} \
  --region us-east-1
```

### Step 4: CodePipeline 생성

> Source(GitHub) → Build(CodeBuild) 2단계로 구성된 파이프라인을 생성합니다.
> ECS 배포는 CodeBuild(buildspec.yml)에서 직접 트리거하므로 Deploy 단계가 없습니다.
> 이 방식은 Pipeline이 Bake Time에 묶이지 않아 빠르게 완료되며, Blue/Green 배포는 ECS가 백그라운드에서 독립적으로 진행합니다.
> 생성 즉시 첫 실행이 자동으로 트리거됩니다.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# CodeStar Connection ARN 확인
CONNECTION_ARN=$(aws codestar-connections list-connections \
  --region us-east-1 \
  --query 'Connections[?ConnectionName==`ci-cd-demo-github`].ConnectionArn' \
  --output text)

echo "Account ID: $ACCOUNT_ID"
echo "Connection ARN: $CONNECTION_ARN"
```

> **두 값이 모두 출력되는지 반드시 확인하세요.** CloudShell 세션이 끊어지면 변수가 초기화됩니다.
> CONNECTION_ARN이 비어있으면 연결 이름을 확인하거나, 아래 명령어로 전체 목록을 조회하세요:
> ```bash
> aws codestar-connections list-connections --region us-east-1
> ```

아래 명령어에서 `<본인-GitHub-ID>`를 교체하세요:

```bash
aws codepipeline create-pipeline \
  --region us-east-1 \
  --pipeline "{
    \"name\": \"ci-cd-demo-pipeline\",
    \"pipelineType\": \"V2\",
    \"roleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/ci-cd-demo-codepipeline-role\",
    \"artifactStore\": {
      \"type\": \"S3\",
      \"location\": \"ci-cd-demo-pipeline-artifacts-${ACCOUNT_ID}\"
    },
    \"stages\": [
      {
        \"name\": \"Source\",
        \"actions\": [
          {
            \"name\": \"GitHub-Source\",
            \"actionTypeId\": {
              \"category\": \"Source\",
              \"owner\": \"AWS\",
              \"provider\": \"CodeStarSourceConnection\",
              \"version\": \"1\"
            },
            \"configuration\": {
              \"ConnectionArn\": \"${CONNECTION_ARN}\",
              \"FullRepositoryId\": \"<본인-GitHub-ID>/aws-ecs-cicd-setup\",
              \"BranchName\": \"main\",
              \"OutputArtifactFormat\": \"CODE_ZIP\"
            },
            \"outputArtifacts\": [{\"name\": \"SourceOutput\"}]
          }
        ]
      },
      {
        \"name\": \"Build\",
        \"actions\": [
          {
            \"name\": \"CodeBuild\",
            \"actionTypeId\": {
              \"category\": \"Build\",
              \"owner\": \"AWS\",
              \"provider\": \"CodeBuild\",
              \"version\": \"1\"
            },
            \"configuration\": {
              \"ProjectName\": \"ci-cd-demo-build\"
            },
            \"inputArtifacts\": [{\"name\": \"SourceOutput\"}]
          }
        ]
      }
    ],
    \"triggers\": [
      {
        \"providerType\": \"CodeStarSourceConnection\",
        \"gitConfiguration\": {
          \"sourceActionName\": \"GitHub-Source\",
          \"push\": [
            {
              \"branches\": {
                \"includes\": [\"main\"]
              }
            }
          ]
        }
      }
    ]
  }"
```

> 파이프라인 생성 시 자동으로 첫 실행이 트리거됩니다.

### Step 5: 파이프라인 상태 확인

```bash
aws codepipeline get-pipeline-state \
  --name ci-cd-demo-pipeline \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status}' \
  --region us-east-1 \
  --output table
```

또는 **CodePipeline 콘솔**에서 시각적으로 확인:
```
CodePipeline → 파이프라인 → ci-cd-demo-pipeline
```

**기대 결과**: Source → Build 모두 **Succeeded** (ECS Blue/Green 배포는 백그라운드에서 진행)

---

## 8. Phase 6: CI/CD 자동 배포 테스트

CodePipeline이 구성되었으므로, 코드를 변경하고 자동 배포를 테스트합니다.

### Step 1: 환경 변수 확인

```bash
# 세션이 끊어졌다면 다시 설정
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
  --output text --region us-east-1)
echo "ALB DNS: $ALB_DNS"
```

### Step 2: 코드 변경 (CloudShell에서)

```bash
cd ~/aws-ecs-cicd-setup
vi app.py
```

`app.py`에서 메시지를 변경합니다:

```python
# 변경 전
return render_template("index.html", message=f" 1 CI/CD test - [current env]  Task: {hostname}")

# 변경 후
return render_template("index.html", message=f" 2 Blue/Green test - [v2]  Task: {hostname}")
```

### Step 3: Push

```bash
git add .
git commit -m "v2: Blue/Green deployment test"
git push origin main
```

> 최초 push 시 GitHub Username과 PAT(Password)을 입력합니다.

### Step 4: CodePipeline 트리거 확인

Push 후 CodePipeline이 자동으로 실행됩니다.

> 자동 트리거가 동작하지 않는 경우 수동으로 실행할 수 있습니다:
> ```bash
> aws codepipeline start-pipeline-execution \
>   --name ci-cd-demo-pipeline \
>   --region us-east-1
> ```

```bash
# 파이프라인 실행 상태 확인
aws codepipeline get-pipeline-state \
  --name ci-cd-demo-pipeline \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status}' \
  --region us-east-1 \
  --output table
```

**콘솔 확인**:
```
CodePipeline → ci-cd-demo-pipeline → 각 Stage 진행 상황 확인
```

### Step 5: ECS 배포 상태 모니터링

```bash
# Blue/Green 배포 상태
aws ecs describe-services \
  --cluster ci-cd-demo-cluster \
  --services ci-cd-demo-service \
  --query 'services[0].deployments[*].{Status:status,Running:runningCount,Desired:desiredCount,Rollout:rolloutState}' \
  --region us-east-1 \
  --output table
```

### Step 6: 결과 확인

```bash
curl http://$ALB_DNS
```

**기대 결과**: "v2: Blue/Green test" 메시지가 표시됨

---

## 9. Phase 7: 자동 롤백 테스트

> 롤백은 **배포 중(Bake Time 이내)** 에만 발생합니다.

### 테스트 1: 헬스체크 실패 (권장)

#### Step 1: 환경 변수 확인

```bash
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name ci-cd-demo-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
  --output text --region us-east-1)
```

#### Step 2: 헬스체크를 실패하도록 코드 변경

```bash
cd ~/aws-ecs-cicd-setup
vi app.py
```

```python
# 변경 전
@app.route('/health')
def health():
    return "SUCCESS", 200

# 변경 후
@app.route('/health')
def health():
    return "FAIL", 500
```

#### Step 3: Push

```bash
git add .
git commit -m "rollback test: health check failure"
git push origin main
```

#### Step 4: CodePipeline + 롤백 과정 모니터링

**CodePipeline 콘솔**에서 Source → Build 진행 확인

**ECS 배포 상태 (CloudShell)**:
```bash
watch -n 10 'aws ecs describe-services \
  --cluster ci-cd-demo-cluster \
  --services ci-cd-demo-service \
  --query "services[0].deployments[*].{Status:status,Running:runningCount,Rollout:rolloutState}" \
  --region us-east-1 \
  --output table'
```

> `Ctrl+C`로 종료

#### 예상 결과

```
1. CodePipeline Source    → 성공
2. CodeBuild 빌드 + 배포  → 성공 (Pipeline 완료)
3. ECS Blue/Green 배포    → 시작 (백그라운드)
4. 새 태스크 시작          → 성공
5. ALB 헬스체크            → 실패 (HTTP 500, 3회 연속)
6. Circuit Breaker        → 자동 롤백
```

**롤백 소요 시간**: 약 2~5분

#### Step 5: 롤백 확인

```bash
# 기존 버전이 여전히 동작하는지 확인
curl http://$ALB_DNS
curl http://$ALB_DNS/health
```

**기대 결과**: 이전 정상 버전(v2)이 그대로 응답

#### Step 6: 코드 복구

```bash
vi app.py
# health를 다시 200으로 복구
```

```python
@app.route('/health')
def health():
    return "SUCCESS", 200
```

```bash
git add .
git commit -m "restore: health check back to normal"
git push origin main
```

### 테스트 2: CloudWatch 알람 기반 롤백 (선택)

#### Step 1: CloudWatch 알람 생성

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

> `HTTPCode_ELB_5XX_Count`가 아닌 `HTTPCode_Target_5XX_Count` 사용!
> - `ELB_5XX`: ALB 자체 오류 (502, 503)
> - `Target_5XX`: 앱에서 반환하는 500 에러

#### Step 2: ECS 서비스에 알람 연결

```
ECS 콘솔 → 서비스 → 배포 탭 → 편집
→ "배포 실패 감지" → "CloudWatch 알람 사용" 활성화
→ ci-cd-demo-5xx-alarm 선택 → 업데이트
```

#### Step 3: 50% 에러 코드 배포

`app.py` 전체를 아래로 교체합니다:

```python
from flask import Flask, render_template
import os
import socket
import random

app = Flask(__name__)

@app.route("/")
def hello():
    if random.random() < 0.5:
        return "Internal Server Error", 500
    hostname = socket.gethostname()[:12]
    return render_template("index.html", message=f"CloudWatch alarm test - Task: {hostname}")

@app.route("/health")
def health():
    return "SUCCESS", 200  # 헬스체크는 통과 (배포 성공 → Bake Time 진입)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

```bash
git add .
git commit -m "alarm test: 50% error rate"
git push origin main
```

#### Step 4: Bake Time 중에 트래픽 발생

> **중요**: 반드시 **Bake Time 중에** 실행해야 롤백이 발생합니다.
> Bake Time이 끝난 후에 트래픽을 보내면 롤백되지 않습니다.
>
> ECS 콘솔 → 클러스터 → ci-cd-demo-cluster → 서비스 → ci-cd-demo-service → **배포** 탭에서
> 배포 상태가 **BAKE_TIME** 인지 확인한 후 아래 명령을 실행하세요.

```bash
for i in $(seq 1 100); do
  curl -s -o /dev/null -w "%{http_code}\n" http://$ALB_DNS/
  sleep 0.5
done
```

#### Step 5: 알람 상태 확인

```bash
aws cloudwatch describe-alarms \
  --alarm-names ci-cd-demo-5xx-alarm \
  --query 'MetricAlarms[0].StateValue' \
  --region us-east-1
```

**예상 결과**: `ALARM` → Bake Time 중이면 자동 롤백

---

## 10. 리소스 정리

> 테스트 완료 후 **반드시** 리소스를 삭제하여 추가 비용을 방지하세요.

### 주의사항

ECS 서비스가 Blue/Green 모드로 변경된 상태에서는 CloudFormation `delete-stack`이 실패할 수 있습니다. 이 경우 아래 순서를 따르세요:

1. ECS 콘솔에서 서비스의 배포 전략을 **롤링 업데이트**로 되돌린 후 삭제
2. 또는 ECS 서비스를 콘솔에서 직접 삭제한 후 CloudFormation 스택 삭제

### 삭제 순서 (역순으로)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 1. CodePipeline 삭제
aws codepipeline delete-pipeline \
  --name ci-cd-demo-pipeline \
  --region us-east-1

# 2. CodeBuild 프로젝트 삭제
aws codebuild delete-project \
  --name ci-cd-demo-build \
  --region us-east-1

# 3. CodeStar Connection 삭제
CONNECTION_ARN=$(aws codestar-connections list-connections \
  --region us-east-1 \
  --query 'Connections[?ConnectionName==`ci-cd-demo-github`].ConnectionArn' \
  --output text)

if [ -n "$CONNECTION_ARN" ]; then
  aws codestar-connections delete-connection \
    --connection-arn $CONNECTION_ARN \
    --region us-east-1
fi

# 4. S3 Artifact 버킷 삭제
aws s3 rb s3://ci-cd-demo-pipeline-artifacts-${ACCOUNT_ID} --force

# 5. ECS 서비스 desire count를 0으로 변경 후 스택 삭제
aws ecs update-service \
  --cluster ci-cd-demo-cluster \
  --service ci-cd-demo-service \
  --desired-count 0 \
  --region us-east-1 2>/dev/null

aws cloudformation delete-stack \
  --stack-name ci-cd-demo-ecs-service \
  --region us-east-1

echo "ECS 서비스 삭제 대기중..."
aws cloudformation wait stack-delete-complete \
  --stack-name ci-cd-demo-ecs-service \
  --region us-east-1

# 6. ECR 이미지 삭제
aws ecr batch-delete-image \
  --repository-name ci-cd-demo-app \
  --image-ids "$(aws ecr list-images --repository-name ci-cd-demo-app --region us-east-1 --query 'imageIds[*]' --output json)" \
  --region us-east-1

# 7. 인프라 스택 삭제
aws cloudformation delete-stack \
  --stack-name ci-cd-demo-infrastructure \
  --region us-east-1

echo "인프라 삭제 대기중..."
aws cloudformation wait stack-delete-complete \
  --stack-name ci-cd-demo-infrastructure \
  --region us-east-1

# 8. IAM 역할 삭제
aws iam delete-role-policy --role-name ci-cd-demo-codebuild-role --policy-name CodeBuildPolicy
aws iam delete-role --role-name ci-cd-demo-codebuild-role

aws iam delete-role-policy --role-name ci-cd-demo-codepipeline-role --policy-name CodePipelinePolicy
aws iam delete-role --role-name ci-cd-demo-codepipeline-role

# 9. CodeBuild GitHub 인증 정보 삭제
SOURCE_CRED_ARN=$(aws codebuild list-source-credentials \
  --query 'sourceCredentialsInfos[?serverType==`GITHUB`].arn' \
  --output text --region us-east-1)

if [ -n "$SOURCE_CRED_ARN" ]; then
  aws codebuild delete-source-credentials \
    --arn $SOURCE_CRED_ARN \
    --region us-east-1
fi

echo "모든 리소스가 삭제되었습니다."
```

### CloudWatch 알람 삭제 (생성한 경우)

```bash
aws cloudwatch delete-alarms \
  --alarm-names ci-cd-demo-5xx-alarm \
  --region us-east-1
```

### 삭제 확인

```bash
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[?contains(StackName,`ci-cd-demo`)].StackName' \
  --region us-east-1
```

---

## 11. FAQ

### Q: CloudShell에서 Docker를 사용할 수 없는데 어떻게 하나요?

**A**: Docker 이미지 빌드는 **CodeBuild가 담당**합니다. CloudShell은 인프라 구축, 모니터링, 확인 작업만 수행합니다.

### Q: CodeDeploy는 더 이상 필요 없나요?

**A**: ECS Blue/Green 배포의 경우 **불필요**합니다. 2025년 AWS가 ECS 네이티브 Blue/Green을 출시하면서 CodeDeploy 없이 ECS 자체에서 Blue/Green을 지원합니다.

### Q: CloudShell 세션이 끊어지면 어떻게 하나요?

**A**: CloudShell 홈 디렉토리(`~/`)의 파일은 유지됩니다. 재접속 후:
1. `cd ~/aws-ecs-cicd-setup` 으로 이동
2. Phase 1 Step 4의 환경 변수 블록을 다시 실행

단, 20분 비활성 시 세션이 종료되므로 장시간 대기 작업은 주의하세요.

### Q: 롤백은 자동인가요?

**A**: 네, 다음 조건에서 자동 롤백됩니다:
- 헬스체크 실패 (3회 연속)
- 태스크 시작 실패
- CloudWatch 알람 트리거 (설정 시)

### Q: Bake Time이란?

**A**: 트래픽 전환 후 이전 환경을 유지하는 시간입니다. 이 시간 동안 문제가 발생하면 즉시 롤백할 수 있습니다. 서비스 특성과 운영 기준에 따라 적절한 값을 설정하세요. (이 워크샵에서는 10분으로 설정)

### Q: 비용은 얼마나 드나요?

**A**: 테스트 완료 후 반드시 리소스를 삭제하세요!
- ECS Blue/Green 자체: **무료**
- CodePipeline: V2 기준 $0.002/action execution minute (월 100분 무료)
- CodeBuild: 빌드 시간 기준 과금 (general1.small 월 100분 무료, 만료 없음)
- Fargate: 태스크 수 x 실행 시간 x (vCPU + 메모리)
- CloudShell: **무료**

---

## 참고 자료

- [AWS 공식: ECS Blue/Green 배포](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-blue-green.html)
- [AWS 공식: CodePipeline + ECS](https://docs.aws.amazon.com/codepipeline/latest/userguide/ecs-cd-pipeline.html)
- [AWS 공식: CodeStar Connections](https://docs.aws.amazon.com/codepipeline/latest/userguide/connections-github.html)
- [AWS 블로그: Amazon ECS 내장 블루/그린 배포](https://aws.amazon.com/ko/blogs/korea/accelerate-safe-software-releases-with-new-built-in-blue-green-deployments-in-amazon-ecs/)
