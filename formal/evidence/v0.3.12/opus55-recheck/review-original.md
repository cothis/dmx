# v0.3.12 작업 트리 독립 리뷰 (Opus 5.5, baseline `7b094ab`)

## 발견 사항

P0~P2 런타임 결함은 찾지 못했습니다. 이번 diff가 새로 만든 런타임 회귀는 F1(P3) 하나입니다. F2는 이번 diff 범위 밖의 잔존 문제이고, 나머지는 테스트·모델 약점입니다.

### 런타임 결함

**F1 — P3, 이번 diff의 신규 회귀: daemon 오류 메시지에 method 접두어가 붙고, exec 경로에서는 접두어가 두 번 붙음**

- **위치:** `Sources/DMXCore/Agent.swift:203-206`. 예전에는 `switch peer`에서 `.daemon`이면 `failure.message`를 그대로 넘겼습니다. 이번에 하나로 합치면서 daemon 쪽 메시지에도 항상 `"\(method): …"`가 붙습니다. code와 hint는 그대로 전달됩니다.
- **흔히 겪는 상황:** `dmx exec -- nosuchcmd`를 실행하면 다음 순서로 접두어가 붙습니다.
  1. 에이전트가 `exec_failed`, `"nosuchcmd: No such file…"`을 보냅니다(`guest/agent/src/exec.rs:115`).
  2. daemon의 AgentClient가 `"exec: nosuchcmd: …"`로 만들어 그대로 전달합니다(`Daemon.swift:182-184`).
  3. CLI의 `FrameConnection(peer: .daemon).exec`가 다시 `"exec: "`를 붙입니다.
  4. 결과는 `error: exec: exec: nosuchcmd: No such file or directory (os error 2)`입니다. 예전에는 `exec:`가 한 번만 붙었습니다.
- **다른 경로도 같습니다:**
  - `port_add`, `start`의 오류도 접두어가 새로 붙습니다.
  - `PortForward.swift:581`의 bad_request와 `Daemon.swift:183`의 internal은 이미 method를 메시지에 넣고 있어서 `port_add: port_add: …`처럼 중복됩니다.
  - MCP 응답 텍스트도 똑같이 바뀝니다.
- **영향 범위:** code 기반의 JSON 계약은 깨지지 않습니다. 사용자에게 보이는 메시지만 나빠집니다.
- **재현 방법:** `peer: .daemon`인 FrameConnection 쌍에서 `{"id":N,"ok":false,"error":{"code":"x","message":"m"}}`로 응답하고 `error.message == "m"`인지 확인하는 단위 테스트를 만듭니다. 현재 코드는 실패합니다. 지금 테스트는 agent peer만 다룹니다(`FrameConnectionTests.swift:144`).
- **수정 방법:** 한 줄이면 됩니다. `let message = peer == .agent ? "\(method): \(failure.message)" : failure.message`.

**F2 — P3, v0.3.11 때부터 남은 문제(이번 diff 범위 밖): daemon 서버 쪽 reply 전송이 dup 실패로 끝나면 클라이언트가 무한 대기**

- **위치:** R1 수정은 클라이언트 쪽만 다뤘습니다. 서버 쪽은 `Daemon.swift:146-184`의 `connection.send`가 여전히 프레임마다 dup합니다(`Agent.swift:258, 262-264`).
- **문제가 되는 흐름:**
  1. 응답을 보내려는 dup이 EMFILE로 실패합니다.
  2. `try? send(DaemonFailure)`도 같은 이유로 실패합니다.
  3. `serve` 루프는 다음 요청을 기다리고, 클라이언트는 이 요청의 응답을 기다립니다.
  4. `DaemonClient`의 호출에는 timeout이 없어서(`DaemonClient.swift:64-70`) `dmx status`나 `dmx port ls`가 끝나지 않습니다.
- **현실적인 조건:** daemon의 descriptor 한도는 OPEN_MAX(10240)까지 올라갑니다(`PortForward.swift:460-469`). 포워딩된 연결 하나가 descriptor 3개를 쓰므로, 동시 연결이 약 3400개를 넘는 부하에서 발생할 수 있습니다.
- **재현 방법:** 리뷰 때 쓴 DYLD interposer를 daemon 프로세스에 걸고, accept한 fd의 2번째와 3번째 `F_DUPFD_CLOEXEC`를 실패시킨 다음 `dmx status`가 멈추는지 봅니다.
- **수정 방법:** reply 전송이 실패하면 `serve`를 바로 끝냅니다(`return usesVM`). 그러면 클라이언트는 `daemon_disconnected`를 받습니다.
- **릴리스 영향:** 막을 이유는 아니고 후속 작업으로 충분합니다.

### 테스트·모델 약점 (모두 P3)

**M1 — 테스트로 잡히지 않는 retire 축소 mutation**

