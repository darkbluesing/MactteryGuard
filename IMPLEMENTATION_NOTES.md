# MactteryGuard Step 2 — 구현 노트

구현 완료일: 2026-11-16 (VM에서 작성, Xcode 미보유로 컴파일 미검증)
버전: 0.2.0 (MARKETING_VERSION 0.2.0, CURRENT_PROJECT_VERSION 2)
설계 근거: `STEP2_DESIGN.md` §0–§14 + `BATT_NATIVE_RESEARCH.md`
사용자 결정: §14 10개 항목 전부 반영 (§14.9의 "앱 종료 후에도 데몬 유지"가
§9.1 초안의 "XPC 24시간 단절 시 자동 해제"보다 우선한다 — 후자는 미구현).

> ⚠️ **이 VM에는 Xcode가 없어 컴파일 검증을 못 했다.**
> 대신 Swift 파일 22개를 전수 수동 리뷰했고, 리뷰에서 컴파일 에러 6건을
> 찾아 고쳤다 (아래 "수동 리뷰에서 찾아 고친 것" 참조).
> 그래도 첫 Mac 빌드에서 문법·API 오류가 나올 수 있다 — 아래
> "실기 검증 필요 항목"의 체크리스트 순서대로 확인하면 된다.

## 1. 구현 내용

### 아키텍처

```
MactteryGuard.app (메뉴바 UI, 사용자 권한)
  └─ XPC (mach 서비스 com.loveaimg.mactteryguard.helper, JSON Data)
MactteryGuardHelper (LaunchDaemon, root, SMAppService 등록)
  ├─ Native 백엔드: PowerUI 슬라이더 API (80–100%) + 설정 경로 (80% 미만)
  ├─ Adapter 백엔드: SMC CHIE 토글 (폴백 + 보정 후 되돌리기)
  └─ 제어 루프: 10초 틱, 60초 재조정, 히스테리시스, FAIL-OPEN
```

- **앱은 절대 쓰지 않는다.** 모든 충전 제어 쓰기는 root 데몬만 수행한다.
- **데몬은 앱이 꺼져 있어도 동작한다.** 설정은 데몬이
  `/Library/Application Support/MactteryGuard/settings.json`에 저장하고,
  앱 종료 후에도 마지막 유효 설정으로 무기한 제어한다 (§14.9).
- **보정 중에는 절대 쓰지 않는다.** notify + OSLogStore + 관찰 3경로로 감지하고,
  메뉴바·팝오버에 "macOS 보정 중"을 표시한다 (§14.7).

### 기능 — §14 결정과 대응

| §14 결정 | 구현 |
| --- | --- |
| 1. 기본 상한 80% | `GuardSettings.upperLimit = 80` |
| 2. 히스테리시스 limit−5% | `lowerOffset = 5` 고정, 하한 = 상한 − 5 |
| 3. 유료 Developer 계정 없음 | CODE_SIGN_STYLE Automatic, DEVELOPMENT_TEAM 미설정 (개인 ID 서명) |
| 4. GitHub 오픈소스 MIT, .dmg/.zip, Gatekeeper 우회 안내 | `LICENSE`, `Packaging/package.sh`, README |
| 5. 슬라이더 50–100%, 80% 미만 경고 문구 | PopoverView 슬라이더 + 지정 문구 그대로 표시 |
| 6. 강제 방전 기본 OFF + 사이클 경고 | 기본 false, 켤 때만 확인 얼럿 |
| 7. "macOS 보정 중" 표시 + 사이클·상태·온도 | 메뉴바 라벨, 팝오버 배너·상세 행 |
| 8. 로그 `~/Library/Logs/MactteryGuard/`, 30일 보관, 열기 버튼 | 날짜별 파일, 30일 지난 파일 자동 삭제, 팝오버 버튼 |
| 9. 앱 종료 후에도 데몬 유지 (기본), 해제 토글 | `releaseOnQuit` 기본 false |
| 10. Top Up 버튼, 100% 후 어댑터 재연결 또는 시간 경과 시 복귀 | 복귀 시간 24시간(기본값, 설정 저장됨) |

