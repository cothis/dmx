## Opus 5.5 3차 릴리스 리뷰: dmx 메뉴 앱 (snapshot `f2e739c`)

**결론: needs-fixes.** 2차 리뷰의 5건(P2 2건, P3 3건)은 실제 호출자와 정리 코드까지 따라가 해결된 것을 확인했습니다. 다만 이번 수정이 만든 새 결함이 남아 있습니다: 앱이 영구히 상주할 수 있는 P2 1건과 P3 2건입니다.

검토는 `third-source/`와 `third.diff`만 Read/Grep으로 읽었고, 명령이나 테스트는 하나도 실행하지 않았습니다. 아래 경로는 모두 `.build/menu-release-review/third-source/` 기준입니다.

### 2차 지적 재확인 (모두 해결)

| 2차 지적 | 확인한 수정 |
|---|---|
| 시작 단계 실패 시 `ready` 고착 (P2-1) | VM 부팅 직후 `booted`가 `ready`를 세움 (`main.swift:104-108`). context·도구 실패는 작업 범위로 분류 (`:71`). 자동 종료는 `startup == nil`을 기준으로 판단 (`:111`). Retry는 `!ready \|\| !setupComplete`일 때 항상 보임 (`:233`) |
| 150초 start deadline (P2-2) | `startForMenu`에 deadline 없음 (`DaemonClient`의 `startForMenu`). Quit이 연결을 닫고, 데몬은 machine이 만들어지기 전이면 다운로드를 취소 |
| 앱·CLI 교체가 비원자적 (P3) | `renamex_np(RENAME_SWAP)`으로 교환하고 CLI link는 `rename(2)`로 덮어씀. 실패하면 다시 swap해 원래 앱을 복구 (`AppInstallation.swift:150-170`) |
| 신뢰 기준이 실행 CLI에 걸림 (P3) | 설치된 앱의 Developer ID team으로 새 앱을 고정 (`:135-141`). 예외는 `--allow-signing-change`를 명시할 때뿐 |
| 메뉴 열기가 idle 타이머 초기화 (P3) | 목록 조회는 `menu_docker_read`의 passive lease로 처리 (`Daemon.swift:126`, `:174`) |

정상 종료 중의 setup 취소 경로도 정상입니다. `stopped` receipt가 오면 `changed`가 `startup.cancel()`을 호출합니다(`main.swift:123`). 취소가 CancellationError로 올라오면 `:89-91`이 정상 정지로 처리하고, defer의 `considerExit`(`:64`)가 앱을 종료합니다.

---

### 새로 발견한 코드 결함

**[P2] 시작 완료 시점에 오래된 RPC 상태로 phase를 덮어써, 이미 처리한 `stopped`를 잃고 앱이 "Running"으로 영구 상주할 수 있습니다**
- 위치:
  - `Sources/DMXCore/MenuEngine.swift:55`: setup 실패 시 `started`(부팅 직후의 start 응답)를 그대로 돌려줍니다. `:52`의 `client.status()`도 응답 직후 시점의 상태일 뿐입니다.
  - `Sources/DMXApp/main.swift:72`: 그 값으로 `session.reconcile(state:)`를 합니다.
  - `main.swift:77-78`: 같은 receipt를 다시 읽지만, 이미 적용한 receipt라 `MenuSessionState.receive`가 false를 돌려주고 phase를 바로잡지 못합니다.
- 재현 순서 (외부 `dmx stop`이 시작 완료 직전에 끼어드는 경우):
  1. 앱의 `startForMenu`가 `running`을 받습니다.
  2. context setup이 즉시 실패합니다(예: 잘못된 `~/.docker/config.json`). 또는 마지막 `status()` 응답이 이미 도착한 상태입니다.
  3. 그 사이 `stopped` receipt가 main actor에서 먼저 처리되어 phase가 `.stopped`가 됩니다. `startup.cancel()`도 불리지만 이미 늦었습니다.
  4. 시작 Task가 재개되어 `:72`에서 phase를 다시 `.running`으로 덮어씁니다.
- 결과: 아래 경로가 모두 phase를 고치지 않아 상태가 영구히 굳습니다.
  - defer의 `considerExit`(`:64`, `:111`)는 phase가 running이라 아무것도 하지 않습니다.
  - refresh는 `status.state != running`이면 phase 갱신 없이 return합니다(`:205-206`).
  - 데몬이 종료해도 `exited`는 정상 정지 분기의 `considerExit()`(`:134-136`)만 호출하므로 역시 종료하지 않습니다.
  - 결국 엔진은 내려갔는데 앱은 "Running" 표시로 무기한 남습니다.
