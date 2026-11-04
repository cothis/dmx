## 판정: 승인 (이 마지막 변경분 한정)

**중간 심각도 이상의 결함은 찾지 못했어요.** 코드를 읽어 판단한 정적 리뷰이고, 빌드와 실행은 하지 않았어요. 검토 모델은 Opus 5.5(`claude-opus-5-5`)예요.

## 변경분 존재 확인
세 변경 모두 아래 세 곳에서 확인했어요.
- **스냅샷:** `.build/review/fex`의 `OpcodeDispatcher.cpp:3722-3738`, `:3800-3842`, `RedundantFlagCalculationElimination.cpp:324`, `SignalDelegator.cpp:1058-1060`
- **실제 패치 원본:** `scripts/build-fex.py:1541-1709`, `:1765`, `:2429-2430`. `RaiseDivideErrorIf`와 `IDIV` 부분은 스냅샷과 같았어요.
- **`canonical-fex-source`:** 대표 행의 번호와 내용만 대조했어요.

## 확인한 내용

**`IDIV r/m64` 산술**
- **크기 계산:** 음수 피제수의 올림 계산이 맞고, `-2^127`은 크기 `2^127`로 넘침 없이 계산돼요. 제수 `INT64_MIN`의 크기 `2^63`도 맞아요.
- **첫 검사:** `|상위| >= |제수|`는 제수 0과 몫 `>= 2^64`를 정확히 잡아서, 나눗셈 전에 몫이 64비트에 들어감을 보장해요.
- **둘째 검사:** 한계가 양수 결과는 `2^63-1`, 음수 결과는 `2^63`이에요. `2^63 / -1`은 통과하고 `2^63 / 1`은 fault가 나요.
- **결과 부호:** 몫 0은 음수 처리 뒤에도 0이고, 나머지 부호는 피제수를 따라요.
- **`DivideBlock`:** 제수 0과 최솟값/-1 외에는 JIT의 `sdiv` 경로로만 가요. `LDIV`로는 가지 않아요.
- **레지스터 재사용:** 제수는 경로마다 한 번만 읽고, 결과 저장보다 먼저 읽어요. 그래서 메모리 제수의 base가 `RAX`나 `RDX`여도, `idivq %rdx`여도 안전해요.

**블록 경계**
- `Quotient`, `Remainder`, `Divisor`, `Lower`, `Upper`와 상수는 모두 쓰는 블록 안에서 정의돼요.
- `CondJump`는 `cbnz`로 내려가고 NZCV를 건드리지 않아요.
- `BreakIfNonZero`는 `IsBlockExit`에 포함되지 않아 블록 중간에 있어도 돼요.

**NZCV와 fault 프레임**
1. `_Select`가 `SaveNZCV`로 게스트 NZCV를 GPR에 저장해요.
2. `CalculateDeferredFlags`가 `_StoreNZCV`로 복원한 뒤 분기해요.
3. `FLAG_ALL`이 이 복원과 PF·AF 저장이 제거되지 않게 지켜 줘요. 패스의 제거 로직에도 걸리지 않아요.
4. 뒤따르는 `SpillStaticRegs`는 NZCV를 바꾸지 않고 저장만 해요.

`LUDIV` 호출 구간도 Spill/Fill 기본값(`NZCV {true}`)으로 보존돼서, 둘째 검사의 fault 플래그도 맞아요.

**x87 동기화**
- `OP_SYNCSTACKTOSLOW`는 원본에 "FastPath를 벗어나지 않는다"고 명시돼 있고, `SynchronizeStackValues()`와 `FlushCachedRegs()`를 함께 호출해요.
- `TopOffset`만 0으로 되돌리므로 이후 push, pop과 블록 끝의 재동기화도 맞아요. `fld1` → 동기화 → `fstp` 순서로 TOP과 태그를 직접 따라가 확인했어요.
- 삽입되는 연산 중 NZCV를 바꾸는 것은 없어요.
- `HasX87`는 방출 순서 기준이지만, 패스가 IR 블록마다 끝에서 동기화하므로 빠지는 경우가 없어요.

