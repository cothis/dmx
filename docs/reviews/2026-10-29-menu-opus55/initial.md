## Opus 5.5 릴리스 리뷰: dmx 메뉴 앱 (snapshot `4d2a411`)

**릴리스 게이트: needs-fixes.** 새로 찾은 코드 결함은 P1 1건, P2 3건, P3 6건입니다. 알려진 릴리스 작업과는 따로 정리했습니다.

검토는 Read/Grep만으로 했고 `initial-source/`와 `initial.diff`만 읽었습니다. 명령이나 테스트는 하나도 실행하지 않았습니다. 아래 경로는 모두 `.build/menu-release-review/initial-source/` 기준입니다. 보고한 결함은 각각 호출자와 정리 코드까지 따라가 확인했습니다.

---

### 새로 발견한 코드 결함

**[P1] 일반적인 작업 오류 한 번으로 앱이 idle 종료에서 영구히 빠지고 상주합니다**
- 위치: `Sources/DMXApp/main.swift:102`, `:109`, `:166`, `:265`. 오류를 설정하는 곳은 `:176`, `:262`이고, 오류를 지우는 곳은 `:248`(Retry)과 `:260`(토글 성공)뿐입니다.
- 동작: 자동 종료를 시작하는 네 경로가 모두 `error == nil`을 요구합니다. 그런데 refresh나 컨테이너 작업이 실패하면 `self.error`가 설정되고, 이후 refresh가 성공하거나 `running`·`stopped` receipt가 와도 지워지지 않습니다. 알림의 OK(`dismissError`, `:297-301`)는 창만 닫습니다.
- 재현 순서:
  1. 짧게 도는 컨테이너가 스스로 끝난 뒤 메뉴에서 Stop을 누르거나(아래 P2-1의 304), 포트가 겹치는 컨테이너에서 Start를 누릅니다.
  2. `fail()`이 호출되고 사용자가 OK를 누릅니다.
  3. idle timeout이 지나 `stopped` receipt가 와도 `:102`가 막습니다.
  4. 데몬이 linger 뒤 종료해도 `exited()`가 `:109`에서 무시합니다.
- 결과: 엔진은 이미 내려갔는데 앱은 "Needs attention" 상태로 무기한 남습니다. 빠져나오는 방법은 Retry뿐인데, 이 상태에서 Retry는 `start()`를 불러 VM을 다시 부팅합니다. `docs/memory.md:21`의 "must exit with normal/idle engine shutdown instead of remaining resident"와 메모리 절약 계약을 정면으로 어깁니다. refresh 실패는 `alert: false`라서 사용자가 모르는 사이에 이 상태가 됩니다.
- 최소 수정: lifecycle 오류(실패 receipt, `daemon_exited`, 시작 실패)와 작업 오류(refresh, 토글)를 서로 다른 상태로 분리합니다. 자동 종료 가드는 lifecycle 오류만 보게 하고, 작업 오류는 다음 성공 refresh나 `stopped` receipt에서 지웁니다.

**[P2-1] Docker의 304 응답을 실패로 처리해 빈 메시지 오류창이 뜹니다**
- 위치: `Sources/DMXCore/MenuEngine.swift:101`, `:104` → `Sources/DMXCore/Sandbox/DockerAPI.swift:194-198`.
- 동작: Engine API는 이미 시작된 컨테이너의 start나 이미 멈춘 컨테이너의 stop에 본문 없는 `304`를 돌려줍니다. 그런데 `json()`은 `200..<300`만 성공으로 받으므로 `DMXError("docker_failed", "dockerd: ")`를 던집니다.
- 재현: 목록을 불러온 뒤 컨테이너가 스스로 끝나거나, restart policy나 CLI로 상태가 바뀐 뒤 메뉴에서 클릭하면 됩니다. 흔한 경로이고, 위 P1을 일으키는 가장 쉬운 방법입니다.
- 최소 수정: `setRunning`에서 `call()`의 상태 코드 `204`와 `304`를 성공으로 처리합니다.

