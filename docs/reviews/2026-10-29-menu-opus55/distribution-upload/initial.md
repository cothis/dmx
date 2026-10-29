## 일회성 소스 업로드 workflow 리뷰: needs-fixes

두 파일만 Read로 읽었고, 아무것도 실행하지 않았습니다. 고칠 결함이 하나 있습니다. 업로드가 확인한 draft의 ID가 아니라 tag 이름으로 대상을 찾습니다.

### 결함

**[P2] 업로드 대상을 tag 이름으로 찾아, 확인한 draft가 아닌 다른 release에 붙을 수 있습니다**
- 위치: `one-time-source-upload.yml:64`의 `gh release upload v0.4.0`.
- 문제: `:59-60`에서는 release ID `427835061`과 tag를 확인하지만, 실제 업로드는 tag 이름으로 대상을 다시 찾습니다.
  - `v0.4.0` tag에 이미 게시된 release가 있으면, gh는 tag endpoint로 그 release를 찾습니다.
  - 같은 tag를 가진 draft가 여러 개면, gh가 그중 하나를 고릅니다. 그게 427835061이라는 보장이 없습니다.
- 결과: 약 496MB 파일이 다른 release에 먼저 붙고, 그 뒤 `:65-67` 검증에서 실패합니다. 실패하지만 부작용은 이미 남았습니다. 최악의 경우 공개된 release에 asset이 추가됩니다.
- 최소 수정: 받아 온 `release['upload_url']`(ID에 묶인 주소)로 직접 올립니다. `{?name,label}` 부분을 떼고 `?name=dmx-sources-0.4.0.tar`를 붙여, `gh api --method POST -H 'Content-Type: application/x-tar' <url> --input dmx-sources-0.4.0.tar`로 보내면 됩니다.
- 함께 `:60`에 `release['draft'] is True` 검사를 추가해, 이미 게시된 release는 건드리지 않도록 막으세요.

### 이상 없음
- **YAML과 heredoc**: block scalar가 들여쓰기 10칸을 제거한 뒤에도 Python 들여쓰기(1~4칸)가 일관됩니다. 종료 표지 `PYCODE`는 0열에 오고, 따옴표로 감싼 delimiter라 셸 확장이 일어나지 않습니다. 2단계 heredoc은 `repack-public-sources.py`와 내용이 같습니다.
- **보안 경계**:
  - checkout과 외부 action이 없어 저장소 코드를 실행하지 않습니다.
  - `${{ }}` 표현식은 `github.token` 하나뿐이고 env로만 전달되므로, 스크립트 주입 경로가 없습니다.
  - 쓰기 권한은 수동 job 하나에만 있고, `main` 브랜치와 저장소 이름으로 실행 조건을 제한합니다.
  - `concurrency`로 동시 실행을 막습니다.
- **입력과 출력 검증**: 이전 공개 archive를 sha256으로 고정하고, https만 허용합니다(리다이렉트 포함). 결과물은 크기와 sha256이 모두 맞아야 다음 단계로 갑니다.
  - 파일과 디렉터리가 아닌 member(symlink나 hardlink)가 있으면 `assert`에 걸려 중단됩니다.
  - 불일치하면 업로드 전에 실패합니다.
- **멱등성**: 같은 이름의 asset이 이미 있으면 업로드를 건너뛰고, 크기, `uploaded` 상태, `digest`를 확인합니다. 값이 다르거나 `digest` 필드가 없으면 실패합니다. 어느 경우든 잘못된 asset을 정상으로 보고하지 않고 실패로 끝납니다.
- **소스 완전성**: GuestPin의 guest 파일 해시가 v0.3.12와 같으므로 guest 바이너리가 그대로이고, 대응 소스도 같다는 주장과 일치합니다. 최종 sha256 고정이 qualified archive와 바이트 단위로 같은지를 보장합니다.

### 참고 (결함 아님)
- **Python 버전**: `hashlib.file_digest` 때문에 Python 3.11 이상이 필요합니다. ubuntu-24.04 runner는 3.12라 충족합니다.
  - tarfile의 PAX 출력은 Python 버전마다 다를 수 있습니다. 로컬에서 바이트 일치를 확인한 Python이 3.12가 아니면 첫 실행이 sha 검사에서 실패할 수 있습니다. 이때도 업로드 전에 멈추므로 안전합니다.
  - 미리 Python 3.12로 같은 결과가 나오는지 확인해 두면 재실행을 피할 수 있습니다.
- **`assert` 사용**: 검증이 모두 `assert`라 `PYTHONOPTIMIZE`가 설정된 환경에서는 무력화됩니다. runner 기본값에서는 설정되지 않지만, 명시적인 `if`와 `sys.exit` 검사가 더 견고합니다.

**판정: needs-fixes.** 업로드를 ID에 묶인 `upload_url`로 바꾸고 draft 검사를 추가하면, 이 범위에서 남는 결함은 없습니다.
