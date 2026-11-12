**판정: RELEASE BLOCKED**

모델은 Claude Sonnet 5.5(`claude-sonnet-5-5`)예요. 코드만 읽었고 빌드·실행·VM 조작은 하지 않았어요. 아래 내용은 모두 코드를 읽고 도출한 것이고 재현은 못 했어요.

## 차단 결함

### F1. UDP 응답 스레드가 non-blocking fd를 poll 없이 읽어요 (High)
- 위치: `Sources/DMXCore/Daemon/UDPForward.swift:141`(`started`가 O_NONBLOCK을 켬), `:191-201`(`replies`의 `readExactly`), `:205`
- 문서와 어긋나요. 처분 표에는 "poll-based reply reader"라고 적혀 있는데, 이 파일에는 `poll`이 없어요(`grep poll`로 확인).
- 실패 순서:
  1. 어떤 피어든 첫 데이터그램으로 flow가 열리면 `started`가 연결 fd를 non-blocking으로 바꿔요. 같은 open file description이라 응답 스레드도 영향을 받아요.
  2. 응답 스레드의 `readExactly(2)`는 게스코가 아직 보낼 게 없으면 `read`가 EAGAIN을 돌려줘요. `offset == 0`이면 `return true`예요. 이 분기는 `send`에서 복사해 온 "drop an unsent datagram" 분기로 보여요.
  3. 호출부는 읽지 않은 `buffer`의 길이 바이트(처음엔 0)로 `count`를 정해요. `readExactly(0)`도 true라서 `sendto(..., 0, ...)`로 **길이 0짜리 UDP 데이터그램을 외부 피어에 계속 보내요**.
  4. 이 루프는 sleep 없이 100% CPU로 돌아요. `queue.async { flow.lastActive = .now }`가 매번 큐에 쌓여서 flow가 idle 만료되지 않아요. 큐도 가득 차요.
- 프레임 중간에 EAGAIN이 나면 다음과 같이 깨져요.
  - 길이 헤더 2바이트만 읽고 본문이 아직 안 왔을 때 `readExactly(count)`가 true를 돌려줘요. 쓰레기(이전 버퍼) 데이터그램이 나가고, 이어서 본문을 길이 헤더로 읽어서 스트림이 어긋나요.
  - `offset > 0`에서 EAGAIN이면 false가 되어 flow를 닫아요.
  - 큰 응답은 vsock 청크로 쪼개져 오므로 이 경우에 걸리기 쉬워요.
- 기존 방어가 못 잡는 이유: `UDPBackpressureTests`는 호스트→게스트 방향만 봐요(읽지 않는 게스트가 `counts`/`close`를 막지 않는지). 게스트→호스트 응답은 검사하지 않아요. 이 테스트는 응답 스레드가 도는 중에도 통과하니, 스핀은 테스트에 보이지 않아요. `test-docker`/`test-daemon`의 UDP echo가 이걸 잡았는지는 확인하지 못했어요. 그 결과는 읽지 않았어요.
- 수정: 응답 스레드는 `poll(POLLIN)`으로 기다린 뒤 읽고, 프레임 도중의 EAGAIN은 poll로 재시도하세요. `offset == 0 → return true` 분기는 `send`에만 두세요. 대안은 읽기 쪽을 blocking으로 되돌리고 쓰기만 `MSG_DONTWAIT` 또는 `poll(POLLOUT, 0)`으로 막는 거예요.
- 테스트: 게스트 쪽 소켓페어 끝에서 (a) 아무것도 안 보내면 호스트 피어가 빈 데이터그램을 받지 않고 CPU가 한가한지, (b) 프레임을 2바이트 + 본문으로 나눠 보내도 한 데이터그램으로 전달되는지 확인하세요.

## 릴리스를 막지는 않지만 고쳐야 할 것

### F2. Docker 목록 실패가 유한 상한 없이 VM을 계속 깨워 둬요 (Medium, 설계 결정 확인 필요)
- 위치: `Docker.swift` `busy`(`listingUnknown || …`), `sync`의 catch, `syncSoon`
- dockerd가 영구히 안 뜨거나 응답이 계속 실패하면 `listingUnknown`이 true로 남아요. VM은 idle 정지하지 못하고, 3초마다 재시도하는 루프도 에폭이 바뀔 때까지 돌아요.
- 이전에는 한 번 실패하면 그냥 건너뛰었어요(G7). 지금은 "항상 busy"라서 반대 방향으로 너무 갔어요.
- 제안: 연속 실패에 상한이나 총 시간 제한을 두고, 넘으면 busy를 풀되 재시도는 계속하세요.

