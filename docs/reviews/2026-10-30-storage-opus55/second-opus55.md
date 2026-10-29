# 재리뷰 (second-source / second.diff)

**결론: Request changes (경미).** 지난번 차단 결함 F1·F2는 구현상 해결됐습니다. 다만 F1·F2 수정이 맞물려 생긴 Low 경쟁 상태 1건(R1)과 문서/힌트 불일치 1건(R2)이 남았습니다. 둘 다 진단 로그에만 영향을 주는 작은 수정입니다. 이 두 건을 고치고 아직 실행 전인 F2 VM 케이스가 통과하면 승인할 수 있습니다. 저는 읽기만 했고 아무것도 실행하지 않았습니다.

---

## 남은 결함

### R1. [Low–Medium · product] dockerd 크래시 직후 재시작하면 새 dockerd의 로그가 수명 내내 꺼질 수 있음
- **코드:** `guest/agent/src/docker.rs:109-110`(reaper가 `child.wait()` 후 `finish()`), `:80-86`(로그 생성 실패 시 `None`으로 대체), `guest/agent/src/rotating_log.rs:23`(`LOCK_NB`)
- **실패 순서:**
  1. 실행 중인 dockerd가 크래시합니다.
  2. reaper 스레드의 `child.wait()`가 반환되고 `finish()`가 시작됩니다. 이때 collector 스레드는 아직 깨어나 FIONREAD 분량을 비우는 중이라 flock을 쥐고 있습니다.
  3. 같은 순간 재시도 중인 Docker 클라이언트 요청으로 `docker_start`가 들어옵니다. `answers()`가 false이므로 `RotatingLog::new`가 실행되고, flock이 EWOULDBLOCK으로 실패합니다.
  4. F2 대체 경로 때문에 `log = None`이 되고 새 dockerd가 정상 시작됩니다. 그러나 이 dockerd의 진단 출력은 VM을 재시작할 때까지 모두 버려집니다. 경고는 guest console에만 남고 `dmx status`에는 나오지 않습니다.
- 창은 ms 단위로 짧습니다. 하지만 이는 악의적인 파일시스템 경쟁이 아니라 정상 경로의 타이밍 경쟁입니다. `dockerd_restart_after_crash` 뒤의 `dockerd_flood_tail` 검사가 이 경우를 우연히 잡을 수는 있지만 결정적으로 재현하지는 못합니다.
- **수정안:** 이전 collector의 `finish()`는 FIONREAD(파이프 용량 이하)만큼만 비우므로 유한 시간에 끝납니다. 따라서 둘 중 하나면 충분합니다.
  - `start()`가 이전 reaper의 완료 신호(예: static `Mutex<Option<Receiver<()>>>`)를 제한 시간을 두고 기다리게 합니다.
  - 또는 flock을 짧게(예: 1–2초) 재시도합니다.
- 무기한 blocking flock은 쓰면 안 됩니다. 살아 있지만 응답하지 않는 dockerd의 collector가 잠금을 쥐고 있으면 static `LOCK`을 쥔 채 영원히 멈춥니다.

### R2. [Low · docs/hint] "`dmx stop` 후 `dmx start`면 sink가 다시 만들어진다"는 안내가 사실이 아님
- **코드:** `docs/docker.md:200`, `Sources/DMXCore/Daemon/Daemon.swift:69`, `RotatingLog.swift`의 `error()` 힌트("then run `dmx start`")
- **원인:** sink는 `Daemon.init`(`Daemon.swift:74-76`)에서 한 번만 만들어집니다. `boot()`는 다시 시도하지 않습니다.
- **실패 순서:** 사용자가 권한을 고친 뒤 안내대로 곧바로 `dmx stop` → `dmx start`를 실행합니다. 데몬이 10초 linger 중이거나, `dmx port` forward가 있거나(`ports.isEmpty == false`), 메뉴 앱 같은 클라이언트가 연결돼 있으면 같은 데몬 프로세스가 계속 응답합니다. 그 결과 sink는 여전히 꺼져 있고 `log_warnings`도 그대로 남습니다. CLI에는 `dmx quit` 같은 명령도 없습니다.
- **수정안:** 둘 중 하나를 권합니다.
  - `boot()`에서 `consoleLog`나 daemon sink가 `nil`이면 다시 생성을 시도하고 `logWarnings`를 갱신합니다. 부팅마다 한 번이라 idle 비용이 없습니다.
  - 또는 문서와 힌트를 "데몬이 끝날 때까지(`dmx status`가 not_running이 될 때까지) 기다린 뒤"로 고칩니다.

---

## 확인 결과 올바른 부분 (조건별)

