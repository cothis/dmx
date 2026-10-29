## Opus 5.5 2차 릴리스 리뷰: dmx 메뉴 앱 (index tree `e299a34`)

**결론: needs-fixes.** 초기 지적 10건은 모두 실제 호출자와 정리 코드까지 따라가 해결된 것을 확인했습니다. 그러나 시작 단계 실패와 관련된 새 P2 결함 2건이 남아 승인할 수 없습니다. 설치·업데이트·신뢰 경로에서는 P1·P2 결함을 찾지 못했고 P3 보강점만 있습니다.

검토는 `second-source/`와 `second.diff`만 Read/Grep으로 읽었고, 명령이나 테스트는 하나도 실행하지 않았습니다. 아래 경로는 모두 `.build/menu-release-review/second-source/` 기준입니다.

### 초기 지적 재확인 (모두 해결)

| 초기 지적 | 수정 내용 |
|---|---|
| 작업 오류 하나로 앱이 상주 (P1) | 작업 오류는 `.operation` 범위로 분리되고 `stopped` receipt에서 지워짐 (`MenuSessionState.swift:41`, `:62`) |
| 304를 실패로 처리 (P2) | `MenuEngine.swift:127`에서 204와 304를 성공으로 처리 |
| `menu_release`가 CLI keepalive 해제 (P2) | 메뉴가 `menu_docker` 터널을 써서 `docker.used`를 건드리지 않음 (`Docker.swift` `forwardMenu`). `menu_release`는 상태만 반환 (`Daemon.swift:165-168`) |
| 첫 실행 Quit 불가 (P2) | `startup?.cancel()` 추가. `Transfer`와 DockerTools가 취소를 지원. 데몬은 `machine == nil`일 때만 boot를 취소 (`Daemon.swift:380`) |
| 상태 라벨 오표시 (P3) | `stateAfterIdle`가 실제 상태로 다시 맞춤. pid가 다르면 nil을 돌려받아 앱이 종료 |
| `automaticExit` 고착 (P3) | `main.swift:125`의 defer와 `:349`에서 리셋 |
| 좀비 자식 프로세스 (P3) | spawn 직후 `DaemonChildren.register`로 모든 자식을 등록하고 reap |
| receipt 재적용과 trace 위치 (P3) | `sequence`와 동등성 검사로 중복 적용 차단. trace는 `logs/`로 이동 |
| control 호출에 deadline 없음 (P3) | `withConnectionDeadline`이 FrameConnection을 retire |
| 메뉴 열기가 VM을 재부팅 (P3) | `menu_docker`가 `state == .running`이 아니면 거부 (`Daemon.swift:172-176`) |

한 가지 의심은 직접 확인한 뒤 기각했습니다. `DaemonClient.open`이 소켓을 `O_NONBLOCK`으로 열어 exec 회귀가 날 수 있어 보였지만, `FrameConnection.init`이 그 플래그를 해제합니다 (`Agent.swift:139-140`).

---

### 새로 발견한 코드 결함

**[P2-1] VM이 뜬 뒤 시작 단계에서 실패하면 `ready`가 영영 false로 남아, 정상 idle 종료에도 앱이 상주하고 거짓 "unexpectedly" 오류를 띄웁니다**
- 위치:
  - `Sources/DMXApp/main.swift:69`: `ready`는 시작이 끝까지 성공할 때만 true가 됩니다.
  - `main.swift:83-88`: 실패하면 기본값인 lifecycle 범위로 `fail()`합니다.
  - `Sources/DMXCore/MenuEngine.swift:38-42`: `client.start()`가 VM을 띄운 뒤에 `DockerContext.install`과 `DockerTools.install`을 실행합니다.
  - `MenuSessionState.swift:55`: `starting`이나 `running` receipt가 오면 lifecycle 실패를 지웁니다.
  - `MenuSessionState.swift:62`, `main.swift:114`, `:173`: 자동 종료, `exited()`의 정상 종료 판정, refresh가 모두 `ready`를 요구합니다.
  - `main.swift:211`: Retry 항목은 오류가 있을 때만 보입니다.
