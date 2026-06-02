# Golf Putting LiDAR 시스템 정밀 분석 및 개선 제안

작성일: 2026-05-30  
대상: `ios/GolfPuttingLiDAR` iOS Swift/ARKit LiDAR 앱

## 1. 분석 범위와 검증 상태

본 분석은 로컬 소스 코드, Xcode 프로젝트 설정, Git 상태, GitNexus 영향도 분석을 기준으로 수행했다. `LiDARScanner` 변경 영향도는 MEDIUM, `PuttingPhysics` 변경 영향도는 HIGH로 확인되어 공개 API를 유지한 상태에서 내부 구현 중심으로 수정했다.

검증 결과:

- 프로젝트 스킴: `GolfPuttingLiDAR`
- 타깃: 앱 타깃 1개만 존재
- 테스트 타깃: 없음
- `swiftlint`, `swiftformat`: 현재 시스템에 설치되어 있지 않음
- `xcodebuild -list -project ios/GolfPuttingLiDAR.xcodeproj`: 성공
- `xcrun --sdk iphoneos swiftc ... -typecheck`: 성공
- `xcodebuild ... build`: Swift 컴파일에는 진입했으나 이 환경의 Interface Builder/iOS 26.4 platform 문제로 `LaunchScreen.storyboard` 컴파일에서 실패
- 현재 Git 상태: `main`은 `origin/main` 기준 로컬 변경사항을 포함함. 기존 추적되지 않은 항목은 `github-sync.command`, `ios/Runner.xcodeproj/`

## 1.1 코드 반영 현황

2026-05-30 기준으로 다음 개선이 코드에 반영되었다.

- Depth 좌표 변환: camera intrinsics를 depth map 해상도에 맞춰 스케일링
- PixelBuffer 접근: depth/confidence 렌더링과 스캔 수집 모두 bytes-per-row 기반으로 변경
- 스캔 종료: 30프레임 즉시 종료 제거, 최소 프레임/시간/ROI 커버리지/반복 관측 기반 자동 종료로 변경
- 데이터 레이스: ARSessionDelegate 전용 serial queue 적용, 스트리밍 스냅샷은 누적 버퍼와 같은 queue에서 생성
- 누적 버퍼: 2차원 배열에서 flat buffer로 변경하고 셀별 height variance 기반 uncertainty map 추가
- 높이 기준: 최종 height map은 ground baseline 기준 상대 높이로 저장하고 AR 투영 시 `groundY`를 다시 더함
- LOD 좌표계: subregion local origin을 명시하고 원본/LOD 좌표 변환을 helper로 통일
- 퍼팅 물리: Bezier 휴리스틱에서 경사/마찰/업힐/다운힐을 반영한 2D numerical simulation 탐색으로 교체
- World Map 저장: `UserDefaults` 직접 저장에서 Application Support 파일 저장으로 변경
- 자동 감지: 스캔 완료 후 Vision 자동 감지 흐름을 실제 진입 경로로 연결
- 오버레이 성능: 경사 최대값 재계산을 terrain signature 기반 캐시로 완화

## 2. 현재 시스템 구조 요약

앱은 UIKit 기반 단일 iOS 앱이며, 핵심 흐름은 다음과 같다.

- `MainViewController`: AR 뷰, 스캔 상태, UI, 위치 지정, 측정 실행을 모두 관리
- `LiDARScanner`: `ARSessionDelegate`로 LiDAR/SceneDepth 프레임을 수집하고 160x160 높이 맵으로 축적
- `HeightMapData`: 높이/신뢰도 그리드 데이터 모델
- `TerrainAnalyzer`: 경사, 높이 범위, Stimp 추정
- `PuttingPhysics`: 퍼팅 속도와 경로 추정
- `TrajectoryOverlayView`: 2D/AR 투영 오버레이 렌더링
- `MeshGrid3DView`: SceneKit 3D 지형 시각화
- `VisionDetector`: Vision 기반 원형 후보 감지

전체적으로 기능은 한 앱 안에 잘 연결되어 있으나, 측정 정확도에 직접 영향을 주는 좌표 변환과 스캔 종료 기준, 성능에 직접 영향을 주는 프레임 처리 방식이 가장 먼저 개선되어야 한다.

