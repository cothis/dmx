# dmx v0.3.11 릴리스 리뷰

검토 범위는 diff 전체, `Agent.swift` 전체, 그리고 인접 호출자입니다. 호출자는 Daemon(serve/exec/relay), PortForward(splice), Docker 브리지(DockerProxy 연결과 HTTP), UDPForward, SandboxReaper/DockerStream, CappedExec/ExecKiller, Exec, VirtioVsock입니다. 그 밖에 `GuestStore.swift` 전체와 Doctor/CLI 호출자, 테스트 3개와 GuestStore 테스트, `formal/` 모델과 문서, 릴리스 노트, 측정 JSON의 관련 부분을 읽었습니다. 빌드나 실행은 하지 않았습니다(read-only).

**결론:** 이번 변경으로 새로 생긴 코드 결함 1건(P2, 드문 조건)이 있습니다. 증명 산출물에도 실질적 결함 1건(P2)이 있습니다. 나머지는 커버리지 공백입니다. GuestStore 변경에서는 결함을 찾지 못했습니다.

---

## 1. [P2, 이번 릴리스에서 도입] 매 프레임 `dup`이 EMFILE로 실패하면 요청/응답 짝이 영구히 어긋남

**위치**
- `Sources/DMXCore/Agent.swift:162-170`: `withOpenFD`가 매 프레임마다 `F_DUPFD_CLOEXEC`를 호출합니다.
- `Agent.swift:177-183`: `reply()`는 쓰기(lease 1)와 읽기(lease 2)를 따로 획득합니다.
- `Agent.swift:306-309`: `readReply`는 응답 id를 확인하지 않습니다.
- `Agent.swift:372-380`: `AgentClient.call`은 타임아웃일 때만 연결을 교체합니다.

**발생 경로**
1. daemon의 control 연결에서 `AgentClient.call` → `reply()`가 실행되고 `writeJSON`이 성공합니다. 요청은 agent로 전송됩니다.
2. 이 시점에 프로세스 fd 테이블이 가득 찹니다. 예: PortForward 연결 폭주. 연결 하나에 fd 3개를 쓰고, 한도는 `OPEN_MAX`=10240입니다.
3. `readReply` → `readFrame` → `withOpenFD`의 `fcntl(F_DUPFD_CLOEXEC)`가 EMFILE을 반환합니다. 결과는 `agent_disconnected` "agent: Too many open files"입니다.
4. 연결은 닫히지 않고, 요청 N의 응답은 소켓에 그대로 남습니다.
5. 다음 call N+1은 응답 N을 즉시 읽습니다. 이후 모든 호출이 한 칸씩 밀립니다.

**기대 동작:** 일시적인 fd 부족이면 해당 호출만 실패하고 연결 상태는 유지돼야 합니다.

**예상 동작:** control 연결이 영구히 어긋납니다.
- `MemoryController.swift:163`의 주기적 `stats`는 한 주기 늦은 값을 조용히 받습니다.
- 메서드가 섞이면(`reclaim` 응답을 `stats`로 디코딩하는 등) `agent_protocol` 오류가 계속 납니다.
- `shutdown()`은 `Empty`라서 아무 응답이나 성공으로 디코딩합니다.
- 오래된 응답이 항상 바로 도착하므로 60 s 타임아웃이 발동하지 않습니다. 따라서 VM이 재시작될 때까지 자가 복구되지 않습니다. 기본 기능인 메모리 절약 루프가 망가집니다.

**기존 방어가 막지 못하는 이유**
- v0.3.10에서는 이미 열린 fd로 읽기 때문에 fd 부족이 진행 중인 프레임 I/O에 영향을 주지 않았습니다. 읽기 오류는 소켓이 실제로 끊겼을 때만 났습니다.
- 지금은 오류 코드도 `*_disconnected`로 잘못 표시되어, 호출자가 연결이 이미 끊겼다고 가정합니다.
- daemon은 fd 고갈을 이미 예상된 운영 조건으로 다룹니다(`PortForward.swift:344` EMFILE 시 accept 일시정지).
- 모델의 A5("dup 실패 = 거부, 안전성상 동등")는 정확히 이 지점을 범위에서 뺍니다.

**가장 싼 결정적 재현:** `FrameConnection` 단위에서 확인합니다.
1. socketpair로 `FrameConnection(fd: a)`를 만듭니다.
2. `writeFrame(.json, …)`가 성공합니다.
3. `open("/dev/null")`을 EMFILE이 날 때까지 반복해 fd 테이블을 채웁니다.
4. peer(b)에 응답 프레임을 씁니다.
5. `readFrame()`이 `agent_disconnected`를 던지는지 확인합니다. `recv(a, MSG_PEEK|MSG_DONTWAIT)`로 응답이 남아 있는지도 확인합니다.
6. 채운 fd를 해제한 뒤 `reply("m2", …)`가 응답 1의 payload를 반환하는지 확인합니다.

production 타이밍(쓰기와 읽기 사이의 고갈)을 그대로 재현하는 테스트는 경쟁 조건이 있어서 결정적이지 않습니다.

