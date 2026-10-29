# R1/R2 집중 재리뷰 (third-source / third.diff)

**결론: Approve.** 단, 최종 릴리스는 말씀하신 대로 아직 진행 중인 실제 VM 결과(기존 F2 케이스 포함)가 통과해야 합니다. 저는 third.diff만 읽었고 아무것도 실행하지 않았습니다. 이번 변경에서 가용성·FD·잠금 회귀나 새 결함은 찾지 못했습니다.

---

## R1: flock 경합 시 제한 시간 재시도 → 조건 충족

**코드 (`guest/agent/src/rotating_log.rs:26-32`)**
- `LOCK_NB`가 `WouldBlock`(EAGAIN)으로 실패할 때만 5 ms 간격으로 최대 1초 재시도합니다. 다른 오류는 바로 반환합니다.
- 경합이 없으면 바로 통과하므로 idle 시 깨어남이 없습니다.

**잠금·FD**
- 실패해 반환하면 lock `File`이 drop되므로 fd 누수가 없습니다.
- `LOCK_NB`는 EINTR을 내지 않으므로 루프 조건이 완전합니다.
- 같은 프로세스 안이라도 서로 다른 open file description끼리는 flock이 충돌합니다(Linux). 그래서 이전 collector와 새 `new()`가 정확히 직렬화됩니다.

**가용성**
- 최악의 경우는 살아 있지만 응답하지 않는 dockerd의 collector가 잠금을 쥔 경우입니다. 이때 `docker.rs`의 static `LOCK`을 쥔 채 최대 1초를 더 기다린 뒤, 기존 F2 대체 경로(`None`)로 넘어갑니다. 무기한 대기가 아니므로 지난번에 우려한 교착은 없습니다.

**1초로 충분한지**
- 크래시 후 reaper의 `finish()`는 FIONREAD만큼만 비웁니다. 이는 파이프 용량(기본 64 KiB) 이하의 동기 page-cache 쓰기라 1초보다 훨씬 짧습니다.
- 디스크가 멈춰 1초를 넘기면 로그만 꺼지는 저하 모드가 되며, 이는 허용 범위입니다.

**테스트 (`rotating_log.rs:163-183`)**
- 소유자가 계속 잠금을 쥐면 1초 이상 3초 미만에 실패하는지 확인합니다.
- 80 ms 뒤 소유자가 풀리면 새 소유자가 쓴 내용이 정확히 남는지 확인합니다.
- `RotatingLog`는 `Send`라 스레드 이동에 문제가 없습니다. 디렉터리 이름 접두사가 다른 테스트와 겹치지 않아 병렬 실행에도 안전합니다.

---

## R2: 같은 데몬 안에서 부팅마다 비활성 sink 재시도 → 조건 충족

**코드**
- `Daemon.swift:62`에서 `DaemonLogs(paths:)`를 만들고, `:311`에서 `Machine` 생성 직전에 `retryDisabled()`를 부릅니다.
- `RotatingLog.swift:174-206`이 `DaemonLogs` 구현입니다.

**FD·소유권**
- `nil`인 sink만 다시 만들고, 정상 sink는 그대로 둡니다. 그래서 같은 경로에 `RotatingLog` 인스턴스가 둘 생기는 일이 없습니다.
- 재시도가 실패해도 `RotatingLog.init`의 기존 close 경로가 적용되어 부팅마다 fd가 새지 않습니다.

**동시성**
- `DaemonLogs`는 `@MainActor`이고, 호출 위치(`Daemon.init`과 boot `Task`)도 MainActor입니다.
- `Diagnostics.install`은 기존 잠금 아래에서 교체하므로, 다른 스레드의 `Diagnostics.write`와도 안전합니다.

**비용**
- 재시도는 sink가 꺼져 있을 때 부팅마다 한 번만 일어납니다. trim I/O는 최대 1 MiB×3이며 이전 init과 같은 수준입니다. idle 비용은 없습니다.

**경고·힌트·문서**
- 경고는 경로별로 관리되고, 해결되면 지워집니다.
- `RotatingLog.swift`의 힌트들과 `docs/docker.md:200-201`이 이제 실제 동작("다음 부팅에서 재시도")과 일치합니다.

**테스트 (`scripts/test-storage.py:165-177`)**
- 수동 클라이언트 소켓을 열어 두면 `clients`가 증가해 데몬이 계속 살아 있습니다. 이 상태에서 다음을 확인합니다.
  - 같은 PID가 유지되는지
  - `log_warnings`가 사라지는지
  - 부팅 마커가 실제로 기록되는지
- 이어서 guest의 `diagnostic logging disabled` 경고가 방금 복구된 console sink로 들어오는지도 확인합니다. 이로써 F2 guest 경고 경로까지 검증됩니다.
- `shutil.rmtree`로 바꾼 정리 단계는 데몬이 종료되기를 기다린 뒤에 실행되므로 안전합니다.

---

## 참고 (결함 아님)
- 저장소를 고친 뒤에도 VM이 정지 상태인 동안에는, 다음 부팅 전까지 `dmx status`에 이전 경고가 남습니다. 문서에 적힌 동작 그대로입니다.
- `containerd_before_crash`/`containerd_after_crash` 메트릭은 지난번 "미확인" 메모(살아남은 containerd가 옛 파이프를 쥐고 있는지)를 실제 증거로 확인해 줍니다. 문서에 이미 알려진 제약으로 반영되어 있습니다.

## 릴리스 조건 (남은 것)
1. 최신 소스로 guest를 다시 빌드한 뒤 `make storagetest` 전체가 통과해야 합니다. 여기에는 기존 F2 케이스와 이번에 추가된 `same_daemon_log_recovery`, `recovered_console_is_live`, `guest_disabled_sink_warning`, `contended_lock…`이 포함됩니다.
2. release checklist의 나머지 호환성 스위트가 통과해야 합니다.

이 결과가 나오면 코드에 대해서는 추가 리뷰 없이 릴리스해도 됩니다.
