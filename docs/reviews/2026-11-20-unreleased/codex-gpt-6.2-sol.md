`5cb05c3..HEAD`를 읽기 전용으로 검토했어요. 기존 볼륨이 덮어써지거나 삭제되는 경로, HTTPS 요청이 다른 컨테이너로 전달되는 경로, 서명 검증을 통과한 APK에 미검증 데이터가 포함되는 경로가 릴리스를 막아요.

커밋 의도와 `docs/PLAN.md`, `docs/docker.md`, `docs/names.md`를 대조했어요. `git diff --check`와 변경된 Python 스크립트의 구문 검사가 통과했고, 캐시에 있는 변경 APK 15개의 SHA-256이 핀과 일치했어요. 실 VM, 브라우저, launchd 통합 테스트는 이번 검토에서 재실행하지 않았어요.

## 가져오기

1. **blocker · 소스 엔진에 이미지와 파일을 남겨요.** 소스에 볼륨만 있고 이미지가 없으면, 복사용 Alpine을 소스에 pull한 뒤 그대로 남겨요. 이미지가 있더라도 선택된 이미지의 `/dmx-import`에 파일이 있고 소스 볼륨이 비어 있으면, dockerd의 볼륨 초기 복사가 헬퍼 생성 시 파일을 써요. `:ro`는 이 초기 복사를 막지 않아요. 두 경우 모두 소스의 영구 상태가 바뀌어요. [Import.swift:516](~/dev/dockermax/Sources/DMXCore/Import.swift:516) · [Import.swift:490](~/dev/dockermax/Sources/DMXCore/Import.swift:490) · [Moby 볼륨 초기화]​(https://github.com/moby/moby/blob/docker-v29.9.3/daemon/create_unix.go#L74-L126)

2. **blocker · 가져오기 도중 생긴 기존 대상 볼륨을 덮어쓰거나 삭제해요.** 대상 목록을 읽은 뒤 다른 import나 Compose가 같은 이름의 로컬 볼륨을 만들면, `POST /volumes/create`는 기존 볼륨을 성공으로 반환해요. import는 자신이 생성했다고 판단해 파일을 복사하고, 복사가 실패하면 그 볼륨을 삭제해요. 복사에 성공해도 같은 경로의 기존 파일이 덮어써져요. 이미지 태그도 최초 목록 확인과 `docker load` 사이에 같은 경쟁 조건이 있어요. [Import.swift:439](~/dev/dockermax/Sources/DMXCore/Import.swift:439) · [Import.swift:460](~/dev/dockermax/Sources/DMXCore/Import.swift:460) · [Import.swift:410](~/dev/dockermax/Sources/DMXCore/Import.swift:410) · [Moby 볼륨 생성]​(https://github.com/moby/moby/blob/docker-v29.9.3/daemon/volume/service/store.go#L563-L572)

3. **should fix · 복사에 실패한 이름 있는 볼륨을 빈 상태로 확정해요.** 볼륨 복사가 실패하고 롤백이 성공해도, 다음 단계에서 그 볼륨을 쓰는 컨테이너를 그대로 생성해요. dockerd는 마운트에 필요한 볼륨을 다시 만들고, 재실행하면 볼륨과 컨테이너가 모두 `exists`로 처리돼요. 일시적인 복사 실패 뒤 사용자가 그대로 컨테이너를 시작하면 원본 데이터 없이 실행돼요. [Import.swift:142](~/dev/dockermax/Sources/DMXCore/Import.swift:142) · [Import.swift:469](~/dev/dockermax/Sources/DMXCore/Import.swift:469) · [Import.swift:595](~/dev/dockermax/Sources/DMXCore/Import.swift:595)

4. **should fix · 익명 볼륨을 복사하지 않고 컨테이너를 남겨요.** `--volumes-from`과 자체 익명 볼륨을 함께 쓰는 컨테이너는 익명 볼륨 전체가 복사 대상에서 빠지고 `imported`로 표시돼요. 별개로, 컨테이너 생성 직후 inspect 요청이 실패하거나 대상 마운트가 누락되면 볼륨만 `failed`로 기록하고 `copied`를 그대로 둬요. 두 경로 모두 데이터가 빠진 컨테이너가 남고 재실행 시 `exists`로 건너뛰어요. [Import.swift:755](~/dev/dockermax/Sources/DMXCore/Import.swift:755) · [Import.swift:607](~/dev/dockermax/Sources/DMXCore/Import.swift:607) · [Import.swift:631](~/dev/dockermax/Sources/DMXCore/Import.swift:631)

5. **should fix · 정리 오류가 양쪽 엔진에 헬퍼를 남겨요.** 복사 후 소스 `rm`이 실패하면 대상 `rm`으로 진행하지 않아요. 대상 헬퍼가 볼륨을 잡고 있어 롤백 삭제가 409를 반환할 수 있고, 그 상태 코드는 무시돼요. 마지막 정리가 뒤늦게 헬퍼를 삭제해도 볼륨 삭제는 재시도하지 않아요. 마지막 정리 중 엔진에 연결할 수 없으면 헬퍼도 남고, 다음 import는 새 라벨을 써서 이전 헬퍼를 찾지 않아요. [Import.swift:469](~/dev/dockermax/Sources/DMXCore/Import.swift:469) · [Import.swift:505](~/dev/dockermax/Sources/DMXCore/Import.swift:505) · [Import.swift:641](~/dev/dockermax/Sources/DMXCore/Import.swift:641)

6. **should fix · `--dry-run`이 VM과 워크로드를 시작할 수 있어요.** dmx가 정지된 상태에서 dry run을 하면 대상 `/info` 조회가 일반 Docker 소켓에 연결돼요. 이 연결은 VM과 dockerd를 시작하고, 저장된 재시작 정책에 따라 컨테이너도 시작할 수 있어요. 소스가 소켓 활성화 엔진이면 최초 `/_ping` 조회도 그 엔진을 깨울 수 있어요. [Import.swift:104](~/dev/dockermax/Sources/DMXCore/Import.swift:104) · [Import.swift:119](~/dev/dockermax/Sources/DMXCore/Import.swift:119) · [Import.swift:135](~/dev/dockermax/Sources/DMXCore/Import.swift:135) · [Docker.swift:289](~/dev/dockermax/Sources/DMXCore/Daemon/Docker.swift:289)

## Docker 소켓 HTTP

7. **should fix · 완전한 chunked 응답도 연결이 열려 있으면 타임아웃돼요.** 엔진이 마지막 청크와 트레일러까지 보내고 연결을 유지하면, `call`은 EOF나 64 MiB까지 읽은 뒤에야 디코더를 호출해요. 작은 정상 응답을 받은 뒤에도 import가 타임아웃될 수 있어요. 반대로 응답이 일찍 끊기면 `Content-Length` 미달과 종료 청크 누락을 오류로 처리하지 않아요. 잘못된 JSON이 `.null`로 바뀌면 import가 대상 목록을 비어 있다고 판단할 수 있어요. [DockerAPI.swift:198](~/dev/dockermax/Sources/DMXCore/Sandbox/DockerAPI.swift:198) · [DockerAPI.swift:244](~/dev/dockermax/Sources/DMXCore/Sandbox/DockerAPI.swift:244) · [Import.swift:221](~/dev/dockermax/Sources/DMXCore/Import.swift:221) · [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html#section-7.1)

8. **should fix · 잘못된 청크 길이가 CLI 또는 MCP 프로세스를 종료시켜요.** 선택한 소켓이 음수 청크 길이를 반환하면 `Int(..., radix: 16)`이 이를 받아들이고, 남은 길이 검사도 통과해요. 역방향 범위로 `Data`를 자르는 곳에서 Swift가 트랩하므로 `DMXError`와 정리 경로를 건너뛰어요. [DockerAPI.swift:220](~/dev/dockermax/Sources/DMXCore/Sandbox/DockerAPI.swift:220)

## 로컬 이름

9. **blocker · 다른 컨테이너가 원래 이름의 HTTPS 요청을 받아요.** 실행 중인 A를 네트워크에서 분리하고, 이미 실행 중인 B가 그 IP를 사용하게 하면 dmx의 라우팅 테이블이 갱신되지 않아요. 구독 필터가 컨테이너 `start`와 `die`만 받아 네트워크 `disconnect`와 `connect`를 놓쳐요. 프록시는 계속 A의 인증서로 TLS를 종료하고 B에게 요청을 보내므로, A의 쿠키나 인증 헤더가 B에게 전달될 수 있어요. [Docker.swift:417](~/dev/dockermax/Sources/DMXCore/Daemon/Docker.swift:417) · [NamesService.swift:255](~/dev/dockermax/Sources/DMXCore/Names/NamesService.swift:255) · [Docker 이벤트 유형](https://docs.docker.com/reference/cli/docker/system/events/#networks)

10. **blocker · 신뢰된 CA의 제한이 IP 주소 인증서를 막지 않아요.** CA는 `dNSName`만 제한해요. `ca.key`가 유출되면 IP SAN만 있는 서버 인증서는 그 제한을 통과할 수 있어요. Apple의 공개 검증 코드에서도 같은 이름 형식의 제약이 없으면 허용해요. 따라서 키가 유출돼도 `dmx.local` 밖을 보증할 수 없다는 문서의 약속이 성립하지 않아요. 설치된 macOS와 브라우저에서의 최종 신뢰 판정은 재현하지 않았어요. [NameCertificates.swift:35](~/dev/dockermax/Sources/DMXCore/Names/NameCertificates.swift:35) · [Apple 이름 제약 검증]​(https://github.com/apple-oss-distributions/Security/blob/main/trust/trustd/nameconstraints.c#L466-L491) · [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280.html#section-4.2.1.10)

11. **should fix · 컨테이너가 호스트 루프백을 경유해 다른 Docker 네트워크에 접근해요.** names가 켜진 상태에서 일반 컨테이너가 `host.docker.internal`의 names 포트에 접근하면, NAT가 연결을 Mac의 `127.0.0.1`로 보내 루프백 검사를 통과시켜요. 이름이 일치하면 게스트 에이전트가 대상 IP에 연결해요. 이 경로를 통해 다른 브리지의 컨테이너가 포트를 게시하지 않은 `--internal` 네트워크의 웹 서비스에도 접근할 수 있어요. [UserNet.swift:108](~/dev/dockermax/Sources/DMXCore/HV/UserNet.swift:108) · [NamesService.swift:200](~/dev/dockermax/Sources/DMXCore/Names/NamesService.swift:200) · [NamesService.swift:266](~/dev/dockermax/Sources/DMXCore/Names/NamesService.swift:266) · [Docker 내부 네트워크](https://docs.docker.com/reference/cli/docker/network/create/#network-internal-mode---internal)

12. **should fix · HTTPS가 리스너와 FD를 계속 보유해요.** 유효한 새 `dmx.local` SNI를 받으면 등록된 컨테이너가 없어도 이름마다 인증서와 `NWListener`를 만들고 데몬에 보관해요. 상한과 만료가 없어요. 또 `NWConnection`이 `.ready` 전에 `.failed`로 끝나는 경우, 펌프는 `shutdown`만 해요. FD를 닫는 `end()`를 호출할 양쪽 작업이 시작되지 않은 상태라 FD가 남는 경로예요. 실패 콜백의 실제 순서는 macOS 실기 확인이 필요해요. [NamesService.swift:294](~/dev/dockermax/Sources/DMXCore/Names/NamesService.swift:294) · [NamesService.swift:318](~/dev/dockermax/Sources/DMXCore/Names/NamesService.swift:318) · [NamesService.swift:474](~/dev/dockermax/Sources/DMXCore/Names/NamesService.swift:474)

13. **should fix · 별도 `DMX_HOME`의 제거 명령이 실제 Mac의 resolver를 지워요.** 기본 환경에서 names를 설정한 뒤, 별도 환경에서 `setup --no-system`과 `names remove`를 실행하면 remove가 시스템 설정 여부를 확인하지 않고 전역 파일의 헤더만 검사해요. 관리자 승인을 받으면 기본 환경의 `/etc/resolver/dmx.local`을 삭제해요. `make namestest`도 이 제거 경로를 사용해요. [NamesSetup.swift:86](~/dev/dockermax/Sources/DMXCore/Names/NamesSetup.swift:86) · [test-names.py:243](~/dev/dockermax/scripts/test-names.py:243)

## 크래시 복구, 게스트, 빌드

14. **should fix · 첫 컨테이너 시작 직후의 크래시가 자동 재부팅을 건너뛸 수 있어요.** 마지막 목록이 비어 있는 상태에서 컨테이너가 시작하고, 새 목록이 도착하기 전에 Docker 연결과 VM이 끊기면 `watch`가 읽는 마지막 카운트는 0이에요. 실패한 재조회가 먼저 `listingUnknown`을 세워도 `dockerdStopped()`가 이를 초기화할 수 있어요. 시작 기록이 이미 디스크에 남았어도 다음 클라이언트가 올 때까지 VM이 정지해요. [Docker.swift:420](~/dev/dockermax/Sources/DMXCore/Daemon/Docker.swift:420) · [Docker.swift:432](~/dev/dockermax/Sources/DMXCore/Daemon/Docker.swift:432) · [Daemon.swift:484](~/dev/dockermax/Sources/DMXCore/Daemon/Daemon.swift:484)

15. **should fix · `on-failure:N`의 재시도 한도를 무시해요.** `on-failure:1` 컨테이너가 한 번 재시작한 뒤 다시 실패해 멈추면, 에이전트는 비정상 종료 코드만 보고 boot 시 dockerd를 띄워요. 고정된 Moby 29.9.3은 저장된 `RestartCount`가 `MaximumRetryCount`에 도달하면 컨테이너를 재시작하지 않아요. 그런 컨테이너만 있는 VM에서도 dockerd와 containerd의 메모리 비용이 발생해요. [docker.rs:232](~/dev/dockermax/guest/agent/src/docker.rs:232) · [Moby 복원 로직]​(https://github.com/moby/moby/blob/docker-v29.9.3/daemon/daemon.go#L520-L544) · [Moby 재시도 한도]​(https://github.com/moby/moby/blob/docker-v29.9.3/daemon/internal/restartmanager/restartmanager.go#L74-L85)

16. **blocker · APK 검증기가 빌드에서 읽는 바이트를 전부 인증하지 않아요.** 유효하게 서명된 세 gzip 멤버 뒤에 추가 gzip 멤버가 있는 APK를 검사하면, 검증기는 앞의 세 멤버만 검증하고 전체 파일의 SHA-256을 출력해요. 그 해시를 핀으로 채택하면 `build-guest.py`는 연결된 gzip 스트림을 `ignore_zeros=True`로 읽어 추가 tar 엔트리도 패키징할 수 있어요. 현재 캐시의 해시 일치는 확인했으며, 결함은 새 핀을 검증하는 경로에 있어요. [verify-apk.py:42](~/dev/dockermax/scripts/verify-apk.py:42) · [verify-apk.py:56](~/dev/dockermax/scripts/verify-apk.py:56) · [build-guest.py:333](~/dev/dockermax/scripts/build-guest.py:333)

17. **should fix · `dmx bench` 실패 정리가 기존 컨테이너를 강제 삭제할 수 있어요.** PID 재사용 등으로 대상 엔진에 같은 벤치마크 이름의 컨테이너가 이미 있으면 `docker run --name`은 충돌로 실패해요. 이후 정리는 생성 성공 여부나 컨테이너 ID 확인 없이 같은 이름에 `rm -fv`를 실행해 기존 컨테이너와 익명 볼륨을 삭제할 수 있어요. [Bench.swift:192](~/dev/dockermax/Sources/DMXCore/Bench.swift:192) · [Bench.swift:227](~/dev/dockermax/Sources/DMXCore/Bench.swift:227) · [Bench.swift:245](~/dev/dockermax/Sources/DMXCore/Bench.swift:245)

RELEASE BLOCKERS