- 발생 창은 좁지만, 일단 일어나면 복구 경로가 없습니다.
- 최소 수정 (셋 다 필요):
  - 시작 완료 시 이 pid의 receipt가 이미 적용됐다면 그 상태를 RPC 스냅샷보다 우선하거나, `menu_state`로 다시 확인합니다.
  - refresh에서 `status.state`가 running이 아니면 `session.reconcile(state:)`를 호출합니다.
  - `exited()`의 정상 정지 분기에서는 `reconcile(state: "stopped")` 후 `considerExit()`를 호출합니다.

**[P3-1] passive lease가 마지막으로 끝나면 idle 기준점(`idleSince`)이 오래된 값으로 남아 VM이 너무 일찍 멈춥니다**
- 위치: `Sources/DMXCore/Daemon/Daemon.swift:92-93`(Docker의 `using` 해제), `:125-126`(연결 종료).
- 동작: active 사용자가 떠날 때도 `users == 0`일 때만 `idleSince`를 갱신합니다.
- 재현: `docker build`나 `dmx exec`가 끝나는 순간에 메뉴 목록 조회가 진행 중인 경우입니다.
  1. active 해제 시점에는 users가 2→1이라 `idleSince`가 갱신되지 않습니다.
  2. 이어서 passive 해제로 users가 1→0이 되지만, passive라 갱신하지 않습니다.
  3. `scheduleIdleCheck`가 과거 시점의 `idleSince`로 deadline을 계산합니다.
- 결과: 방금 쓴 VM이 `idle_timeout`을 기다리지 않고 바로 멈추고, 다음 명령에서 재부팅합니다. 실행 중인 컨테이너가 있으면 `busy` 검사로 막히므로 데이터 손실은 없습니다.
- 최소 수정: active 해제 시에는 users 수와 관계없이 항상 `idleSince = .now`로 갱신합니다. 이 값은 `users == 0`일 때만 쓰이므로 안전합니다.

**[P3-2] 설치된 앱의 team 고정보다 helper 실행이 먼저 일어납니다**
- 위치: `Sources/DMXCore/AppInstallation.swift:77`, `:134`(`verify`가 `:97`에서 helper `--version`을 실행)가 `:135`의 team 고정 검사보다 앞섭니다.
- 동작: 실행하는 CLI가 ad-hoc이면 caller 기준 team 검사가 생략됩니다. 따라서 `dmx app install --archive`로 받은 helper가 설치된 Developer ID team 검사를 받기 전에 실행됩니다. 같은 사용자 권한 범위 안의 하드닝 문제입니다.
- 최소 수정: 대상 앱의 team 검사를 `verify`의 실행 단계 앞으로 옮기거나, `verify(source)`보다 먼저 수행합니다.

---

### 남은 릴리스 증거 (실행했다고 주장하지 않음)
- 이번 증분(시작 경로, 원자적 swap, passive read)을 대상으로 한 단위·VM·메뉴 테스트가 아직 없습니다. 이전 통과 결과는 이 패치보다 앞선 것입니다.
- 실제 GUI에서 잘못된 context로 첫 실행하는 경우와 150초를 넘는 첫 guest 다운로드를 확인한 결과가 아직 없습니다.
- Java100과 최종 메뉴 테스트 결과가 아직 없습니다.
- 서명·공증된 archive 왕복, 설치기 리허설, 게시 후 다운로드 검증이 아직 없습니다.
- 실제 Start/Stop/Quit 클릭은 windowless 앱의 자동화 한계로 검증할 수 없습니다. API 테스트는 클릭 증거가 아닙니다. 이 경로들은 코드상 `busy`/`quitting` 가드와 drain 순서를 확인했고 결함은 찾지 못했지만, 그것이 클릭 증거를 대신하지는 않습니다.

### 게이트
- **코드 게이트: needs-fixes.** P2를 수정해야 하고, P3 두 건도 수정을 권합니다. 이후 다음 회귀 테스트로 증명해야 합니다.
  - 시작 완료 직전에 `stopped`가 끼어들어도 앱이 정지 상태로 수렴하고 종료함
  - passive 조회와 active 사용이 겹쳐도 `idleSince`가 active 해제 시점으로 갱신됨
- **릴리스 증거 게이트: 미충족.** 위 남은 증거 목록이 모두 채워져야 공개할 수 있습니다.

이번 검토로 모든 결함을 찾았다고 보장하지는 않습니다.