**[P2-2] standalone 모드에서 `menu_release`가 CLI의 Docker 사용분까지 해제합니다 (CLI 독립성 회귀)**
- 위치: `Sources/DMXCore/Daemon/Daemon.swift:168-169`, `Sources/DMXCore/Daemon/Docker.swift:49-51`, `:85`.
- 동작: `docker.used = false`는 누가 docker.sock을 썼는지 가리지 않고 초기화합니다.
- 재현 순서:
  1. launchd 에이전트가 없는 상태에서 앱을 씁니다. `docs/menu-app.md`의 `make install-app` 절차를 그대로 따르면 기본으로 이 상태가 됩니다.
  2. 터미널에서 `docker run`이나 `docker stop`을 씁니다.
  3. VM이 idle로 멈춥니다.
  4. 앱이 release를 보내면 데몬이 linger 뒤 종료하면서 docker.sock을 unlink합니다.
  5. 이후 `docker ps`가 "Cannot connect"로 실패합니다.
- 결과: 앱이 없을 때는 같은 상황에서 데몬이 상주해 소켓이 응답합니다(`Docker.swift:49` 주석). 즉 앱이 떠 있다는 사실만으로 CLI와 Docker 동작이 바뀝니다. 문서화된 선택이긴 하지만 `docs/memory.md:22`의 "CLI use stays independent"와 충돌합니다.
- 최소 수정: 메뉴에서 온 Docker 연결을 구분합니다. 예를 들어 메뉴 요청에 식별 헤더를 붙여 DockerProxy가 인식하게 하거나, 메뉴 조회를 control socket 메서드로 옮깁니다. 그다음 release는 메뉴가 만든 keepalive만 해제하게 합니다.

**[P2-3] 첫 실행 중 Quit을 누르면 다운로드와 부팅이 전부 끝날 때까지 취소할 수 없습니다**
- 위치: `Sources/DMXApp/main.swift:320`, `Sources/DMXCore/MenuEngine.swift:29-32`. 데몬 쪽 `stop`도 `Daemon.swift:361-362`에서 부팅을 기다립니다.
- 재현: guest나 도구가 없는 첫 실행에서 "Starting…" 동안 Quit을 누릅니다.
- 결과: Quit 항목이 "Stopping dmx…"로 비활성화됩니다. 그 상태에서 guest 다운로드, VM 부팅, `DockerTools.install` 다운로드가 모두 끝난 뒤에야 종료합니다. 진행 표시도 취소도 없어서 사용자에게 남는 선택지는 강제 종료뿐입니다.
- 최소 수정:
  - 앱 쪽에서는 Quit 시 startup을 취소합니다. `client.start()` 이후 quitting 플래그를 확인해 도구 설치를 건너뛰고, start 연결을 닫아 lease를 해제합니다.
  - 데몬 쪽 부팅 취소가 불가능하다는 점은 문서에 남깁니다.

**[P3]**
1. **release가 거부되면 상태 라벨이 실제와 달라집니다** (`main.swift:125`). 외부에서 `dmx stop`이 도구 설치 중에 오면, 앱이 방금 닫은 start lease를 데몬이 아직 처리하지 않아 `users == 1`로 거부될 수 있습니다. 다른 클라이언트가 재부팅을 시작한 경우도 같습니다. 이때 VM이 stopped이거나 starting인데 "Running"과 채워진 아이콘이 표시됩니다. `hello.pid != pid`이면 false를 돌려주는 부분(`MenuEngine.swift:68`)도 사라진 세션을 "Running"으로 남깁니다. 수정: 고정값 대신 최신 receipt로 phase를 다시 계산하고, pid가 다르면 세션이 끝난 것으로 처리합니다.
2. **Quit이 실패하면 `automaticExit`가 true로 고정됩니다** (`main.swift:119`, `:123`, `:127`, `:331`). release가 진행 중일 때 Quit을 누르면 release 쪽이 조기 return합니다. 그 뒤 `engine.stop()`이 실패(예: `menu_stop_timeout`)하면 refresh, 자동 종료, `exited` 처리가 모두 영구히 막힙니다. 수정: Quit 실패 경로에서 `automaticExit`를 리셋합니다.
3. **좀비 자식 프로세스가 남을 수 있습니다** (`DaemonClient.swift:114-120`). spawn한 pid를 버립니다. 데몬 종료 창에서 spawn이 일어나면(`Daemon.swift:443-447`의 unlink 이후 프로세스 종료 전), helper는 lock 경합에서 져서 바로 종료합니다(`:458-461`). 앱은 `hello.pid`만 감시하므로 이 helper는 reap되지 않고 Retry할 때마다 쌓입니다. 수정: spawn한 pid를 돌려받아 별도로 reap합니다.
4. **receipt에 순서 번호가 없고, trace 파일을 감시 디렉터리에 씁니다** (`EngineActivity.swift:55-58`, `main.swift:154`). `DMX_MENU_TRACE=1`이면 Retry의 `dismissError` trace 쓰기가 디렉터리 이벤트를 일으킵니다. 그러면 실패 직후 데몬이 아직 같은 pid로 살아 있을 때(linger 중이거나 used로 상주) 아직 덮어써지지 않은 실패 receipt를 다시 적용해, Retry가 성공해도 오류가 남습니다. 이 trace 모드로 모은 QA 증거가 영향을 받았을 수 있습니다. 수정: receipt에 단조 증가 sequence를 넣어 더 새로운 것만 적용하고, trace는 다른 경로에 씁니다.
5. **control socket 호출에 deadline이 없습니다** (`MenuEngine.swift:9-10`의 주석이 과장, `Agent.swift:185-196`). `status`, `stop`, `quit`에 시간 제한이 없습니다. 데몬이 멈추면 refresh가 걸리고, Quit은 `:324`에서 그 refresh를 기다리므로 Quit도 영구히 걸립니다. 30초 deadline은 Docker HTTP에만 적용됩니다.
6. **메뉴 열기가 idle stop과 겹치면 VM이 재부팅됩니다.** refresh의 `containers()`(`main.swift:172`)가 docker.sock에 연결하면 `running()`이 `.stopping`이 끝나기를 기다린 뒤 다시 부팅합니다(`Daemon.swift:262-265`). 기존 Docker 클라이언트도 같은 동작이지만 이 경우는 메뉴가 원인입니다. 창이 짧아 영향은 작습니다.