**신뢰도:** 메커니즘은 높습니다(fcntl(2)에 F_DUPFD의 EMFILE이 명시되어 있고, 코드 경로가 명확합니다). 실제 빈도는 낮음~중간입니다. fd 약 1만 개 수준의 압박이 필요합니다.

---

## 2. [P2, 증명 산출물, 이번 릴리스에서 도입] TLA+ 모델은 고정 구성에서 성질이 구성상 참이 됨

**위치:** `formal/frame-connection-lifetime/tla/Spec.tla:341`, `:349`
- `lateAcquire' = (lateAcquire \/ (closed /\ ~LeaseFD))`
- `foreignIO' = (foreignIO \/ (~LeaseFD /\ slot = "foreign"))`

`MC.cfg`에서는 `LeaseFD = TRUE`이므로 두 ghost 변수가 어떤 전이에서도 FALSE로 고정됩니다. 따라서 `NoForeignIO`와 `NoLateAcquire`는 Acquire나 Transfer의 실제 구조와 무관하게 성립합니다.
- 예를 들어 Acquire의 closed 검사를 지워 `phase' = "active"`로 바꿔도 MC.cfg는 그대로 통과할 것으로 예상합니다.
- "mutation"(`MC_bug.cfg`)은 같은 ghost 식 안의 `LeaseFD` 플래그를 뒤집을 뿐입니다. 그래서 이 반례는 모델이 lease 로직의 버그를 잡을 수 있다는 증거가 되지 못합니다.

**구분**
- 구현 오류가 아니라 모델링 결함입니다.
- 코드를 직접 읽어 보면 NoForeignIO와 NoLateAcquire는 실제로 성립한다고 판단합니다. 근거는 closed 검사와 dup이 같은 lock 구간에 있고, 프레임 전체가 사본 fd를 쓴다는 점입니다.
- Properties.tla 자체가 약화된 것은 아닙니다. 하지만 계측(ghost)이 결론을 미리 담고 있습니다.

**릴리스 노트 문장:** "134 states에서 성립, 수정을 제거하면 반례"는 문자 그대로는 참입니다. 그러나 검증 근거로는 오해를 부릅니다.

**정직한 형태:** 각 연산에 `binding[o] ∈ {none, number, dup}`을 두고 다음과 같이 정의하면 됩니다.
- `lateAcquire' = lateAcquire ∨ (closed ∧ phase'[o]="active")`
- `foreignIO' = foreignIO ∨ (binding[o]="number" ∧ slot="foreign")`

**재현:** scratch 사본에서 Acquire의 `LeaseFD /\ closed` 분기를 지우고 `check.py`의 model-after를 실행합니다. 통과할 것으로 예상합니다.

**신뢰도:** 높음(식만 보면 결정됩니다).

---

## 3. [P3, 커버리지 공백] `close()`의 shutdown이 실제로 blocked I/O를 깨우는지 검증하는 테스트가 없음

**위치**
- `Tests/DMXCoreTests/FrameConnectionTests.swift:216-217`: 테스트가 직접 `shutdown(original[1], SHUT_RDWR)`를 호출합니다.
- `Agent.swift:156`

lease 설계에서 이 shutdown은 필수입니다. 이것이 없으면 대기 중인 reader의 사본 fd가 소켓을 살려 둡니다. 그러면 reader가 깨어나지 않고, peer도 EOF를 보지 못합니다. 영향받는 곳은 `AgentClient.replace` → `abort()`, Daemon serve 종료, 그리고 exec 종료입니다.

**공백 내용**
- 세 번째 테스트에서는 peer 쪽 shutdown이 같은 EOF를 만들어 냅니다. 그래서 `Agent.swift:156`을 지워도 세 테스트가 모두 통과할 것으로 예상합니다.
- 테스트 1과 2는 "닫힌 뒤에는 시작하지 않음"만 검사합니다. dup이 없고 closed 검사만 있는 구현으로도 통과합니다.
- CORRESPONDENCE A4("close의 shutdown/wakeup은 실제 소켓 회귀 테스트로 커버")는 과장입니다. VM/MCP 스위트의 timeout과 cancellation은 `ExecKiller`의 raw `shutdown`(`CappedExec.swift:183`)을 거치기 때문에 `close()` 경로가 아닙니다.
- `AgentClient.replace`에 대한 단위 테스트도 없습니다.

**재현:** scratch 사본에서 156행을 제거하고 `FrameConnectionTests`를 실행합니다. 통과할 것으로 예상합니다.

---

## 4. 회귀 감사: shutdown-on-close에서는 회귀를 찾지 못함

