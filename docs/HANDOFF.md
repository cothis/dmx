# 다음 세션 인계 — 2026-10-26 (작업 지시서 전부 완료, 0.3.0 대기)

`이어서 진행해`라는 요청을 받으면 [PLAN.md](PLAN.md)의 **Next up**과 이 문서를 읽어요.
대화 이력이나 `/tmp` 파일은 필요 없어요. 계획·결정·측정의 기준은 `PLAN.md`예요.

## 시작 상태와 작업 규칙

- `main`에서 직접 작업해요(브랜치·worktree 없음). 원격과는 fast-forward로만 맞추고, 분기나
  push 거절은 force push·reset 없이 보고해요. 커밋 후 `git push`는 묻지 않고 해요.
- 로직은 `Sources/DMXCore`, CLI는 인자 처리와 출력. 메모리 절약은 기본 동작. 게스트 입력은
  sha256 고정, `~/.dmx`(커널·QEMU·initramfs·캐시)는 커밋하지 않아요.
- 태그·GitHub 릴리스 게시·커뮤니티 홍보는 maintainer 확인 후에만 해요.

```sh
cd /Users/cothis/dockermax
git status --short --branch && git log --oneline -10 && git pull --ff-only origin main
make build && make guest   # 캐시가 없으면 make kernel(5–12분), make qemu(30초), make fex(70초) 먼저
make selftest              # 이후 daemontest, dockertest, sandboxtest, mcptest, x86test
```

## 현재 상태

