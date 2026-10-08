# STT 회의록 자동화 프로젝트

로컬 ASR(Qwen3-ASR-1.7B) · 화자분리(pyannote) · LLM-Wiki 회의록 생성 파이프라인. 네이티브 SwiftUI macOS 앱이 녹음·세션·재생·worker 수명주기를 담당하고, `meeting_stt` Python 패키지가 전사와 회의록 생성을 담당한다.

## 디렉터리
- `macos/Sources/MeetingSTTApp/` SwiftUI 앱 · `meeting_stt/` Python worker와 CLI · `native/apptap.swift` 시스템/앱 출력 캡처 헬퍼 · `scripts/download_models.py` 모델 다운로드 · `build.sh` 통합 빌드(deps·apptap·app·icon·models) · `STT실행.app` 기본 런처 · `STT실행.command` 레거시 웹 런처 · `assets/` 아이콘 원본. `.env`·`models/`·`STT_env/`·`outputs/`는 로컬 런타임이며 Git에서 제외한다.
- **HF 토큰**: `.env`의 `HF_TOKEN` 또는 환경변수에서 읽음(`config.load_hf_token`). keys.json은 폐기(레거시 폴백만 유지).

## 하네스: STT 회의록 빌드

**목표:** SwiftUI macOS 앱과 `meeting_stt` Python worker/CLI를 기존 디스크 계약으로 연결해 로컬 회의 녹음·전사·회의록 워크플로우를 구현하고 유지보수한다.

**트리거:** STT 프로그램 구현·수정·재실행, SwiftUI 앱, ASR/화자분리/회의록 파이프라인, 녹음 세션·재생·나중 전사, 전사·요약 기능 추가/보완 요청 시 `stt-build-orchestrator` 스킬을 사용하라. 단순 개념 질문은 직접 응답 가능.

