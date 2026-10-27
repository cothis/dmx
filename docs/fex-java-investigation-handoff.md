# Claude Code 작업 지시서: FEX / Java 간헐 충돌 추가 조사

> 결과(2026-10-27): 원인을 확정했고 두 번째 결함(오래된 번역)을 `fex-2610-dmx10`으로 고쳤어요.
> [진단 기록의 후속 절](fex-java-2026-10-27.md#follow-up-cause-confirmed-and-a-second-defect-2026-10-27)과
> [측정 기록](measurements/2026-10-27-fex-code-patching.json)을 보세요. 아래는 작성 당시의 지시서예요.

작성일: 2026-10-27. 작업 경로: `~/dev/dockermax`.

## 목표

FEX에서 발생한 amd64 Java 간헐 충돌을 추가 조사한다.
수정 전에는 실패하고 수정 후에는 통과하는 최소 재현을 확보하거나,
현재 증거로 확정할 수 없는 부분을 정확히 밝혀라.
반복 시험이 통과했다는 이유만으로 원인 해결을 선언하지 마라.

## 작업 규칙

- `../AGENTS.md`, `AGENTS.md`, `docs/PLAN.md`, `docs/HANDOFF.md`, `docs/memory.md`부터 읽어라.
- 기존 `main`에서 작업한다. 브랜치와 worktree를 만들지 않는다.
- 변경 상태를 확인하고 `git pull --ff-only origin main`으로 동기화한다.
- 기존 변경과 과거 실패 로그를 보존한다. 분기나 push 거절을 force push·reset·자동 merge/rebase로 해결하지 않는다.
- VM은 하나씩, 별도 임시 `DMX_HOME`과 `shares=[]`로 실행한다.
- 사용자 VM·데이터·Docker 설정은 건드리지 않는다. 다른 에이전트와 같은 레포를 동시에 편집하지 않는다.
- 게스트 입력은 기존 sha256 고정을 유지한다. `~/.dmx`의 캐시나 바이너리는 커밋하지 않는다.
- 검증된 변경과 문서는 `main`에 커밋하고 push한다. 실제 변경에 필요한 VM 검사를 실행하고 결과를 기록한다.
- 새 릴리스·태그 생성이나 기존 v0.3.4 교체는 이번 범위가 아니다.
- 진행 상황을 한국어로 알리고, 실행 중인지·막혔는지 명확히 구분한다.

## 현재 상태

- v0.3.4는 이미 공개됐으며 서명·공증·설치·업데이트 검증도 완료됐다.
- 릴리스 코드 커밋: `04ef90d`.
- 릴리스 기록 커밋: `d4aa2a3`.
- Java의 정확한 충돌 원인까지 확정된 것은 아니다.
- 아래 내용은 작성 시점의 인계다. 현재 git 상태와 로컬 산출물을 확인한 뒤 시작하라.

## 먼저 읽을 자료

- [Java 진단 기록](fex-java-2026-10-27.md)
- [릴리스 측정 기록](measurements/2026-10-27-release-0.3.4.json)
- [FEX 빌드 스크립트](../scripts/build-fex.py)의 `FEX_PATCH`
- [이미지 검사 스크립트](../scripts/test-images.py)의 Java workload
- `.build/release-checks-0.3.4/`의 `hs_err` 파일과 실험 로그
- `.build/java-repro-luna/report.md`
- `.build/java-repro-luna/entry-race.S`
- `.build/java-repro-luna/run-probe.py` 및 `results` / `run` 로그

`.build/` 아래 자료는 이 체크아웃의 로컬 산출물이며 git에 포함되지 않는다.
파일이 없다면 검증에 사용했다고 주장하지 말고, 확보 가능한 자료와 누락된 자료를 구분하라.

## 확인된 기존 증거

기존 FEX dmx8에서 Java가 간헐적으로 SIGILL/SIGSEGV로 종료됐다.
같은 Java workload를 실행한 결과는 다음과 같다.

| 조합 | 통과 / 실행 |
|---|---|
| v0.3.3 호스트 + 기존 FEX | 39 / 40 |
| v0.3.4 호스트 + 기존 FEX | 39 / 40 |
| QEMU | 20 / 20 |
| signal-return 수정만 적용한 FEX | 99 / 100 |
| decoder 수정만 적용한 FEX | 150 / 150 |
| 두 수정을 합친 최종 dmx9 | 100 / 100 |

signal-return 버그는 별도 작은 프로그램으로 수정 전 실패·수정 후 성공을 확인했다.
Java 충돌과 decoder 수정 사이에는 아직 직접적인 재현 증거가 부족하다.

## v0.3.4에 들어간 FEX 수정

1. 신호 처리 후 RIP가 그대로여도 `InSyscallInfo`를 복구한다.
   누락되면 후속 신호가 오래된 스택 위치를 사용해 데이터를 덮어쓸 수 있다.
2. 명령어 하나를 해석하는 동안 정렬된 8바이트 단어를 한 번만 읽는다.
   opcode와 operand가 Java의 원자적 엔트리 교체 전후에서 섞이는 것을 방지한다.
   이것이 관찰된 Java 충돌의 직접 원인이었는지는 추가 입증이 필요하다.

## 중요한 실험 오류

- 초기 후보 게스트 일부는 실제로 기존 FEX를 포함했다.
  imported `build-guest.DMX_FEX`만 바꾸고 `X86_EMULATORS`를 바꾸지 않았기 때문이다.
- `java-smc-predecode-results`의 99/100과 `java-atomic-fetch-results`의 149/150은
  후보 증거가 아니라 baseline이다. 이름에 `verified`가 있는 대조와 혼동하지 마라.
- 현재 `~/.dmx/guest`는 dmx9다. 기존 dmx8 게스트로 착각하지 마라.
- 새 후보 게스트를 만들 때 `DMX_FEX`와 `X86_EMULATORS["FEX"]`를 함께 설정하고,
  `docker.img`에 포장된 FEX 및 실행 VM의 `/var/lib/dmx/x86/FEX` 해시를 모두 확인하라.
- `scripts/test-images.py --expect-emulator-sha256`으로 의도하지 않은 실행 파일을 거부할 수 있다.

## 캐시와 SHA-256

| 대상 | 캐시 파일 | SHA-256 |
|---|---|---|
| 기존 FEX | `~/.dmx/cache/fex-2610-dmx8` | `f6c78ffe2a93c55ab0d9b708132a6827ac74f8cba66fc878106e5ce5a70a2b7c` |
| 최종 FEX | `~/.dmx/cache/fex-2610-dmx9` | `5468c106014cd11cf74b04b7858778b0ee7145b43b19817aa45f0ca8338e9741` |
| decoder-only | `~/.dmx/cache/fex-2610-atomic-fetch-test` | `55ee8c4df48708439cee1cbfab6c082a0af33ab67d033a57ecf283118d13fce6` |
| QEMU | `~/.dmx/cache/qemu-x86_64-11.0.3-dmx1` | `e5e7c40cde4a9489019e1b580b8ce5936ef3b4b19c9f528be4406d708e1d4ed4` |

Java 이미지:

```text
library/eclipse-temurin@sha256:074d6f95f1e69965dbd23750a37ec3b234025d0864e9821e0b1fba0763a3e853
```

## Luna 후속 실험: 반드시 재검토할 부분

- 512개 엔트리를 reader가 실행하고 writer가 정렬된 8바이트 엔트리를 교체하는 프로브를 만들었다.
- 초안에는 잘못된 기계어 상수와 명령 경계 문제가 있었다.
  해당 SIGSEGV는 제품 버그의 증거에서 제외해야 한다.
- 두 버전은 모두 단일 5바이트 명령이고, 뒤의 RET/NOP 바이트가 동일해야 한다.
  올바른 예는 아래와 같다. 주석이나 상수 이름만 믿지 말고 실제 바이트를 확인하라.

  ```text
  mov eax,42; ret; nop; nop: 0x9090c30000002ab8
  jmp entry+64; ret; nop; nop: 0x9090c30000003be9
  ```

  각 `entry+64`에는 고정된 `mov eax,42; ret` 코드가 필요하다.
- 실제로 reader와 writer가 겹쳐 실행됐음을 시작 신호·sweep counter·종료 확인으로 검증해야 한다.
- Luna는 최종 v2에서 기존 FEX/수정 FEX/QEMU 각각 3/3 통과했다고 보고했다.
  그러나 부모 에이전트가 최종 코드와 전체 결과를 독립 검증하지는 않았다.
- 도중 dmx8에서 exit 1과 `entry-race-failed`가 한 번 보고됐다.
  당시 잘못된 반환값과 sweep 검사 실패가 같은 메시지를 사용했다.
  이 실패를 분류하지 않은 채 마지막 통과 결과로 덮어쓰지 마라.
- `report.md`의 설명도 그대로 믿지 말고 코드·로그·바이너리 해시와 대조하라.

## 우선 할 일

1. Luna 프로브와 실패 분류를 감사하고, 유효한 실험인지 먼저 판단한다.
2. 기존 `hs_err`의 실패 위치·명령 바이트와 FEX decoder 동작을 대조한다.
3. 원인을 구별할 수 있는 작은 실험을 선택한다.
   필요하면 진단용 FEX에서 실제 읽은 opcode/operand를 기록하되,
   계측으로 타이밍이 바뀐다는 점도 구분한다.
4. 같은 입력으로 기존 FEX·수정 FEX·QEMU를 순차 대조한다.
5. 원인이 입증되면 재현 코드를 회귀 테스트로 정리한다.
   차이가 나오지 않으면 원인 미확정으로 기록한다.

## 최종 보고

- 새로 확인한 사실과 아직 남은 가설
- 수정 전후 대조 결과 및 모든 실패의 분류
- 실행 명령, 바이너리 해시, 재현 코드·로그 경로
- Java 원인 확정 여부와 추가 조사 필요성
- 임시 VM/daemon 정리 여부
- 코드나 문서 변경이 있다면 검증 결과와 commit/push 상태

기존 100회 통과를 다시 요약하는 것으로 조사를 끝내지 마라.
새로운 판별 증거가 없으면 “이번 조사로는 원인을 확정하지 못했다”고 명확히 보고하라.