**F1 (collector 수명)**
- `poll(-1)`을 쓰므로 주기 타이머나 바쁜 루프가 없습니다(`docker.rs:139-191`).
- cancel 소켓을 drop하면 POLLHUP이 오고, 이는 `events`에 넣지 않아도 항상 보고됩니다.
- 비우는 양은 그 시점 FIONREAD로 정해지며 `min(…, LIMIT)`이고, 실제로는 파이프 용량 이하입니다. 살아 있는 자손이 이 양을 늘릴 수 없습니다.
- 캡처된 `log`(flock)는 스레드 클로저가 끝날 때 drop됩니다. 그래서 `join()`이 반환되면 잠금은 이미 풀려 있습니다.
- 실패 경로(`:116`)와 타임아웃 경로(`:120-123`)는 반환하기 전에 `finish()`를 마칩니다. 따라서 상속된 파이프가 남아 있어도 재시도할 수 있습니다.
- `OutputCollector::start`가 실패하면 자식 프로세스를 kill하고 reap합니다.
- 메모리는 8 KiB 버퍼와 8 KiB tail로 고정이고, `drain(..excess)`는 panic하지 않습니다.

**F2 (기동 실패 대체)**
- host는 sink마다 best-effort로 생성하고 경고를 status JSON과 평문 출력에 모두 노출합니다.
- trim 중 `ftruncate` 이후 쓰기가 실패해도 파일은 한도 이내로 남고 데몬은 시작됩니다.
- FIFO는 `O_NONBLOCK` 덕분에 멈추지 않고 거부됩니다. symlink·hardlink 대상은 수정하지 않습니다.
- `detachLegacyLog`가 이제 `stat`(링크를 따라감)을 써서, 예전 plist가 symlink를 따라 연 fd도 분리합니다.
- guest는 로그 생성에 실패해도 출력을 계속 비우고 tail을 유지합니다.

**디스크·FD**
- 회전 산술은 한도 ×3 이내입니다.
- 부분 쓰기 뒤에는 reopen이 `fstat`으로 크기를 다시 맞춥니다.
- 실패한 경로에서 이중 close나 fd 누수가 없습니다. Rust 쪽은 `new()`가 실패하면 lock `File`이 drop되어 잠금이 풀립니다.

**호환성**
- `25m` 예시는 유효합니다. 명시적인 드라이버와 옵션을 그대로 보존하고, 새 컨테이너에만 적용됩니다.
- `log_warnings`는 optional 필드로 추가됐습니다. 이전 클라이언트와 이전 데몬 양쪽 모두 하위 호환됩니다.

**테스트 (지난 조건 기준)**

| 지난 조건 | 결과 |
|---|---|
| 1. 위치 의존 패턴 | 충족 |
| 4. 쓰기·회전 실패 후 복구 (Swift, Rust) | 충족 |
| 5. cargo harness 기본 빌드·실행 (storagetest, release checklist) | 충족 |
| 7. lsof로 fd 1/2가 `/dev/null`인지 확인 | 충족 |
| F1 시나리오 | 충족: 상속 stderr Rust 단위 테스트, 실제 실패 스크립트 재시도, 실제 dockerd 크래시 재시작 |

그 밖에 비정렬 동시 기록 테스트, reopen 시 전체 내용 비교, 회전 중 `FileNotFoundError` 허용, 부팅 마커 기준 현재 부팅 console 검사도 모두 적절합니다.

---

## 비차단 메모
- **알려진 제약으로 문서화 권장 (미확인):** 크래시 후 새 dockerd가 살아남은 기존 containerd를 pidfile로 재사용한다면, 그 containerd의 stderr는 이미 닫힌 옛 파이프입니다. 그러면 containerd 진단 출력은 VM 재시작 전까지 유실됩니다. F3와 같은 범주이며, 제 기억에 의존한 부분이라 확인이 필요합니다.
- **선택 사항:** `unsafe_guest_log_still_starts_docker` 검사에서 console에 `diagnostic logging disabled` 경고가 찍혔는지도 확인하면 문서 내용과 맞출 수 있습니다.
- 지난번에 적은 `"log-opts": null` 거부는 그대로이며 비차단입니다.
- 같은 사용자의 악의적 파일시스템 경쟁(예: `stat`과 `open` 사이 TOCTOU, 로그 디렉터리 rename 경쟁)은 요청하신 대로 결함에서 제외했습니다.

## 릴리스 조건
1. R1 수정. 제한 시간 대기 또는 짧은 flock 재시도로 충분합니다.
2. R2 수정. 부팅 시 재생성 또는 문서·힌트 정정입니다.
3. 아직 실행 전인 F2 VM 케이스 4개가 실제 VM에서 통과: `unwritable_*`, `unsafe_host_*`, `unsafe_guest_log_*`, `unsafe_log_target_unchanged`

R1·R2 수정 범위가 위 설명대로라면 전체 재리뷰 없이 해당 diff만 확인하면 됩니다.