**`ExitBlock`과 시그널 경로**
- **`ExitBlock`:** 두 경로 모두 `Jump`에서 플러시하고 `CFInverted`를 ABI 값으로 맞춰서 들어와요. `StartNewBlock`이 NZCV 캐시, 세그먼트 검사 상태, MMX 상태를 다시 초기화해요.
- **`Select` 인라인:** `Interface` 아래에 `OP_SELECT` 특수 처리가 없어요. 상수와 레지스터가 섞인 `Select`는 JIT의 인라인 상수 경고에 걸리지 않고 `csel`로 내려가요.
- **시그널:** `signal(SIG_DFL)` → unblock → `tgkill` 순서라 차단된 fault도 프로그램을 끝내요. `SIGFPE`의 기본 동작도 `DEFAULT_COREDUMP`로 등록돼 있어요.

## 차단 사유가 아닌 참고 사항
1. **낮음, 확신 중간:** 상속된 `SIGFPE = SIG_IGN`에서는 종료되지 않고 무한 반복할 수 있어요.
   - **순서:** 게스트가 핸들러를 설치하면 `OldAction`에 `SIG_IGN`이 저장돼요(`SignalDelegator.cpp:1155`). 이후 `SIGFPE`를 막고 0으로 나누면 `:1032`에서 아무것도 하지 않고 반환해요.
   - **결과:** 같은 `hlt`로 돌아가 `SIGILL`이 반복될 것으로 봐요. 흔치 않은 조건이라 차단 사유로 보지 않았고, 실행으로 확인하지도 않았어요.
2. **테스트 공백:** `div-fault` 픽스처에 아래 경우가 없어요. 코드상으로는 맞지만 회귀를 막아 주지는 못해요.
   - `LongBlock`에서 음수 피제수의 0이 아닌 나머지
   - `LongBlock`의 첫 검사 fault와 제수 0
   - 제수 `INT64_MIN`
   - `idivq (%rdx)`처럼 base가 `RDX`나 `RAX`인 메모리 제수
   - x87 값이 있는 상태에서 fault 없이 계속 가는 경로
   - `LUDIV` 뒤 둘째 검사 fault의 플래그
3. **업스트림 정책:** `canonical-fex-source/CLAUDE.md`에 FEX 기여 코드에 AI 생성을 쓰지 말라고 적혀 있어요. 이번 리뷰에는 해당하지 않지만, 이 패치를 FEX에 올릴 계획이면 먼저 확인해야 해요.

## 근거의 한계
- **산술 검증:** 경계값을 손으로 유도했어요. Codex가 보고한 전수 대조(299,584건 등)는 다시 돌리지 않았어요.
- **원본 대조 범위:**
  - **직접 읽음:** `canonical-fex-source`에서 x87 패스, `Arm64Emitter.h`의 Spill/Fill 옵션
  - **Codex 로그 발췌로만 읽음:** `delta-codex.err`의 JIT `Div`/`UDiv`/`Select`, `CalculateDeferredFlags`, `LUDIV`, EFLAGS 복원
  - **미확인:** 이 트리와 고정 tar의 일치, RA와 JIT 블록 배치 코드 전체(기존 다중 블록 연산과 같다고 판단)
- **실행 기록:** `.build/qual/x86test.log`에 `fex.div_fault` 통과가 있고, 에뮬레이터는 `summary.txt`의 `fb3b0acde0a8`이에요. 다만 이 기록이 이번 스냅샷의 빌드인지는 확인하지 못해서 승인 근거에 넣지 않았어요.
- **검토 범위:** 지정된 세 변경과 그 주변만 봤어요. `Daemon.swift` 등 다른 미커밋 변경과 패치의 나머지 부분은 보지 않았어요.
