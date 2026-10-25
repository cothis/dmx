# 다음 세션 인계 — 2026-10-25 (v0.2.1 이후)

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
make build && make guest   # 캐시가 없으면 make kernel(7–12분), make qemu(30초) 먼저
make selftest              # 이후 daemontest, dockertest, sandboxtest, mcptest, x86test
```

## 현재 상태

- **게시된 릴리스:** [v0.2.1](https://github.com/cothis/dmx/releases/tag/v0.2.1)(서명·공증).
  GitHub에서 받아 설치·부팅까지 확인했어요. main은 v0.2.1 태그와 같아요(문서 커밋만 뒤에 있어요).
- **v0.2.0 → v0.2.1 변경:**
  - 에이전트 control 호출 60초 타임아웃과 연결 교체(`AgentClient`)
  - 부팅 시 `e2fsck -p`, 실패하면 `-fy`(`guest/init`)
  - `disk_size`를 올리면 데이터 디스크를 온라인으로 확장(호스트 `ftruncate`, 에이전트
    `EXT4_IOC_RESIZE_FS`)
  - 게스트 DNS를 macOS 리졸버로 처리(`HostDNS.swift`, `DNSServiceQueryRecord`): split DNS,
    `.local`, 네트워크 변경. 없는 이름은 NXDOMAIN 대신 빈 NOERROR예요.
  - 공유 폴더: 게스트가 Unix 소켓을 bind할 수 있고(게스트끼리 연결), `user.*` xattr만 보이며,
    chown과 non-root 사용자가 만든 파일의 소유자를 호스트 xattr `com.dmx.owner`에 저장해요.
    virtio-fs는 늘 default_permissions라 이게 있어야 non-root 컨테이너가 바인드 마운트에 써요
    (postgres 데이터 디렉터리). FUSE 7.33 + `HANDLE_KILLPRIV_V2`(`FUSEServer.swift`).
  - Mac의 SSH 에이전트를 VM의 `/run/host-services/ssh-auth.sock`으로 제공(Docker Desktop과 같은
    경로). vsock 장치가 게스트에서 먼저 여는 연결을 받아요(`VirtioVsock.listen`, 포트 1025,
    `HostServices.swift`, 에이전트 `host_services.rs`).
  - CNAME 뒤 주소를 1.5초가 아니라 쿼리 제한(5초)까지 기다려요(느린 네트워크에서 주소 없는 답 방지).
- **v0.2.1 이후 main(미배포):** VM 네트워크 IPv6. 게스트 `fd64:646d:7800::2/64`, 게이트웨이
  `::1`(NDP·ping·DNS), `::254`는 Mac의 `::1`. TCP/UDP/ICMPv6 echo를 Mac의 IPv6 소켓으로 보내요
  (`UserNet.swift`의 `IPAddress`, `ipFrame`). Mac에 경로가 없는 AAAA는 걸러요(`HostDNS.routable`).
  dockerd의 `ip6tables`를 더 이상 끄지 않아 `--ipv6` 네트워크가 NAT66으로 나가요. ULA라서
  듀얼스택 이름은 계속 IPv4가 먼저예요. 이 Mac에는 IPv6 기본 경로가 없어 인터넷 IPv6는 시험하지
  못했어요(Mac의 `::1`, Tailscale ULA로 확인). 이어서 게스트로 ICMP 오류(destination unreachable)를
  전달해요(`UserNet.unreachable`): 연결 실패가 "connection refused" 대신 실제 사유로 보이고, 닫힌
  UDP 포트는 바로 오류가 나요.
- **마지막 검증**(0.2.1 릴리스, load 1.2–3.3): 단위 42/42, selftest 86 MB, daemontest 48/48,
  mcptest 30/30, x86test 16/16, dockertest 66/66, sandboxtest 41/41. GitHub에서 설치한 0.2.1
  selftest 96 MB.

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

PLAN.md의 Next up 순서를 따라요. 요약하면: Mac 쪽 IPv6 포트 포워딩, 조용한 Mac에서 엔진 비교 재측정,
커뮤니티 홍보(maintainer 결정), 한 번 본 게스트 커널 oops(재현 안 됨), 실제 회사망에서 Phase 11
확인. 0.2.1 릴리스는 maintainer가 원할 때 release.md 절차로 내요.
