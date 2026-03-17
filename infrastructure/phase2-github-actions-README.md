# Phase 2: CI/CD 파이프라인 (CodePipeline)

> 이 워크샵에서는 GitHub Actions 대신 **AWS CodePipeline + CodeBuild**를 사용합니다.

## 파이프라인 구성요소

| 구성요소 | 역할 |
|---------|------|
| **CodeStar Connections** | GitHub 저장소 연동 |
| **CodePipeline** | 파이프라인 오케스트레이션 (Source → Build → Deploy) |
| **CodeBuild** | Docker 이미지 빌드 및 ECR 푸시 |
| **buildspec.yml** | CodeBuild 빌드 스펙 |

## 파이프라인 동작 과정

### 1. 트리거
- `main` 브랜치에 push 시 CodePipeline 자동 실행 (CodeStar Connections 연동)

### 2. Source Stage
- CodeStar Connections를 통해 GitHub에서 소스 코드 가져오기

### 3. Build Stage (CodeBuild)
1. ECR 로그인
2. Docker 이미지 빌드
3. ECR에 이미지 푸시 (commit hash 태그 + latest)
4. `imagedefinitions.json` 생성 (Deploy Stage에서 사용)

### 4. Deploy Stage (Amazon ECS)
1. `imagedefinitions.json`에서 새 이미지 URI 확인
2. ECS Task Definition 업데이트
3. ECS 서비스에 새 Task Definition 배포
4. Blue/Green 설정 시 자동으로 Blue/Green 전환

## 설정 필요사항

### CodeStar Connections 설정 (콘솔)

```
AWS 콘솔 → 개발자 도구 → 설정 → 연결 → 연결 생성
→ 공급자: GitHub
→ 연결 이름: ci-cd-demo-github
→ "새 앱 설치" → GitHub에서 AWS Connector for GitHub Enable
→ 저장소 접근 권한 허용 → 연결
```

> "새 앱 설치" 단계를 반드시 거쳐야 push 시 자동 트리거가 동작합니다.

### CodeBuild 프로젝트 생성 (CLI)

자세한 절차는 `readme_cloudshell.md` Phase 2, Phase 5를 참조하세요.

### 주요 파일

- **`buildspec.yml`**: CodeBuild 빌드 스펙 (Docker 빌드 + ECR 푸시 + imagedefinitions.json)
- **`task-definition.json`**: ECS Task Definition 템플릿

### Task Definition 수정

`task-definition.json`에서 `{ACCOUNT_ID}`를 실제 AWS 계정 ID로 교체:

**Account ID 확인 방법:**
```bash
aws sts get-caller-identity --query Account --output text
```

## CodePipeline을 사용하는 이유

| 항목 | CodePipeline | GitHub Actions |
|------|-------------|----------------|
| CI/CD 리소스 위치 | AWS 내 완결 | GitHub 측 |
| 인증 방식 | CodeStar Connections | GitHub Secrets |
| 모니터링 | CodePipeline 콘솔 | GitHub Actions 탭 |
| 고객 환경 | 동일 경험 | 별도 구성 |

## 다음 단계

- `phase2-1-deploy.sh` 로 ECS 서비스 생성
