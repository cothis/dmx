# 다음 세션 인계 — 2026-10-27 (v0.3.10 릴리스 완료)

`이어서 진행해`라는 요청을 받으면 [PLAN.md](PLAN.md)의 **Next up**과 이 문서를 읽어요.
계획·결정·측정의 기준은 `PLAN.md`, 공유 작업 메모는 [memory.md](memory.md)예요.

## 현재 상태

- 게시된 최신 릴리스는 [v0.3.10](https://github.com/cothis/dmx/releases/tag/v0.3.10)이에요(태그 커밋 `aa061fc`,
  Developer ID 서명·Apple 공증). `dmx install`이 Docker Desktop 경로 `~/.docker/run/docker.sock`을 dmx 소켓에 링크해,
  docker context를 읽지 않는 도구(SDK·IDE 플러그인·Testcontainers)도 dmx를 찾아요. 게스트 부팅 파일은 0.3.9와 같아요.
  v0.3.9(`1051460`)는 게스트 MTU를 49126으로 낮춰, 새로 켠 VM의 수신이 약 1% 확률로 영구히 멈추던 교착을 고쳤어요.
  v0.3.8(`7f32e3f`)은 `dmx install`이 launchd 재등록을 기다려요(보안 에이전트가 있는 Mac에서 실패하던 문제).
  v0.3.7(`b4f9da0`)은 깨진 `docker` 링크를 교체하고 README에 서명 확인법을 적었어요.
  v0.3.6(`14d7866`)은 idle 정리 때 데이터 디스크를 trim해 discard가 놓친 공간을 Mac에 돌려줘요.
  그 전 v0.3.5(`610c3c5`)는 FEX dmx11(오래된 번역 수정)을 담았어요. 그 전 릴리스 v0.3.4(`04ef90d`)는 아래와 같아요.
- **v0.3.4의 공개 전 검수·문서 정리·릴리스는 완료됐어요.** 14개 게시 파일을 다시 내려받아 해시를
  확인했고, 신규 설치·VM selftest·실행 중인 0.3.3에서 업데이트·기존 데이터 보존·다음 부팅의
  새 게스트 적용·arm64/amd64/386 컨테이너 실행까지 통과했어요. 게시본 selftest 유휴 메모리는 97 MiB예요.
  검수의 재현 조건은 [검수 기록](review-2026-10-27.md), 최종 수치는
  [릴리스 측정 기록](measurements/2026-10-27-release-0.3.4.json)에 있어요.
  커뮤니티 게시글은 올리지 않았으며, 홍보 시점과 채널은 maintainer의 다음 결정이에요.
- 수정: virtqueue의 게스트 주소 오버플로, 읽기 전용 공유의 권한 변경, 파일·디렉터리 핸들의
  동시 닫기, 잘못된 샌드박스 CIDR, 호스트 정수 범위를 넘는 크기·MCP TTL 입력이에요.
- 릴리스 재검증에서 FEX의 amd64 Java 충돌을 발견했고, maintainer가 **Java까지 고친 뒤 릴리스**를
  선택했어요. 후보와 게시된 0.3.3이 각각 40회 중 1회 실패했고 QEMU는 20/20 통과했어요.
  최종 dmx9의 신호 복귀·명령 디코딩 수정으로 Java 100/100과 전체 검증을 통과했어요.
  진단과 실패 대조군은 [FEX 기록](fex-java-2026-10-27.md)에 있어요. 단순 재시도로 실패를 지우지 않아요.
- 릴리스 뒤 후속 조사로 Java 원인을 확정했어요. 충돌 보고 6건의 레지스터·오류 주소가 HotSpot의
  원자적 entry 패치를 옛 opcode와 새 operand로 섞어 디코드한 결과와 정확히 일치해요. 새 fixture
  `entry-patch`가 기존 FEX에서 18/20 실패하고 decoder 수정본·dmx9·QEMU에서 통과해요.
  같은 조사에서 **오래된 번역이 계속 실행되는 두 번째 결함**을 찾았어요. 번역 중에 바뀐 코드가
  새 바이트 게시와 직렬화 뒤에도 실행돼요(dmx9 0/20, QEMU 30/30). `fex-2610-dmx11`이 고쳤고
  컴파일 비용도 없앴어요(첫 수정 dmx10은 컴파일 폭주에서 19% 느렸어요).
- **v0.3.5를 게시했어요**(2026-10-27, 서명·공증, 태그 커밋 `610c3c5`). 14개 파일 재다운로드 해시, 신규 설치,
  실행 중인 0.3.4에서 업데이트(VM·데이터 보존, 다음 부팅에 dmx11 적용), arm64/amd64/386 컨테이너를 확인했어요.
  `make javatest`는 같은 고정 이미지의 javac/JIT 작업을
  100회 반복하고, 한 번이라도 실패하면 실패예요. 전체 이미지 검사는 `make imagetest`예요.
- 기본 x86 에뮬레이터는 FEX-Emu예요. v0.3.5 게스트는 `fex-2610-dmx11`이고(v0.3.4는 dmx9)
  amd64와 386을 지원해요.
  QEMU는 `dmx config set x86_emulator qemu`로 선택하고 amd64만 지원해요.