- 재현 A (첫 실행 오프라인, 또는 `~/.docker/config.json`이 JSON 객체가 아닌 경우):
  1. `client.start()`가 성공해 VM이 실행됩니다.
  2. `DockerContext.updateConfig`(`DockerContext.swift:71-73`)나 도구 다운로드가 throw합니다.
  3. 앱이 이를 lifecycle 오류로 기록하므로 `blocksAutomaticExit`이 켜집니다.
  4. idle stop의 `stopped` receipt가 와도 `reconcile`이 막혀 있습니다(`MenuSessionState.swift:38`). 데몬 종료 알림도 `main.swift:110`에서 무시됩니다.
  5. 결과: 엔진은 정상 종료했는데 앱은 무기한 남습니다. 초기 P1과 같은 계약 위반이 다른 경로로 재발한 것입니다.
- 재현 B (아래 P2-2 timeout 경로, 또는 시작 실패 뒤 사용자가 CLI로 `dmx start`를 실행한 경우):
  1. 같은 데몬에서 `running` receipt가 옵니다.
  2. lifecycle 실패가 지워져 오류 표시가 사라지지만 `ready`는 여전히 false입니다.
  3. Retry도 Refresh도 없고 컨테이너 목록도 영영 불러오지 못합니다. Docker context와 도구도 설치되지 않은 채로 남습니다.
  4. idle stop 후 앱은 종료하지 않습니다. 데몬이 종료하면 `main.swift:117`이 정상 종료를 "The dmx engine exited unexpectedly"로 보고합니다.
- 최소 수정:
  - `client.start()`가 성공한 시점에 엔진 준비 상태를 확정합니다.
  - context와 도구 실패는 `.operation` 범위로 분류합니다.
  - 자동 종료와 `exited()`는 "startup이 끝났는가(`startup == nil`)"를 기준으로 판단하게 합니다.
  - 시작에 실패해 `ready`가 아닌 동안에는 Retry를 항상 보여 줍니다.

**[P2-2] 앱의 start deadline 150초가 데몬이 정당하게 쓸 수 있는 시간보다 짧습니다**
- 위치: `MenuEngine.swift:38`. 반면 데몬은 `Daemon.swift:299`에서 제한 없는 guest 다운로드(63MB, `GuestPin.swift:7`)를 하고, `:311`에서 agent 연결에 최대 120초를 기다립니다.
- 재현: guest가 없는 첫 실행에서 느린 회선이나 프록시 때문에 다운로드와 첫 디스크 포맷이 합쳐 150초를 넘는 경우입니다.
- 결과:
  - 앱에는 `daemon_timeout` 오류가 뜨고, 힌트는 "retrying `dmx stop`"을 안내해 오해를 부릅니다.
  - 데몬은 클라이언트가 끊겨도 boot를 계속합니다.
  - VM이 뜨면 위 재현 B의 고착 상태로 이어집니다.
- 최소 수정: start에는 deadline을 두지 않거나 데몬 쪽 예산보다 길게 잡습니다. 진행 여부는 receipt로 판단하고, 앱이 취소할 수 있는 것은 Quit 하나만 남깁니다.

**[P3]**
1. **앱 교체와 CLI link 교체가 원자적이지 않습니다** (`AppInstallation.swift:143-147`). "기존 앱을 옆으로 옮기기"와 "새 앱을 제자리에 넣기"가 별도의 move 두 번입니다.
   - 그 사이에 프로세스가 죽으면 앱이 없는 상태로 남고, 숨김 `.previous`는 자동 복구되지 않습니다.
   - 그 순간 launchd가 `~/.local/bin/dmx`나 앱 helper를 활성화하면 ENOENT가 납니다.
   - 수정: 디렉터리는 `renamex_np(RENAME_SWAP)`으로 교환하고, symlink는 `rename(2)`로 덮어씁니다.