**범위 고정:** ASR은 **Qwen3-ASR-1.7B 단일**(Whisper 제외). 화자분리는 pyannote.

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-10-08 | 결과 복사 확인 토스트 | AppModel(`toast`, `showToast`: 2초 뒤 자동으로 사라짐 + VoiceOver 알림), ContentView(상세 화면 아래 overlay) | 사용자 요청: 복사했을 때 복사됐다는 표시가 로그 한 줄뿐이라 눈에 띄지 않음 |
| 2026-10-08 | 자식 프로세스 종료 대기 멈춤 수정 | ProcessRunner(`ProcessExit`: `waitUntilExit()` 대신 `run()` 전에 건 종료 핸들러 신호를 기다림 — `ProcessExecution.run`·`NativeRecording` 3곳), 믹서 테스트(짧은 프로세스 150회) | `scripts/test-recording.sh`가 가끔 끝나지 않음. GCD 스레드에서 부른 `waitUntilExit()`이 금방 끝나는 프로세스의 종료 알림을 놓침(20~50번에 한 번꼴). 앱의 녹음 합치기·전사 worker·apptap도 같은 경로 |
| 2026-10-08 | 녹음 중 마이크 장치 자동 전환 + `!dev` 정지 오류 수정 | DeviceRecorder(`VirtualInput`: WAV 하나를 유지하고 장치를 붙였다 뗌, 공백은 무음, 포맷이 다른 장치는 AudioConverter로 변환; 장치 목록·기본 입력 변화 감시 후 `reconcile`), AppModel(`microphoneNotice`), ContentView 경고, 믹서 테스트 | AirPods가 녹음 중 끊기자 정지 시 `OSStatus !dev`로 합치기가 건너뛰어져 세션이 오류 처리됨. 끊기면 기본 입력으로 넘어가고 돌아오면 복귀하도록 사용자 요청 |
| 2026-10-06 | 녹음 일시 정지/재개 | apptap(SIGUSR1/2 + `PAUSABLE` 핸드셰이크), DeviceRecorder·NativeRecorder(`setPaused`), AppModel(`togglePause`), RecordingMixer(`pauses` 보정), ContentView 버튼, 믹서 테스트 | 사용자 요청: 종료 전에 녹음을 멈췄다 이어가기. 정지 구간은 WAV에서 제외 |
| 2026-09-30 | 시스템 출력 + 마이크 기본 모드, host time 동기화, 원본 보존 및 WAV 합성 | AppModel·RecordingMixer·DeviceRecorder·ProcessRunner·apptap, 독립 녹음 테스트 | PID 선택 없이 회의 입출력 동시 녹음 |
| 2026-06-20 | 초기 구성 | 전체 (agents 4, skills 4) | - |
| 2026-06-20 | Whisper 제거, Qwen3 단일 모델 | 전 에이전트/스킬 | 사용자 피드백: 모델 둘 다 받을 필요 없음 |
| 2026-06-20 | 노트북 버그 수정 명시 | asr-diarization 스킬 | soundfile import 누락 등 |
| 2026-06-21 | 로컬 웹 대시보드 확장 | +agents 2(audio-capture, dashboard), +skills 2(audio-capture, web-dashboard), capture.py/server.py/web/ | 사용자 요청: 녹음·장치선택·전사보기 대시보드 |
| 2026-06-21 | 원클릭 런처 추가 | start-dashboard.command(macOS), start-dashboard.bat(Windows) | 사용자 요청: 파일 더블클릭 실행 |
| 2026-06-21 | 앱별 오디오 캡처(네이티브) | +skill native-audio-capture, native/apptap.swift(Core Audio Process Tap), capture.py(AppRecorder), server.py(app-sources), 대시보드 소스 선택 | 사용자 요청: 웹미팅 등 특정 앱 소리 녹음 |
| 2026-06-21 | 실환경 구축 + API 버그 수정 | Py3.12 venv + ASR스택 + ffmpeg + Qwen3-ASR 모델(4.4G), asr.py(initial_prompt→context), notes.py(None 폴백), test.ipynb/proven-code 동기화 | 실제 전사 동작 확인(한국어 정상). qwen-asr 0.0.6 실제 API는 context= 인자 |
| 2026-06-21 | 화자분리 gated 우회 + pyannote 4.x 대응 | config.DIARIZE_SOURCE=pyannote-community/speaker-diarization-community-1(비gated 미러), diarize.py(token=/DiarizeOutput/min_duration_off 방어), download_models.py | gated 약관 API 동의 불가 → MIT 미러로 우회. 2화자 분리 실측 성공 |
| 2026-06-21 | output 통합 + 음성 분리 + 디렉터리 정리 | 회의당 {stem}.md(전사+회의록 통합)+{stem}.json, 음성은 recordings/, clean-audio 명령 추가. notebooks/·scripts/·assets/ 폴더화. 런처 STT실행.command(아이콘) | 파일 산만함·2시간 음성 용량 → 텍스트/음성 분리로 삭제 용이 |
| 2026-06-21 | 빌드 통합 + 키 env화 + 윈도우 런처 제거 | build.sh 1개로 통합(native/build.sh·scripts/apply-icon.sh 흡수), HF토큰 .env(HF_TOKEN)로 이전+keys.json 삭제, STT실행.bat 삭제, requirements.txt를 실동작 venv freeze로 갱신 | 사용자 요청: .bat 제거·빌드 한 파일·키 env |
| 2026-06-25 | 시스템 전체 출력 캡처 + 녹음 하트비트 | apptap.swift(`record-system`=stereoGlobalTapButExcludeProcesses 전역탭 + 200ms RMS `LEVEL` stdout), capture.py(`SystemRecorder`/`_NativeRecorder`/`Recorder.level`/`buffered_bytes`), server.py(source=system, `GET /api/record/status`), web/index.html(🔊시스템출력 옵션·박동점·VU·기록량·무신호 경고, 400ms 폴링) | 사용자 피드백: 비슷한 프로세스명이 많아 앱 선택이 어려움 → 출력 전체 녹음 + 녹음 동작 확인용 하트비트 |
| 2026-06-27 | 영구 녹음 세션 워크플로우 반영 | dashboard/audio-capture agents, web-dashboard/audio-capture/stt-build-orchestrator skills, CLAUDE.md | 녹음을 `outputs/recordings/{timestamp_slug}/audio.wav`+`metadata.json`으로 저장하고 재시작 후 재생·미전사 목록·나중 전사를 지원 |
| 2026-07-03 | 대시보드 토스 스타일 리디자인 + 세션 관리 기능 | web/index.html(토스 스타일 라이트/다크·#3182F6·Pretendard·자체완결), server.py(`POST /api/recordings/{id}/rename`→metadata `name`, `DELETE /api/recordings/{id}`→폴더+transcript .md/.json 고아삭제, `_recording_payload`에 name 노출), 전사 복사 버튼(clipboard+폴백) | 사용자 요청: 전사 결과 복사·세션 이름 수정·세션 삭제 + 새 디자인 적용 |
| 2026-08-15 | 회의록 자동 요약(`--ai`) | notes.py(`generate_ai_notes`, `claude -p` 호출), cli.py(notes/run `--ai`), ContentView "AI 회의록" 버튼, tests/test_ai_notes.py | 요약이 수동(프롬프트 복붙)이었음. API 키 대신 기존 Claude Code 로그인 사용 |
| 2026-07-13 | SwiftUI 네이티브 앱 전환 | macos/MeetingSTTApp(AppModel·ContentView·SessionStore·ProcessRunner·DeviceRecorder), build.sh app, STT실행.app | 브라우저 없이 입력·시스템·앱 녹음, 세션, 재생, 전사와 회의록을 관리하고 기존 Python ML worker를 재사용 |

## 환경 현황 (2026-07-13)
- venv: `STT_env` (Python 3.12.13), ASR 스택(torch 2.12.1, qwen-asr 0.0.6, pyannote.audio 4.0.4) + 대시보드 의존성. ffmpeg 8.1.2.
- 모델: `models/Qwen3-ASR`(완료). 화자분리는 비-gated 미러 `pyannote-community/speaker-diarization-community-1`을 HF 캐시로 받음(약관 동의 불필요). 재다운로드: `STT_env/bin/python scripts/download_models.py`.
- **전사·화자분리·회의록 전부 실측 동작 확인**(2화자 A→B→A 정확 분리).
- 디바이스: CPU/float32. MPS 가용하나 pyannote 호환 위해 보류.
- gated 메모: pyannote 공식 모델은 약관 수동 동의 필요(API 동의 불가). MIT 라이선스라 자체완결 미러로 대체함.
- SwiftUI 앱 release 빌드와 ad-hoc 서명, 시스템 출력 LEVEL 실시간 전달, 앱·시스템 출력 WAV finalize를 확인함.
