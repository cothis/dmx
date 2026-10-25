# 다음 세션 인계 — 2026-10-25 (Redis 수정, 엔진 비교 후)

`이어서 진행해`라는 요청을 받으면 [PLAN.md](PLAN.md)의 **Next up**과 이 문서를 읽어요.
별도 대화 이력이나 `/tmp` 파일은 필요하지 않아요. 계획·결정의 기준은 계속 `PLAN.md`예요.

## 시작 상태와 작업 규칙

- 마지막 기능 구현·검증 커밋은 이 문서를 함께 갱신한 커밋이에요(`git log -1 -- docs/HANDOFF.md`).
  `main`에 커밋하고 `origin/main`까지 푸시했어요. 새 세션에서는 현재 상태를 다시 확인해요.
- 기존 체크아웃 `/Users/cothis/dockermax`의 **`main`에서 직접 작업**해요. 브랜치나 worktree를
  만들지 않아요. 작업 전 브랜치·미커밋 변경을 확인하고 기존 변경을 보존해요.
- 원격 main은 fast-forward로 동기화해요. 분기되거나 push가 거절되면 force push, reset,
  자동 merge/rebase로 해결하지 말고 상태를 보고해요.
- 로직은 `Sources/DMXCore`, CLI는 인자 처리와 출력이에요. 메모리 절약은 항상 기본 동작이에요.
  게스트 입력은 sha256 고정을 유지하고, `~/.dmx`의 커널·QEMU·initramfs·캐시를 커밋하지 않아요.

```sh
cd /Users/cothis/dockermax
git status --short --branch
git log --oneline -10
git pull --ff-only origin main
make build && make guest   # 캐시가 없으면 make kernel, make qemu를 먼저 실행해요
```

`make guest`는 `~/.dmx/cache/kernel-6.18.58-dmx-4k.tar`와
`~/.dmx/cache/qemu-x86_64-11.0.3-dmx1`이 필요해요. 없으면 각각 `make kernel`(약 7–12분),
`make qemu`(약 30초)를 실행해요. 둘 다 stock Alpine 커널로 부팅한 bootstrap VM에서 빌드해요.

## 이번에 완료한 내용: amd64 Redis 기본 실행 수정

- **원인:** QEMU 11.0.3 linux-user는 64비트 게스트에 `-R`이 없으면 `guest_addr_max = ~0`이라
  어떤 호스트 주소든 게스트에 줘요. 게스트 커널은 48비트 VA라서 hint가 막히면 2^48 바로 아래부터
  top-down으로 찾고, x86_64 프로그램은 x86-64 user space(2^47) 밖의 `0x0000ffff…` 주소를 받아요.
  Redis의 jemalloc은 포인터를 bit 47부터 부호 확장해서 `0xffffffff…`가 되고 SIGSEGV가 나요.
- **수정:** `scripts/build-qemu.py`(`make qemu`)가 qemu.org 11.0.3 소스, Alpine aports
  `51049924…`의 패치 6개, Alpine static linux-user configure를 그대로 쓰고, aarch64 호스트에서
  `-B`/`QEMU_GUEST_BASE`가 없을 때 x86_64 guest base를 2^47로 두는 패치 하나를 더해요.
  입력(소스, 패치, 툴체인 87개 apk)은 모두 sha256 고정이고, 두 번 빌드해 같은 sha256
  (`e5e7c40c…`)을 얻었어요. 링크된 정적 라이브러리는 musl, glib, libintl, pcre2, libatomic,
  libgcc예요(`STATIC_LINKED`). `build-guest.py`는 Alpine apk 대신 이 바이너리를 docker.img에 넣어요.
- **환경변수·wrapper를 쓰지 않은 이유:** 컨테이너 환경변수는 노출되고 `env -i`로 사라져요.
  binfmt wrapper는 `F`(컨테이너에 qemu 없음), `O`/`C`(권한·execute-only) 의미를 깨요. 인터프리터
  기본값이면 run, exec, fork, chroot 모두 같은 동작을 받아요. `QEMU_GUEST_BASE=0`이면 예전 동작이에요.
- **릴리스/GPL:** `release.py`가 qemu-x86_64를 수정 빌드로 인벤토리에 넣고, 정적 링크된 Alpine
  라이브러리도 넣고, `qemu-x86_64-11.0.3-dmx1.build.py`를 자산으로 내보내요. GPL-3.0-or-later
  텍스트(gettext)를 추가로 고정했어요. 소스 제공 방식(첨부 대 written offer) 결정은 여전히 남아 있어요.

## 검증 결과 (실제 VM)

