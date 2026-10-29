## Opus 5.5 최종 검증: dmx 메뉴 앱 (index tree `fde17c1`)

**결론: 코드 게이트 approve.** 승인한 `ca3cedf` 이후의 변경 세 가지에서 새 코드 결함이나 정확성 회귀를 찾지 못했습니다. 이전 리뷰에서 지적한 코드 결함은 모두 해결됐습니다.

검토는 `final.diff`, `final-source/`, `final-evidence/`만 Read/Grep으로 읽었고, 명령이나 테스트는 하나도 실행하지 않았습니다.

### 변경 확인
1. **첫 render 위치 이동** (`Sources/DMXApp/main.swift`)
   - 이제 `render()`는 `startup` Task를 할당한 뒤, `start()`의 맨 끝에서 호출됩니다.
   - `start()`는 main actor에서 동기로 실행되므로, Task 본문보다 render가 먼저 실행되고 이때 `startup != nil`입니다. 그래서 시작 중에 Retry가 잘못 보이던 P3가 해소됩니다.
   - observer 생성이 실패하는 조기 return 경로는 `fail()`이 직접 render하므로 화면 갱신이 빠지지 않습니다.
   - 다른 상태 전이는 바뀌지 않았습니다.
2. **GuestPin** (`Sources/DMXCore/GuestPin.swift:5-8`)
   - tag, archive 이름, 크기, archive sha256만 v0.4.0으로 바뀌었습니다.
   - 안의 `Image`, `docker.img`, `initramfs.gz`, `manifest.json` 해시는 그대로입니다. 따라서 guest 내용은 바뀌지 않았고, archive만 다시 패키징된 것과 일치합니다.
3. **`scripts/test-app-identity.py`**
   - 서명 주체가 없는(ad-hoc) CLI로 Developer ID 앱을 덮어쓰려 하면 `update_unsigned`로 거부되고, 거부된 helper가 실행되지 않는지(marker 파일이 생기지 않는지)를 검사합니다.
   - 같은 fixture가 `--allow-signing-change`를 줄 때만 실행되는지 대조 검사도 합니다.
   - 설계가 올바르고, 기록된 결과(`app-identity.log`)도 성공입니다.

### 확인한 증거 (기록된 결과이며, 제가 실행한 것은 아님)
- **menutest** (`round4-menutest.log`): 다음 항목을 포함해 전부 ok입니다.
  - `passive_overlap_ack`
  - `active_completion_sets_idle_epoch_under_passive_lease`: idle 정지까지 2초 남음, idle_timeout은 3초
  - `menu_cannot_boot_idle_vm`
  - `guest_poweroff_reported_as_failure`
  - `MenuEngineVMTests`도 통과했습니다.
- **서명된 installer** (`signed-installer.json`):
  - 설치기 하나로 앱, CLI, Docker 도구가 설치되고 엔진은 시작되지 않았습니다.
  - `codesign --verify`, `stapler validate`, `spctl` 검사가 모두 통과했고, `spctl` 결과는 "Notarized Developer ID"입니다.

### 남은 작업 (코드 결함 아님)
- **최종 재패키징**: 서명·공증된 archive는 render 위치를 옮기기 전에 만든 것입니다. 태그 전에 최종 소스로 다시 패키징하고 서명·공증해야 하며, 그 archive로 `codesign`, `stapler`, `spctl` 검사와 install.sh 왕복을 다시 해야 합니다.
- **최종 소스 대상 재실행**: app, selftest, daemon, MCP, menu 테스트를 최종 소스로 다시 돌리는 중입니다. 결과는 아직 받지 못했습니다.
- **게시 후 검증**: 공개 asset을 실제로 내려받아 확인하는 작업은 아직 일어나지 않았습니다.
- **알려진 증거 한계**:
  - 시작 완료 직전에 stopped가 끼어드는 경우는 단위 모델로만 검증됐고, 실제 GUI에서 그 순서가 재현된 적은 없습니다.
  - 컨테이너 Start/Stop과 Quit의 직접 클릭은 windowless 자동화로 수행할 수 없어 하지 않았습니다. 해당 코드 경로에서 결함은 찾지 못했지만, 이 부분은 수동 육안 확인 항목으로 남습니다. 이 문제는 코드를 바꿔서 해결할 수 있는 것이 아닙니다.

### 게이트
- **코드 게이트: approve.**
- **릴리스 게이트: 위 남은 작업을 마친 뒤 판단.**

이번 검토로 모든 결함을 찾았다고 보장하지는 않습니다.