## 3. 우선순위 높은 문제점

| 우선순위 | 문제 | 영향 | 근거 |
|---|---|---|---|
| P0 | 깊이 맵 픽셀을 카메라 좌표로 변환할 때 intrinsics 해상도 보정이 없음 | 실제 월드 좌표가 틀어져 높이 맵, 경사, 퍼팅 경로 전체 정확도 저하 | `LiDARScanner.processDepthData`, `ios/GolfPuttingLiDAR/LiDAR/LiDARScanner.swift:512` |
| P0 | `CVPixelBuffer` row stride를 무시하고 `v * width + u`로 접근 | 버퍼 padding이 있는 기기/포맷에서 잘못된 픽셀을 읽을 수 있음 | `LiDARScanner.swift:506`, `DepthImageRenderer.swift:44`, `LiDARScanner.swift:774` |
| P0 | 스캔 진행률이 `frameCount / 30`이고 30프레임 도달 시 바로 종료 | 약 1초 내 자동 종료되어 커버리지/품질이 충분하지 않아도 스캔 완료 가능 | `LiDARScanner.swift:47`, `LiDARScanner.swift:370`, `MainViewController.swift:1306` |
| P0 | 스트리밍 스냅샷이 백그라운드에서 누적 배열을 읽는 동안 AR delegate가 같은 배열을 수정 | 데이터 레이스, 간헐적 크래시, 깨진 미리보기 가능 | `LiDARScanner.swift:592`, `LiDARScanner.swift:637`, `LiDARScanner.swift:647` |
| P1 | LOD 고해상도 서브 리전 좌표계가 원본 좌표계와 일관되지 않음 | 고해상도 계산을 켰을 때 볼/홀 위치, 경사 샘플링, 경로가 실제 위치에서 벗어날 수 있음 | `MathUtils.swift:163`, `MathUtils.swift:223`, `MainViewController.swift:1088` |
| P1 | 퍼팅 물리는 Bezier 휴리스틱이며 업힐/다운힐 속도, 감속, 컵 도달 판정이 없음 | 추천 속도와 브레이크가 실제 퍼팅과 다를 가능성 높음 | `PuttingPhysics.swift:3`, `PuttingPhysics.swift:104` |
| P1 | 커버리지 계산이 전체 목표 영역이 아니라 채워진 셀 bounding box 기준 | 작은 영역만 빽빽하게 채워져도 높은 커버리지로 판단 가능 | `LiDARScanner.swift:716` |
| P1 | 높이 범위는 cm인데 UI는 m로 표시 | 사용자에게 높이차가 100배 잘못 보일 수 있음 | `TerrainAnalyzer.swift:26`, `MainViewController.swift:736` |
| P2 | World Map을 `UserDefaults`에 직접 저장 | 데이터가 커지면 앱 설정 저장소에 부담, 실패/마이그레이션 처리 취약 | `MainViewController.swift:617` |
| P2 | 자동 감지 코드가 있으나 스캔 완료 후 수동 위치 지정으로 바로 이동 | 구현된 Vision 흐름이 실제 UX에서 활용되지 않음 | `MainViewController.swift:762`, `MainViewController.swift:769` |

## 4. 정확도 개선 제안

### 4.1 Depth 좌표 변환을 먼저 고쳐야 함

현재 `processDepthData`는 `frame.camera.intrinsics`를 깊이 맵 픽셀 좌표에 그대로 사용한다. ARKit의 camera intrinsics는 보통 captured image 기준이고, scene depth map은 더 낮은 해상도다. 따라서 depth map 크기에 맞춰 intrinsics를 스케일링해야 한다.

개선 방향:

- `frame.camera.imageResolution`과 `CVPixelBufferGetWidth/Height(depthMap)`의 비율을 계산
- `fx`, `fy`, `cx`, `cy`를 depth map 좌표계로 변환
- 화면 회전과 image orientation 영향을 별도로 검증
- 실측 검증: 평평한 바닥 1m x 1m를 스캔했을 때 재구성 평면 RMS 오차를 기록

### 4.2 PixelBuffer 접근은 bytesPerRow 기반으로 변경

