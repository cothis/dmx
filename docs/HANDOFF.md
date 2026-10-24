# 다음 세션 인계 — 2026-10-25

`이어서 진행해`라는 요청을 받으면 [PLAN.md](PLAN.md)의 **Next up**과 이 문서를 읽고,
아래 Redis 재현부터 시작해요. 별도 대화 이력이나 `/tmp` 파일은 필요하지 않아요.
계획·결정의 기준은 계속 `PLAN.md`이며, 이 문서는 바로 실행할 수 있는 인계 자료예요.

## 시작 상태와 작업 규칙

- 마지막 기능 구현·검증 커밋은 **`95432bd`**예요. `main`에 커밋하고 `origin/main`까지
  푸시했어요. 이후에는 이 인계 문서의 커밋이 추가돼요. 새 세션에서는 현재 상태를 다시 확인해요.
- 기존 체크아웃 `/Users/cothis/dockermax`의 **`main`에서 직접 작업**해요. 브랜치나 worktree를
  만들지 않아요. 작업 전 브랜치·미커밋 변경을 확인하고 기존 변경을 보존해요.
  다른 브랜치라면 안전하게 전환할 수 있을 때만 main으로 이동해요. 전환이 막히면 보고하고,
  새 브랜치나 worktree로 우회하지 않아요.
- 원격 main은 fast-forward로 동기화해요. 분기되거나 push가 거절되면 force push, reset,
  자동 merge/rebase로 해결하지 말고 상태를 보고해요. 같은 체크아웃의 동시 편집을 피해요.
- 검증한 요청 범위와 PLAN 갱신을 함께 커밋하고 `git push origin main`까지 진행해요.
  PR 생성이나 재확인은 기본 절차가 아니에요. 저장소 로컬 Git 신원도 바꾸지 않아요.
- 로직은 `Sources/DMXCore`, CLI는 인자 처리와 출력이에요. 메모리 절약은 항상 기본 동작이에요.
  게스트 입력은 sha256 고정을 유지하고, `~/.dmx`의 커널·initramfs·캐시를 커밋하지 않아요.

```sh
cd /Users/cothis/dockermax
git status --short --branch
git branch --show-current
git log --oneline -10
# main과 기존 변경의 안전성을 확인한 뒤 실행해요.
git pull --ff-only origin main
```

## 이번에 완료한 내용

### 이미지 호환성과 4K 기본 커널

- 공식 이미지 9개 × arm64/amd64의 실제 작업을 검증하는 `make imagetest`를 추가했어요.
  입력은 [image-matrix.json](../scripts/image-matrix.json)의 플랫폼별 digest로 고정돼요.
  보통 재현에서는 `--pin`을 실행하지 않아요. 현재 실패를 다른 이미지로 바꿔 숨기면 안 돼요.
- 이전 16K 커널에서 15/18, 4K 커널에서 **17/18**을 통과했어요. native arm64는 9/9예요.
  Python의 `libpython3.14.so.1.0` 매핑과 Java의 부분 `msync` 실패는 4K에서 해결됐어요.
- 기본 커널은 **`6.18.58-dmx-4k`**예요. 16K로 되돌려 Redis를 해결하려 하지 않아요.
  Redis 실패는 4K에서도 재현되는 별도 문제예요.
- `make x86test`는 4K `MAP_SHARED`, `MAP_FIXED|MAP_SHARED`, `mincore`, 부분 `munmap`,
  `msync`, guard-page fault, `MADV_DONTNEED` zeroing을 실제로 요구해요. 예전처럼
  16K 제약을 관찰한 것만으로 성공 처리하지 않아요. 현재 열 가지 probe가 모두 true예요.

### 4K 메모리 회수가 느렸던 두 원인과 수정

1. **데이터 페이지:** Linux의 reporting 예산이 자유 목록의 1/16이고 다음 작업은 2초 뒤여서,
   작은 buddy 블록을 쓰는 4K 커널에서는 여러 차례 대기했어요. `scripts/build-kernel.py`가
   `mm/page_reporting.c`를 수정해 초기 목록 길이 안에서 한 번에 처리하도록 했어요.
   무제한 루프가 아니며, 원래의 2초 scheduling delay 자체는 유지해요.
