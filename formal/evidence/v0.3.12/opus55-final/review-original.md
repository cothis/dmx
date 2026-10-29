## 판정: v0.3.12 릴리스 진행을 권합니다

이전 리뷰의 F1, F2와 M1~M4가 최종 소스와 새 증거 기준으로 모두 해결됐습니다. 새로 발견한 런타임 결함이나 거짓 검증 주장은 없습니다. 지적사항을 채우려고 억지로 만든 항목도 없습니다.

## 이전 지적 재검증

| 항목 | 상태 | 근거 |
|---|---|---|
| **F1** daemon 메시지에 method 접두어 중복 | **해결** | `Agent.swift:206`에서 이제 agent peer일 때만 접두어를 붙입니다. `FrameConnectionTests.swift:161-183`이 code, message, hint를 모두 확인합니다. 예전 코드라면 message가 `"exec: exec: original message"`가 되어 이 테스트가 실패합니다. |
| **F2** 서버 reply 실패 후 클라이언트 무한 대기 | **해결** | 흐름은 이렇습니다.<br>1. `Agent.swift:259-267`의 `send`가 실패하면 `close()`합니다.<br>2. `Daemon.swift:184`의 `try? send(DaemonFailure)`는 닫힌 연결이라 바로 실패합니다.<br>3. `:138`의 `receive()`가 throw해서 `serve`가 return합니다.<br>4. 클라이언트는 EOF를 받습니다.<br>실제 daemon 증거도 이 흐름과 맞습니다. before 로그에는 fault 주입이 2회(send와 `try? send`)이고 결과는 stalled입니다. after 로그에는 1회이고 결과는 closed입니다. 두 번째 send가 closed 검사에서 끝났기 때문입니다. 단위 테스트는 `:185-190`입니다. |
| **M1** retire 범위 축소 mutation | **해결** | `:192-212`가 stdout kind 프레임, 깨진 JSON, length 0 세 경우 모두 `isClosed`와 이후 호출 거부를 확인합니다. retire를 ID 불일치로만 줄이면 세 경우가 모두 실패합니다. |
| **M2** lease 대상 descriptor 미보호 | **해결** | `:214-234`가 다른 socketpair로 binding을 바꿔 확인하고, 파괴적인 FD 재사용은 하지 않습니다. 원래 `raw-binding` 로그에서는 테스트 8개가 모두 통과했습니다. `raw-binding-final`에서는 이 테스트만 assertion 4개로 실패하고, gated probe도 `:38` precondition에서 실패합니다. 확인 내용은 다음과 같습니다.<br>- gate는 두 번째 poll, 즉 body 읽기에서 멈춥니다(`gate-poll.c:9`). 정상 코드에서는 copy가 shutdown된 소켓을 가리키므로 EOF가 나고, mutant에서는 victim 소켓의 body를 읽습니다. 판별력이 있습니다.<br>- `check-code.py:14`가 이제 `swift build`를 실행합니다.<br>- `formaltest`는 `Makefile:86-88`에 연결돼 있습니다. |
| **M3** frame 모델 | **해결** | `MC_guard_harm`은 `NoForeignIO`만 검사하며, Close → Reuse → Acquire → Transfer 순서로 깊이 6에서 위반이 나옵니다. `MC_atomic`은 guard를 켠 상태에서 `CheckOnly`, Close, Reuse, `DuplicateAfterCheck` 순서로 깊이 7에서 위반이 나옵니다. 따라서 guard 제거와 원자성 깨짐을 독립적으로 구분합니다. |
| **M4** RPC 모델의 NoReplay가 위반 불가 | **해결** | `Replay` 상수를 추가했고(`Spec.tla:51-53`), `sent ∈ 0..2`로 넓혔습니다(`:63`). `MC_replay`가 TypeOK를 통과한 뒤 `NoReplay`를 깊이 7에서 위반하는 것을 확인했습니다. |

## 추가된 retirement의 부작용 확인

- **aligned 애플리케이션 오류:** 영향이 없습니다.
  - 클라이언트 쪽에서는 ID가 일치하는 `ok:false` 응답이 `do/catch` 밖(`:203-208`)에서 처리되므로 retire하지 않습니다.
  - daemon 쪽에서는 `add()`, `running()` 같은 핸들러 오류가 `send` 전에 throw됩니다. 그 뒤 정상적인 `DaemonFailure`가 전송되므로 연결이 유지됩니다.
- **교착:** 생기지 않습니다.
  - `close()`는 closeLock만 잡고, shutdown과 close 시스템 호출은 블로킹되지 않습니다.
  - `send`와 `reply`에서 `close()`를 부르는 시점에는 closeLock(`:172`에서 이미 해제)도 writeLock(defer로 해제)도 잡혀 있지 않습니다.
  - exec 경로(`Daemon.swift:200`)에서 send가 실패해도 serve의 catch, 이어서 receive 실패를 거쳐 정상적으로 return합니다.

## 남은 사항 (모두 선택 사항, 릴리스를 막지 않음)

1. **인코딩 실패만으로도 retire됨 (P3, 기존 동작, 현재는 발생 불가):** `send`(`:260`)와 `reply`(`:195`)에서는 인코딩이 retire 범위 안에 있습니다. 그래서 바이트를 하나도 쓰기 전의 인코딩 실패도 연결 종료로 이어집니다. 다만 daemon 응답에서 Double은 반올림한 `uptimeS`뿐이라 NaN이 나올 수 없고, 실제 트리거는 없습니다.
2. **증거 출처 기록 공백 (문서):** `daemon-fault-before`의 바이너리 해시(`ccb816…`)는 `baseline-binary.sha256`(`31e6e5…`)과 다르고, 어느 소스 리비전으로 빌드했는지 기록이 없습니다. before/after 로그의 fault 횟수는 코드 추론과 일치하므로 거짓 주장은 아닙니다. 다만 해당 소스 상태를 함께 적어 두기를 권합니다.
3. **잡히지 않는 mutation (선택적 확장):** `reply()` 안에서만 `self.fd`를 직접 쓰는 mutation은 현재 테스트가 잡지 못합니다. 지금 binding mutant는 `withOpenFD`의 `body(copy)`만 바꿉니다.
4. **실행 디렉터리 의존:** `check-code.py:14`의 `swift build`는 `--package-path` 없이 현재 디렉터리에 의존합니다. Makefile에서 실행하면 문제가 없습니다.

## 범위와 한계

Read, Grep, Glob만 사용했습니다. 빌드, 테스트, TLC는 실행하지 않았습니다. 테스트, probe, 모델 결과는 기록된 로그를 읽고 코드와 대조해 판단했습니다. `results.json`의 입력 해시가 현재 파일과 일치하는지는 직접 계산하지 않았으므로, 태그 전에 `make formaltest`를 한 번 실행해서 확인하기를 권합니다.