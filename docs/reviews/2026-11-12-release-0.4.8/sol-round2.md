**차단 결함 1건이 남아 있어요.** 정적 코드 검토로 확인했으며 재현 테스트는 실행하지 않았어요.

1. **[P1] Docker 작업 취소가 진행 중인 HTTP 스레드의 fd를 닫아 다른 연결을 침범할 수 있어요.**

   위치: [Docker.swift:416](../../../Sources/DMXCore/Daemon/Docker.swift:416), [Docker.swift:428](../../../Sources/DMXCore/Daemon/Docker.swift:428). 해당 fd를 사용하는 경로는 [Docker.swift:528](../../../Sources/DMXCore/Daemon/Docker.swift:528), [Docker.swift:544](../../../Sources/DMXCore/Daemon/Docker.swift:544), [Docker.swift:569](../../../Sources/DMXCore/Daemon/Docker.swift:569)예요.

   **실패 순서:** 목록 조회 또는 이벤트 스레드가 `readSocket(fd, …)`의 `poll`에서 기다리거나 다음 I/O 전에 멈춰 있어요. 이때 VM 종료나 dockerd 연결 실패가 `resetListing()` / `dockerdStopped()`를 호출하면 `FrameConnection.close()`가 `shutdown`과 실제 `close`를 수행해요. 이후 새 연결이 같은 fd 번호를 받으면, 이전 HTTP 스레드의 다음 `read`·`write`가 새 연결에 적용돼요. 새 연결의 응답을 가로채거나 HTTP 요청 바이트를 잘못 전송하고, 종료됐어야 할 작업이 새 소켓에서 다시 대기할 수 있어요.

   **기존 방어가 부족한 이유:** `Task.cancel()`은 `Thread.detachNewThread`의 I/O를 중단하지 않아요. epoch·generation 검사는 HTTP 작업이 반환한 **뒤의 상태 반영**만 막아요. `DockerHTTP`는 raw fd를 사용하므로 `FrameConnection.withOpenFD`의 fd 수명 보호도 적용되지 않아요.

   **최소 수정:** 취소 시에는 소켓을 `shutdown`해 대기만 깨우고, HTTP 작업이 끝날 때까지 fd를 소유한 뒤 닫으세요. 또는 전체 HTTP 작업 동안 별도 fd lease를 유지하세요. 목록과 이벤트 경로 모두 필요해요.

   **회귀 테스트:** 격리된 자식 프로세스에서 HTTP 스레드를 `poll` 반환과 `read` 사이에 멈추고, 취소 후 `dup2`로 fd 재사용을 강제하세요. 이전 작업이 종료되고 새 소켓의 바이트를 읽거나 쓰지 않는지 검사해야 해요. 현재 주입형 목록 테스트는 실제 HTTP I/O를 우회해서 이 경쟁을 검출하지 못해요.

이전 지적의 UDP EAGAIN·분할 프레임 처리, EOF의 입력 크레딧 대기자 깨우기, legacy 누적 4096바이트 초과의 `guest_upgrade_required` 안전 실패, half-close의 유효 ACK 갱신·30분 만료, fresh 연결 이후 시계 샘플링은 현재 코드에서 확인했어요. Docker의 재시도·세대 폐기는 추가됐지만 위 fd 수명 문제가 남아요.

검토 범위는 `9852647`부터 `08f09f5` 및 현재 작업 트리의 변경된 production Swift/Rust/shell과 주변 호출 경로예요. PID·PTY, boot/shutdown deadline, teardown 잠금·RAM 수명, ENOSPC 대기·취소·요청 처리, UDP, Docker, NAT·keepalive, 초기화·vCPU 실패 정리와 새 릴리스 회귀 스크립트를 확인했어요. 계약 문서와 원래 17개 finding, 두 이전 리뷰도 대조했어요. 그 밖에 확정할 추가 결함은 찾지 못했어요.

수정·빌드·테스트 실행·VM 조작·커밋·push·릴리스·외부 메시지·다른 리뷰어 호출은 하지 않았어요. 모델은 Codex(GPT-6 기반)이며 정확한 런타임 모델 ID는 노출되지 않았어요.

**RELEASE BLOCKED**