- **위치:** `Agent.swift:194-202`.
- **mutation:** retire 범위를 "ID 불일치일 때만"으로 줄이는 변경입니다. 예를 들어 `self.close()`를 id 검사 분기로 옮기는 경우입니다.
- **결과:** FrameConnectionTests 8개가 모두 그대로 통과합니다. 지금 retire를 확인하는 테스트는 wrong-ID 하나뿐입니다(`FrameConnectionTests.swift:129`). RPC 모델도 오염된 응답을 "ID 3" 하나로만 다룹니다.
- **보완할 테스트:** peer가 stdout kind 프레임, 깨진 JSON, `bad frame length` 중 하나를 보낸 뒤 정상 응답을 보내게 합니다. 그리고 `isClosed`가 참인지, 다음 호출이 이전 응답을 받지 않는지 확인합니다.

**M2 — 단위 테스트가 lease 대상 descriptor를 보호하지 않음 (R4 수정의 부작용)**

- **배경:** dup2를 쓰는 파괴적 테스트를 child process(`IsolatedFDProbe.swift`)로 옮긴 판단 자체는 맞습니다.
- **잡히지 않는 mutation:** `withOpenFD`가 `duplicateFD`는 호출하되 실제 I/O는 `self.fd`로 하는 변경입니다. 지금 `swift test`는 이것을 잡지 못합니다. guard, shutdown wakeup, RPC 테스트가 모두 원래 fd로도 통과하기 때문입니다.
- **수동 probe의 한계:**
  - `check-code.py:8,14`는 미리 빌드된 `.build/out/Products/Debug/DMXCore.o`를 빌드하지도, 최신인지 확인하지도 않고 링크합니다.
  - Makefile에 연결되어 있지 않습니다.
  - 이 probe가 mutation을 실제로 잡는다는 대조 실험도 이번 버전에서는 하지 않았습니다.
  - CI를 쓰지 않는 저장소라서, 원래 v0.3.11에서 고친 wrong-socket 결함은 정기적으로 확인되지 않습니다.
- **보완할 테스트 (파괴적 조작 없이 프로세스 안에서 가능):** 주입한 `duplicateFD`가 *다른* socketpair B의 dup을 돌려주게 합니다. 그리고 write/read 바이트가 B에서만 오가는지 확인합니다.

**M3 — frame 모델**

- **guard 제거 탐지:** `MC_guard.cfg`는 `NoLateAcquire`만 검사합니다. 이 속성은 "닫힌 뒤 acquire가 받아들여짐"을 뜻해서 guard를 말로 다시 적은 것에 가깝습니다. 피해를 기준으로 한 `NoForeignIO`만 검사하는 설정(예: `MC_guard_harm`)을 추가하는 편이 좋습니다. Close → Reuse → Acquire → Transfer, 깊이 6에서 위반이 나와야 합니다. 둘을 한 설정에 넣으면 BFS가 `NoLateAcquire`를 먼저 보고하므로 설정을 분리해야 합니다.
- **빠진 mutation:** 닫힘 검사와 dup이 lock 안에서 원자적이어야 한다는 성질에 대한 mutation이 없습니다. 검사 → unlock → dup으로 나누는 변경입니다. `Acquire`(Spec.tla:22-29)를 Check와 Dup 두 단계로 나누는 상수를 두면 독립적으로 구분할 수 있습니다.

**M4 — RPC 모델의 NoReplay는 위반될 수 없음**

- **원인:** `Send`는 호출마다 구조적으로 한 번만 일어나고, 재전송을 만드는 mutation 상수가 없습니다.
- **추가 문제:** `TypeOK`가 `sent ∈ 0..1`로 묶여 있습니다(`rpc Spec.tla:60`). 그래서 replay mutation을 넣어도 NoReplay가 아니라 TypeOK 위반으로 먼저 보고됩니다.
- **현재 상태:** "replay 없음"은 실제로는 테스트(`FrameConnectionTests.swift:161`)만 보장하고 있습니다.
- **보완 방법:** Reconnect 때 진행 중인 호출을 다시 보내는 `Replay` 상수를 추가하고, TypeOK를 `0..2`로 넓힙니다.

**M5 — 문서·증거 정합성 (docs 갱신 대상)**

- **`\* src:` 주석 오류:**
  - `Terminated`가 `Agent.swift:176-177`, `210-212`를 가리킵니다.
  - `FailAfterSend`가 현재 catch 블록을 가리키지만, 이 동작은 이제 과거 split lease에만 해당합니다.
  - `Reuse`가 `IsolatedFDProbe.swift:40-42`를 가리키는데, dup2는 39행입니다.
- **README 오래됨:** `formal/README.md`의 증거 위치와 기대 결과 목록이 옛 내용입니다.
- **properties 해시:** rpc의 `properties.sha256`은 보호 대상 파일과 같은 커밋에서 같은 디렉터리에 함께 만들어져, 스스로를 증명하는 구조입니다.
- **리뷰 중 증거가 바뀜:** 리뷰하는 동안 `formal/evidence/v0.3.12`의 로그가 10:52에서 10:56 실행본으로 다시 생성됐습니다. Spec에도 주석이 추가됐습니다. 최종 커밋에서 로그와 Spec이 같은 리비전인지 확인해야 합니다. 지금은 로직이 동일하고 행 번호도 맞습니다.