### 파일 목록 (22개 Swift 파일, 총 ~3,970줄)

**Shared/ — 앱·데몬 공용 (양쪽 타깃에 컴파일)**
| 파일 | 내용 |
| --- | --- |
| `GuardTypes.swift` | 계약: 상수, GuardSettings, BackendKind/ControlState/TopUpState, BatteryReading, DaemonState, XPC 프로토콜, GuardXPCError |
| `GuardLogger.swift` | 날짜별 로그 파일 + 30일 자동 삭제 (앱 `mactteryguard-*.log`, 데몬 `helper-*.log`) |
| `SMCClient.swift` | AppleSMC 최소 클라이언트 (KeyInfo/읽기/쓰기/read-back, 80바이트 버퍼) + SMCTemperature 디코딩 |
| `BatteryReader.swift` | IOPS + IORegistry + SMC 폴백 체인 (사이클·상태·온도, 단위 변환·plausibility 검증) |

**MactteryGuard/ — 앱 UI (Step 1 파일 포함 7개)**
| 파일 | 내용 |
| --- | --- |
| `MactteryGuardApp.swift` | MenuBarExtra + AppDelegate(종료 시 releaseOnQuit 처리, 2초 타임아웃) |
| `AppState.swift` | 상태 허브: 10초 폴링, 설정 디바운스 전송, 등록·Top Up·제거 액션 |
| `AppSettings.swift` | UserDefaults 설정 (`bg.*` 키 5개) |
| `DaemonClient.swift` | XPC 클라이언트 (6개 메서드 async 래핑) |
| `DaemonRegistration.swift` | SMAppService 등록 래퍼 |
| `BatteryMonitor.swift` | Step 1 모니터 + 사이클·상태·온도 (BatteryReader 위임) |
| `PopoverView.swift` | 320pt 팝오버: 보정 배너, 슬라이더, Top Up, 강제 방전, 데몬 상태, 설정 |

**MactteryGuardHelper/ — 특권 데몬 (11개)**
| 파일 | 내용 |
| --- | --- |
| `main.swift` | 진입점: 로거·저장소·엔진·XPC 시작, 시그널 FAIL-OPEN 복원 |
| `ControlEngine.swift` | 제어 루프 + 상태 머신 (10초 틱, 60초 재조정, 보정·되돌리기·Top Up) |
| `ChargeBackend.swift` | 백엔드 프로토콜 + UnavailableBackend 스텁 |
| `NativeBackend.swift` | PowerUI 슬라이더 + 설정 경로, 원래 값 저장·복원, pmset 등록 확인 |
| `PowerUIClient.swift` | 비공개 PowerUI 프레임워크 클라이언트 (dlopen + IMP 캐스트) |
| `AdapterBackend.swift` | CH0I/CH0J/CHIE 토글, 안전 가드(10% 하한·클램셸·수면 복원) |
| `CalibrationDetector.swift` | notify 1차 + OSLogStore 2차 보정 감지 |
| `SleepWakeMonitor.swift` | IORegisterForSystemPower 수면/복귀 알림 |
| `PmsetParser.swift` | `pmset -g battlimit` 실행·파싱 |
| `DaemonStore.swift` | settings.json / originals.json / shadow.json |
| `XPCService.swift` | NSXPCListener + 프로토콜 구현 (전부 MainActor 태스크 경유) |

**그 외**
| 파일 | 내용 |
| --- | --- |
| `MactteryGuard.xcodeproj/project.pbxproj` | 헬퍼 타깃 + Shared 그룹 + 임베딩 스크립트 단계 추가 (아래 참조) |
| `Packaging/com.loveaimg.mactteryguard.helper.plist` | LaunchDaemon plist (Label, BundleProgram, RunAtLoad, KeepAlive, MachServices) |
| `Packaging/package.sh` | Release 빌드 → `dist/MactteryGuard-<버전>.zip` + `.dmg` (헬퍼 임베딩 검증 포함) |
| `LICENSE` | MIT (Copyright 2026 loveaimg) |
| `README.md` | 한국어: 기능, 빌드, 데몬 등록, Gatekeeper 우회, 로그, 문제 해결, 수동 제거 |

