코드에서 확인한 결함 4건이 남아 있어요. 모두 정적 검토 결과이며 재현 테스트는 실행하지 않았어요.

1. **[P1] UDP 응답이 없어도 데이터그램을 계속 만들어 전송해요.**
   위치: [UDPForward.swift:197](../../../Sources/DMXCore/Daemon/UDPForward.swift:197)

   `started()`가 스트림을 비차단으로 바꾼 뒤, 응답 스레드의 `readExactly()`는 `EAGAIN`을 성공으로 반환해요. 첫 요청에 아직 응답이 없으면 초기 버퍼의 `00 00`을 길이로 해석하여 빈 UDP 데이터그램을 반복 전송하고, `lastActive` 갱신 작업도 계속 쌓아요. 실제 응답 뒤에는 이전 버퍼 내용을 재사용할 수도 있어요. 헤더 일부만 읽고 `EAGAIN`이 나면 정상 연결을 종료해요.

   `offset == 0` 검사는 “읽은 데이터 없음”을 성공으로 바꾸므로 보호 장치가 되지 않아요. `poll`로 기다리면서 부분 프레임의 offset을 보존해야 해요. **무응답 동안 전송 없음**, **헤더와 payload를 나눠 도착시켜 정확히 한 번 전달**, **close 완료**를 검사하는 테스트가 필요해요.

2. **[P2] dockerd가 죽어도 목록 재시도가 계속되어 VM 유휴 종료를 막아요.**
   위치: [Docker.swift:418](../../../Sources/DMXCore/Daemon/Docker.swift:418), [Docker.swift:391](../../../Sources/DMXCore/Daemon/Docker.swift:391)

   목록 조회가 한 번 실패하면 `listingUnknown = true`가 되고 재시도가 시작돼요. 이후 dockerd가 종료되어 이벤트 감시자의 연결 probe도 실패하면, 감시자는 `up = false`, `containers = nil`만 설정하고 끝나요. 목록 작업은 같은 VM epoch에서 계속 실패하며 `listingUnknown`을 유지해요. 따라서 Docker 클라이언트와 컨테이너가 없어도 `busy`가 영구적으로 true예요.

   epoch 검사는 **VM 교체**만 감지하고 **같은 VM에서 dockerd 종료**는 감지하지 못해요. dockerd 부재를 확인하면 목록 작업을 취소하고 unknown 상태를 정리해야 해요. 목록 실패 → dockerd 부재 → 재시도 중단과 `busy == false` → Docker 재시작 후 재동기화 순서를 검사하면 돼요.

3. **[P2] `exit` 없는 연결 EOF가 stdin 크레딧 대기자를 깨우지 않아요.**
   위치: [Agent.swift:293](../../../Sources/DMXCore/Agent.swift:293), [Agent.swift:149](../../../Sources/DMXCore/Agent.swift:149), [Agent.swift:613](../../../Sources/DMXCore/Agent.swift:613)

   읽지 않는 자식에게 큰 입력을 보내 크레딧이 소진된 상태에서 게스트 에이전트나 VM이 종료되면, 이벤트 읽기는 EOF 오류로 끝나요. 그러나 `finishInput()`은 정상 `exit` 또는 명시적인 로컬 `close()`에서만 호출돼요. `AgentClient.run()`의 detached 입력 작업은 `input.wait()`에 남고, 자신이 session을 보유하므로 deinit을 통한 close도 발생하지 않아요. 프로세스가 계속 살아 있는 API 사용 환경에서는 작업·스레드·입력 버퍼가 남아요.

   소켓 EOF는 `NSCondition`을 깨우지 않으며 `Task.cancel()`도 이 대기를 중단하지 못해요. 이벤트 읽기의 모든 종결 오류에서 입력을 종료하고, `run()`에도 session 정리를 보장해야 해요. 크레딧 소진 후 `exit` 없이 peer를 닫아 입력 작업이 종료되는지 검사해야 해요.

4. **[P1] legacy backpressure 경로에서는 G1의 Ctrl-C 교착이 여전히 가능해요.**
   위치: [exec.rs:66](../../../guest/agent/src/exec.rs:66), [Agent.swift:324](../../../Sources/DMXCore/Agent.swift:324), [GuestStore.swift:137](../../../Sources/DMXCore/GuestStore.swift:137)

   `flow_control`이 없는 요청은 새 게스트에서도 큐가 가득 차면 연결 reader를 기다리게 해요. 읽지 않는 자식에게 충분히 큰 입력을 보내면 backpressure가 호스트까지 전파되고, stdin 쓰기가 `writeLock`을 잡은 채 막혀요. Ctrl-C 처리의 `session.signal()`도 같은 잠금을 기다려 CLI의 메인 큐가 막혀요. 새 호스트가 구버전 게스트로 폴백할 때도 같은 문제가 남아요. `GuestStore.ensure()`가 다운로드 실패 시 구버전 게스트 부팅을 허용하므로 실제 지원 경로예요.

   별도 hangup observer는 **연결이 닫혀야** 작동해요. Ctrl-C는 연결을 닫지 않고 막힌 잠금으로 신호를 보내므로 해결하지 못해요. 크레딧 없는 경로의 취소를 별도로 보장하거나, 보장할 수 없는 게스트에서는 실행 전에 명확한 호환성 오류를 반환해야 해요. 현재/legacy 요청 및 구버전 게스트 조합에서 큰 stdin과 SIGINT·disconnect를 각각 검사해야 해요.

검토 범위는 `9852647..08f09f5`의 변경된 production Swift/Rust/shell과 주변 호출 경로예요. stdin·EOF·PID/PTY 소유권, boot/shutdown deadline, 장치 teardown·잠금·RAM 수명, ENOSPC 재시도·취소·요청 처리, UDP, Docker retry/accept/epoch, NAT half-close·keepalive, 초기화·vCPU 실패 정리를 확인했어요. 기존 17개 disposition과 관련 테스트도 대조했으며, 나머지 항목에서 추가로 확정할 결함은 찾지 못했어요.

수정·테스트 실행·VM 조작·커밋·push·외부 메시지·다른 리뷰어 호출은 하지 않았어요. 검토 중 제가 수정하지 않은 `UDPBackpressureTests.swift` 변경이 나타났으며, 판정은 지정한 `08f09f5` 기준이에요. 모델은 Codex(GPT-6 기반)이며 정확한 런타임 모델 ID는 노출되지 않았어요.

**RELEASE BLOCKED**