현재 깊이/신뢰도 버퍼 접근은 선형 index를 `v * width + u`로 계산한다. `CVPixelBuffer`는 row padding이 있을 수 있으므로 `CVPixelBufferGetBytesPerRow`를 사용해야 한다.

개선 방향:

- depth row stride: `CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride`
- confidence row stride: `CVPixelBufferGetBytesPerRow(confMap)`
- `DepthImageRenderer`와 `calculateAverageConfidence`도 같은 방식으로 수정

### 4.3 자동 종료 기준을 품질 기반으로 바꿔야 함

현재는 30프레임 수집 후 `progress >= 1.0`이면 `stopScanning()`을 호출한다. 30fps 환경에서는 약 1초 만에 종료될 수 있다. LiDAR 측정은 시간보다 ROI 커버리지, 지점별 반복 관측 수, 안정성, 기울기 품질이 더 중요하다.

개선 방향:

- 최소 시간: 3~5초
- 최소 프레임: 90~150프레임
- ROI 기준 커버리지: 목표 ROI 셀 대비 유효 셀 비율
- 셀당 최소 관측 수: 예: 중앙 경로 영역 평균 3~5회 이상
- 품질 조건이 연속 N프레임 유지될 때만 자동 종료
- 사용자가 명시적으로 중지한 경우와 자동 종료를 분리

### 4.4 높이 맵 기준면과 불확실도를 명시적으로 관리

현재는 월드 Y 좌표를 누적하고 groundY를 별도로 저장하지만, 실제 높이 맵 값은 기준면으로 정규화되지 않는다. 경사는 높이 차분이라 큰 문제는 덜하지만, 표시/통계/필터링에서는 기준면과 이상치가 영향을 준다.

개선 방향:

- 최종 height map은 `worldY - fittedGroundPlaneY(x,z)` 또는 `worldY - groundY`로 정규화
- 수집 point cloud에서 RANSAC/least squares로 그린 평면을 추정
- 셀별 평균만 저장하지 말고 분산, 관측 수, 신뢰도 합계를 함께 저장
- 최종 confidence는 단순 `wsum / 5`보다 관측 수, 분산, ARKit confidence를 결합

### 4.5 LOD 좌표계를 재설계해야 함

`extractHighResSubRegion`은 subregion의 원점 metadata를 `originX + startX * cellSize`처럼 계산한다. `startX`는 이미 meter 단위이므로 다시 `cellSize`를 곱하면 좌표가 축소된다. 또한 `MainViewController.performMeasurement`는 LOD가 원본 중앙 기준이라고 가정하지만 실제 subregion은 볼-홀 중점을 중심으로 생성된다.

개선 방향:

- `HeightMapData`에 `localMinX`, `localMinY` 또는 `worldMinX`, `worldMinZ`를 명확히 추가
- subregion 생성 시 원본 좌표에서 subregion 좌표로 변환하는 함수를 함께 반환
- LOD 좌표 변환을 `ball - subregionOriginLocal` 형태로 단순화
- LOD 적용 여부 판단에서 x/y 상한을 모두 검사

### 4.6 퍼팅 물리 모델을 실측 가능한 모델로 교체

현재 `PuttingPhysics`는 평균 횡경사와 Bezier 제어점을 이용해 경로를 만든다. 시각적으로는 안정적이지만 실제 퍼팅에서는 다음 요소가 빠져 있다.

- 업힐/다운힐에 따른 필요 속도 변화
- 마찰에 따른 감속
- 경사 방향이 위치별로 바뀌는 경우의 누적 영향
- 컵 주변 도달 속도와 capture 조건
- 저항 슬라이더와 실제 green speed 사이의 calibration

개선 방향:

- 2D 운동 방정식 기반 numerical integration으로 변경
- 위치별 경사 벡터에서 가속도 계산
- 마찰/rolling resistance와 중력 성분을 동시에 반영
- 여러 초기 속도와 aim angle을 탐색하여 컵 도달 오차가 최소인 경로 선택
- 실측 putt 10~20개로 resistance/stimp 매핑 보정

## 5. 성능 개선 제안

### 5.1 ARSessionDelegate 처리를 전용 serial queue로 이동