### pbxproj 변경 (신규 ID BB-0040 ~ BB-0056)

- 헬퍼 타깃 `MactteryGuardHelper` (com.apple.product-type.tool) 추가.
- Shared 동기화 그룹을 **앱·헬퍼 양쪽 타깃**에 등록.
- 앱 타깃에 `ServiceManagement.framework`, 헬퍼 타깃에 `IOKit`·`OSLog.framework` 추가.
- 앱 타깃에 "Embed Helper Daemon" Run Script 단계 추가 — 빌드 시 헬퍼 바이너리와
  plist를 `MactteryGuard.app/Contents/Library/LaunchDaemons/`에 복사한다.
  (Copy Files 단계 대신 Run Script를 쓴 이유: dstSubfolderSpec을 손으로 적을 때
  값이 불확실해서. 스크립트가 명시적이고 검증 가능하다.)
- 앱 타깃이 헬퍼 타깃에 의존 (빌드 순서 보장).
- 검증: 중괄호/괄호 균형, ID 중복 없음, 참조된 모든 ID 정의됨, 신규 ID 전부 존재.

## 2. 설계 문서에 없던 결정 사항과 그 이유

1. **보정 감지는 데몬이 담당한다** (§4.2는 로그 폴링을 앱에 배정).
   앱이 꺼져 있어도 보정을 감지하고 쓰기를 멈춰야 하기 때문.
2. **XPC 24시간 단절 시 자동 해제(§9.1 초안) 미구현.**
   §14.9(앱 종료 후에도 데몬 유지)가 우선한다. 데몬은 마지막 유효 설정으로 무기한 제어한다.
3. **Top Up 자동 복귀 시간 24시간 고정(기본값).**
   §14.10의 "일정 시간"을 24시간으로 정하고 `GuardSettings.topUpAutoReturnHours`에
   저장했다 (1–72시간 범위 검증, UI에서 변경 불가 — v1).
4. **데몬 로그는 `/Library/Logs/MactteryGuard/`에 저장한다.**
   root 데몬은 사용자 홈에 쓸 수 없으므로 §14.8의 경로는 앱 로그에만 적용하고,
   데몬은 시스템 로그 경로를 쓴다. 파일 접두사는 앱 `mactteryguard-`, 데몬 `helper-`.
5. **Top Up(100%)은 NativeBackend에서 특별 처리한다.**
   설정 경로는 1–99 범위라 100을 쓸 수 없으므로, 100은 슬라이더 API만 쓰고
   실패 시 `disableMCL:`(=상한 없음)로 동등한 효과를 낸다.
6. **XPC는 JSON Data 블롭으로 주고받는다.**
   커스텀 클래스를 XPC로 보내려면 NSSecureCoding 클래스가 필요한데,
   JSON 인코딩이면 plist 안전 타입(Data)만으로 충분하다.
   양쪽 모두 Foundation 기본 JSON 인코딩(날짜 deferredToDate)을 쓴다.
7. **PowerUI 클라이언트는 순수 Swift로 작성했다 (ObjC 브릿지 파일 없음).**
   dlopen + IMP 캐스트 방식이라 브릿징 헤더가 필요 없고 pbxproj가 단순해진다.
   `availableChargeLimitsWithError:`는 소유권(반환 객체 해제) 처리가 미묘해서
   쓰지 않았다 — 프로브는 `isMCLSupported` + setLimit 성공 + pmset 등록으로 충분하다.
8. **SMC는 C 구조체 없이 80바이트 버퍼 + 고정 오프셋으로 접근한다.**
   Swift 구조체는 패딩·정렬이 C와 다를 수 있어 바이트 단위 접근이 안전하다.
   dataSize 바이트 순서는 휴리스틱으로 처리한다 (LE 해석이 0...32 범위면 LE, 아니면 BE).