- [WORKORDER.md](WORKORDER.md)는 완료됐어요. FEX·TSO·32비트 지원과 성능 수정은 이미 0.3.0에
  들어갔고, IPv6와 메모리 압박 시 디스크 I/O 손상 수정은 0.2.2에 들어갔어요.
  이전 인계 문서의 “v0.2.2 이후 미배포” 목록은 더 이상 현재 상태가 아니에요.
- README와 [benchmark.md](benchmark.md)의 엔진 비교는 2026-10-26의 **0.3.0** 측정이에요.
  이번 검수의 selftest·통합 테스트 수치와 구분하세요. 엔진 비교를 새로 한 것은 아니에요.

## 작업 규칙과 검증

- 기존 체크아웃 `~/dev/dockermax`의 `main`에서 직접 작업해요. 브랜치·worktree를 만들지 않아요.
  미커밋 변경 확인 후 `git pull --ff-only origin main`, 검증한 범위만 커밋하고 `git push origin main`해요.
  분기·push 거절은 force push·reset·자동 merge/rebase 없이 보고해요.
- 로직은 `Sources/DMXCore`, CLI는 인자 처리와 출력이에요. 메모리 절약은 기본 동작이고 게스트 입력은
  sha256으로 고정해요. `~/.dmx`의 커널·캐시·initramfs는 커밋하지 않아요.
- 호스트 VM 메모리는 `ri_phys_footprint`(`host.footprint_mb`)로 재요. `footprint` 도구는 쓰지 않아요.

```sh
cd ~/dev/dockermax
git status --short --branch && git log --oneline -10 && git pull --ff-only origin main
make build && make guest && make selftest
make test && make daemontest && make mcptest && make x86test
make dockertest && make sandboxtest && make imagetest
make javatest
# 메모리·디스크 경로 변경 시: make pressuretest (Mac을 몇 분간 스왑시킴)
```

- 캐시가 없거나 입력이 바뀌면 `make kernel`, `make qemu`, `make fex`를 `make guest` 전에 실행해요.
- 무거운 빌드·VM 테스트·벤치마크는 동시에 돌리지 않아요. 코어를 나눠 쓰면 측정이 달라져요.
- 셸에 `DMX_HOME`이 남아 있으면 테스트가 잘못된 guest를 볼 수 있어요. `env -u DMX_HOME make ...`로 실행해요.
- `test-daemon.py`는 바이너리 경로로 데몬을 찾아요. 테스트에는 저장소의 `.build/release/dmx`를 넘겨요.
- `swift build`만 하면 hypervisor 엔타이틀먼트가 빠져요. VM은 `make build`로 서명한 바이너리로 검증해요.
- 실행 중인 서명 바이너리를 `cp`로 덮어쓰면 SIGKILL될 수 있어요. 임시 파일을 rename하거나 지우고 복사해요.
- VM을 끄는 명령은 `dmx stop`이에요. `dmx daemon stop`은 없어요. 컨테이너와 데이터 디스크를 보존해요.

## 다음 릴리스

[release.md](release.md)를 따르세요. `docs/release-notes/<버전>.md`를 먼저 쓰고,
버전·게스트 pin·README 설치 URL을 같은 릴리스로 맞춰요. `make release`가 NOTES.md와 SHA256SUMS를
자동 생성하므로 손으로 요약을 넣거나 해시를 다시 계산하지 않아요. v0.3.9의 태그·게시·게시본 검증은 완료됐어요.

서명 설정은 저장소 밖에 있어요. 자세한 절차는 release.md와 `scripts/release.py`를 사용하고,
키·암호·개인 인프라 정보는 이 공개 저장소에 적지 않아요. CLI 바이너리의 `spctl` 결과가
“valid but not an app”이면 그 결과만으로 공증 실패라고 판단하지 말고
`codesign --verify --strict --check-notarization`과 실제 실행을 함께 확인하세요.

## 남은 검증과 알려진 제한

1. 커뮤니티 공개(Show HN, Reddit, GeekNews)는 maintainer의 다음 결정이에요.
2. 실제 사내 TLS 검사 프록시·VPN 환경과 외부 IPv6 연결: 해당 환경에서 수용 시험이 필요해요.
   로컬 프록시·사설 CA·IPv6 loopback 검사는 이 증거를 대신하지 않아요.
3. QEMU는 386을 지원하지 않아요. FEX는 32비트 프로세스의 `uname -m`에도 `x86_64`를 반환해요.
4. 따뜻한 `docker run`이 Colima보다 느린 것은 데이터 디스크의 쓰기 순서 보장을 유지한 결정이에요.
5. 공유 파일 ACL·DAX·임의 호스트 Unix 소켓 연결과 phase 8 자체 런타임은 완료한 기능이 아니에요.

엔진 비교를 다시 할 때는 [benchmark.md](benchmark.md)의 설정·측정 간격을 그대로 사용하고,
Docker Desktop Resource Saver는 기본값을 유지하세요. 비교용 앱의 설정·Docker context는 백업하고 복원해요.
idle CPU 분석에서는 이 Mac의 in-kernel GIC가 WFI를 커널 안에서 기다린다는 점에 유의하세요.
게스트 실행 시간은 `/proc/*/task/*/schedstat`으로 재며 tickless의 `/proc/stat` jiffy는 부정확해요.
