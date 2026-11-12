**차단 결함 1건이 남아 있어요.** 정적 코드 검토로 확인했으며 재현 테스트는 실행하지 않았어요.

1. **[P1] MCP exec 취소가 재사용된 fd의 다른 연결을 종료할 수 있어요.**

   위치: [CappedExec.swift:183](../../../Sources/DMXCore/MCP/CappedExec.swift:183), 새 종료 경로는 [Agent.swift:318](../../../Sources/DMXCore/Agent.swift:318)예요.

   **실패 순서:** MCP exec가 `exit` 없는 EOF를 받으면 `nextEvent()`가 연결을 닫아 fd를 반환해요. `ExecKiller.finish()`가 실행되기 전에 다른 동시 작업이 같은 fd 번호를 할당받고, 타임아웃이나 작업 취소가 `ExecKiller.kill()`을 실행하면 이전 번호에 `shutdown(SHUT_RDWR)`을 호출해요. 따라서 관계없는 MCP 작업의 소켓이 종료될 수 있어요. legacy stdin 초과로 feeder가 연결을 닫는 경로에서도 같은 경쟁이 가능해요.

   **기존 방어가 부족한 이유:** `ExecKiller`의 `done`과 잠금은 자체 `kill`·`finish`만 직렬화해요. 새 EOF·입력 오류 경로의 `FrameConnection.close()`는 별도의 `closeLock`을 사용하므로, 연결이 닫혀도 `done`은 여전히 false일 수 있어요. Docker에 추가된 FD lease는 이 호출부를 보호하지 않아요.

   **최소 수정·검사:** raw fd의 `shutdown` 대신 `session.connection.close()`를 호출해 연결의 닫힘 검사와 수명 잠금을 공유하세요. 격리된 자식 프로세스에서 EOF 정리 후 `finish()` 전에 멈추고, `dup2`로 fd 재사용을 강제한 다음 취소를 실행해 새 연결이 양방향 통신을 유지하는지 검사하면 돼요. 현재 EOF 회귀 검사는 입력 작업의 깨어남만 확인하고, `DockerFDProbe`는 Docker 경로만 검사해요.

이전 지적의 Docker HTTP lease, `AgentClient.run` 조기 종료 처리, 부팅 시계 동기화 15초 제한과 `runInGuest` shutdown 실패 시 fallback은 코드상 확인했어요.

검토 범위는 `9852647`부터 HEAD `08f09f5` 및 현재 작업 트리의 변경된 production Swift/Rust/shell과 주변 호출부예요. 계약 문서·원래 17개 finding·round1/round2 보고서, stdin/EOF·PID/PTY·boot/shutdown·teardown 잠금과 RAM 수명·ENOSPC·UDP·Docker 세대/재시도·NAT/keepalive·초기화/vCPU 실패 정리 및 새 릴리스 회귀 코드를 확인했어요. `0.4.8` 패키징 시 `GuestPin`을 생성하는 기존 게이트도 그대로 필요해요.

수정·빌드·테스트·VM 조작·커밋·push·릴리스·외부 메시지·리뷰어 호출은 하지 않았어요. 모델은 Codex(GPT-6 기반)이며 정확한 런타임 모델 ID는 노출되지 않았어요.

**RELEASE BLOCKED**