9. **엔타이틀먼트 파일 없음.** SMAppService는 팀 ID 서명만 필요하고,
   데몬이 쓰는 API(SMC/CFPreferences/notify/OSLogStore-as-root)는
   엔타이틀먼트가 필요 없다.
10. **데몬 plist에 StandardOutPath/StandardErrorPath 없음.**
    launchd가 데몬보다 먼저 로그 파일을 열기 때문에 데몬이 로그 디렉토리를
    만들 기회를 잃는다. 데몬은 자체 로그를 직접 관리한다.
11. **`temporarilyDisableMCL:` 미사용.** 연구 노트에서 미검증(U5)이라
    Top Up은 setLimit(100)/disableMCL:로 구현했다.
12. **Native 설정 도메인 프로브는 관대하다.** `CFPreferencesCopyValue`로는
    "키 없음"과 "도메인 읽기 불가"를 구분할 수 없어, 프로브는 PowerUI 불가 시
    설정 도메인을 "읽을 수 있다"고 판단한다. 실제 쓰기 불가 여부는 setLimit에서
    드러나고 FAIL-OPEN으로 처리된다. 이 기기에서는 PowerUI가 1차 신호라 실무 영향은 작다.

## 3. 전수 수동 리뷰에서 찾아 고친 것 (컴파일 에러 6건 + 로직 1건)

VM에 컴파일러가 없어 22개 파일을 한 줄씩 리뷰했다. 찾은 것:

| # | 위치 | 문제 | 수정 |
| --- | --- | --- | --- |
| 1 | `GuardTypes.swift` | `BackendKind`에 `adapter` 케이스 없음 (`displayName`이 참조) — 빌드 전체 차단 | `adapter` 케이스 추가 (UI 서브에이전트가 발견) |
| 2 | `SMCClient.call()` | `input.count`(Int)를 `mach_msg_type_number_t` 파라미터에 그대로 전달, `outputSize`도 Int | 명시적 캐스트 + `mach_msg_type_number_t` 선언 |
| 3 | `SMCClient.write()` | `UInt32 == Int` 비교 (`info.dataSize == data.count`) | `Int(info.dataSize) == data.count` |
| 4 | `CalibrationDetector.pollLog()` | `OSLogEntry`에 `subsystem` 없음 (OSLogEntryLog에만 있음) | `as? OSLogEntryLog` 캐스트 후 접근 |
| 5 | `SleepWakeMonitor` | C 콜백 함수에 파라미터 라벨 있음 (`@convention(c)` 타입과 불일치 가능) | 라벨 제거 (`_`) |
| 6 | `main.swift` + `DaemonStore` + `XPCService` | Swift 6 전역 상태 규칙: `var signalSources` 가변 전역 + 비-Sendable 전역 `let` | `SignalSourceStore` 래퍼 클래스(락 보호) 도입, `DaemonStore`·`XPCService`에 `@unchecked Sendable` + 근거 주석 |
| 7 | `SMCTemperature.decode` | 타입 코드 `"flt\0"` 패딩 시 매치 실패 (공백만 제거) | 공백 + NUL 함께 제거 |
| 8 | `ControlEngine.handleDischargeBack` | 하한 검사 분기가 도달 불가 (상한 검사가 먼저라 하한 이하는 항상 상한 이하) | 하한 검사 먼저 수행하도록 순서 교환 |
| 9 | `README.md` | 로그 파일명 오기 (`app-`/`daemon-` → 실제 `mactteryguard-`/`helper-`) | 정정 |
| 10 | `package.sh`·README | `-scheme MactteryGuard` — 스킴 파일이 없어 fresh checkout에서 실패 | `-target MactteryGuard`로 변경 |

## 4. 실기 검증 필요 항목 (중요도 순)

### 🔴 빌드 차단 가능 — 첫 빌드에서 즉시 확인

