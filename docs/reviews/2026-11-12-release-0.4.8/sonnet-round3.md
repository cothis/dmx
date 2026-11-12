# 릴리스 전 3차 코드 리뷰 결과

모델은 Claude Sonnet 5.5(`claude-sonnet-5-5`)예요. 코드만 읽었고, 빌드·테스트·VM 조작·수정·커밋은 하지 않았어요.

## 결과: 릴리스를 막을 결함은 찾지 못했어요

3차에서 고친 부분과 주변 계약을 하나씩 추적했어요. 실패하는 시퀀스를 만들 수 있는 결함은 없었어요.

## 3차 수정 확인

- **DockerHTTP fd 리스**
  - `Agent.swift`의 `duplicateOpenFD()`는 `closeLock` 안에서 dup하고, `close()`도 같은 락 안에서 닫아요. 둘 사이에 끼어들 틈이 없어요.
  - `close()`가 소켓을 `shutdown(SHUT_RDWR)`하고, dup은 같은 소켓 객체를 가리켜요. 그래서 `poll`/`read`에서 막혀 있던 스레드가 EOF로 깨어나고, fd 번호가 재사용돼도 다른 연결을 건드리지 않아요.
  - 목록 조회(`sync`), 이벤트(`follow`/`lines`), inspect, `DELETE` 경로가 모두 `DockerHTTP.get/send/lines(FrameConnection)`을 거쳐요. raw fd를 받는 오버로드는 `private`이라 우회로가 없어요.
  - 잘린 본문은 JSON 파싱이 실패하고, 그 뒤 세대·epoch 검사가 걸러내요.
- **`AgentClient.run`**
  - `exit` 프레임이 마지막으로 도착하므로(guest가 펌프를 비운 뒤에 보내요) 그 시점에 연결을 닫아도 출력은 손실되지 않아요.
  - 닫으면 `finishInput()`이 크레딧 대기자를 깨우고 feeder가 끝나요. 오류 경로에서도 `defer`가 닫아서 feeder가 매달리지 않아요.
  - 자식이 stdin을 다 읽지 않고 끝내면(`head` 등) 그 종료가 이겨요. `guest_upgrade_required`는 `stdinFailure`로 보존돼요.
- **`syncTime` / `shutdown` / `runInGuest`**
  - `urgent`의 `open()`은 vsock 연결 타임아웃이 1초라 무한 대기가 없어요. 그 뒤 `withConnectionDeadline`이 15초(콜드 부팅) 또는 2초를 적용해요.
  - guest의 `shutdown` 핸들러는 ACK를 먼저 보내고 `docker::stop`을 해요. 그래서 2초 ACK 타임아웃이 guest의 sync를 중간에 끊지 않아요.
  - `runInGuest`는 `shutdown` 실패 시 `machine.stop()`으로 내려가고 `status`는 보존돼요.
  - `Daemon.powerOff`는 시작부터 13초 데드라인을 두고, ACK를 받으면 10초로 다시 걸어요.

## 이전 라운드 수정 재확인

- **UDP**
  - 연결이 `O_NONBLOCK`일 때, `offset == 0`이면 EAGAIN에서 데이터그램을 버려요.
  - `offset > 0`에서 EAGAIN이 나면 플로우를 끝내요. 프레이밍이 어긋나지 않아요.
  - 읽기는 EAGAIN이면 `poll` 후 재시도해요.
  - `counts`는 스냅샷 락을 쓰고 `close()`는 비동기라서, 닫는 쪽이 큐 때문에 막히지 않아요.
- **게스트 stdin (`exec.rs`)**
  - 모던 게스트는 프레임 리더가 stdin 큐에서 막히지 않아요.
  - 호스트 크레딧 64 KiB와 게스트 큐 한도 64 KiB가 같고, 크레딧은 쓰기가 끝난 뒤 반환돼요. 그래서 정상 호스트는 한도를 넘지 않아요.
  - EOF 프레임(빈 payload)은 큐가 가득 차 있어도 받아들여져요.
  - 레거시 클라이언트는 큐 한도가 `MAX_FRAME`이고, 넘치면 연결을 닫고 프로세스 그룹을 SIGKILL해요.
