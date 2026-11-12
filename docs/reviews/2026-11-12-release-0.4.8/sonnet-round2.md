**판정: NO RELEASE BLOCKERS.** 코드 읽기만 했고 빌드·테스트·VM 조작은 하지 않았어요. 모델은 Claude Sonnet 5.5(`claude-sonnet-5-5`)예요. 아래 결함은 모두 정적 분석이라 재현하지 않았어요. 패키징 단계에 하나 조건이 걸려요. 맨 아래에 적었어요.

## 1라운드 지적 재검증

| 항목 | 결과 |
|---|---|
| UDP `EAGAIN` / 프레임 분할 | `UDPForward.swift:197-203`에서 `poll`로 기다리고 offset을 보존해요. `offset == 0` 분기는 `send`에만 남아 있어요. 해결됐어요. |
| dockerd 재시도·연결·generation 정리 | `resetListing`과 `dockerdStopped`가 task, stream, `listingUnknown`을 정리해요. `follow`, `syncSoon`, `sync`가 모두 epoch와 generation을 확인해요. 해결됐어요. |
| EOF가 stdin 크레딧 대기를 깨움 | `nextEvent`의 `catch`가 `close()`를 호출하고 `close()`가 `finishInput()`을 호출해요. 해결됐어요. 다만 아래 결함 2가 새로 생겼어요. |
| 레거시 stdin backpressure | 새 호스트는 레거시 게스트에 누적 4096바이트까지만 보내요. 넘으면 `guest_upgrade_required`로 연결을 닫아요. 새 게스트는 reader가 `push`에서 막히지 않아요. `legacy-fixed.log`에서도 통과했어요. |
| half-close ACK 갱신과 30분 만료 | `madeProgress`가 `acked >= 0`인 ACK마다 갱신해요. 주석은 "probe는 갱신 안 함"이라 하지만 코드는 갱신해요. 살아 있는 ACK로 갱신하는 것은 의도이고 실제 TCP와도 같아서 결함으로 보지 않아요. |
| 연결 직후 시계 샘플링 | `urgent` 안에서 `open()` 뒤에 `sent`와 `unixNs`를 잡아요. 해결됐어요. |

PID 수명도 맞아요. `waitid(WNOWAIT)`로 종료만 관찰하고, `alive` 락 안에서 reap해요. `control_if_live`와 reader의 `kill`이 그 락을 공유해요. PTY master는 `Arc`로 소유해서 reader 스레드보다 먼저 닫히지 않아요.

그 밖에 vCPU 생성 실패와 `loadGuest` 실패는 `teardown.wait()`로 정리돼요. `hostMappings.exclusive` 아래에서 `vmAlive`를 검사하고, 장치 `stop()`은 `destroyVM` 전에 `queue.sync`로 막아요. ENOSPC 대기자는 `beginStop`이 `Machine.stop` 첫머리와 `close()`에서 풀어요.

## 결함

### 1. [Low-Medium] 부팅 `syncTime`과 `shutdown`에 2초 제한이 새로 걸렸어요
- 위치: `Agent.swift`의 `urgent`(2초 deadline), 호출부 `Daemon.swift:321`, `RunCommand.swift:17`, `RunCommand.swift:35`
- 이전에는 공용 `call`의 60초 `callTimeout`을 썼어요.
- 실패 순서 A: 부하가 큰 맥에서 첫 부팅이 이어지고 게스트가 `time_sync`에 2초 안에 답하지 못해요. `agent_timeout`이 나고, `boot()`의 `catch`가 VM을 멈춰서 `boot_failed`가 돼요. 기존의 "첫 부팅 30초 허용"과 어긋나요.
- 실패 순서 B: `dmx run`에서 명령이 정상 종료됐는데 `agent.shutdown()`이 2초를 넘겨요. `catch`가 `machine.stop()`을 호출한 뒤 예외를 던져서, 명령의 종료 코드가 사라져요.
- 기존 방어: `connectAgent(timeout: 120)`는 연결만 확인하고 첫 요청의 지연은 막지 못해요.
- 수정: 부팅 시 `syncTime`은 10~15초를 주거나 실패해도 부팅을 막지 않고 `keepClock`에 맡기세요. `RunCommand`의 `shutdown()`은 `try?`로 바꾸세요. 주기적 보정의 2초는 유지해도 돼요.