1. **`import IOKit.pwr_mgt`** (`SleepWakeMonitor.swift`).
   ~~`IOKit.ps`는 Step 1에서 검증됐지만 `pwr_mgt` 서브모듈 이름은 미검증이다.
   "no such module"이 나면 해당 import를 지우고 `import IOKit`만으로
   `IORegisterForSystemPower`/`IOAllowPowerChange`가 보이는지 확인한다.~~
   **검증됨 (2026-11-16, 부모 리뷰)**: 2026년 6월 공개 글에서 Swift 코드가
   `import IOKit.pwr_mgt`를 그대로 사용해 IOPMAssertion API를 호출하는 것이
   확인됐다 (https://www.yurii-lytvynenko.com/articles/keeping-a-mac-awake-without-breaking-sleep/).
   `ps`와 같은 정식 서브모듈이므로 첫 빌드에서 import 오류가 날 가능성은 낮다.
   만일 "no such module"이 나면 해당 import를 지우고 `import IOKit`만으로
   `IORegisterForSystemPower`/`IOAllowPowerChange`가 보이는지 확인한다.
2. **Shared 동기화 그룹의 두 타깃 등록.**
   같은 동기화 그룹(0040)을 앱·헬퍼 양쪽 타깃의 `fileSystemSynchronizedGroups`에
   넣었다. Xcode 16+에서는 지원되는 것으로 알지만, 빌드 오류가 나면
   Shared 파일을 각 타깃에 개별 파일로 등록하는 방식으로 바꿔야 한다.
3. **Swift 6 동시성.** 전수 리뷰로 6건을 고쳤지만 컴파일러 검증이 아니다.
   첫 빌드에서 남은 Sendable/@MainActor 오류를 확인한다.
   특히 `main.swift` 최상위 코드의 MainActor 격리(전역 `let engine` 등)와
   `XPCService`의 `@unchecked Sendable` 부분을 본다.
4. **서명 팀 미설정.** `CODE_SIGN_STYLE = Automatic`인데 `DEVELOPMENT_TEAM`이 없다.
   Xcode에서 팀을 선택해야 할 수 있다 (개인 Apple ID로 충분).
   SMAppService 데몬 등록은 팀 ID 서명이 필요하므로, 개인 팀 서명으로
   등록이 되는지 확인한다.

### 🟡 동작 검증 — 빌드 성공 후

5. **Native 설정 경로 쓰기 (가장 중요한 동작 검증).**
   80% 미만 상한은 root 데몬이 `com.apple.smartcharging.topoffprotection`에
   `MCLFeatureState=1` + `mclLimitValue=N`을 쓰는 경로인데, 이 기기(펌웨어
   20457.41.3 / macOS 27.2)에서는 아직 검증되지 않았다 (문헌은 20457.1.29/27.0).
   **검증은 현재 보정(ChargingUpForGauging)이 끝난 뒤에 할 것** — 보정 중에는
   데몬이 쓰기를 거부하고, macOS도 상한 등록을 무시한다.
   검증 방법: 상한을 70%로 설정 → `pmset -g battlimit`에서
   `manualChargeLimit` + `chargeSocLimitSoc: 70` 확인 → 80%로 복귀.
6. **`pmset -g battlimit` 출력 형식.** 파서는 관대하게 작성했고 원시 출력을
   로그에 남긴다 (`daemon-*.log`가 아니라 `helper-*.log`의 DEBUG 라인).
   형식이 다르면 `PmsetParser.parse`만 고치면 된다.
7. **SMAppService 등록 흐름.** 팝오버의 "데몬 등록" → 관리자 인증 →
   시스템 설정 로그인 항목 승인 → 상태 `.enabled` 확인.
   앱 번들 `Contents/Library/LaunchDaemons/` 안에 헬퍼+plist가 임베딩됐는지
   먼저 확인한다 (없으면 "찾을 수 없음" 상태가 된다).
8. **보정 감지 notify.** `com.apple.system.powersources.chargingtofulloverride`가
   이 기기에서 실제로 보정 시 1이 되는지 확인한다. (2026-11-16에 보정이
   02:46→03:45+ 진행된 적이 있으니, 다음 보정 때 로그로 확인 가능.)
9. **온도 표시.** `Temperature`가 IORegistry/IOPS에 없을 경우 SMC TB0T 폴백이
   동작하는지 확인한다. 사용자 기기 ismc 덤프에서 TB0T `64 66 06 42` =
   33.6°C(LE float)로 확인된 바 있다. 팝오버 온도가 33°C 근처면 정상,
   3000°C대면 단위 변환 버그(있을 수 없는 값이라 plausibility 필터가 걸러야 함).
10. **Top Up 복귀.** 100% 도달 후 어댑터 재연결 시 원래 상한으로 복귀하는지,
    24시간 경과 복귀는 로그 타임스탬프로 확인한다.
11. **클램셸 동작.** 뚜껑을 닫은 상태에서 Adapter 절단이 일시정지되는지,
    수면 직전 어댑터 허용 복원이 되는지 확인한다.
12. **보정 후 되돌리기.** 보정이 끝난 뒤 잔량이 상한 위면 되돌리기 상태로 전이하고,
    강제 방전 옵트인 시 CHIE 절단으로 내려가는지 확인한다.
    옵트인 OFF 시에는 macOS 자체 드레인에 위임하므로 복귀가 느릴 수 있다
    (드레인 속도는 미지수 — R9/U2).

### 🟢 UX·보조 확인

13. **팝오버 높이.** PopoverView 콘텐츠가 약 700pt라 ScrollView 없이 배치했다.
    작은 화면에서 잘리는지 확인하고, 필요하면 ScrollView로 감싼다.
14. **메뉴바 라벨.** 보정 중 `"80% · 보정 중"` 표시, 그 외 Step 1과 동일(`% ⚡`).
15. **로그 보존.** 30일 지난 파일 삭제는 `pruneIfNeeded`가 하루 1회 수행한다.
    (강제 테스트하려면 파일 수정 시각을 과거로 바꾸면 된다.)

## 5. 알려진 한계

- **macOS 보정 충전은 어떤 앱도 막을 수 없다.** MactteryGuard는 보정 종료 후
  되돌리는 것만 할 수 있다. 목표는 "100%에 도달하지 않는 것"이 아니라
  "100%에 머무는 시간을 최소화하는 것"이다.
- **80% 미만 상한은 비공개 메커니즘(설정 경로)에 의존한다.**
  macOS 업데이트로 동작이 바뀔 수 있다. 검증된 동작은 80%이다.
- **직접 SMC 충전 차단 키(CH0B/CH0C)는 이 기기에서 사용할 수 없다.**
  펌웨어 20457.41.3에서 게이팅되어 키 자체가 열거되지 않는다.
  어댑터 키(CHIE)만 사용한다.
- **XPC 호출자 코드 서명 검증 없음 (v1).**
  로컬 mach 서비스라 동일 기기 내에서만 접근 가능하지만, 데몬은 연결 프로세스의
  서명을 검증하지 않는다. 설정은 범위 검증(`validated()`) 후 적용한다.
- **Native 등록은 배터리 전원에서 철회된다.**
  macOS가 배터리 동작 중에는 약 5분 후 상한 등록을 철회하므로,
  어댑터 분리 시 "미등록"은 정상이다. 어댑터 연결 후 재등록된다.
- **보정 종료 판정에 최대 10분 지연이 있을 수 있다.**
  OSLogStore 조회 창이 10분이라, 보정이 끝나도 최근 로그 신호가 남아 있으면
  되돌리기가 늦어진다. notify 신호가 1차라 실제로는 더 빠르다.
- **데몬이 크래시하면 launchd(KeepAlive)가 재시작한다.**
  재시작 시 섀도 상태로 재동기화하지만, 크래시 순간에 어댑터가 차단된 채
  남아 있으면 다음 시작 시 복원된다 (시작 시 Adapter 복원 수행).
- **UI 희망 사항(사용자, 2026-11-16 04:18)은 미반영.**
  "배터리 상태 표시에 예쁜 그래픽 요소"는 나중에 논의하기로 하고
  이번 Step 2 구현에는 포함하지 않았다.