| 검증 | 결과 |
|---|---|
| `make imagetest` (우회 없음) | **18/18**, 커널 BUG/soft lockup/module verification 메시지 없음 |
| `make x86test` | **16/16**: 47비트 주소 probe True, 대조군(`QEMU_GUEST_BASE=0`) False, jemalloc·mimalloc preload 통과 |
| 대조: 예전 레이아웃의 jemalloc preload python3 | exit 139(SIGSEGV), 새 기본값에서는 통과 |
| selftest / daemon / Docker / MCP / sandbox | 21/21, 41/41, 57/57, 30/30, 41/41 |
| `swift test` | 33/33 |
| 8G/10CPU 유휴(selftest) | 92 MB, 1 GiB 해제 후 634 ms에 복귀 |
| QEMU 전후 x86test(각 2회) | RSS·시작 시간·sha256 속도·정리 후 footprint 회귀 없음 |
| benchmark 2CPU/4G | idle 180–292 MB(3회, 292는 이상치; 기록 193), 2 GiB 반납 1.6–6.5 s |
| benchmark 10CPU/8G | 2 GiB 사용 후 6.6 s에 baseline 아래로 |

원자료: [images-guest-base](measurements/2026-10-25-images-guest-base.json),
[qemu-guest-base](measurements/2026-10-25-qemu-guest-base.json). 측정 중 호스트 load는 2–6이었어요.
`make install`과 공개 릴리스는 하지 않았어요.

## 엔진 비교 (완료, 잠정)

maintainer 승인(2026-10-25)으로 Docker Desktop 4.96.3, OrbStack 2.2.5, Colima 0.10.3을 잠시
설치해 2 CPU/4 GiB, 한 번에 한 엔진, 순서를 바꾼 3라운드로 측정했어요. 측정 후 앱·데이터·
`~/.docker`·brew 패키지를 지우고, OrbStack/Colima가 `~/.zprofile`·`~/.ssh/config`에 넣은 줄도
되돌렸어요. 결과는 [benchmark.md](benchmark.md#results-2026-10-25)와
[원자료](measurements/2026-10-25-engine-comparison.json)에 있어요. 중앙값 idle은 dmx 180,
OrbStack 528, Colima 1097, Docker Desktop 1176 MB예요. 호스트 load가 2–6이라 잠정치예요.
다시 측정할 때도 설치한 엔진은 끝나고 지우고, 약관·관리자 암호 창은 maintainer가 처리해요.

## v0.1.0 공개 릴리스 (완료)

maintainer가 추천안을 모두 승인했어요: `v0.1.0`, GPL 소스 번들 첨부(3a), ad-hoc 서명, 이름 dmx.
`release.py`가 `dmx-sources-<version>.tar`를 만들어요(467 MiB, 재현 가능, aports 코드 실행 없음).
<https://github.com/cothis/dmx/releases/tag/v0.1.0>에 15개 파일을 올렸고, GitHub에서 받은
파일이 SHA256SUMS와 일치하며, `curl … | sh` 설치와 새 `DMX_HOME`의 게스트 다운로드(5.4 s)·
selftest(유휴 90 MB)가 통과했어요. 다음 릴리스도 release.md 절차를 따르고, 태그·게시는
maintainer 확인 후에만 해요.

## 남은 작업과 경계

- **성능(완료):** warm `docker run` 차이는 데이터 디스크 barrier flush 때문이에요. 전원 차단 안전을 위해 유지하기로 했어요(PLAN Decisions, benchmark.md).
- **Phase 6 확장:** 부팅 fsck와 디스크 확장은 완료(2026-10-25). 다음은 split DNS, IPv6, 공유 파일의 Unix socket/xattrs/소유권.
- **비교 재측정:** 조용한 Mac에서 다시 측정하면 범위가 좁아져요.
- **서명(완료):** Developer ID 인증서와 서명 전용 키체인이 `~/.dmx-signing`에 있고, `release.py`가 서명·공증해요(설정 `~/.dmx-signing/release.json`, 저장소 밖). v0.2.0이 첫 서명·공증 릴리스예요(2026-10-25 게시).
- **지속 결정:** GitHub CI와 Homebrew 의존성은 추가하지 않아요. Phase 8 자체 런타임은 미착수예요.

## 근거와 코드 위치

| 위치 | 용도 |
|---|---|
| [compatibility.md](compatibility.md), [measurements/](measurements/) | 18/18 보고서, 이전 17/18과 우회 기록 |
| [build-qemu.py](../scripts/build-qemu.py) | QEMU 입력 고정, guest-base 패치, configure, `--lock` |
| [build-kernel.py](../scripts/build-kernel.py) | 커널 빌드, 공유 `fetch`/`apk_url`/`lock`(main·community) |
| [build-guest.py](../scripts/build-guest.py) | `DMX_QEMU`를 docker.img 끝에 xz로 넣음 |
| [test-x86.py](../scripts/test-x86.py) | 47비트 주소 probe와 대조군, jemalloc/mimalloc preload |
| [test-images.py](../scripts/test-images.py) | digest 고정 이미지 작업, `--qemu-guest-base` 진단 옵션 |
| [release.py](../scripts/release.py) | 수정 QEMU와 정적 라이브러리 인벤토리, 레시피 자산 |
