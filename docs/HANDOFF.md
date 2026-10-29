# v0.3.12 검수 수정 작업 상태 (2026-10-29)

R1–R5와 추가 Opus 지적 두 건을 수정했어요. 최종 Core Opus 5.5 검수는 새 런타임 결함 없이
릴리즈 진행을 권고했어요. 전체 RPC lease, 응답 ID 검사, 오류 후 retire/reconnect(재전송 없음),
서버 응답 실패 종료와 daemon 오류 원문 보존, 같은 archive의 receipt tag 갱신이 포함돼요.

원래 수학 모델은 관측값이 fix toggle에 의존해 가드 삭제를 놓쳤고, 테스트는 peer 종료가
생산 코드의 wakeup을 대신했어요. 지금은 binding과 reply queue를 모델링하고 독립 mutation을
검사해요. 원래 FD 속성 해시는 유지했어요. 모델 2개(134/26 상태), 필수 실패 검사 13개,
안전한 binding 단위 검사와 자식 프로세스 syscall 검사가 연결돼 있어요(`make formaltest`).
스킬 수정본·패치·블라인드 평가도 `formal/skill-improvements/`에 보존했어요.

첫 후속 daemon 검사 57/58의 메모리 실패는 숨기지 않았어요. 이전 검사는 만족한 측정값을
버리고 즉시 다시 측정해 판정했어요. 합성 replay로 가능한 거짓 실패를 재현했고, 기존 메모리
경로를 계측한 5회는 모두 통과했어요. 최초 실패의 정확한 선행 측정값은 저장되지 않아 원인을
확정할 수 없다는 한계도 기록했어요. 기준·15초 제한은 그대로 두고 동일 측정값으로 판정하게
했으며, 별도 Opus 검수와 최종 daemon/MCP 결과를 보존해요.

최종 단위 76, VM selftest 23, 보정된 daemon 58, MCP 33 검사를 통과했어요. 전체 선행
검증은 x86 53, Docker 69, sandbox 44, image 24, Java 100을 통과했어요. 전후 selftest
idle은 94→99MiB이고 단발 측정이라 통계적 성능 비교는 아니에요. 첫 패키징의 서명·공증과
0.3.12 guest pin 생성도 끝났어요. 현재 공개 버전은 아직 v0.3.11이에요. 두 번째 패키징의
pin_changed=false와 설치/실행 중 업데이트 리허설 후 main/tag push·공개 배포를 마무리해야 해요.
[원인과 증거](formal-verification-miss-2026-10-29.md)를 확인하세요.

---

# 다음 세션 인계 — 2026-10-29 (v0.3.11 릴리스 완료)

`이어서 진행해`라는 요청을 받으면 [PLAN.md](PLAN.md)의 **Next up**과 이 문서를 읽어요.
계획·결정·측정의 기준은 `PLAN.md`, 공유 작업 메모는 [memory.md](memory.md)예요.

## 현재 상태

- **다음 작업은 Opus 5.5 검수 후속 수정이에요.** 요청한 `claude-opus-5-5`가 실제로 호출됐고,
  읽기 전용 검수 38턴을 마쳤어요. Opus의 세 지적을 별도 재현으로 확인했어요: P2 FD 복제 실패 뒤
  RPC 응답이 한 칸 밀리는 결함, P2 모델의 닫힘 검사 제거를 놓치는 공백, P3 close의 shutdown을
  빼도 기존 세 테스트가 모두 통과하는 공백이에요. 부모 에이전트는 추가로 테스트 사이에 FD 번호를
  강제 재사용하다 다른 테스트의 파일을 닫을 수 있는 순서도 재현했어요. 이 범위에서 P0/P1은 없었어요.
  제품 수정·새 릴리스는 하지 않았고, 현재 게시본은 여전히 0.3.11이에요.
  [검수 기록·재현 증거](review-2026-10-29-opus55.md)를 먼저 읽으세요. 기존 134상태 통과는
  역사적 결과지만 회귀 검증력이 충분하다는 근거로 삼으면 안 돼요. formal 보고서에도 한계를 추가했어요.