### F3. 반쪽 닫힌 NAT flow를 120초 idle이면 RST로 끊어요 (Medium, 호환 위험)
- 위치: `UserNetTCP.swift`의 `halfCloseTimeout`, `tcpTick`
- 게스트가 FIN을 보낸 뒤 긴 서버 처리를 기다리는 경우(`nc < file`, 업로드 후 대기)에 걸려요. 호스트가 EOF를 낸 뒤 게스트 앱이 2분 넘게 읽지 않는 경우에도 걸려요.
- 이때 `sndUna`가 전진하지 않으니 zero-window probe는 진행으로 치지 않고, 두 경우 모두 RST로 정상 연결을 끊어요.
- 제안: 시간을 늘리거나(예: 30분 이상), 상대가 살아 있다는 신호(window update, ACK)를 진행으로 치세요. 이 동작을 의도한 거라면 `docs/memory.md`에 명시하세요.

### F4. `urgent()` 이후 시계 측정 시각이 어긋나요 (Low)
- 위치: `Agent.swift:565-571`, `:577-583`
- `unixNs`와 `sent`를 `open()` 전에 잡는데, 이제 매 호출마다 새 연결을 열어요. 그래서 RTT와 오프셋에 연결 수립 시간이 들어가요. 구간 경계는 여전히 맞지만(`[arrival - rtt, arrival]`), `trustedRoundTrip`을 넘기면 `exact`가 false가 되어 15초마다 재측정만 반복할 수 있어요.
- 제안: `urgent` 안에서 연결을 연 뒤 `sent`와 `unixNs`를 잡으세요.

## 확인했지만 결함이 아닌 것
- **G1 호환성**
  - 새 호스트와 옛 에이전트: `stdin_window`가 없어 `inputCredit`이 nil이고, 32KiB 블로킹 쓰기로 동작해요.
  - 옛 호스트와 새 에이전트: `flow_control`이 false이고, `InputQueue(legacy)`와 POLLRDHUP 감시 스레드가 hangup을 처리해요.
  - 데몬은 원시 바이트 릴레이라서 크레딧 JSON이 CLI까지 그대로 가요. `ExecStarted.stdinWindow`도 일관돼요.
  - `closeStdin`이 두 번 호출되어 SIGKILL이 나가는 호출부는 없어요.
- **G9**: `waitid(WNOWAIT)` 후 `alive` 락 안에서 reap하고, 제어는 `control_if_live`로 막아요. 순서가 맞아요.
- **G4**: ACK가 `docker::stop` 앞에서 나가고 `urgent`가 새 연결을 써요. 13초 안전망과 ACK 후 10초 데드라인이 서로 맞아요.
- **L1/L2/G2**
  - `vmAlive`가 `hostMappings.exclusive` 아래에 있어요.
  - 장치 `stop()`은 destroy 전에 `queue.sync`로 배리어를 걸어요.
  - 실패한 `start()`는 `teardown.wait()`로 정리돼요.
  - 워치독은 `_exit(70)`이에요.
  - 데드락 경로는 찾지 못했어요.
- **G6**: `beginStop`이 대기자를 풀고, `close`에서도 호출돼요.
- **G11**: `suspend`와 `resume`이 균형이 맞아요.

## 점검 범위
`git diff 9852647..08f09f5`의 프로덕션 코드를 읽었어요.
- Swift: `Agent`, `ConnectionDeadline`, `Daemon`, `DaemonClient`, `Docker`, `UDPForward`, `PortForward`, `MemoryController`, `Machine`, `TeardownWatchdog`, `VCPU`, `VirtioBlock`/`Balloon`/`Mem`/`Net`/`Vsock`, `UserNetTCP`, `FUSEServer`
- Rust·셸: `guest/agent/src/exec.rs`, `vsock.rs`, `main.rs`의 `serve`/`shutdown`, `guest/docker`, `guest/init`

읽지 않은 것은 다음과 같아요.
- 증거 로그와 `formal/` 모델
- `VirtioFS` 본체
- `scripts/`의 UDP 통합 테스트 내용
- exec.rs의 PTY 출력 펌프 세부 (diff 밖)

**RELEASE BLOCKED**예요. F1을 고치고, 응답 방향 테스트와 UDP echo 통합 테스트를 통과시킨 뒤 릴리스하는 걸 권해요.
