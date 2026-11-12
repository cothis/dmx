**NO RELEASE BLOCKERS** (정적 검토만 했고 아무것도 실행하지 않았어요.)

## 확인한 수리

- **`ExecKiller`**(`CappedExec.swift:176-192`): `kill`과 `finish`가 모두 `session.connection.close()`만 불러요.
  - 이 호출은 `closeLock`과 `closed` 플래그 아래에서 한 번만 실행돼요. 종료 시점에 `shutdown(fd)`를 부르고 그 뒤에 `closeConnection()`이 fd를 닫아요.
  - `nextEvent`(`Agent.swift:318`)나 `writeStdin`(`Agent.swift:158`)이 먼저 연결을 닫았으면 `kill`은 아무것도 하지 않아요. 그래서 재사용된 fd 번호에는 닿지 않아요. round3의 P1 순서는 막혔어요.
  - 락 순서는 `ExecKiller.lock`, `closeLock`, `input` 순이에요. `writeStdin`은 `input` 락을 푼 뒤에 `close()`를 부르니, 반대 방향으로 잡는 경로가 없어서 데드락은 없어요.
- **블록 중인 읽기**: `readFrame`이 `withOpenFD`로 dup한 사본을 쥐고 있어요. `close()`의 `shutdown`은 같은 소켓에 걸리니, 그 읽기도 깨어나요.
- **`DockerBridge.vmStopped`**(`Docker.swift:~108`): `events?.close()`를 써요. `DockerHTTP.send/get/lines`는 `duplicateOpenFD`로 빌린 사본으로 동작해서 같은 이유로 안전해요.
- **`ExecKillerFDProbe`**: 순서가 맞아요. EOF를 받아 fd를 풀고, `dup2`로 같은 번호를 다른 소켓에 재사용시킨 다음 옛 killer의 `kill`과 `finish`를 부르고, 낯선 소켓이 양방향으로 계속 통신하는지 확인해요. `check-code.py`는 이 프로브를 따로 컴파일해서 별도 자식 프로세스로 돌려요.

## 남은 `FrameConnection` raw fd 사용처 감사

| 사용처 | 판정 |
|---|---|
| `Daemon.swift:230` `relay(client.fd, session.connection.fd)` | `relay`는 두 펌프 스레드가 모두 끝나야 돌아오고, 두 fd의 `close`는 그 뒤(`defer`, serve 루프)에만 일어나요. 그 사이에 이 연결을 닫는 다른 경로는 없어요. 안전해요. |
| `Daemon.swift:191` `forwardMenu(connection.fd)` | 닫는 쪽이 serve 루프 하나뿐이고, 호출이 끝난 뒤에 닫아요. 안전해요. |
| `UDPForward.swift:141-198` | `end`(`shutdown`)와 `send`(`write`)는 `queue`에서만 돌아요. `end`는 `flow`를 `flows`에서 먼저 빼요. `close`는 reply 스레드가 끝난 뒤 같은 `queue`에서 `end` 다음에 실행돼서, 닫힌 fd에 접근하는 경로가 없어요. 이번 diff의 `poll` 추가도 `close` 전에 일어나는 읽기라 문제없어요. |
| `PortForward.swift:386`, `Docker.swift:161,175` | stream은 `splice`/`proxy.run()`이 끝난 뒤에만 `close`해요. 안전해요. |
| `DaemonClient.menuDocker:94`, `SandboxReaper.swift:22` | `DockerStream`의 `closed` 플래그와 락이 `shutdown`·`close`를 직렬화해요. `connection`은 이 클로저만 쥐고 있어서 다른 닫는 쪽이 없어요. 안전해요. |
| `Agent.swift:643,658,720` | round3에서 이미 확인했고 이번에도 달라진 게 없어요. |

## 실제 결함

없어요.

## 차단은 아닌 추측성 위험

- `ExecKiller.kill(timedOut: true)`가 EOF로 이미 끊긴(`exit` 없음) 시점부터 `finish()` 전 사이에 타이머로 불리면, `daemon_disconnected` 대신 `timedOut: true` 결과가 나올 수 있어요. 창이 아주 짧고 fd 안전성과는 무관해요. 고치려면 `nextEvent`에서 EOF를 본 쪽이 `killer`에 알리면 돼요. 이번 릴리스에서는 고치지 않아도 돼요.

## 검토 범위

`9852647`부터 `HEAD 08f09f5`까지와 현재 작업 트리를 봤어요. 중점은 `Agent.swift`의 `FrameConnection`, `CappedExec.swift`, `ExecKillerFDProbe.swift`와 `check-code.py`, `Docker.swift`, `DockerAPI.swift`, `UDPForward.swift`, `Daemon.swift`의 `relay`/`exec`, `PortForward.swift`, `DaemonClient.swift`, `SandboxReaper.swift`, `ConnectionDeadline.swift`예요. `sol-round3.txt`도 읽었고, `sonnet-round3.json`은 열어보지 않았어요. 이번 확인은 정적 검토여서, 빌드·프로브 실행·VM 조작·수정·커밋은 하지 않았어요.

`GuestPin`은 `0.4.7`로 두고 `0.4.8` 패키징 때 갱신해야 해요. 서명된 fresh/update/fallback/lifecycle 게이트를 통과한 뒤에 배포하세요.

저는 Sonnet 5.5(`claude-sonnet-5-5`)예요.