참고(결함 아님): Finder에서 실행한 앱은 셸의 `DMX_HOME`을 물려받지 않으므로, 커스텀 홈을 쓰는 사용자는 CLI와 다른 엔진을 띄울 수 있습니다.

---

### 알려진 릴리스 작업 (새 결함 아님)
- `scripts/install.sh:58-62`는 `dmx`만 설치하고, `scripts/release.py:535-575`는 단일 바이너리만 서명·공증합니다. 앱은 `build-app.py`의 ad-hoc 서명뿐입니다. 두 Mach-O 모두 Developer ID와 hardened runtime으로 서명하고(helper에는 hypervisor entitlement 포함), `.app`을 공증·staple해야 합니다. 배포 경로도 아직 없습니다.
- 번들 CLI는 `dmx update`를 거부합니다(`SelfUpdate.swift:251-254`). 그래서 앱 자체를 업데이트할 경로가 없습니다.
- `Version.swift:7`이 `0.3.12`인데, 공개된 v0.3.12 데몬에는 activity capability가 없습니다. 같은 버전 문자열로 다른 기능을 내보내지 않도록 버전을 올려야 합니다.

### 증거 공백 (결함과 별개)
- `MenuApp` 상태 기계를 다루는 테스트가 없습니다. P1, P2-1, P2-3, P3-1과 P3-2는 기존 테스트로 잡히지 않습니다.
- 실제 GUI 동작은 확인되지 않았습니다: 컨테이너 Start/Stop 클릭, Quit 클릭, 하위 메뉴, 메뉴가 열린 상태에서 `render()`가 `removeAllItems()`로 다시 그리는 동작.
- 확인되지 않은 시나리오: standalone 모드에서 CLI와 앱을 함께 쓰는 경우, 304와 포트 충돌 경로, 첫 실행 중 Quit.

### 게이트 판정
**needs-fixes.** P1과 P2-1~P2-3은 실제 코드 결함이라 수정이 필요합니다. 수정 뒤에는 다음을 증명해야 합니다.
- 작업 오류가 난 뒤에도 idle 종료와 데몬 종료 때 앱이 실제로 종료함
- start와 stop의 304를 성공으로 처리함
- standalone 모드에서 CLI로 Docker를 쓴 뒤에도 release 후 docker.sock이 유지되거나, 의도된 정책이 명시됨
- 첫 실행 중 Quit이 다운로드를 끝까지 기다리지 않음
- 공개 전에 앱 서명·공증·설치·업데이트 경로를 완성

이번 검토로 모든 결함을 찾았다고 보장하지는 않습니다.