현재 `session.delegate = self`만 설정되어 있고 delegate queue가 명시되어 있지 않다. 프레임마다 모든 depth pixel을 처리하고, mesh anchor까지 누적하면 UI thread 또는 ARKit callback queue가 쉽게 밀릴 수 있다.

개선 방향:

- `let processingQueue = DispatchQueue(label: "lidar.processing.queue", qos: .userInitiated)`
- ARSession delegate queue를 processingQueue로 지정
- 누적 배열 접근도 같은 queue에서만 수행
- UI 콜백은 main queue로만 전달

### 5.2 누적 그리드는 2차원 배열 대신 flat buffer로 변경

현재 `[[Double]]`, `[[Int]]` 구조를 사용한다. 160x160에서는 동작하지만 per-pixel mapping에서는 cache locality와 bounds check 비용이 누적된다.

개선 방향:

- `accumulatedHeights: [Double]`
- `accumulatedCounts: [Int]`
- `accumulatedConfidence: [Double]`
- index는 `gz * targetGridWidth + gx`
- `shiftGrid`도 flat copy 또는 ring-buffer origin offset 방식으로 최적화

### 5.3 프레임별 모든 픽셀 처리 전략을 adaptive sampling으로 변경

주석에는 정밀도를 위해 step=1이라고 되어 있지만, 모든 프레임에서 모든 픽셀을 처리하는 방식은 발열과 프레임 드롭을 유발할 수 있다.

개선 방향:

- 스캔 초기: `step=2` 또는 ROI 중심 우선
- 품질 낮은 구역: step=1로 보강
- 셀당 관측 수가 충분한 영역은 skip
- confidence가 낮은 pixel은 빠르게 discard
- depth map 처리는 Metal compute 또는 Accelerate 기반으로 벡터화 검토

### 5.4 스트리밍 스냅샷은 lock/snapshot 복사 후 렌더링

`generateStreamingSnapshot`은 `filledCells`, `accumulatedHeights`, `accumulatedConfidence`를 background queue에서 읽는다. 동시에 `mapToGrid`가 같은 데이터를 수정할 수 있다.

개선 방향:

- processing queue 안에서 필요한 배열을 얕은 단위로 복사
- 복사본으로 background snapshot 생성
- 또는 `NSLock`/actor를 사용하되 AR frame path에서 lock 대기 시간이 길어지지 않게 설계

### 5.5 오버레이 렌더링은 캐싱 필요

`TrajectoryOverlayView.draw`는 히트맵, 격자, 물 흐름 화살표, 등고선을 매번 다시 계산한다. 결과 화면 animation 중 `CADisplayLink`가 돌면 같은 지형 데이터를 여러 번 다시 그릴 수 있다.

개선 방향:

- 지형 히트맵/격자/등고선은 `UIImage` 또는 `CGLayer`로 캐시
- animation 중에는 trajectory layer만 redraw
- `TerrainAnalyzer.calculateSlopeMagnitudeMap` 결과를 terrain 단위로 캐시
- 3D SceneKit 화살표/등고선은 노드 수 제한 또는 instancing 검토

## 6. 안정성 및 유지보수 개선 제안

### 6.1 `MainViewController` 분리

`MainViewController.swift`는 약 1,400라인이며 AR 세션, 스캔 상태, UI 배치, 자동 감지, 위치 변환, 측정 실행을 모두 담당한다. 기능 변경 시 회귀 위험이 크다.

권장 분리:

- `ScanStateMachine`: 상태 전이
- `ScanCoordinator`: scanner callback과 UI 연결
- `PlacementCoordinator`: 볼/홀 선택과 screen-grid 변환
- `MeasurementService`: LOD, physics, 결과 생성
- `WorldMapStore`: ARWorldMap 저장/복원

### 6.2 테스트 타깃 추가

현재 테스트 타깃이 없다. 정확도/성능 개선 전에는 최소한 계산 로직부터 테스트해야 한다.

우선 테스트할 항목:

- `HeightMapData.get/set`, smoothing
- `TerrainAnalyzer.calculateHighPrecisionSlope`
- screen-grid 변환의 round trip
- LOD subregion 좌표 변환
- `PuttingPhysics`가 평면에서는 직선을 반환하는지
- 일정한 횡경사에서는 break 방향과 크기가 일관적인지