2. **신뢰 기준이 설치된 앱이 아니라 설치를 실행하는 CLI의 서명에 걸려 있습니다** (`AppInstallation.swift:93-95`, `SelfUpdate.swift:335-336`). ad-hoc 서명 CLI로 `dmx app install --bundle`을 실행하면 Developer ID로 서명된 설치 앱을 ad-hoc 번들로 덮을 수 있습니다. 같은 사용자 권한 범위 안이라 P3입니다. 수정: 대상 앱에 team이 있으면 들어오는 앱도 같은 team을 요구하고, 명시적 플래그로만 예외를 둡니다.
3. **메뉴를 열기만 해도 idle 타이머가 초기화됩니다** (`Daemon.swift:176`의 `claimVM`, `:124-126`). 목록 조회도 VM 사용으로 집계되므로 상태를 보는 것만으로 idle stop이 최대 `idle_timeout`만큼 늦어집니다. 메모리 절약 기본값과 충돌합니다. 수정: 메뉴의 읽기 전용 터널은 `idleSince`를 갱신하지 않게 합니다.

### 설치·업데이트·신뢰 경로: 결함 없음 (철저히 증명했다는 뜻은 아님)

코드상 확인한 사항은 다음과 같습니다.
- **archive 해제**: tar member는 stdout으로만 꺼내 우리가 만든 일반 파일에 씁니다. 이름의 문자 집합, 개수, 크기를 제한하고 중복을 거부합니다. symlink나 hardlink member는 빈 파일이 되어 이후 서명 검증에서 실패합니다.
- **실행 전 검증**: 실행 전에 seal, team, 버전을 검사합니다. staging 사본을 다시 검증하고, 다른 앱이나 link는 덮어쓰지 않으며, advisory lock을 걸고, 실패하면 rollback합니다.
- **업데이트 대상 판별**: `_NSGetExecutablePath`로 실제 실행 파일을 찾은 뒤 앱을 통째로 교체합니다. 앱 없는 옛 archive로 downgrade하려 하면 교체 전에 실패합니다.
- **실행 중 VM**: rename과 unlink만 하므로 실행 중인 helper나 데몬의 실행 이미지를 건드리지 않고, `handOver`도 데몬을 멈추지 않습니다.
- **install.sh**: publisher team을 확인한 뒤에만 root CLI를 실행합니다. `DMX_VERSION`으로 다른 버전을 지정해도 team 검사는 그대로 적용됩니다.

### 남은 릴리스 증거 (테스트를 실행했다고 주장하지 않음)
- 포트 충돌 회귀 테스트의 새 실행 결과와 전체 release matrix가 아직 없습니다.
- 서명·공증된 archive의 왕복 검증(`stapler`, `spctl`), 공개 설치기 리허설, 게시 후 다운로드 검증이 아직 없습니다.
- 실행 중인 VM이 있는 상태에서 실제로 `dmx update`나 install.sh로 앱을 교체하고 VM·컨테이너가 유지되는지 확인한 증거가 없습니다.
- 위 P2-1·P2-2 경로(시작 단계 실패, 150초 초과)를 다루는 테스트가 없습니다. 보고된 malformed config 재현은 `docker_failed`(작업 범위)였고, `docker_context_failed`가 나는 시작 단계 경로와는 다른 경로입니다.
- 실제 GUI 클릭(Start/Stop/Quit, 하위 메뉴)은 여전히 검증되지 않았습니다. API 테스트는 GUI 클릭 증거가 아닙니다.

### 게이트
- **코드 리뷰 게이트: needs-fixes.** P2-1과 P2-2를 고친 뒤, 다음 회귀 테스트로 증명해야 합니다.
  - 시작 단계 실패(오프라인 도구 다운로드, 잘못된 Docker config) 뒤에도 idle 종료와 데몬 종료 때 앱이 실제로 종료함
  - 150초를 넘는 첫 boot에서 앱이 정상 상태로 수렴함
- **릴리스 증거 게이트: 미충족.** 위 남은 증거 목록이 모두 채워져야 공개할 수 있습니다.

이번 검토로 모든 결함을 찾았다고 보장하지는 않습니다.