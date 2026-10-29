## 일회성 소스 업로드 workflow 재리뷰: approve

수정된 `one-time-source-upload.yml`만 Read로 읽었고, 아무것도 실행하지 않았습니다. 남은 코드 결함은 찾지 못했습니다.

### 지난 지적 해결 확인
- **ID에 묶인 업로드**:
  - `:59`에서 ID `427835061`로 release를 가져옵니다.
  - `:60`에서 id, tag, `draft is True`를 모두 확인합니다.
  - `:64-66`은 그 release의 `upload_url`에서 템플릿 부분을 떼어 고정 주소 `uploads.github.com/repos/cothis/dmx/releases/427835061/assets`와 일치하는지 확인한 뒤, 그 주소로만 POST합니다.
  - 따라서 tag 이름으로 다른 release를 찾을 경로가 없어졌고, 게시된 release는 처음부터 거부됩니다.
- **`assert` 무력화 방지**: 두 Python 실행 모두 `python3 -I`(`:27`, `:55`)라 `PYTHONOPTIMIZE`를 포함한 `PYTHON*` 환경변수를 무시합니다. 따라서 `assert` 검증이 유지됩니다.

### 다시 확인한 사항 (이상 없음)
- **heredoc**: 들여쓰기와 종료 표지 `PYCODE`가 올바르고, 따옴표 delimiter라 셸 확장이 없습니다.
- **실패 처리**: `check_output`은 gh가 실패하면 예외를 던져 step이 실패합니다. 업로드 후 다시 가져와 크기, `uploaded` 상태, `digest`를 확인합니다(`:67-69`). 중간 상태 asset이 남거나 `digest` 필드가 없어도 잘못된 asset을 정상으로 보고하지 않고 실패로 끝납니다.
- **보안 경계**: checkout과 외부 action 없음, 실행 조건 제한(수동 실행, 저장소, `main`), job 단위 `contents: write`, `concurrency`, 이전 archive와 결과물의 sha256 고정. 모두 이전 검토와 같습니다.

### 참고 (결함 아님)
- 업로드 중간에 실패하면 asset이 중간 상태로 남을 수 있습니다. 이 경우 재실행해도 `:69`에서 실패하므로, 수동으로 asset을 지운 뒤 다시 실행해야 합니다.
- 실행 전에 남은 일은 코드가 아니라 절차입니다.
  - "No GitHub CI" 원칙의 예외에 대한 사용자 승인이 아직 없습니다.
  - 업로드 후 workflow 파일을 제거해야 합니다.

**판정: approve.** 단, 실제 실행은 사용자 승인 이후입니다.