- **최신 릴리스는 [v0.3.11](https://github.com/cothis/dmx/releases/tag/v0.3.11)이에요.** 2026-10-29,
  태그 커밋 `13c1257`, Developer ID 서명·Apple 공증을 완료했어요. 소켓 수명과 게스트 영수증 수정을
  포함해 단위 66, selftest 23(96 MiB), daemon 58, MCP 33, x86 53, Docker 69, sandbox 44,
  이미지 24, Java 100과 수학적 모델 재검증을 모두 통과했어요. 두 번째 패키징은 핀을 유지했고,
  게시 파일 14개를 다시 받아 모두 해시가 일치했어요. 로컬 리허설 selftest는 97 MiB,
  GitHub 신규 설치 selftest는 95 MiB, 둘 다 23/23이에요. 실행 중인 0.3.10에서 업데이트할 때
  VM·컨테이너를 유지했고, 이후 VM 재시작에서도 데이터 디스크와 이름 있는 볼륨이 보존됐어요.
  게스트 다운로드를 차단한 첫 부팅에서, 명시적 fetch 전에 영수증·guest·doctor가 v0.3.11을
  표시했고 부팅 파일 4개의 inode와 해시는 그대로였어요. 게시본의 arm64/amd64/386 컨테이너와
  MCP 33/33(스트림·타임아웃·취소)도 통과했어요. [측정 기록](measurements/2026-10-29-release-0.3.11.json)을 보세요.
- 이전 [v0.3.10](https://github.com/cothis/dmx/releases/tag/v0.3.10)은 태그 커밋 `aa061fc`예요
  (Developer ID 서명·Apple 공증). `dmx install`이 Docker Desktop 경로 `~/.docker/run/docker.sock`을 dmx 소켓에 링크해,
  docker context를 읽지 않는 도구(SDK·IDE 플러그인·Testcontainers)도 dmx를 찾아요. 게스트 부팅 파일은 0.3.9와 같아요.
- **v0.3.11에 반영한 수정 2건:** 부팅 파일이 같은 릴리스로 올라가도 게스트 영수증(`release.json`)이 옛 태그에
  머물던 문제(`dmx guest`가 0.3.10에서도 v0.3.6 표시)를 고쳤어요(`77433a0`). v0.3.11에 함께 넣었어요.
  v0.3.9(`1051460`)는 게스트 MTU를 49126으로 낮춰, 새로 켠 VM의 수신이 약 1% 확률로 영구히 멈추던 교착을 고쳤어요.
  v0.3.8(`7f32e3f`)은 `dmx install`이 launchd 재등록을 기다려요(보안 에이전트가 있는 Mac에서 실패하던 문제).
  v0.3.7(`b4f9da0`)은 깨진 `docker` 링크를 교체하고 README에 서명 확인법을 적었어요.
  v0.3.6(`14d7866`)은 idle 정리 때 데이터 디스크를 trim해 discard가 놓친 공간을 Mac에 돌려줘요.
  그 전 v0.3.5(`610c3c5`)는 FEX dmx11(오래된 번역 수정)을 담았어요. 그 전 릴리스 v0.3.4(`04ef90d`)는 아래와 같아요.
- **2026-10-29 수학적 검증에서 소켓 종료 경합 1건을 추가 수정했어요.** `FrameConnection`이 닫힌 뒤
  옛 디스크립터 번호를 다른 소켓이 재사용하면 늦은 읽기·쓰기가 새 연결에 접근했어요. 원본 코드에서
  재현했고, 프레임마다 close 잠금 아래 복제한 디스크립터를 소유하도록 고쳤어요. close는 대기 중인
  I/O도 깨워요. TLA+는 2작업×각 2회 I/O, 134개 상태에서 두 안전 속성을 확인했고 수정 제거 시 다시
  반례가 나와요. 프로그램 전체나 무한 크기의 증명은 아니에요. 단위 66/66, 실제 VM selftest 23/23,
  daemon 58/58, MCP 33/33을 통과했어요. 메모리는 단일 전후 표본으로 idle 94→96 MiB,
  1 GiB 회수 후 101→104 MiB예요. [보고서](../formal/reports/frame-connection-lifetime.html),
  [재실행 방법과 증거](../formal/README.md)를 보세요. 두 수정 모두 v0.3.11에서 배포했어요.
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
자동 생성하므로 손으로 요약을 넣거나 해시를 다시 계산하지 않아요. v0.3.11의 태그·게시·게시본 검증은 완료됐어요.

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
