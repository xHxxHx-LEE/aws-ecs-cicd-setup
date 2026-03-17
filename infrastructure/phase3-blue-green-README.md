# Phase 3: ECS 네이티브 Blue/Green 배포 설정

## 개요

AWS ECS의 **네이티브 Blue/Green 배포** 기능을 사용합니다.
2025년 출시된 이 기능은 CodeDeploy 없이 ECS 자체에서 Blue/Green 배포를 지원합니다.

## 전제 조건

- ✅ Phase 1: 기본 인프라 완료 (ecsInfrastructureRoleForLoadBalancers 포함)
- ✅ Phase 2-1: ECS 서비스 생성 완료

## Blue/Green 배포 설정 (콘솔)

### 1. ECS 콘솔에서 서비스 편집

```
ECS → 클러스터 → ci-cd-demo-cluster → 서비스 → ci-cd-demo-service → 배포 탭 → 편집
```

### 2. 설정값

| 항목 | 값 |
|------|-----|
| 배포 전략 | **블루/그린** |
| Bake time | 5분 |
| 컨테이너 | `app 8080:8080` |
| 로드 밸런서 | `ci-cd-demo-alb` |
| 리스너 | `HTTP:80` |
| 프로덕션 리스너 규칙 | `우선순위: default` |
| 블루 대상 그룹 | `ci-cd-demo-blue-tg` |
| 그린 대상 그룹 | `ci-cd-demo-green-tg` |
| **로드 밸런서 역할** | `ecsInfrastructureRoleForLoadBalancers` |

---

## Blue/Green 배포 흐름

```
1. Green 환경 생성    새 태스크 시작, 헬스체크 대기
        ↓
2. 트래픽 전환       ALB가 Blue → Green으로 전환
        ↓
3. Bake Time        5분간 모니터링 (문제 시 롤백)
        ↓
4. Blue 정리        기존 태스크 종료
```

### 배포 상태 확인 위치

**콘솔**:
```
ECS → 클러스터 → 서비스 → 배포 탭
```

**CLI**:
```bash
aws ecs describe-services \
  --cluster ci-cd-demo-cluster \
  --services ci-cd-demo-service \
  --query 'services[0].deployments' \
  --region us-east-1
```

---

## 자동 롤백 조건

| 조건 | 설명 |
|------|------|
| 헬스체크 실패 | ALB `/health` 체크 3회 연속 실패 |
| 태스크 시작 실패 | 컨테이너 크래시, 이미지 pull 실패 등 |
| CloudWatch 알람 | 설정된 알람 트리거 시 |

> ⚠️ 롤백은 **배포 중**에만 발생합니다. 배포 완료 후 문제는 태스크 재시작으로 처리됩니다.

---

## CodeDeploy 방식과의 차이

| 항목 | ECS 네이티브 | CodeDeploy |
|------|-------------|------------|
| 추가 리소스 | 불필요 | CodeDeploy App, Deployment Group |
| appspec.yml | 불필요 | 필요 |
| 설정 위치 | ECS 서비스 내 | CodeDeploy 별도 관리 |
| AWS 권장 | **현재 권장** | 레거시 |
