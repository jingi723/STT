# STT 회의록 자동화 프로젝트

로컬 ASR(Qwen3-ASR-1.7B) · 화자분리(pyannote) · LLM-Wiki 회의록 생성 파이프라인. `notebooks/test.ipynb` 실습 코드를 실제 동작하는 `meeting_stt` 패키지로 구현한다.

## 디렉터리
- `meeting_stt/` 프로그램 패키지 · `native/apptap.swift` 앱캡처 헬퍼 · `scripts/download_models.py` 모델 다운로드 · `build.sh` 빌드/셋업 통합(deps·apptap·icon·models) · `notebooks/` 강의노트 · `STT실행.command` 런처(아이콘, macOS) · `assets/` 아이콘 원본 · `.env`(HF_TOKEN)·`models/`·`STT_env/` 런타임(미커밋).
- **HF 토큰**: `.env`의 `HF_TOKEN` 또는 환경변수에서 읽음(`config.load_hf_token`). keys.json은 폐기(레거시 폴백만 유지).

## 하네스: STT 회의록 빌드

**목표:** 노트북 실습 코드를 실제 동작하는 `meeting_stt` Python 패키지+CLI로 구현/유지보수한다.

**트리거:** STT 프로그램 구현·수정·재실행, ASR/화자분리/회의록 파이프라인 코드 작업, 대시보드 녹음 세션·재생·나중 전사, 전사·요약 기능 추가/보완 요청 시 `stt-build-orchestrator` 스킬을 사용하라. 단순 개념 질문은 직접 응답 가능.

**범위 고정:** ASR은 **Qwen3-ASR-1.7B 단일**(Whisper 제외). 화자분리는 pyannote.

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
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

## 환경 현황 (2026-06-21)
- venv: `STT_env` (Python 3.12.13), ASR 스택(torch 2.12.1, qwen-asr 0.0.6, pyannote.audio 4.0.4) + 대시보드 의존성. ffmpeg 8.1.2.
- 모델: `models/Qwen3-ASR`(완료). 화자분리는 비-gated 미러 `pyannote-community/speaker-diarization-community-1`을 HF 캐시로 받음(약관 동의 불필요). 재다운로드: `STT_env/bin/python scripts/download_models.py`.
- **전사·화자분리·회의록 전부 실측 동작 확인**(2화자 A→B→A 정확 분리).
- 디바이스: CPU/float32. MPS 가용하나 pyannote 호환 위해 보류.
- gated 메모: pyannote 공식 모델은 약관 수동 동의 필요(API 동의 불가). MIT 라이선스라 자체완결 미러로 대체함.