2. **남은 RAM과 memmap:** 4K는 memmap 비용이 커요. 데이터가 돌아와도 정상 상태의
   30초 unplug 지연과 10초 quiet polling 때문에 기본 8G 상한에서는 잔여 footprint가
   10초 목표를 넘었어요. `MemoryPlugPolicy`의 surplus 대기를 **5초**, 그 대기 중 polling을
   **최대 1초**로 바꿨어요. 이미 unplug가 진행 중이면 countdown을 계속 새로 만들지 않아요.

호스트는 Image 헤더에서 Linux page size를 읽어요. busy reporting은 512 KiB
(4K에서 order 7), idle reporting은 호스트 한 페이지를 덮는 크기
(16K Mac + 4K Linux에서 order 2)로 유지해요. 부분적으로 사용 중인 호스트 페이지를
반납하지 않아요. `dmx status --json`의 `memory.guest_page_size`도 추가했어요.

| 실제 VM 측정 | 결과 |
|---|---|
| 같은 2CPU/4G 조건, 4K의 1 GiB 회수 | 수정 전 8.29–10.00초 → 수정 후 0.317–2.114초, 각각 3회 |
| 같은 조건의 유휴 footprint | 16K 64–66 MiB, 4K 77–78 MiB |
| 현재 기본 10CPU/8G 유휴 selftest | 약 89–90 MiB, 목표 150 MiB 아래 |
| 기본 10CPU/8G에서 2 GiB 컨테이너 사용 후 | 수정 전 10.08초에도 baseline +78.86 MiB; 수정 후 **6.14초**에 baseline보다 낮아짐 |
| 2CPU/4G에서 같은 2 GiB 작업 | **1.50초**에 baseline +64 MiB 이내 |
| daemon의 별도 정상 상태 unplug 검증 | **7.0초** 안에 RAM과 footprint 복귀 |

이 수치는 실제 Hypervisor.framework VM의 `ri_phys_footprint`예요. RSS나 `footprint` 명령으로
대체하지 않아요. 2 GiB 검증은 VM 종료나 호스트 pressure 강제 없이 정상 상태에서 했어요.

### 검증 범위

- 실제 VM: selftest **21/21**, daemon **41/41**, Docker **57/57**, MCP **30/30**,
  sandbox **41/41**, x86 **13/13**이에요. unit tests는 **33/33**이에요.
- 정상 unplug deadline을 daemon 검증에 추가했고, critical 검증은 balloon의 중간 상태만 보고
  실패하지 않도록 같은 deadline 안에서 balloon과 footprint 두 조건을 모두 기다려요.
- 5초 정책 변경 뒤 daemon·Docker를 다시 통과했고, 마지막 `make build && make guest && make selftest`
  도 통과했어요. 이미지 검증의 게스트 로그에는 module verification failure, BUG, soft lockup이 없었어요.
- **이미지 전체 검증은 17/18 실패 하나가 남은 상태**예요. `make imagetest`의 현재 exit 1은
  아래 Redis 문제 때문이에요. 이를 전체 성공이나 18/18로 보고하면 안 돼요.
- 로컬 빌드·게스트 생성·main push까지 했어요. 이번 작업에서 `make install`이나 공개 릴리스는
  하지 않았어요. 설치된 CLI/daemon이 최신 빌드라고 가정하지 말고 필요할 때 별도로 확인해요.

## 바로 할 작업: amd64 Redis 기본 실행 수정

### 확인된 현상

- 고정된 `redis:8-alpine` amd64 이미지에서 기본 QEMU layout의 `redis-cli`가 SIGSEGV로
  끝나요. native Redis는 정상이에요. 현재 QEMU는 Alpine의 고정된 **11.0.3** 바이너리예요.
- strace에서 높은 `0x0000ffff...` 매핑 뒤 `0xffffffff...` 주소를 사용하는 흔적이 있어요.
  주소 배치/allocator 상호작용이 유력하지만, 정확한 원인은 더 확인해야 해요.