- **게시된 릴리스:** [v0.2.2](https://github.com/cothis/dmx/releases/tag/v0.2.2)(서명·공증, 2026-10-26).
  GitHub에서 받아 설치·부팅까지 확인했어요.
- **main의 미배포 변경(v0.2.2 이후):**
  - idle CPU 수정(idle trim을 idle 구간마다 한 번, 1.4 → 0.57 %).
  - x86_64 기본 에뮬레이터가 FEX-Emu(`fex-2610-dmx4`)예요. `make fex`(`scripts/build-fex.py`)가 고정된 소스와
    Alpine clang으로 정적 musl PIE를 빌드해요. dmx 패치는 (1) FEXServer 없이 실행, (2) glibc 가정 네 곳
    (rwlock 재잠금, `PTHREAD_STACK_MIN`, 이중 detach, `getdents64`), (3) `AT_SECURE`면 호출자 설정을 무시
    (setuid x86 프로그램 보안), (4) `/proc` 없을 때 `MAP_FIXED_NOREPLACE` 프로브로 2^47 위를 예약, (5) 번역 블록
    상한 `MaxInst` 5000 → 150(node 시작 650 → 246 ms), (6) 대체 vsyscall 페이지에 실행 권한(32비트 x86이 동작하게)
    이에요. FEX는 `fex-2610-dmx5`. 커널에는 Asahi의 TSO 패치 4개와 ACTLR_EL1을 값이
    바뀔 때만 쓰는 dmx 수정이 들어가요. `dmx config set x86_emulator qemu`로 QEMU를 쓸 수 있어요. docker.img는 형식 3.
  - `make release`가 FEX 도입 이후 깨져 있던 것(`source_bundle`의 `path` 섀도잉)을 고쳤어요. 0.3.0-rc 리허설로
    확인(소스 묶음 496 MB, `fex/`·`linux/asahi-tso/`, 라이선스 15종)했고 결과물은 지웠어요.
  - `benchmark.py`가 유휴 메모리를 35·50·65·80·95초에 재요(`idle_at_35s`, `idle_min`, `idle`). 예전의 "유휴가
    ~100 MB 높게 읽히는" 현상은 트림 직전에 재던 것이었어요.
  - THIRD_PARTY의 cephes 항목에 정확한 조건(파일 10개, Moshier 저작권, Netlib 조건, 저자의 BSD 허락)을 적었어요.
  - **32비트 x86(`linux/386`) 지원**: `/init`이 FEX일 때만 `FEX-x86` binfmt 항목을 등록해요(qemu-x86_64는 32비트를
    못 돌리니 그 설정에서는 등록하지 않아요). x86test에 32비트 Alpine 루트 검사가 있고, `test-images.py`는 선택
    플랫폼과 `--pin-optional`을 지원해요(9개 중 6개 이미지가 386 매니페스트를 제공).
- **작업 지시서([WORKORDER.md](WORKORDER.md))는 전부 완료예요.**
- **v0.2.1 → v0.2.2 변경:**
  - 게스트 메모리 손상 수정: Mac이 스왑할 때 virtio-blk의 direct I/O(`F_NOCACHE`)가 게스트
    페이지에 직접 닿아 게스트 메모리가 0으로 보였어요(커널 oops, 파일 유실). 이제 virtio-blk는
    자체 bounce 버퍼로 복사하고(`VirtioBlock.bounced`), virtio-fs는 게스트의 O_DIRECT를
    `F_NOCACHE`로 넘기지 않아요. 재현은 `make pressuretest`(Mac을 몇 분간 스왑시켜요, 릴리스
    체크에는 넣지 않았지만 0.2.2는 릴리스 바이너리로 12/12 통과).
  - VM 네트워크 IPv6: 게스트 `fd64:646d:7800::2/64`, 게이트웨이 `::1`(NDP·ping·DNS), `::254`는
    Mac의 `::1`. TCP/UDP/ICMPv6 echo를 Mac의 IPv6 소켓으로 보내요(`UserNet.swift`). Mac에 경로가
    없는 AAAA는 걸러요(`HostDNS.routable`). dockerd의 `--ipv6` 네트워크가 NAT66으로 나가요.
    이 Mac에는 IPv6 기본 경로가 없어 인터넷 IPv6는 시험하지 못했어요.
  - 게스트로 ICMP 오류(destination unreachable) 전달(`UserNet.unreachable`).
  - 포트 포워딩과 published 포트가 Mac의 IPv6에서도 받아요(127.0.0.1이면 `::1`, 0.0.0.0이면 `::`).
- **v0.2.0 → v0.2.1 변경**(요약): 에이전트 control 호출 타임아웃, 부팅 시 e2fsck, 데이터 디스크
  온라인 확장, macOS 리졸버로 DNS, 공유 폴더의 Unix 소켓·`user.*` xattr·소유자 저장
  (`com.dmx.owner`), Mac SSH 에이전트(`/run/host-services/ssh-auth.sock`).
- **마지막 검증**(2026-10-26, main, load 1–10): 단위 42/42, selftest 97 MB, daemontest 53/53, x86test 44/44,
  dockertest 69/69, mcptest 30/30, sandboxtest 41/41, pressuretest 12/12, 이미지 매트릭스 24/24(arm64·amd64·386,
  조용한 Mac), 벤치마크 유휴 바닥 191–204 MB·정상상태 216–225 MB·유휴 CPU 0.44–0.53 %.
- **릴리스 노트:** `release.py`가 만드는 NOTES.md에는 변경 요약이 없어요. 0.2.2는 "Changes since
  0.2.1" 절을 손으로 넣고 SHA256SUMS의 NOTES.md 줄을 다시 계산했어요.

## 서명·공증 (저장소 밖)

- `~/.dmx-signing/`(700): 서명 전용 키체인 `dmx-signing.keychain-db`와 그 암호 파일, Developer ID
  인증서·개인 키, 설정 `release.json`. `make release`가 이 설정으로 서명·공증해요
  (`scripts/release.py`의 `sign_and_notarize`). 공증 키는 `~/.appstoreconnect/private_keys`의
  기존 App Store Connect 키 `ci-upload`(관리자 권한)를 참조해요.
- 로그인 키체인은 터미널 세션에서 잠겨 있어 쓸 수 없어요(그래서 전용 키체인). `security` 명령은
  샌드박스 밖(`dangerouslyDisableSandbox`)에서 실행해야 해요.
- codesign은 검색 목록에 있는 키체인만 봐요. release.py가 잠깐 추가했다가 원래 목록으로
  되돌려요. 직접 손댈 때는 목록을 **경로별 인자로** 복원해야 해요(공백으로 합치면 깨져요).
- 공증 직후 약 1분은 Gatekeeper가 티켓을 못 찾아요. 확인은 그 뒤에 해요.

## 테스트 팁

- `export DMX_HOME=...`이 남은 셸에서 `make dockertest` 등을 돌리지 않아요. 테스트가 그
  디렉터리의 guest를 쓰는데, 지우고 나면 끊긴 링크가 돼요. `env -u DMX_HOME make ...`로 돌려요.
- `test-daemon.py`는 바이너리 경로로 데몬을 찾아요(`pgrep -f`). 심볼릭 링크가 낀 경로
  (`/tmp/...`)의 바이너리를 넘기지 말고 저장소 안 경로(`.build/...`)를 써요.
- `swift build`만 하면 엔타이틀먼트 서명이 빠져 `hv_vm_create failed: 0xfae94007`가 나요. `make build`로
  빌드해요. 서명된 바이너리를 `cp`로 제자리에 덮어쓰면 다음 실행이 SIGKILL(137)돼요. 지우고 복사해요.
- VM과 데몬을 끄는 건 `dmx stop`이에요(`dmx daemon stop`은 없는 명령이라 데몬이 남아요).
- 시스템 프록시 변경이나 VPN 도메인별 DNS 서버 생성은 관리자 권한이 필요해서 자동 테스트에서
  안 해요. 대신 로컬 프록시, 사설 CA, `.local` 이름으로 같은 경로를 시험해요.

## 남은 작업

작업 지시서는 전부 끝났어요. 다음은 **0.3.0 릴리스**인데 maintainer 결정이 필요해요:

1. 태그·게시 여부(`make release VERSION=0.3.0` → 서명·공증 → GitHub).
2. NOTES.md의 "Changes since 0.2.2"는 손으로 써야 해요(0.2.2처럼; SHA256SUMS의 NOTES.md 줄 재계산).
3. 공개된 유휴 수치(README·benchmark.md의 198 MB)는 35초 정의예요. 정상상태는 ~20 MB 높아서, 네 엔진 비교를
   다시 돌릴지가 maintainer 결정이에요([PLAN.md](PLAN.md)의 O1 행).

무거운 빌드·측정(make kernel, make fex, 이미지 매트릭스, 데몬 VM 안 컨테이너 빌드)은 동시에 돌리지 않아요.
두 VM이 코어를 나눠 쓰면 둘 다 몇 배 느려지고 측정값도 못 믿어요(커널 315초 → 3110초). 실험 컨테이너는
끝나면 지워요. 엔진 비교는 2026-10-26에 조용한 Mac에서 다시 쟀어요
([benchmark.md](benchmark.md#results-2026-10-26-quiet-mac)). 다시 잴 때 Docker Desktop은 설정 파일에
`EnableDefaultDockerSocket`·`RequireVmnetd`·`EnablePrivilegedPorts`를 끄고 `DockerBinInstallPath: user`로
두어야 암호 창이 안 떠요. OrbStack은 `setup.use_admin false`.

idle CPU를 다시 볼 때: 이 macOS(26.6)에서는 in-kernel GIC를 쓰면 vCPU가 WFI로 `hv_vcpu_run`을 빠져나오지
않아요(Hypervisor.framework가 커널에서 기다려요). 그래서 `VCPU.waitForInterrupt`와 1 ms 상한은 실행되지
않아요. 게스트 쪽 실행 시간은 `/proc/*/task/*/schedstat`(ns)으로 재요. `/proc/stat` jiffy는 tickless라 부정확해요.