### 선택적 개선

- **timeout 경로의 중복 `replace`:** `Agent.swift:407`에서 `replace`를 부르고, catch(`:413`)에서 다시 부릅니다. 그 사이에 첫 재연결 Task가 실패해 끝나면 재연결과 로그가 한 번 더 나옵니다. 무해합니다.
- **인코딩 실패에 따른 불필요한 retire:** 인코딩이 retire하는 `do` 블록 안에 있어서(`:195`), 인코딩 실패만으로도 정상 연결이 retire됩니다. 지금 파라미터에는 Double이 없어 실제로는 일어나지 않습니다.
- **EOF 때마다 시작되는 재연결:** I/O 오류로 retire되면 이제 재연결을 시작합니다. 그래서 VM이 멈출 때 진행 중이던 호출이 EOF를 받으면, 멈춘 vsock에 1초짜리 connect를 시도하고 "cannot reconnect" 로그가 남습니다. `connectAgent` 루프에서 hello가 I/O 오류로 실패할 때도 고아 재연결이 생깁니다. 둘 다 자원을 잠깐 더 쓸 뿐, 안전성 문제는 아닙니다.
- **retire 직후 즉시 실패:** retire 직후, 비동기 swap이 끝나기 전에 들어온 다음 호출은 `agent_disconnected`로 바로 실패합니다. 모델(Acquire에 `live` 필요)과 테스트(`MainActor.run` 대기)는 둘 다 이 경우를 피해 갑니다. replay를 하지 않는 설계와는 일치하고, SCOPE 문서에 한계로 적혀 있습니다.

## R1~R5 처리 상태

| 항목 | 상태 | 근거 |
|---|---|---|
| R1: 응답 어긋남 | **해결** | 교환 전체에 단일 lease(`Agent.swift:190-209`), ID 검사(`:344-347`), 불확실하면 retire(`:197-201`), 재연결은 하되 replay 없음(`:403-453`). 닫힌 뒤 재연결 금지(`:395-401`, `:436`, `:450`). agent(`main.rs:156-161`)와 daemon(`DaemonProtocol.swift:66-76`) 모두 `id`를 echo해서 호환됩니다. 실제 fcntl EMFILE probe도 통과했습니다. 남은 것은 M1. |
| R2: 모델 민감도 | **대체로 해결** | 관찰값이 이제 fix selector가 아니라 descriptor binding에서 나옵니다. guard / lease / early-release mutation이 각각 실패합니다. 남은 것은 M3, M4. |
| R3: shutdown wakeup | **해결** | peer를 정리하기 전에 assert합니다(`FrameConnectionTests.swift:64-104`). shutdown을 제거하면 두 assertion이 모두 실패하는 것을 증거로 확인했습니다(`.build/fixes-0.3.12/no-shutdown/test.log`). |
| R4: 테스트 FD 격리 | **해결** | 단위 테스트에서 dup2를 없애고 child probe로 분리했습니다. 대신 M2의 공백이 생겼습니다. |
| R5: 같은 archive, 다른 tag | **해결** | `GuestStore.swift:159`에서 `receipt != pin`을 비교하고, `GuestStoreTests`에 새 테스트가 있습니다. 다운로드 경로는 바뀌지 않았습니다. |

## 범위와 한계

- Read/Grep/Glob만 사용했고 빌드, 테스트, TLC, 실제 VM은 실행하지 않았습니다.
- 모델 결과와 probe 결과는 기록된 로그(`formal/evidence/v0.3.12`, `.build/fixes-0.3.12/*`)를 읽고 판단했습니다.
- F1과 M1~M4는 코드와 로그를 읽어서 추론한 것이며, 재현해 보지는 않았습니다.
- 이 리뷰는 전체 프로그램의 정확성이나 운영 환경에서의 발생 빈도를 보증하지 않습니다.

## 릴리스 권고

**조건부 진행.** R1~R5는 실질적으로 해결됐고, 새로 생긴 P0~P2 결함은 없습니다.

- **태그 전에 고칠 것:** F1을 한 줄로 고치고 daemon peer 메시지 테스트를 추가한 뒤, `swift test --filter FrameConnectionTests`와 `make daemontest`를 다시 돌리기를 권합니다. F1을 그대로 출시해도 code 계약은 깨지지 않지만, `dmx exec` 오타처럼 흔한 경로에서 메시지가 나빠집니다.
- **후속으로 넘겨도 되는 것:** F2와 M1~M5는 출시를 막지 않습니다. 이 중 M2의 lease 대상 테스트와 M1의 retire 범위 테스트는 다음 패치에 넣기를 권합니다.