### 6.3 실측 벤치마크 데이터셋 추가

정확도 개선은 코드만으로 판단하기 어렵다. 반복 가능한 샘플이 필요하다.

권장 데이터:

- 평평한 표면 3회
- 1cm, 2cm, 5cm 단차 표면
- 좌/우 일정 경사 표면
- 실제 퍼팅 그린의 동일 구역 반복 스캔 5회
- 각 샘플의 ground truth: 수평계, 줄자, known slope jig 등

측정 지표:

- 높이 RMS 오차
- 반복 스캔 간 cell-wise 표준편차
- plane fit residual
- 볼/홀 위치 변환 오차
- 추천 aim과 실제 성공/근접률
- 프레임 처리 시간 p50/p95
- 스캔 중 FPS와 thermal state

### 6.4 저장소 정리

현재 추적되지 않은 `ios/Runner.xcodeproj/`가 있다. 실제로 필요한 프로젝트가 아니면 제거하거나 `.gitignore`에 명시해야 한다. 필요한 경우 Git에 추가하고 역할을 문서화해야 한다.

`github-sync.command`는 동기화 도구로 유용하지만 아직 Git에 추가되지 않았다. 팀/다른 장비에서도 사용할 파일이면 커밋 대상에 포함하는 것이 좋다.

## 7. 단계별 실행 계획

### 즉시 수정 권장

1. `CVPixelBufferGetBytesPerRow` 기반으로 depth/confidence 접근 수정
2. camera intrinsics를 depth map 해상도로 스케일링
3. `progress >= 1.0` 즉시 종료 제거, 품질 기반 종료로 변경
4. 스트리밍 snapshot과 depth image rendering의 비동기 데이터 lifetime/race 정리
5. 높이 범위 UI 단위 수정: cm이면 `cm`, m이면 값을 100으로 나누지 않음

### 단기 개선

1. LOD subregion 좌표계를 명시적 origin/transform 기반으로 재구현
2. `MainViewController`에서 measurement/placement 로직 분리
3. `HeightMapData` flat buffer화
4. 오버레이 정적 레이어 캐싱
5. Unit test target 추가

### 중기 개선

1. RANSAC/least squares ground plane fitting
2. 셀별 variance/uncertainty map 추가
3. numerical integration 기반 퍼팅 물리 모델 도입
4. 실측 calibration dataset 구축
5. 프레임 처리 시간과 FPS 자동 계측

## 8. 권장 성공 기준

개선 후 다음 기준을 만족하면 정확도와 성능이 실질적으로 좋아졌다고 판단할 수 있다.

- 평면 스캔 RMS 높이 오차: 5mm 이하 목표
- 동일 영역 5회 반복 스캔의 경사 방향 일치율: 90% 이상
- 볼/홀 위치 변환 오차: 화면 선택 기준 3cm 이하
- 스캔 중 UI FPS: 30fps 이상 유지 
- per-frame depth processing p95: 20ms 이하
- 자동 종료 전 중앙 ROI 커버리지: 80% 이상
- 셀당 평균 관측 수: 3회 이상
- 추천 경로 재계산 시간: 200ms 이하

## 9. 결론

현재 앱은 ARKit LiDAR 수집, 높이 맵 생성, 퍼팅 경로 시각화까지 end-to-end 흐름이 구현되어 있다. 다만 측정 앱으로 신뢰도를 높이려면 먼저 depth 좌표 변환과 PixelBuffer 접근 방식, 스캔 종료 기준을 수정해야 한다. 이 세 가지는 정확도에 직접 영향을 주는 핵심 문제다.

성능 측면에서는 모든 픽셀을 매 프레임 처리하는 구조, nested array, 매번 다시 그리는 오버레이가 주 병목이다. 전용 processing queue, flat buffer, adaptive sampling, 렌더링 캐시를 적용하면 실기기에서 발열과 프레임 드롭을 줄일 수 있다.

마지막으로 현재 퍼팅 물리는 시각적 휴리스틱에 가깝다. 실제 추천 정확도를 높이려면 실측 데이터 기반 calibration과 numerical integration 모델로 넘어가는 것이 필요하다.