- **`QEMU_GUEST_BASE=0x800000000000`**을 지정하면 동일 digest에서 SET/GET,
  BGSAVE 완료, AOF 및 재시작 후 데이터 보존까지 통과해요. `run`뿐 아니라 `exec`로 시작하는
  프로세스에도 설정이 필요해요. 테스트 도구의 진단 옵션이 두 경로에 모두 넣어요.
- 이 우회는 기본 구현에 적용돼 있지 않아요. [관련 Nix upstream 보고](https://github.com/NixOS/nix/issues/16184)와
  비슷한 증상이지만 Redis의 원인이 같다고 확정하지 않았어요.

### 처음 실행할 명령

커널 캐시가 없다면 `make guest`가 알려주는 대로 먼저 `make kernel`을 실행해요.
지난 로컬 빌드에서는 약 7–12분 걸렸지만 부하에 따라 달라져요. bootstrap용 stock Alpine
커널을 기본 게스트 대신 사용하지 않아요. 최근 커널 캐시/빌드는 영구적인 보장이 아니에요.

```sh
make build
make guest

# 기본 실행: 현재는 Redis 실패와 exit 1을 예상해요. readiness 때문에 약 90초 걸릴 수 있어요.
python3 -B -I scripts/test-images.py --state-dir /tmp/dmx-redis-resume \
  --image redis --platform linux/amd64 > .build/redis-default.json

# 동일 상태/이미지로 우회 재현: 현재는 성공해요. 기본 결과와 파일을 분리해요.
python3 -B -I scripts/test-images.py --state-dir /tmp/dmx-redis-resume \
  --image redis --platform linux/amd64 --qemu-guest-base 0x800000000000 \
  > .build/redis-workaround.json
```

`--state-dir`는 자체 marker가 있는 전용 디렉터리를 재사용하며, 이미지 다운로드를 줄여줘요.
`~/.dmx`나 다른 프로그램의 상태 디렉터리를 여기에 지정하지 않아요. `-B`는 진단용 Python
import가 저장소에 `__pycache__`를 남기지 않게 해줘요. 이전 세션의 임시 이미지 상태와
실험 helper는 정리했으므로 의존하지 않아요. 보존할 결과는 `docs/measurements`에 있어요.

### 조사·수정 순서와 완료 기준

1. 위 두 결과를 읽고 기본 실행/우회의 차이를 다시 확인해요. QEMU strace와 allocator의
   주소 계산을 좁혀 QEMU의 guest base/mmap 배치 쪽을 조사해요.
2. 이미 해 본 진단을 무작정 반복하지 않아요: `QEMU_RESERVED_VA`를 47/45-bit 크기로 지정하면
   `Cannot allocate vsyscall page`였어요. `QEMU_CPU=max,la57=off`는 해결하지 못했고,
   작은 guest base `0x100000000000`, `0x4000000000`도 진단 timeout이었어요.
3. 이미지별 환경변수 삽입으로만 결과를 녹색으로 만들지 않아요. 일반적인 기본 수정이 필요해요.
   QEMU/인터프리터를 바꾼다면 run, exec, fork 및 컨테이너 안에 QEMU 파일이 없는 chroot 경로를
   유지해요. 다른 allocator도 고정된 입력으로 검증해요. 새 소스·도구가 필요하면 sha256과
   빌드 provenance를 추가하고, 수정한 GPL 구성 요소의 source notices/recipe도 갱신해요.
4. **`--qemu-guest-base` 없이 Redis가 통과하고 전체 matrix가 18/18**이어야 기본 문제가 해결된
   것으로 보고해요. workaround 성공과 기본 성공은 계속 구분해요.
5. 메모리나 QEMU가 바뀌면 전후 host footprint를 측정하고 아래 게이트를 실행해요. 비교 측정과
   여러 VM workload를 동시에 돌리지 않아요. 문제를 피하려고 16K로 되돌리거나 메모리 절약을
   opt-in으로 바꾸지 않아요.

```sh
make build && make guest && make selftest
make daemontest
make x86test
make dockertest
make mcptest
make sandboxtest
swift test
make imagetest
python3 -B -I scripts/benchmark.py > .build/benchmark-4g.json
python3 -B -I scripts/benchmark.py --cpus 10 --ceiling-gb 8 > .build/benchmark-8g.json
```

CPU 수는 현재 호스트에 맞춰요. 위 10CPU는 검증한 Mac의 값이에요. 완료 후 PLAN의 checkbox,
**Next up**, **Findings and measurements**, 날짜별 **Progress log**를 같은 커밋에 갱신해요.
이 HANDOFF의 시작점·검증 결과도 갱신하거나, 새 인계 문서를 만들고 PLAN의 링크를 교체해요.

## 이후 남은 작업과 경계

- **엔진 비교:** 2026-10-25 확인 당시 Docker Desktop·OrbStack·Colima/Lima가 설치되어 있지
  않았어요. 현재 상태는 다시 확인해요. [benchmark.md](benchmark.md)의 동일 설정과 실제 VM/helper
  PID attribution으로 조용한 Mac에서 반복·교차 측정해야 해요. 도구는 준비했지만 다른 엔진
  경로는 검증하지 못했어요. 기존 dmx 측정은 단일 엔진의 로컬 자료이며 비교 완료가 아니에요.
- **공개 릴리스:** 마지막 확인에서는 GitHub Release가 없었어요. 버전/태그(`v0.1.0`은 가정),
  GPL 소스 첨부 대 written offer, Developer ID 서명·공증은 maintainer 결정/준비가 남았어요.
  계정이나 인증서가 없다고 확인한 것은 아니에요. 공개 단계 전에 [release.md](release.md)를 읽어요.
  커널은 이제 수정된 소스이므로 `release.py`가 recipe와 패치가 담긴 `.build.py`를 함께 내보내고,
  기존의 "unmodified kernel" 설명을 제거했어요. 소스 제공 방식이 확정됐다는 뜻은 아니에요.
- **지속 결정:** GitHub CI와 Homebrew 의존성은 추가하지 않아요. Docker CLI·Compose·Buildx는
  dmx가 제공하는 고정된 도구를 사용해요. 예전 고부하 soft lockup은 재현되지 않았으며 열린
  관찰 사항이에요. 재발하면 로그와 부하를 기록하고 조사해요.
- **별도 backlog:** Phase 8 자체 런타임은 미착수예요. Phase 6의 fsck/디스크 확장,
  IPv6/ICMP errors/split DNS, 공유 파일의 Unix socket/xattrs/ACL/DAX/소유권도 남아 있어요.
  완료된 acceptance suite가 전체 backlog 완료를 뜻하지 않아요.

## 근거와 코드 위치

| 위치 | 용도 |
|---|---|
| [compatibility.md](compatibility.md), [measurements/](measurements/) | 16K/4K 대조, 최종 17/18, 우회, 메모리 전후 원자료 |
| [test-images.py](../scripts/test-images.py), [image-matrix.json](../scripts/image-matrix.json) | digest 고정과 실제 이미지 작업, 명시적 우회 모드 |
| [guest/init](../guest/init), [build-guest.py](../scripts/build-guest.py) | QEMU unpack·binfmt 등록, 고정된 패키지와 docker.img 구성 |
| [build-kernel.py](../scripts/build-kernel.py) | 4K 설정, reporting budget 패치와 입력 sha256 |
| [Machine.swift](../Sources/DMXCore/HV/Machine.swift) | Image page-size flags, busy reporting order, host page release |
| [MemoryPlugPolicy.swift](../Sources/DMXCore/HV/MemoryPlugPolicy.swift) | 성장률 headroom, 정상 5초 unplug, 대기 중 polling |
| [MemoryController.swift](../Sources/DMXCore/Daemon/MemoryController.swift) | pressure, idle sweep, page-size별 reporting |
| [test-daemon.py](../scripts/test-daemon.py), [test-x86.py](../scripts/test-x86.py) | 정상/critical 회수 deadline, 실제 4K syscall 검증 |
| [benchmark.py](../scripts/benchmark.py) | ri_phys_footprint 및 Mach timebase/getrusage 교차 확인 |
| [release.py](../scripts/release.py) | 수정 커널 source notices, recipe와 릴리스 구성 |