- 모든 `FrameConnection` fd는 AF_UNIX 스트림 소켓입니다. daemon 소켓과 VirtioVsock socketpair(`VirtioVsock.swift:163`)가 여기에 해당합니다.
- 다른 참조가 없을 때 `shutdown(SHUT_RDWR)`+`close`는 `close`만 한 것과 같습니다. Unix 소켓은 보낸 데이터가 이미 peer의 수신 버퍼에 들어가 있어서 유실이 없습니다.
- 참조가 더 있는 경우는 lease 사본, 그리고 CLOEXEC가 아닌 accept/vsock fd의 상속입니다. 이때 shutdown은 의도된 개선입니다.
- raw `.fd` 사용자는 모두 사용을 마친 뒤에 순차적으로 close합니다.
  - Daemon `relay`(`Daemon.swift:199-204`)
  - PortForward `splice` → `stream.close()`(`:385-386`)
  - Docker `DockerProxy`와 `DockerHTTP`
  - UDPForward: 같은 serial queue에서 `end` → `close`를 수행합니다.
  - DockerStream과 StreamKiller: 자체 lock과 "shutdown 후 close" 순서를 지킵니다.
  - ExecKiller: `kill`과 `finish`가 같은 lock 안에 있습니다.
- relay와 splice 주석이 우려하는 "읽지 않은 마지막 출력 폐기"는 양방향이 모두 끝난 다음에 close하므로 해당되지 않습니다.
- lock 순서는 writeLock → closeLock과 DockerStream.lock → closeLock 두 가지입니다. 역순 경로가 없어서 교착이 없습니다.
- `AgentClient.replace` 이후 같은 큐에 대기하던 호출은 이제 "connection closed"로 실패합니다. 예전에는 닫힌 번호나 재사용된 번호에 접근할 수 있었으므로 개선입니다.
- 공개 API와 오류 코드 호환성은 유지됩니다. `abort`와 `readFrame`은 internal입니다.

## 5. GuestStore: 결함 없음

- `renamed`는 `source == .release`일 때만 성립하므로 로컬 guest는 건드리지 않습니다.
- 손상되었거나 없는 receipt는 `.local`로 판정되어 대상에서 빠집니다.
- 실제 갱신은 `guest.lock` 아래에서 state와 receipt를 다시 확인한 뒤 원자적으로 씁니다(`.atomic`).
- 네트워크를 쓰지 않으므로 오프라인 fallback이 필요 없습니다.
- 다른 파일을 가진 릴리스에 대한 기존 다운로드와 fallback 경로는 그대로입니다.
- 테스트 `bootRecordsTheNewTagOfTheSameFiles`는 연결 불가 URL로 "다운로드 없음"을 적절히 확인합니다.

**P3 관찰(결함 아님)**
- (a) tag만 다르고 archive sha256가 같으면 매 부팅마다 lock만 잡고 아무것도 하지 않습니다. 현실성은 거의 없습니다.
- (b) 이제 부팅이 동시에 실행 중인 `guest fetch --force`의 lock을 기다립니다. 이는 올바른 동작입니다.
- (c) 이 경로에서 lock 열기에 실패하면 "cannot update the guest from X to Y"라는 다소 오해를 부르는 로그가 남습니다.
- (d) `try? writeReceipt` 실패 뒤에도 "kept them" 로그가 남습니다.
- `GuestState`의 필드와 의미는 변하지 않았습니다. 부팅 전 `dmx guest`는 여전히 이전 tag를 보여 주는데, 릴리스 노트의 "next boot 이후"와 일치합니다.

## 6. 릴리스 주장 검증

- "세 테스트가 수정 전에는 실패": `repro-before.log`에서 3건 모두 실패가 확인됩니다.
- "134 states": `model-after/tlc.log:94`에서 확인됩니다. 다만 의미는 2번 결함에 따라 제한됩니다.
- 측정 JSON은 `"scope": "bounded safety model; no whole-program or blocked-I/O liveness proof"`라고 적고 있고, descriptor 재사용이 published CLI로 강제되지 않았다는 점도 정직하게 밝힙니다.
- 지지되지 않는 주장은 두 가지입니다. 하나는 "Closing also shuts down pending I/O"의 테스트 근거(3번)이고, 다른 하나는 모델이 lease를 검증한다는 함의(2번)입니다.

---

## 판정

- 이번 릴리스는 원래 버그(재사용된 fd로 framed I/O가 가는 문제)를 코드 수준에서 올바르게 고친 것으로 판단합니다. 긴급 회수(P0/P1)가 필요한 문제는 없습니다.
- 다만 1번은 새로 도입된 실제 결함입니다. 다음 패치에서 처리할 만합니다. 예를 들어 연결별 lease를 재사용하거나, 읽기 실패 시 연결을 폐기하는 방법이 있습니다.
- 2번과 3번은 검증 근거를 실제보다 강하게 보이게 하므로 문서와 모델을 바로잡을 필요가 있습니다.

## 남은 사각지대

- blocked-I/O liveness는 모델에도 단위 테스트에도 없습니다. 특히 `abort`/`close`로 깨우는 경로입니다.
- 실제 production 스케줄에서 descriptor 재사용이나 EMFILE이 얼마나 자주 발생하는지는 측정되지 않았습니다.
- daemon이 자식 프로세스에 CLOEXEC가 아닌 fd를 물려주는지는 확인하지 않았습니다(Foundation `Process`의 동작).
- `onQueue`는 취소를 반영하지 않습니다(기존 문제).
- 어떤 bounded 모델도 Swift 코드 전체에 대한 증명은 아닙니다.