- **PID 수명**
  - `waitid(WNOWAIT)` 뒤 `alive` 락 안에서 `child.wait()`를 하고, 리더의 `kill(-pid)`와 컨트롤 신호는 같은 락 안에서만 나가요. PID 재사용 창이 없어요.
- **NAT**
  - 게스트 FIN과 호스트 EOF에서만 `halfClosedAt`을 세팅해요. `readHost`는 `finSeq != nil`이면 일찍 반환하므로 EOF가 타이머를 반복해서 리셋하지 않아요.
  - 데이터와 유효 ACK가 시간을 갱신하고, 30분 idle이 지나면 RST로 정리해요.
- **초기화·vCPU 실패 정리**
  - init 실패 정리, `created` 플래그, `start()` 실패 후 `teardown.wait()`가 맞게 들어가 있어요. HV 쪽에는 MainActor 호출이 없어서 `teardown.wait()`가 교착되지 않아요.
- **ENOSPC**
  - `waitForSpace`가 요청을 완료하지 않은 채 대기하고, `beginStop`이 대기자를 깨워요.
- **호환성**
  - 새 호스트와 옛 guest: `stdin_window`가 없으면 레거시로 처리해요. 4096바이트까지는 정상이고 초과하면 `guest_upgrade_required`로 닫아요. 이 동작은 의도한 대로예요.
  - 옛 호스트와 새 guest: `flow_control`이 없어 레거시 큐가 되고, 넘치면 연결을 끊어요. GuestPin이 짝을 맞춰 두므로 지원 범위 밖이에요.
  - guest `Params`에 `deny_unknown_fields`가 없어서 옛 guest가 새 필드를 받아도 거부하지 않아요.
- **회귀 스크립트**
  - `test-legacy-exec.py`의 4096바이트 경계, 1 MiB 실패, SIGINT 응답, 회수 확인이 코드 동작과 맞아요.
  - `test-release.py`는 마지막에 `failed`일 때 `exit(1)`을 하도록 바뀌었어요.

## 비차단 관찰

1. **낮음 — `Docker.swift` `connect()`**
   - `agent_connect_failed`를 받으면 `dockerdStopped()`가 `ports.setDockerForwards([])`까지 비워요.
   - dockerd가 실제로 죽은 경우엔 맞는 동작이에요. 일시적인 연결 거부라면 `ensureDocker` → `follow` → 재목록이 복구하기 전까지 공개 포트가 잠깐 끊겨요.
   - 이 코드 경로가 일시 오류에도 진입하는지는 확인하지 못했어요. 확인하면 좋지만 릴리스 조건은 아니에요.
2. **낮음 (로그 문구)** — `Daemon.powerOff`의 로그가 "10 s"인데 첫 데드라인은 13초예요.
3. **문서화된 안전 실패** — UDP는 페이로드 중간에서 EAGAIN이 나면 플로우를 종료해요(재현 가능, 의도된 동작). 레거시 stdin 4 KiB 초과도 마찬가지예요.

## 검토 범위

`9852647`부터 `08f09f5`와 현재 작업 트리까지 아래를 읽었어요.

- `Agent.swift`, `Docker.swift`, `Daemon.swift`, `DaemonClient.swift`, `RunCommand.swift`, `Exec.swift`, `CappedExec.swift`
- `UDPForward.swift`, `UserNetTCP.swift`, `Machine.swift`, `VCPU.swift`, `TeardownWatchdog.swift`, `VirtioBlock.swift`, `ConnectionDeadline.swift`
- `guest/agent/src/exec.rs`, `vsock.rs`, `main.rs`의 shutdown 핸들러, `guest/docker`, `guest/init`
- `scripts/test-legacy-exec.py`, `scripts/test-release.py`

실행으로 확인한 것은 없고 모두 정적으로 읽은 결과예요. `GuestPin`/버전 패키징 게이트는 그대로예요.

**NO RELEASE BLOCKERS**