### 2. [Low] 일찍 끝나는 프로세스에 64KiB 넘는 stdin을 주면 `AgentClient.run`이 실패해요
- 위치: `Agent.swift:296`(`exit` 시 `finishInput`), `Agent.swift:149-173`(`writeStdin`), `Agent.swift:642-653`(`run`의 `try await feed.value`)
- 실패 순서: `run(["true"], stdin: 1MiB)`를 호출해요. 게스트는 첫 청크에서 EPIPE가 나서 `stdin = None`이 돼요. 그래도 크레딧은 계속 돌려줘요. 게스트가 `exit` 이벤트를 먼저 보내면 호스트가 `finishInput()`을 호출해요. 호스트 feeder는 남은 청크에서 `agent_disconnected`를 던지고, `run`이 `feed.value`에서 같은 오류로 실패해요. 0.4.7은 성공했어요.
- 기존 방어: 게스트는 EPIPE 뒤에도 크레딧을 돌려주지만, 경주 상황이라 막아 주지 못해요.
- 수정: `exit`를 받은 뒤에는 `_ = try? await feed.value`로 feeder 오류를 무시하세요. 테스트는 `run(["true"], stdin: 1MiB)`가 exit 0으로 반환되는지 보세요. 현재 호출부는 대부분 소량 stdin이라 영향은 작아요.

### 3. [Low] 레거시 경로의 보수성
- 새 호스트와 옛 게스트에서는 tty 대화형 세션도 누적 4096바이트를 넘기면 끊겨요. 붙여넣기 한 번으로 셸이 죽어요. `guest_upgrade_required`로 의도한 안전 실패라 결함은 아니에요. 호환 범위는 "GuestStore가 항상 맞는 게스트를 받는다"는 가정에 기대요.
- 옛 호스트와 새 게스트에서는 `flow_control` 없이 큐 한도가 `MAX_FRAME`(16MiB)이고, 넘으면 프로세스 그룹을 SIGKILL해요. 느린 소비자에게 16MiB 넘게 보내던 옛 호스트는 막히는 대신 죽어요. 호스트와 게스트 버전이 짝으로 배포되므로 실제 영향은 작아요.

### 4. [Low] 사소한 사항 세 가지
- `Docker.swift` `connect()`: `agent_connect_failed`가 한 번만 나도 `dockerdStopped()`가 `ports.setDockerForwards([])`를 호출해요. 일시적 실패에도 모든 컨테이너 포트 포워드가 재조회가 끝날 때까지 내려가요. 예전에는 `up = false`만 했어요.
- `Docker.swift` `busy`: dockerd가 연결은 받는데 목록 조회만 계속 실패하면 `listingUnknown`이 영구히 true예요. 3초 간격 재시도는 계속되고 VM은 idle 종료를 못 해요. 보수적 설계이고 sonnet 1라운드의 F2와 같아요. 상한 시간을 두는 정도를 권해요.
- `UDPForward.swift` `send`: 부분 쓰기(`n > 0`) 뒤 `EAGAIN`이 나면 flow를 종료해요. 안전한 실패이고 다음 데이터그램에서 flow가 다시 열려요.

## 릴리스 조건 (패키징 게이트)
`GuestPin`이 0.4.7인 채로 0.4.8 호스트를 내면 안 돼요. 게스트가 옛 것이라 stdin이 4096바이트를 넘는 모든 `exec`가 실패해요. `test-release.py`의 `fix_large_stdin_lossless`(1MiB)와 `update_previous_guest_fallback`이 이를 잡으니, 패키징 뒤 두 검사를 반드시 통과시키세요. `guest/docker`·`guest/init`의 `durable-v1` 마커도 새 initramfs에 들어가야 해요.

## 점검한 범위
- Swift: `Agent`, `ConnectionDeadline`, `Daemon`, `DaemonClient`, `DaemonProtocol`, `Docker`, `UDPForward`, `PortForward`, `MemoryController`, `Launchd`, `Machine`, `TeardownWatchdog`, `VCPU`, `VirtioBlock`/`Balloon`/`Mem`/`Net`/`Vsock`, `FUSEServer`, `UserNetTCP`, `HostMappings`, `RunCommand`, `Daemon.relay`
- Rust·셸: `exec.rs`(테스트 포함), `vsock.rs`, `main.rs`의 shutdown, `guest/docker`, `guest/init`
- 스크립트: `test-legacy-exec.py`, `test-release.py` diff, 그리고 1라운드 보고서 2건과 `legacy-fixed.log`

`formal/` 증거 로그, `VirtioFS` 본체, 유닛 테스트 본문은 읽지 않았어요.
