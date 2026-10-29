## Opus 5.5 4차 릴리스 리뷰: dmx 메뉴 앱 (snapshot `ca3cedf`)

**결론: 코드 게이트 approve.** 3차 리뷰의 3건(P2 1건, P3 2건)은 실제 호출자와 정리 코드까지 따라가 모두 해결된 것을 확인했고, 이번 증분에서 새로 생긴 정확성 결함은 찾지 못했습니다. 다만 화면 표시만 잘못되는 P3 1건이 있어, 한 줄로 고치기를 권합니다.

검토는 `fourth-source/`, `fourth.diff`, `fourth-evidence/`만 Read/Grep으로 읽었고, 명령이나 테스트는 하나도 실행하지 않았습니다. 아래 경로는 모두 `.build/menu-release-review/fourth-source/` 기준입니다.

### 3차 지적 재확인

**[P2] 오래된 RPC 상태로 phase를 덮어쓰던 문제: 해결**
- 시작 완료 시점에 RPC 결과로 phase를 맞추던 코드가 아예 없어졌습니다(`main.swift:69-84`).
- `booted`는 먼저 최신 receipt를 동기적으로 읽어 적용합니다(`:104`). 이번 start 동안 이미 적용한 receipt가 있으면, 부팅 응답은 그보다 우선하지 않습니다(`MenuSessionState`의 `reconcileBoot`).
- 3차에서 지적한 순서(running 적용 → stopped 적용 → 늦은 부팅 응답과 setup 실패 도착)를 따라가 보면:
  - 늦은 setup 실패는 phase가 `.stopped`이므로 무시됩니다(`failed`의 `.operation` 분기).
  - 같은 receipt는 다시 적용되지 않고, defer의 `considerExit`가 앱을 종료합니다.
- 복구 경로도 모두 고쳐졌습니다.
  - refresh: 상태가 running이 아니면 최신 receipt를 읽고, 그 사이 새 receipt가 없을 때만 RPC 값을 적용합니다.
  - `exited`: 정상 종료 분기에서 `reconcile(state: "stopped")`를 먼저 호출합니다(`:134`).
  - `exitAfterIdle`: RPC를 보낸 뒤 새 receipt가 왔으면 그것을 우선합니다.
- 부작용이 없는지도 확인했습니다.
  - 데몬은 부팅 끝에 `running` receipt를 쓴 뒤 start에 응답합니다. 그래서 `booted`가 파일을 읽을 때 오래된 `stopped`를 볼 수 없습니다.
  - 새 데몬이 처음 쓰는 `stopped` receipt는 `ready`가 false일 때 도착하므로, 시작 작업을 취소하지 않습니다(`:122`).
  - 자동 종료가 진행 중이면 Retry와 start가 막힙니다(`:53`).

**[P3-1] passive lease 뒤 `idleSince`가 오래된 값으로 남던 문제: 해결**
- active 사용자가 떠날 때는 남은 users 수와 관계없이 `idleSince`를 갱신합니다.
  - Docker와 포트 연결: `using` 닫힘 시(`Daemon.swift` `!open`)
  - control 연결: `use.resetsIdle`일 때
- 실행 중이던 컨테이너가 모두 끝나 busy에서 idle로 바뀔 때만 갱신하므로, 메뉴의 첫 목록 조회(컨테이너 수가 nil에서 0이 되는 경우)는 idle 타이머를 초기화하지 않습니다.
- 관련 회귀 테스트(`scripts/test-menu.py:293-307`)의 논리도 맞습니다. idle_timeout 3초에서 `sleep 4`인 exec가 끝나며 `idleSince`가 갱신되므로, passive 연결을 닫은 뒤 남은 시간이 2초 이상이어야 합니다.

**[P3-2] team 고정보다 helper 실행이 먼저 일어나던 문제: 해결**
- `AppInstallation.verify`에서 설치된 앱의 team 검사(`:123-127`)가 helper `--version` 실행(`:128`)보다 앞에 있습니다. 원본 설치 경로(`:106`)와 staging 사본(`:143`) 모두 같은 함수를 거칩니다.
- `SelfUpdate.checkSignature`는 이제 설치된 앱 루트를 신뢰 기준으로 삼습니다. 따라서 root CLI를 실행하기 전에도 설치된 앱의 team을 요구합니다.
- 서명 변경을 허용하는 플래그는 `build-app.py --install`에서만 넘깁니다. 공개 install.sh는 넘기지 않습니다.

### 남은 결함

**[P3, 표시만 잘못됨] 시작 직후 Retry가 잠시 잘못 보입니다**
- 위치: `Sources/DMXApp/main.swift:56`. `render()`가 `:63`에서 `startup`을 할당하기 전에 호출됩니다. 이때 `:233`의 조건(`startup == nil` 이고 `!ready`)이 참이라 Retry가 활성 상태로 그려집니다.
- 실제 증거: `fourth-evidence/setup-failure-ui.json`의 첫 이벤트가 `startupActive: false`, `pid: 0` 상태에서 Retry가 활성으로 그려진 장면입니다.
- 이 상태는 다음 receipt나 `booted`로 다시 그려질 때까지 남습니다. 그 사이에 메뉴를 열면 `refresh`는 `ready` 가드에서 return하므로 화면이 갱신되지 않습니다.
- 영향: 이때 Retry를 눌러도 `start()`가 `startup == nil` 가드에서 바로 return하므로 아무 일도 일어나지 않습니다. 정확성 문제는 없습니다.
- 최소 수정: `:56`의 `render()`를 startup Task 할당 뒤로 옮기면 됩니다.

### 참고 (결함 아님)
- setup 실패 UI 증거에 "Command-Q from error window had no observed effect"라고 기록돼 있습니다. accessory 앱에는 메인 메뉴가 없고, Cmd-Q는 상태 메뉴의 "Quit dmx" 항목에만 연결되어 있습니다. 승인된 범위의 동작이지만 문서에 적어 둘 만합니다.

### 남은 릴리스 증거 (실행했다고 주장하지 않음)
- **idle-overlap 테스트**: VM 위에서 도는 새 회귀 테스트이며, 아직 실행 중입니다.
- **이번 패치의 좁은 interleaving**: 시작 완료 직전에 stopped가 끼어드는 경우는 단위 모델(`MenuSessionTests`)로만 검증됐습니다. 실제 앱 증거 두 건은 이 패치보다 앞선 것입니다.
- **qualification.json의 11개 대상**: 여러 소스 revision에 걸쳐 실행된 결과입니다. app과 proxy 일부 검사는 최종 증분보다 앞섭니다.
- **서명·배포**: Developer ID 서명과 공증·staple을 거친 archive 왕복, install.sh 리허설, 게시된 asset 다운로드 검증이 아직 없습니다.
- **GUI 클릭**: Start/Stop/Quit 직접 클릭은 windowless 자동화의 한계로 증명할 수 없습니다. 코드상 `busy`와 `quitting` 가드, drain 순서에서 결함을 찾지 못했지만, API·VM 테스트는 클릭 증거가 아닙니다.

### 게이트
- **코드 게이트: approve.** 정확성 결함은 찾지 못했습니다. P3(표시만 잘못됨)는 한 줄 수정을 권하지만 승인을 막지 않습니다.
- **릴리스 증거 게이트: 미충족.** 위 남은 증거가 모두 채워진 뒤에 공개해야 합니다.

이번 검토로 모든 결함을 찾았다고 보장하지는 않습니다.