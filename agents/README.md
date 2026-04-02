# LiDAR Golf Putting Analyzer — Multi-Agent System

Claude API 기반의 전문 에이전트 시스템. 각 에이전트는 자신의 도메인 파일을 분석하고 개선하며,
평가 에이전트가 결과를 검토하고 피드백 루프를 통해 품질을 보장합니다.

---

## 시스템 구조

```
agents/
├── run.py              ← CLI 진입점
├── harness.py          ← 파이프라인 오케스트레이터
├── config.py           ← 프로젝트 설정
├── requirements.txt
├── agents/
│   ├── base.py         ← 공통 도구 + 에이전트 루프
│   ├── lidar.py        ← LiDAR 스캐닝 전문가
│   ├── ui.py           ← UI/뷰 전문가
│   ├── physics.py      ← 물리/분석 전문가
│   ├── vision.py       ← 비전/감지 전문가
│   └── evaluator.py    ← 평가 에이전트
├── prompts/            ← 각 에이전트의 전문 시스템 프롬프트
│   ├── lidar.md
│   ├── ui.md
│   ├── physics.md
│   ├── vision.md
│   └── evaluator.md
├── results/            ← 실행 결과 JSON
└── logs/               ← 실행 로그
```

---

## 전문 에이전트

| 에이전트    | 담당 파일 | 전문 영역 |
|------------|-----------|-----------|
| `lidar`    | `LiDAR/LiDARScanner.swift` | ARKit, 깊이 처리, 하이트맵 |
| `ui`       | `Views/MainViewController.swift`, `*OverlayView.swift`, `MeshGrid3DView.swift`, `TrajectoryOverlayView.swift` | 상태 기계, AR 오버레이, SceneKit |
| `physics`  | `Utils/TerrainAnalyzer.swift`, `PuttingPhysics.swift`, `MathUtils.swift` | 경사 분석, 퍼팅 물리, 벡터 수학 |
| `vision`   | `Views/VisionDetector.swift`, `Utils/DepthImageRenderer.swift` | 원 감지, 깊이→컬러 렌더링 |
| `evaluator`| (모든 파일 읽기) | 코드 품질 평가, 피드백 생성 |

---

## 에이전트 도구

모든 전문 에이전트는 다음 도구를 사용할 수 있습니다:

- **`read_file`** — Swift 소스 파일을 줄 번호와 함께 읽기
- **`write_file`** — 파일 전체 내용 작성 (생성/덮어쓰기)
- **`list_directory`** — 디렉토리 내 파일 목록
- **`search_code`** — 정규식으로 프로젝트 파일 검색
- **`run_syntax_check`** — `swiftc -parse`로 Swift 문법 검사

---

## 평가 파이프라인

```
task → [라우터] → 전문 에이전트들 → [평가 에이전트] → PASS? → 완료
                       ↑                    ↓ FAIL
                  [피드백 반영]  ←  [에이전트별 피드백]
                 (최대 3회 반복)
```

### 평가 점수 기준

| 차원 | 가중치 | 검사 항목 |
|------|--------|-----------|
| 정확성 | 35% | 논리, 알고리즘, 경계 조건 |
| 안전성 | 25% | 강제 언래핑, nil 처리, 스레드 안전성 |
| 완성도 | 20% | 요구 사항 충족, 회귀 없음 |
| 코드 품질 | 10% | Swift 관용구, 가독성, 문서화 |
| 성능 | 10% | 핫 패스 알고리즘, 메인 스레드 블로킹 없음 |

**통과 기준**: 전체 점수 ≥ 7.0 AND CRITICAL 이슈 없음

---

## 설치 및 실행

```bash
cd /Volumes/LeeUSB/SwiftProject/lidar_test/agents

# 의존성 설치
pip install -r requirements.txt

# API 키 설정
export ANTHROPIC_API_KEY="sk-ant-..."

# 전체 파이프라인 실행 (에이전트 자동 선택 + 평가)
python run.py "LiDARScanner에서 depth frame이 nil일 때 크래시 수정"

# 특정 에이전트만 실행 (평가 없음)
python run.py --agent physics "오르막 퍼팅의 브레이크 계산 정확도 개선"

# 분석 모드 (파일 수정 없이 검토만)
python run.py --analyze "LiDARScanner 콜백의 스레드 안전성 검토"

# 사용 가능한 에이전트 목록
python run.py --list-agents
```

---

## 결과 파일

각 실행 후 `results/run_YYYYMMDD_HHMMSS.json`에 저장됩니다:

```json
{
  "task": "...",
  "success": true,
  "iterations": [
    {
      "iteration": 1,
      "agents_run": ["lidar"],
      "evaluation_score": 8.5,
      "evaluation_pass": true,
      "issues": []
    }
  ],
  "final_evaluation": {
    "overall_score": 8.5,
    "approved_changes": ["ios/Runner/LiDAR/LiDARScanner.swift"]
  }
}
```

---

## 사용 예시

```bash
# 버그 수정
python run.py "TrajectoryOverlayView에서 ball position이 화면 밖으로 나가는 버그 수정"

# 기능 개선
python run.py "스캔 완료 후 메시 품질 점수 계산 로직 개선"

# 성능 최적화
python run.py --agent lidar "하이트맵 업데이트를 vDSP로 최적화"

# 코드 리뷰
python run.py --analyze "PuttingPhysics의 수치 정확도 전체 검토"
```
