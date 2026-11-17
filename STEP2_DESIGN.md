# MactteryGuard Step 2 설계 문서

> **설계만 다룬다. SMC 제어 코드는 포함하지 않는다.**
> 작성일: 2026-11-16 · 상태: 초안 (사용자 승인 전) · 전제: Step 1(읽기 전용 메뉴바 앱) 완료
> 대상 기기: M4 Pro MacBook Pro, macOS 27.2, Xcode 27

---

## 0. 요약 — 이 문서에서 가장 중요한 발견

**Step 2를 CH0B/CH0C 직접 쓰기 전제로 설계하면 안 된다.**

batt(charlie0129/batt) v0.9.0 릴리스 노트와 README에 따르면, macOS 27 개발자 베타 4(펌웨어 `20457.0.125.0.2`+)부터 Apple은 SMC 충전 제어 키를 비공개 엔타이틀먼트(`com.apple.private.iokit.soc-limit`) 뒤에 가뒀다. 레거시 키(`CH0B`/`CH0C`/`CHTE`)와 펌웨어 제한 키(`bfF0`/`bfD0`/`bfE0`) 모두 **root라도 `kIOReturnNotPrivileged`를 반환**한다. 사용자는 macOS 27.2 정식 버전을 쓰므로 펌웨어가 해당 구간일 가능성이 매우 높다.

따라서 Step 2의 아키텍처는 **백엔드 선택형**이어야 한다(batt의 모델을 따른다):

| 백엔드 | 방식 | 적용 조건 |
|---|---|---|
| Legacy | CH0B/CH0C 직접 토글 | 펌웨어 < 20xxx (구형, 이 기기 해당 가능성 낮음) |
| Firmware | bfF0/bfD0/bfE0 상·하한 쓰기, 펌웨어가 강제 (수면 중에도 유지) | 20xxx 베타 1~3 구간 펌웨어 |
| Native | PowerUIAgent 상한 목표 동기화 (10~99%) | 27 베타 4+ / 게이팅된 펌웨어 — **이 기기의 유력 후보** |
| Adapter | 벽전원(어댑터) 키 토글, 히스테리시스 루프 | 충전 키 게이팅 + 어댑터 키 사용 가능 시 (깨어 있을 때만) |

**어느 백엔드가 이 기기에서 동작하는지는 코드 작성 전에 반드시 실측으로 확인해야 한다** (§10 게이트 체크리스트). 펌웨어 버전 확인이 첫 번째 단계이며, macOS 버전만으로는 판단할 수 없다(batt 문서: "Do NOT rely on macOS version").

그 외 확정 사항:

- **정직한 목표는 "100%에 머무는 시간 최소화"**이지 "100% 도달 제로"가 아니다. macOS 보정(full charge)은 어떤 앱도 막을 수 없다(AlDente 제작사 공식 인정: "AlDente can't interrupt this", 1.40 릴리스 노트).
- **특권 헬퍼는 SMAppService(데몬 등록)가 정석**이다. SMJobBless는 macOS 13에서 deprecated. 개인 사용은 **무료 Apple ID 서명(Personal Team)으로도 가능**한 것으로 확인된다(Team ID가 있으면 됨). 유료 Developer 계정($99/년) + 공증은 **타인에게 배포**할 때 필요하다.
- **보정 감지에는 공개된 신호가 있다.** PowerUIAgent 로그의 `ChargingUpForGauging` / `Battery mitigations are in place, MCL will be ignored` (AlDente 공식 진단법). 앱에서는 `OSLogStore.local()` 폴링으로 읽는 것이 유력한 1차 경로, 관찰 기반 감지(차단 상태에서 잔량 상승)가 2차 경로다.

---

## 1. 목표와 비목표

### 1.1 목표

1. **하드 충전 상한 유지**: 기본 80%, 사용자가 정한 상한을 패턴 학습 없이 규칙대로 지킨다.
2. **보정 후 자동 되돌리기**: macOS 보정으로 100%까지 간 뒤, 보정이 끝나면 자동으로 상한까지 되돌린다(AlDente Pro의 "After macOS Calibration" 기본 동작과 동일).
3. **수면/복귀 유지**: 잠자기·깨우기, 뚜껑 닫고 외부 모니터만 쓰는 클램셸 상태에서도 상한이 유지된다(백엔드에 따라 보장 수준이 다름 — §8).
4. **하한(세일링)**: 상한 도달 시 충전 차단, 하한(상한 −5%, 기본 75%) 도달 시 재충전. 잘게 끊어 충전하는 마이크로 사이클을 방지한다.
5. **안전 우선**: 어떤 오류·종료·제거 상황에서도 충전 허용 상태로 복원한다(FAIL-OPEN, §9).

### 1.2 비목표 (v1에서 하지 않는 것)

- **보정 자체의 차단**: 불가능하다. 시도하지 않는다.
- **히트 프로텍션(온도 기반 차단)**: AlDente Pro 기능이나 v1 범위 밖. 후순위 후보로만 기록한다.
- **스케줄/통계/단축어**: v1 범위 밖.
- **macOS 26 이하 지원**: Step 1 배포 타깃은 macOS 26.0이나, Step 2 제어 로직은 macOS 27.2 실측 기준으로 설계한다. 구형 macOS 대응은 백엔드 선택 구조 덕에 나중에 추가 가능하나, v1 검증 대상이 아니다.
- **Intel Mac 지원**: 대상 기기가 Apple Silicon 전용이다. Intel용 BCLM 키는 다루지 않는다.

### 1.3 슬라이더 범위 (잠정)

- v1: 상한 50~100% (기본 80%). Battery-Toolkit의 상한 하한(50%)과 동일하게 둔다.
- 네이티브 백엔드가 확인되면 10~99%까지 확장 검토(batt 네이티브 모드는 10~99% 지원). 단, 80% 미만에서는 macOS가 플러그를 꽂은 상태에서도 배터리를 드레인 쪽으로 끌고 갈 수 있다(batt 문서)는 점을 사용자에게 밝혀야 한다.
- 하한은 상한 −5% 고정으로 시작하고, 별도 조절은 사용자 피드백 후 검토한다.

---

## 2. Step 1 현황 (실측 기반 — 이 설계를 떠받치는 전제)

`~/workspace/battery-guard/` 실파일 기준:

| 항목 | Step 1 실측 |
|---|---|
| 번들 ID | `com.loveaimg.mactteryguard` |
| 배포 타깃 | macOS 26.0, Swift 6.0, Xcode 27 프로젝트 |
| 앱 형태 | MenuBarExtra(.window), LSUIElement(메뉴바 전용, Dock 아이콘 없음) |
| 샌드박스 | OFF (`ENABLE_APP_SANDBOX = NO`) — Step 2에 유리하다 (아래 참조) |
| 배터리 읽기 | `BatteryMonitor` — IOKit `IOPSCopyPowerSourcesInfo/List` + `IOPSGetPowerSourceDescription`, 10초 Timer 폴링. 잔량 %, 충전 여부, AC 전원, 남은 시간 |
| UI | `PopoverView` — 잔량·상태·어댑터·남은 시간 + "Step 1 — 읽기 전용" 각주 + 종료 버튼 |
| SMC 코드 | 없음 ("SMC" 언급은 "쓰기 하지 않는다"는 주석뿐) |

### 2.1 Step 2가 재사용하는 것

- `BatteryMonitor`의 IOKit 읽기 경로와 10초 폴링 — 제어 루프의 상태 입력으로 그대로 쓴다. 단, 제어 판단은 데몬이 하므로, 모니터는 **표시용**과 **데몬 상태 조회용**으로 역할이 나뉜다(§4).
- 메뉴바 UI/팝오버 골격 — 설정 UI(상한 슬라이더, 상태 표시, 보정 알림)를 얹는다.
- 샌드박스 OFF 상태 — `OSLogStore.local()` 전체 로그 읽기에 필요하다(샌드박스 앱은 자기 프로세스 로그만 읽을 수 있음, §3.5). 샌드박스를 켜면 안 된다.

### 2.2 Step 2가 새로 만드는 것

- 특권 데몬 타깃 + LaunchDaemon plist + XPC IPC (§4).
- 백엔드 추상화 + 제어 루프 + 상태 머신 (§5, §6).
- 보정 감지 + 되돌리기 (§7).
- 설치/제거 플로우 (§4.4).

---

## 3. 핵심 조사 결과

### 3.1 macOS 27의 SMC 키 게이팅 — 설계 전체를 좌우하는 사실

- batt v0.9.0: "Apple gated the SMC charge-control keys behind a private entitlement, so `batt` now falls back to the native macOS charge limit (PowerUIAgent) when direct SMC control is unavailable."
- batt README(게이팅 구간 설명): macOS 27 개발자 베타 4(펌웨어 `20457.0.125.0.2`+, 일부 macOS 15.x/26.x 보안 업데이트에도 포함)부터 "Apple gated the SMC charge-control keys behind a private entitlement (`com.apple.private.iokit.soc-limit`). Both the legacy keys (`CH0B`/`CH0C`/`CHTE`) and the firmware-limit keys (`bfF0`/`bfD0`/`bfE0`) now return `kIOReturnNotPrivileged` even to root, so neither the legacy nor the firmware backend works."
- 펌웨어 구간 정리(batt 호환성 매트릭스):

| 펌웨어 | macOS | 동작 백엔드 |
|---|---|---|
| < 20xxx | ~26.x | Legacy (CH0B/CH0C) |
| `20356.0.0.0.15` ~ `20457.0.77.0.2` | 27 베타 1~3 | Firmware (bfF0/bfD0/bfE0), 수면 중에도 유지 |
| `20457.0.125.0.2`+ | 27 베타 4+ (정식 포함) | Native (PowerUIAgent, 10~99%) 또는 Adapter 모드 |
| 15.8.x의 20xxx | 15.8 | Firmware 유지 (예외 구간) |

- **판정 기준은 펌웨어 버전이지 macOS 버전이 아니다.** 구형 macOS에도 신형 펌웨어가 실릴 수 있다(batt: "Firmware version is different from macOS version").
- 이 기기는 macOS 27.2 정식이므로 **게이팅 구간(베타 4+)일 가능성이 매우 높다** — 다만 실측 전에는 확정하지 않는다 (§10 체크 0번).
- AlDente도 1.39에서 "completely rebuilt charge control with macOS 27 support"를 했고, 80% 미만 한도에 별도 토글이 필요해졌다 — 같은 게이팅 환경에 적응한 정황이다. AlDente의 구체적 메커니즘은 비공개(프로프라이어터리)이므로 확인 불가하다. **[미검증]**

### 3.2 백엔드 4종 (batt 아키텍처 — MactteryGuard 설계의 모델)

batt 문서를 종합하면 데몬은 런타임에 사용 가능한 키·서비스로부터 백엔드를 자동 선택한다:

1. **Legacy**: 배터리 %를 계속 읽으며 직접 충전을 토글한다. 펌웨어 < 20xxx에서만 동작.
2. **Firmware**: 상·하한을 쓰고 주기적으로 재조정(reconcile)하며, Apple 펌웨어가 범위를 강제한다. **수면 중에도 유지**된다.
3. **Native**: PowerUIAgent의 상한 목표를 동기화 상태로 유지한다. 10~99% 설정 가능, 상한만 존재(하한 없음). 배터리 잔량이 상한보다 높으면 macOS가 플러그 연결 상태에서도 상한 쪽으로 드레인할 수 있고, 가끔 100%까지 충전할 수 있다(보정). v0.10.0에서 "macOS가 나중에 적용하는 목표를 받아들이는" 방식으로 신뢰성이 개선됐다. 실험적 no-drain 모드(상한 위에서 벽전원 유지, `powerd` 재시작 필요)가 있다.
4. **Adapter**(옵트인): 어댑터(벽전원) SMC 키는 게이팅되지 않았으므로, legacy와 같은 히스테리시스 루프를 충전 상태 대신 벽전원 토글로 수행한다. batt가 깨어 있을 때만 동작하고, Force Discharge·자동 보정을 비활성화한다. 클램셸 모드에서 어댑터 차단 중 깨어 있게 유지하는 처리가 있다.

batt의 백엔드 선택은 macOS/펌웨어 버전에 분기하지 않고 **런타임에 키·서비스 가용성을 검사**한다. MactteryGuard도 이 원칙을 따른다(§5).

### 3.3 SMC 키 인벤토리 (Apple Silicon)

| 키 | 용도 | 값 | 상태 / 근거 |
|---|---|---|---|
| CH0B | 충전 제어 (주) | 00=허용, 02=차단 | AlDente + actuallymentor/battery에서 검증됨. **27 베타 4+ 펌웨어에서 쓰기 게이팅됨** (batt) |
| CH0C | 충전 제어 (보조) | 00=허용, 02=차단 | CH0B 단독 사용 시 수면 중 충전 누수 사례가 있어 dual-key 사용 (battery.sh 주석). 게이팅 동일 |
| CHTE | 충전 제어 폴백 | u32, 00000000=허용, 01000000=차단 | 구형 Apple Silicon 폴백 키. 게이팅 동일 (batt) |
| CH0I | 방전 강제 | 00=정상, 01=방전 강제 | actuallymentor/battery(@howie65 발견), BatFi 동일. 어댑터 모드 관련 키일 가능성 — **[미검증]** 어느 키가 batt의 "어댑터 키"인지는 소스 확인 필요 |
| CH0J / CH0K | 방전/AC 제어 | 00/01 | BatteryOptimizer visudo에 CH0I와 함께 등장. 역할 세부 미확인 **[미검증]** |
| CHIE | 방전 enable | 00=끄기, 08=켜기 | BatteryOptimizer visudo에만 등장. **[미검증]** |
| bfF0 / bfD0 / bfE0 | 펌웨어 상·하한 | (batt 내부) | 20xxx 베타 1~3 구간 펌웨어 제한 키. 베타 4+에서 쓰기 게이팅됨 (batt) |
| CHLS | Apple 자체 상한 (구형 펌웨어) | u16, 하위 바이트=종료 임계값, −5 오프셋 | Linux macsmc-power 드라이버가 **읽기만** 한다. 쓰기 가능 여부 미확인 — §3.4 참조 |
| CHWA | Apple 자체 상한 (신형 펌웨어) | 플래그, 고정 80% 종료 임계값 | Linux 드라이버 읽기 전용. 쓰기 가능 여부 미확인 — §3.4 참조 |
| CHNC / CH0R / CH0X | 상태 플래그 집합 | 비트필드 | CHNC bit24 = CHLS 제한 활성, CH0R bit11 = NOAC_CHWA 등. 상태 조회용 후보 **[미검증]** |

**주의**: CH0B/CH0C에 03을 쓰는 구현도 있다(BatFi: "2 or 3"). 02와 03의 차이는 본 조사에서 확인되지 않았다. **[미검증]** — v1은 02만 사용한다.

### 3.4 CHLS / CHWA — Apple 자체 상한 키, 쓰기는 미검증

Linux 커널 macsmc-power 드라이버(v7, 2026-02-17)는 CHLS/CHWA를 **사용자 지정 충전 상한을 읽는** 용도로만 사용한다:

- `has_chls` = "Charge limit (Older firmware)", `has_chwa` = "Charge limit (Modern firmware)".
- CHLS는 u16: 상한 = (하위 바이트) − 5 (시작 오프셋 5). `CHLS_FORCE_DISCHARGE 0x100` 비트가 존재한다.
- CHWA는 플래그: 설정 시 상한 = 80 − 5 = 75 (종료 80, 재시작 75 — Apple 자체 히스테리시스 5%).
- 드라이버는 충전 거동을 바꿀 때 CH0C/CH0I/CHTE를 쓰고, CHLS/CHWA에는 쓰지 않는다.

**결론: CHLS 쓰기가 유효한 경로라는 근거는 찾지 못했다.** batt의 펌웨어 백엔드가 쓰는 키도 CHLS가 아니라 bfF0/bfD0/bfE0이다. CHLS와 bf* 키의 관계는 확인되지 않았다. **[미검증]** — 설계에서는 CHLS/CHWA를 **읽기 전용 상태 조회 후보**로만 두고, 쓰기 경로로 채택하지 않는다. 게이트 체크에서 존재 여부만 기록한다.

### 3.5 보정 감지 — 공개된 로그 신호가 있다

AlDente 공식 문서(2026-10-27, AlDente 1.40 기준)는 보정 여부를 확인하는 터미널 명령어를 공개하고 있다:

```
/usr/bin/log show --last 2h --style compact --predicate 'process == "PowerUIAgent"' | grep -Ei 'ChargingUpForGauging|mitigations are in place'
```

- 출력에 `ChargingUpForGauging` 또는 `Battery mitigations are in place, MCL will be ignored`가 있으면 macOS가 보정 중이고 모든 충전 제한을 무시하는 상태다.
- 출력이 비어 있으면 보정 중이 아니다.
- 시간당 한 번씩 나타나는 `GaugingMitigationActions` 항목은 모든 맥에 나타나는 정상 항목이며 보정 신호가 아니다.
- AlDente는 보정 감지 시 "macOS is forcing a battery calibration" 알림을 띄우고, 보정이 끝날 때까지 상한 변경과 "Stop Calibration"을 잠근다. 1.39부터는 Apple 보정을 자동 감지해 자사 보정 모드에 통합한다.

**앱 내 구현 경로 (설계 결정)**:

- 1차: `OSLogStore.local()`로 PowerUIAgent 로그를 폴링한다. macOS에서 `OSLogStore.local()`은 전체 시스템 로그를 읽을 수 있다. 문서상 `com.apple.logging.local-store` 엔타이틀먼트가 필요하다고 되어 있으나, Apple DTS(Quinn "The Eskimo!")와 Michael Tsai의 확인에 따르면 **관리자 계정으로 실행하면 엔타이틀먼트 없이 동작**한다. 단, **App Sandbox 안에서는 동작하지 않는다**(자기 프로세스 범위만 가능). MactteryGuard는 샌드박스 OFF이고 사용자는 관리자이므로 조건을 만족한다. **[조건부 검증 — 실기 확인 필요]**
- 제약: OSLogStore에는 푸시/스트리밍 콜백이 없어 **폴링만 가능**하다. 로그 문구는 안정성 계약이 없어 Apple이 언제든 바꿀 수 있다(문구 변경 시 감지 실패 → 2차 경로로 폴백).
- 2차(관찰 기반): 충전 차단 상태에서 잔량이 상승하면 보정으로 간주한다. 오탐 가능 요인: 어댑터 재연결, SMC 리셋, 다른 앱 간섭, 센서 오차. 확정 전에 2회 연속 확인(예: 60초 간격 2회)을 요구한다.
- 보정 종료 판정은 100% 도달 + 충전 전류 0 + 로그 신호 소멸을 조합한다. 종료 판정의 정확한 조건은 실측으로 정한다. **[미검증]**

### 3.6 특권 헬퍼 — SMAppService가 정석, 서명 요구사항 정리

**판결: SMAppService 데몬 등록을 1차로 채택한다. SMJobBless는 채택하지 않는다.**

| 항목 | SMJobBless | SMAppService |
|---|---|---|
| 상태 | macOS 13에서 deprecated, Apple이 SMAppService 사용 권장 | macOS 13+ 현행 권장 방식 |
| 등록 방식 | `/Library/PrivilegedHelperTools/`에 바이너리 복사 + `/Library/LaunchDaemons/`에 plist, `SMPrivilegedExecutables` 요구 | 앱 번들 내 `Contents/Library/LaunchDaemons/`에 plist + `BundleProgram`, `SMAppService.daemon(plistName:).register()` |
| 사용자 승인 | Authorization Services 관리자 인증 | 관리자 인증 + 시스템 설정 → 로그인 항목 및 확장 프로그램에서 승인 (앱당 하나의 스위치) |
| 상태 확인 | 파일시스템/`launchctl print` 확인 | `.status` (notRegistered / enabled / requiresApproval / notFound) |
| 제거 | 파일 + plist 수동 삭제 | `SMAppService.daemon(plistName:).unregister()` |
| 참고 구현 | Battery-Toolkit (macOS 13 미만 레거시 경로), Blessed 패키지 | Battery-Toolkit (13+), BatFi, Hosts, Procexp-Mac, Agent |

**서명 요구사항 — 핵심 질문에 대한 답:**

- SMAppService 등록은 **앱과 헬퍼가 동일한 Team ID로 서명**될 것을 요구한다. ad-hoc 서명(팀 ID 없음)으로는 등록이 안 된다(Agent 프로젝트 문서: "Without a developer account the app is ad-hoc signed. The Launch Agent/Daemon helpers won't register (SMAppService needs a team ID)").
- **무료 Apple ID(Personal Team) 서명으로도 가능하다.** 근거:
  - Hosts(/etc/hosts 편집기): "Open the project in Xcode (free) and sign it with your own free signing certificate — any Apple ID works, no paid Developer Program needed." — SMAppService LaunchDaemon 헬퍼 포함.
  - Spotiglass: macOS 26은 무료 Apple Development identity(Personal Team)로 서명한 드라이버를 로드한다. Developer ID는 개발자 머신 밖 배포 시에만 필요.
  - Microsoft Procexp-Mac: SMAppService 데몬 등록에 "stable, non-ad-hoc identity — a Developer ID Application certificate for distribution, or a self-signed identity for local development"이 필요하다고 명시.
- **유료 Apple Developer Program($99/년) + Developer ID + 공증(notarization)은 타인에게 배포할 때 필요하다.** 개인 사용(자신의 맥에서 직접 빌드·실행)에는 불필요하다. Homebrew Cask 배포 시에도 서명+공증이 요구된다(auto-wifi 조사 문서).
- 주의: 등록 후 재서명하면 번들 해시가 바뀌어 Mach 서비스 채널이 단절된다(Agent 문서). 업데이트 시에는 재등록 절차가 필요하다(§4.4).
- SMAppService 데몬 등록 신뢰성: macOS 13에서 서드파티 데몬 등록 신뢰성 문제가 있었다는 보고가 있어, StaticRouteHelper는 macOS 14부터 SMAppService를 시도하고 실패 시 SMJobBless로 폴백한다. MactteryGuard 배포 타깃이 macOS 26.0이므로 해당 문제는 범위 밖이나, 등록 실패 시 폴백 경로는 §4.5에 둔다.

### 3.7 수면/복귀 — 백엔드별 보장 수준이 다르다

- **Firmware/Native 백엔드**: 펌웨어 또는 macOS가 강제하므로 수면 중에도 상한이 유지된다(batt: "Limits remain active during sleep").
- **Legacy 백엔드**: SMC 쓰기는 휘발성이다. battery.sh 주석: CH0B만 쓰면 수면 중 충전이 누수되는 경우가 있어 CH0B+CH0C를 함께 쓴다. Battery-Toolkit은 `refreshState()`로 수면/복귀 후 섀도 상태를 하드웨어와 재동기화한다. → 복귀 시 재확인·재적용이 필수다(§8).
- **Adapter 모드**: batt가 깨어 있을 때만 동작한다. 수면 중에는 상한을 강제할 수 없다.
- AlDente Free가 수면 중 상한을 유지하지 못하는 것은 앱 수준 제한(데몬 부재)이다. MactteryGuard는 root 데몬이 제어 주체이므로, 복귀 즉시 재적용이 가능하다. 단, 수면 "중"의 강제 여부는 백엔드에 달려 있다.
- 클램셸(뚜껑 닫힘 + 외부 모니터 + 전원): macOS는 깨어 있는 상태를 유지하므로 데몬이 계속 동작한다. batt는 어댑터 차단 중 클램셸을 깨워 두는 처리를 별도로 둔다(어댑터 모드 한정 참고 사항).

### 3.8 참고 구현 요약

| 프로젝트 | 라이선스 | MactteryGuard 설계에 주는 것 |
|---|---|---|
| charlie0129/batt | GPL-2.0 | 백엔드 선택 아키텍처, 펌웨어 구간별 동작, Adapter 모드, unix socket IPC, 게이팅 사실 자체 |
| mhaeuser/Battery-Toolkit | (미확인 — 코드 재사용 전 라이선스 확인 필요) | SMAppService 데몬 + XPC IPC, 상태 머신(standard/toLimit/toFull), 히스테리시스(min 75/max 80 기본값), 수면 후 refreshState, 설정 검증 |
| rurza/BatFi | (미확인) | SMC 키 정의(CH0B/CH0C 2 or 3, CH0I=1), 헬퍼+XPC 구조 |
| actuallymentor/battery | (미확인) | SMC 키 발굴(CH0B/CH0C/CH0I, CHTE 폴백), visudo 스코프 모델, dual-key 근거 |
| js4jiang5/BatteryOptimizer | (미확인) | 스코프형 sudoers 대안 아키텍처, CH0J/CH0K/CHIE 키 목록 |
| AppHouseKitchen/AlDente | 프로프라이어터리 | 보정 감지 로그 신호, "After macOS Calibration" UX, 1.39 재구축 charge control (메커니즘 비공개) |

**라이선스 주의**: batt는 GPL-2.0이다. batt 코드를 직접 가져오면 MactteryGuard도 GPL 의무를 진다. 본 설계는 batt를 **설계 참조(아이디어 수준)** 로만 삼고, 코드 이식은 하지 않는다. 다른 프로젝트의 코드를 참조할 때도 라이선스를 먼저 확인한다.

---

## 4. 아키텍처

### 4.1 컴포넌트

```
┌─────────────────────────────────────────────────────────────────┐
│ MactteryGuard.app (메뉴바 앱, 사용자 권한, 샌드박스 OFF)            │
│  - 메뉴바 UI / 팝오버 (Step 1 재사용 + 설정 UI 추가)              │
│  - 설정 관리 (상한, 하한, 되돌리기 on/off, 자동 시작)             │
│  - 데몬 상태 표시 (등록됨/승인 대기/오류, 현재 백엔드, 보정 중)    │
│  - 보정 로그 폴링 (OSLogStore) → 결과를 데몬에 전달               │
│  - 설치/제거 UI (데몬 등록·해제, 충전 복원)                       │
└───────────────────────────┬─────────────────────────────────────┘
                            │ XPC (Mach service, launchd 관리)
                            │  - 설정 전달 (상한/하한/모드)
                            │  - 상태 조회 (현재 상태, 백엔드, 마지막 쓰기)
                            │  - 명령 (일시정지/재개/1회 완충/제거)
┌───────────────────────────┴─────────────────────────────────────┐
│ com.loveaimg.mactteryguard.helper (LaunchDaemon, root)            │
│  - 제어 루프 소유자 (유일한 SMC/네이티브 쓰기 주체)               │
│  - 백엔드 선택·실행 (legacy/firmware/native/adapter)             │
│  - 상태 머신 (§6), 섀도 상태, 쓰기 로그                          │
│  - 수면/복귀 재확인, 주기적 재조정(reconcile)                    │
│  - FAIL-OPEN 복원 (시작/종료/오류 시)                            │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 책임 분리 (누가 무엇을 하는가)

| 책임 | 앱 | 데몬 |
|---|---|---|
| 배터리 상태 읽기 (표시용) | ○ (Step 1 BatteryMonitor) | ○ (제어 판단용, 별도 읽기) |
| 사용자 설정 UI·저장 | ○ | — (앱으로부터 XPC로 전달받음) |
| SMC/네이티브 쓰기 | ✗ (절대 하지 않음) | ○ (유일한 쓰기 주체) |
| 제어 루프·상태 머신 | — | ○ |
| 보정 로그 폴링 | ○ (OSLogStore, 결과를 데몬에 전달) | △ (관찰 기반 감지는 데몬이 직접 수행) |
| 수면/복귀 처리 | — | ○ (복귀 시 재확인·재적용) |
| 쓰기 로그 기록 | — | ○ (타임스탬프 포함) |
| 로그인 항목 등록 | ○ (SMAppService.mainApp) | — (데몬은 launchd가 관리) |

**왜 데몬이 제어 주체인가**: 앱이 종료되거나 사용자가 로그아웃해도 상한이 유지되어야 하고, 수면/복귀 시 즉시 재적용되어야 하며, SMC 쓰기에 root 권한이 필요하기 때문이다. Battery-Toolkit·BatFi·batt 모두 같은 분리를 둔다.

### 4.3 IPC — XPC (Mach service)

- **1차: XPC.** launchd가 관리하고, 서명(Team ID) 기반으로 신뢰가 강제되며, Battery-Toolkit/BatFi의 검증된 방식이다. 데몬은 XPC 리스너, 앱은 클라이언트.
- **대안: Unix domain socket** (batt 방식). 단순하고 디버깅이 쉽지만, 접근 제어를 직접 구현해야 한다(소켓 파일 권한). XPC 등록에 문제가 생길 경우의 폴백으로만 둔다.
- XPC 인터페이스는 최소로 유지한다: `setLimit(upper:lower:)`, `setEnabled(_:)`, `chargeToFullOnce()`, `getState()`, `pause()/resume()`, `uninstall()`. 데몬은 앱의 요청을 검증한 뒤에만 수행한다(상한 범위 10~100, 하한 < 상한 등).
- **보안 원칙**: 데몬은 XPC 요청을 무조건 신뢰하지 않는다. 요청 출처가 동일 Team ID 서명인지 launchd/XPC 계층이 보장하지만, 값 범위 검증은 데몬이 직접 수행한다. 데몬은 임의 명령 실행, 셸 실행, 파일 쓰기(로그·설정 제외)를 하지 않는다.

### 4.4 설치·업데이트·제거

**설치 (최초 1회)**:

1. 앱 실행 → 설정에서 "충전 제어 활성화" 선택.
2. 앱이 `SMAppService.daemon(plistName:)` 등록 요청 → 관리자 인증 프롬프트.
3. 시스템 설정 → 로그인 항목 및 확장 프로그램에서 사용자가 데몬 승인 (상태 `requiresApproval` → `enabled`).
4. 데몬 시작 → 백엔드 자동 감지 → 현재 SMC/네이티브 상태 읽기 → 설정 적용.
5. 앱은 데몬 상태(등록됨/승인 대기/백엔드 종류)를 UI에 표시한다.

**데몬 plist**: 앱 번들 내 `Contents/Library/LaunchDaemons/com.loveaimg.mactteryguard.helper.plist`, `BundleProgram`으로 헬퍼 바이너리 지정. `RunAtLoad` / `KeepAlive` 여부는 구현 시 결정한다 (초안: `RunAtLoad=true`, `KeepAlive=true` — launchd가 크래시 시 재시작. **[설계 결정 사항]**).

**업데이트**:

- 앱 업데이트 시 헬퍼 바이너리도 함께 교체된다. 재서명하면 번들 해시가 바뀌어 기존 Mach 채널이 단절될 수 있으므로(Agent 문서), 업데이트 후 재등록 절차가 필요하다. 앱 시작 시 데몬 상태와 번들 버전을 비교해 불일치 시 재등록을 안내한다.
- 설정은 업데이트 시 유지된다. 설정 저장 위치는 앱 UserDefaults(앱 설정)와 데몬 공용 위치로 분리한다 — 데몬이 앱 종료 중에도 설정을 읽어야 하므로, 데몬용 설정은 `/Library/Application Support/MactteryGuard/`에 두는 것을 초안으로 한다. **[미검증 — 구현 시 권한 모델 확인 필요]**

**제거 (반드시 앱 내 경로를 제공한다)**:

1. 앱 설정 → "MactteryGuard 제거" → 확인 대화상자.
2. 데몬에 `uninstall` 명령: **충전 허용 복원(FAIL-OPEN)을 먼저 수행**한 뒤 데몬 unregister.
3. `SMAppService.daemon(plistName:).unregister()` 호출.
4. 설정·로그 파일 제거 여부 선택 (기본: 로그 유지, 설정 제거).
5. 앱을 휴지통으로만 버리면 데몬이 남을 수 있다. 이를 README와 앱 내 안내에 명시한다. Battery-Toolkit도 앱 내 제거 기능을 둔다.

### 4.5 폴백: SMAppService 등록 실패 시

SMAppService 등록이 실패하면(예: 개인 팀 서명 문제, macOS 버그) 다음 순서로 폴백한다:

1. **재시도 + 상태 진단**: `status` 확인, 시스템 설정 승인 여부 안내, 재등록.
2. **수동 LaunchDaemon 설치 (batt 모델)**: `sudo`로 plist를 `/Library/LaunchDaemons/`에 설치하고 `launchctl`로 로드. 설치 스크립트 방식이며 SMAppService를 우회한다. 단, Gatekeeper/서명 요구와 업데이트 관리가 수동이 된다.
3. **스코프형 sudoers + smc 바이너리 (BatteryOptimizer/actuallymentor 모델)**: `/private/etc/sudoers.d/`에 SMC 명령만 허용하는 항목을 두고, 앱(사용자 권한)이 `sudo smc`를 호출한다. 데몬이 없어 구조가 단순하지만, sudoers 수정이 필요하고, 앱이 꺼지면 제어가 멈추며, 수면 중 유지가 안 된다. **최후의 수단**으로만 둔다.

폴백 2·3은 v1 구현 범위 밖이며, SMAppService 실패가 확인된 뒤에 설계한다.

---

## 5. 백엔드 선택 설계

### 5.1 결정 트리 (런타임 자동 선택 — batt 원칙)

```
1. 펌웨어 버전 확인 (system_profiler, 참고용 — 분기 기준이 아님)
2. 키 존재 여부 확인 (읽기)
3. 쓰기 가능 여부 확인 (no-op 쓰기 프로브 — §10 체크 3번, 사용자 승인 후)
4. 가용성에 따라 백엔드 선택:
   - CH0B/CH0C 쓰기 가능 → Legacy
   - bfF0/bfD0/bfE0 쓰기 가능 → Firmware
   - 둘 다 불가 + PowerUIAgent 네이티브 경로 가용 → Native
   - 네이티브 불가 + 어댑터 키 가용 → Adapter
   - 전부 불가 → 제어 불가 상태로 UI에 표시 (읽기 전용 모드로 폴백)
5. 선택된 백엔드와 그 근거를 UI와 로그에 기록한다.
```

**버전에 분기하지 않는다.** 같은 macOS 27.2라도 펌웨어·하드웨어 리비전에 따라 결과가 다를 수 있다. batt와 동일하게 런타임 가용성 검사가 유일한 기준이다.

### 5.2 백엔드별 동작 명세

| 백엔드 | 상한 강제 방식 | 하한 (세일링) | 수면 중 유지 | 되돌리기 (방전) |
|---|---|---|---|---|
| Legacy | CH0B/CH0C=02 차단, 00 허용 | CH0B/CH0C 토글 (하한 도달 시 허용) | ✗ (복귀 시 재적용) | CH0I=01 방전 강제, 상한 도달 시 00 |
| Firmware | bf* 상·하한 쓰기 + 주기적 reconcile | 펌웨어가 범위 강제 | ○ | CHLS_FORCE_DISCHARGE 상당 기능 여부 **[미검증]** — 미확인 시 CH0I 경로 사용 |
| Native | PowerUIAgent 상한 목표 동기화 | ✗ (상한만 존재) | ○ (macOS가 강제) | macOS 자체 드레인에 위임 (상한 위에서 플러그 연결 시 드레인됨). no-drain 옵션은 v1 범위 밖 |
| Adapter | 벽전원 토글 (어댑터 키) | 벽전원 토글 | ✗ (깨어 있을 때만) | 벽전원 차단 = 배터리 사용과 동일 (사실상 방전). Force Discharge 비활성화 |

**네이티브 백엔드 메커니즘은 미검증이다.** batt 문서에 "PowerUIAgent의 상한 목표를 동기화 상태로 유지한다"고만 되어 있고, 구체적으로 어떤 API/기본값/XPC를 쓰는지는 공개 문서에서 확인되지 않았다. **구현 전 batt 소스(`pkg/` 내 네이티브 백엔드)를 연구해 메커니즘을 확인할 것.** 메커니즘이 비공개 API에 의존하면 Apple 업데이트로 깨질 수 있음을 문서화한다. **[미검증 — 구현 전 필수 조사]**

### 5.3 v1 범위 결정

- 게이트 체크 결과에 따라 **하나의 주 백엔드**만 v1에 구현한다. 이 기기에서는 Native가 유력하다.
- 다른 백엔드는 인터페이스(추상화)만 설계하고 구현은 후순위로 둔다. 단, Legacy는 설계 문서 수준에서 완비해 둔다(구형 기기·향후 펌웨어 변경 대비).
- 백엔드 선택 로직 자체는 v1에 포함한다(선택 실패 시 읽기 전용 모드 + UI 안내).

---

## 6. 제어 루프와 상태 머신

### 6.1 폴링 간격

| 항목 | 간격 | 근거 |
|---|---|---|
| 배터리 상태 읽기 (데몬) | 10초 | Step 1과 동일. IOKit 읽기는 저렴하다 |
| SMC/네이티브 상태 재확인 (reconcile) | 60초 | 펌웨어 백엔드의 주기적 재조정 패턴. 외부 간섭(다른 앱, 시스템 설정 변경) 감지 |
| 보정 로그 폴링 (앱) | 60초 | OSLogStore는 폴링만 가능하고 비용이 있다. 단, 잔량 상승 이벤트 시 즉시 1회 조회 |
| 관찰 기반 보정 확인 | 60초 간격 2회 연속 | 오탐 방지 (§3.5) |

### 6.2 히스테리시스

- **상한 도달 시 충전 차단, 하한(상한 −5%) 도달 시 재충전.** 기본 80/75.
- 5%를 선택한 근거: Apple 자체 오프셋(CHLS/CHWA의 FIXED_START_OFFSET = 5)과 Battery-Toolkit 기본값(min 75 / max 80)이 일치한다. Gemini 초안의 −3%보다 검증된 값이다.
- 하한 오프셋은 사용자 설정으로 노출할지 미결정이다 (§11).
- **섀도 상태**: 데몬은 마지막으로 쓴 값을 기억하고, 상태 변화가 있을 때만 쓴다(Battery-Toolkit `BTPowerState` 패턴). 불필요한 SMC 쓰기를 없애고, 외부에서 값이 바뀐 것을 감지할 수 있다.

### 6.3 상태 머신

```
                    ┌──────────────┐
                    │    IDLE      │ (제어 비활성: 한도 100% / 일시정지 / 어댑터 분리)
                    └──────┬───────┘
                           │ 활성화 (상한 < 100, 어댑터 연결, 백엔드 가용)
                           ▼
                    ┌──────────────┐  잔량 < 상한       ┌──────────────┐
                    │  CHARGING    │ ─────────────────▶ │  HOLDING     │
                    │  (충전 허용)  │  잔량 ≤ 하한       │  (충전 차단)  │
                    └──────┬───────┘ ◀───────────────── └──────┬───────┘
                           │                                    │
              잔량 상승 감지 (차단 중) / 로그 신호                │ 보정 종료 감지
                           ▼                                    ▼
                    ┌──────────────┐  100% 도달 + 신호 소멸  ┌──────────────┐
                    │ CALIBRATING  │ ─────────────────────▶ │ DISCHARGE_   │
                    │ (보정 중,    │                         │ BACK         │
                    │  쓰기 중단)   │                         │ (상한까지    │
                    └──────────────┘                         │  방전)       │
                                                             └──────┬───────┘
                                                                    │ 상한 도달
                                                                    ▼
                                                             ┌──────────────┐
                                                             │  HOLDING     │
                                                             └──────────────┘

  모든 상태에서: 오류 발생 / 데몬 종료 / 제거 요청 → FAIL_OPEN (충전 허용 복원) → IDLE
  모든 상태에서: 어댑터 분리 → IDLE (제어 일시정지, 복원하지 않음 — 배터리 사용 중이므로)
```

**전이 조건 (상세)**:

| 전이 | 조건 |
|---|---|
| IDLE → CHARGING | 제어 활성화 + 어댑터 연결 + 잔량 < 상한 + 보정 아님 |
| CHARGING → HOLDING | 잔량 ≥ 상한 (백엔드에 차단 명령) |
| HOLDING → CHARGING | 잔량 ≤ 하한 (백엔드에 허용 명령) |
| HOLDING → CALIBRATING | (로그 신호) 또는 (차단 상태에서 60초 간격 2회 연속 잔량 상승) |
| CHARGING → CALIBRATING | 로그 신호 (충전 중에도 보정 시작 가능 — 이 경우 쓰기 중단만 하고 상태 유지) |
| CALIBRATING → DISCHARGE_BACK | 100% 도달 + 로그 신호 소멸 (또는 잔량 정체 2회 연속) |
| DISCHARGE_BACK → HOLDING | 잔량 ≤ 상한 (방전 중단, 차단 상태로) |
| DISCHARGE_BACK → CHARGING | 잔량 ≤ 하한 (방전이 하한을 넘긴 경우 — 안전장치) |
| ANY → FAIL_OPEN | SMC 쓰기 오류 3회 연속 / XPC 단절 타임아웃 / 데몬 종료 신호 / 제거 요청 |
| ANY → IDLE | 사용자가 일시정지 / 상한을 100%로 설정 / 어댑터 분리 |

**1회 완충 (Charge to Full Once)**: 사용자가 요청하면 상한을 무시하고 100%까지 1회 충전한 뒤 자동으로 상한 모드로 복귀한다(batt `charge full`, AlDente Top Up 상당). 보정과는 별개 기능이다.

---

## 7. 보정 감지 + 되돌리기 플로우

### 7.1 감지 (2경로)

1. **로그 기반 (1차)**: `OSLogStore.local()`로 PowerUIAgent 항목 폴링. `ChargingUpForGauging` 또는 `Battery mitigations are in place, MCL will be ignored` 검출 시 보정 시작으로 판정. `GaugingMitigationActions`는 정상 항목이므로 무시한다.
2. **관찰 기반 (2차)**: 충전 차단(HOLDING) 상태에서 잔량이 상승하면 보정 의심 → 60초 후 재확인 → 상승 지속 시 보정 확정. 로그 경로가 문구 변경 등으로 실패할 때의 폴백이다.

**오탐 리스크**: 어댑터 재연결 직후의 일시적 상승, SMC 리셋, 다른 충전 제어 앱과의 충돌, 센서 오차. 2회 연속 확인과 로그 신호 교차 검증으로 줄인다. 오탐이 발생해도 결과는 "쓰기 일시 중단 + 되돌리기"이므로 안전 방향이다(FAIL-OPEN과 같은 방향).

### 7.2 보정 중 동작 — 쓰지 않는다 (결정)

**보정 중에는 어떤 쓰기도 하지 않는다.** 근거:

- macOS가 보정 중에는 모든 충전 제한을 무시하므로(AlDente 공식 문서), 쓰기는 무의미하다.
- 보정 요청은 배터리가 완전히 충전될 때만 해제된다(MacFix 보도 Support 답변: "this restriction is only cleared once the battery has fully charged"). 케이블을 뽑아도 해제되지 않고, 다시 꽂으면 100% 강제가 재개된다. 따라서 보정을 방해하는 것보다 끝까지 두는 것이 맞다.
- AlDente도 보정 중에는 상한 변경과 중단을 잠근다.

보정 중 UI에는 "macOS 배터리 보정 중 — 상한이 일시적으로 무시됩니다"를 표시하고, 상한 변경 UI를 잠근다(AlDente와 동일).

### 7.3 되돌리기 (방전)

- **트리거**: 보정 종료 판정(100% 도달 + 로그 신호 소멸) 즉시.
- **방식 (백엔드별)**:
  - Legacy/Firmware: CH0I=01 방전 강제 → 잔량 ≤ 상한 시 CH0I=00 + 차단 상태로 복귀.
  - Native: macOS 자체 드레인에 위임한다(batt 문서: 상한 위에서 플러그 연결 시 macOS가 상한 쪽으로 드레인). 드레인이 시작되지 않으면(예: 30분 경과 후에도 100% 유지) 사용자에게 알림 — 자동 개입 방법은 미정이다. **[미검증 — 실측 필요]**
  - Adapter: 벽전원 차단 상태 유지 = 배터리 사용과 동일하므로 자연스럽게 상한까지 내려간다.
- **안전장치**: 방전 중 잔량이 하한 이하로 내려가면 즉시 방전 중단 + 충전 허용. 방전 최대 지속 시간(예: 2시간) 초과 시 중단 + 알림. **[초안 수치 — 실측 후 조정]**
- **방전 중 사용자 개입**: 사용자가 케이블을 뽑으면 방전은 무의미해지므로 중단하고 IDLE로 전이한다.

---

## 8. 수면/복귀 + 로그인 항목

### 8.1 수면/복귀

| 백엔드 | 수면 중 | 복귀 시 동작 |
|---|---|---|
| Legacy | 유지 안 됨 (휘발성, 누수 가능) | 즉시 상태 재확인 + 필요 시 재적용 (Battery-Toolkit `refreshState()` 패턴) |
| Firmware | 유지됨 (펌웨어 강제) | 재확인(reconcile)만 수행 |
| Native | 유지됨 (macOS 강제) | PowerUIAgent 목표 동기화 상태 재확인 |
| Adapter | 유지 안 됨 | 복귀 시 제어 루프 재개 |

**복귀 감지**: 데몬이 IOKit 전원 이벤트(`IOPMConnection` / `NSWorkspace.didWakeNotification` 상당)를 구독한다. 앱이 아닌 데몬이 구독하는 것이 맞다(앱이 꺼져 있어도 동작해야 함). **[구현 세부 — API 선택은 구현 시 확정]**

**수면 직전**: 별도 동작 없음. 휘발성 키는 어차피 수면 중 리셋될 수 있으므로, 복귀 시 재적용으로 대응한다. 수면을 막지는 않는다(GlobalSleep 방식의 수면 방지는 채택하지 않는다 — 사용자 기기를 깨워 두는 것은 부작용이 크다).

### 8.2 로그인 항목

- **앱 자동 실행**: `SMAppService.mainApp`으로 로그인 항목 등록 (사용자 선택, 기본 OFF로 시작해 피드백 후 결정).
- **데몬**: LaunchDaemon은 launchd가 부팅 시 관리하므로 별도 로그인 항목이 필요 없다. `RunAtLoad`로 부팅 시 시작한다.
- 클램셸 사용(뚜껑 닫힘 + 외부 모니터) 시 macOS는 깨어 있으므로 데몬·앱 모두 정상 동작한다. 단, 앱이 로그인 항목에 없으면 메뉴바 UI는 사용자가 직접 실행할 때까지 나타나지 않는다 — 데몬은 독립적으로 계속 제어한다.

---

## 9. 안전 규칙 (FAIL-OPEN)

**핵심 원칙: 의심스러우면 충전을 허용한다.** 충전 차단은 배터리를 보호하는 편의 기능이지, 충전 허용 상태(기본값)보다 안전하지 않다. 차단 상태로 고착되면 사용자가 배터리를 못 쓰는 사태가 생긴다.

### 9.1 복원 규칙

| 상황 | 동작 |
|---|---|
| 데몬 정상 종료 (SIGTERM) | 종료 전 충전 허용 복원 + 방전 해제 + 네이티브 상한 원래 값으로 복원 |
| 데몬 크래시 | launchd 재시작 → 시작 시 설정 재동기화 → 설정 읽기 실패 시 충전 허용 복원 |
| 앱 종료 | 데몬은 독립적으로 계속 제어한다 (의도된 동작). 단, 앱 종료 시 "제어도 함께 중지" 옵션을 설정에서 제공한다 (기본: 계속 제어) |
| 제거 (uninstall) | 복원 → 데몬 unregister → 파일 제거 순서를 반드시 지킨다 |
| SMC 쓰기 오류 3회 연속 | FAIL_OPEN 상태로 전이, 충전 허용 복원, UI에 오류 표시, 자동 재시도 중단 (사용자 수동 재개 필요) |
| XPC 단절 (앱-데몬) | 데몬은 마지막 유효 설정으로 계속 제어한다. 단절이 24시간 지속되면 충전 허용 복원 후 대기 **[초안 — 검토 필요]** |
| 상한을 100%로 설정 | 제어 비활성화 + 충전 허용 복원 (batt와 동일) |
| 어댑터 분리 | 제어 일시정지 (IDLE). 복원은 하지 않는다 (배터리 사용 중이므로 차단 상태가 무의미) |
| macOS 업데이트 감지 | (가능하면) 업데이트 후 첫 시작 시 백엔드 재감지 + 사용자에게 재확인 요청. 키 게이팅 변경에 대비한다 |

**네이티브 상한 복원**: 네이티브 백엔드는 macOS 자체 설정을 바꾸므로, 제거 시 **원래 값**(MactteryGuard 설치 전 사용자가 쓰던 상한 — 100% 또는 설정된 값)을 저장해 두었다가 복원해야 한다. 원래 값을 모르면 100%로 복원한다.

### 9.2 쓰기 규칙

- **사용자 승인 없는 쓰기 금지**: 상한이 설정되고 제어가 활성화된 경우에만 쓴다. 초기 상태는 비활성화다.
- **보정 중 쓰기 금지** (§7.2).
- **쓰기 속도 제한**: 동일 키에 10초 내 1회 초과 금지. 상태 변화가 있을 때만 쓴다(섀도 상태, §6.2). **[초안 수치]**
- **모든 쓰기 로깅**: 타임스탬프 + 키 + 이전 값 + 새 값 + 트리거(상태 전이/사용자 명령/복귀 재적용)를 로그 파일에 기록한다. 로그 위치 초안: `~/Library/Logs/MactteryGuard/` (앱) 및 `/Library/Logs/MactteryGuard/` (데몬). **[위치는 구현 시 확정]**
- **값 범위 검증**: 데몬은 모든 쓰기 전 값을 검증한다(상한 10~100, 하한 < 상한, 키별 허용 값만). 범위 밖 값은 거부하고 로그에 남긴다.
- **원자적 dual-key 쓰기**: Legacy 백엔드에서 CH0B/CH0C는 항상 함께 쓴다. 하나만 성공하면 즉시 재시도하고, 지속 실패 시 FAIL_OPEN.
- **방전 시간 상한**: 연속 방전은 최대 2시간으로 제한한다(§7.3). **[초안 수치]**

### 9.3 그 외 안전장치

- **다른 충전 제어 앱과의 충돌 방지**: AlDente·batt·Battery-Toolkit·내장 Charge Limit이 동시에 켜져 있으면 두 시스템이 같은 상태를 두고 싸운다. 앱 시작 시 내장 Charge Limit이 100%가 아닌 값을 가지고 있으면 사용자에게 끄도록 안내한다(batt 권장 사항과 동일). AlDente/batt 설치 감지는 하지 않는다(탐지의 신뢰성 문제) — README와 UI 안내로 대신한다. **[설계 결정]**
- **Optimized Battery Charging**: batt는 사용 시 OBC를 끄도록 권장한다. MactteryGuard도 동일하게 안내한다(두 시스템이 충돌하지 않도록).
- **배터리 잔량 20% 미만**: 어떤 경우에도 충전을 차단하지 않는다(방전 상태면 즉시 충전 허용). 깊은 방전 방지가 상한 유지보다 우선한다.

---

## 10. 게이트 체크리스트 — 제어 코드 작성 전 필수

**아래 항목이 모두 끝나기 전에는 어떤 제어 코드도 작성하지 않는다.** 결과는 이 문서 하단(§10.7)에 기록한다.

### 체크 0: 펌웨어 버전 확인 (가장 먼저)

```sh
system_profiler SPHardwareDataType | grep -i firmware
```

- 기록: 펌웨어 버전 전체 문자열.
- 판정: `20457.0.125.0.2`+ 이면 게이팅 구간 → Native/Adapter 후보. `20356`~`20457.0.77` 구간이면 Firmware 후보. 20xxx 미만이면 Legacy 후보.

### 체크 1: SMC 키 존재 확인 (읽기 전용) — iSMC

iSMC(dkorunic/iSMC)는 읽기 전용 SMC 조회 도구이며, Apple Silicon M1~M5를 지원하고, Homebrew tap으로 설치할 수 있다. 쓰기 기능이 없어 게이트 체크에 안전하다.

```sh
brew tap dkorunic/tap
brew install ismc
ismc raw
```

- `ismc raw`는 모든 SMC 키와 바이트 값을 덤프한다. 다음 키의 존재 여부를 기록한다:
  `CH0B CH0C CHTE CH0I CH0J CH0K CHIE CHLS CHWA bfF0 bfD0 bfE0 CHNC CH0R CH0X`
- 읽기가 실패하면 `sudo ismc raw`로 재시도하고, sudo가 필요했는지 기록한다. **[읽기에 sudo가 필요한지는 미검증]**
- iSMC 설치가 안 되면 대안: smcFanControl 소스에서 `smc` 도구만 빌드한다(hholtmann/smcFanControl — actuallymentor/battery와 batt의 smc 코드 원천). 빌드 절차는 해당 저장소 문서를 따른다. **미리 빌드된 smc 바이너리를 출처 불명의 곳에서 받지 않는다.**

### 체크 2: 현재 충전 상태 기준선 기록

```sh
pmset -g batt
system_profiler SPPowerDataType | grep -E "Cycle Count|Condition|Maximum Capacity"
```

- 기록: 현재 잔량, 사이클 수, 최대 용량, 상태. (이후 제어 효과 비교용 기준선)

### 체크 3: 쓰기 가능 여부 프로브 (⚠️ 쓰기 포함 — 사용자 명시 승인 후에만)

존재 확인만으로는 부족하다. 게이팅 여부는 **써 봐야** 안다. 다만 안전하게, 현재 값을 그대로 다시 쓰는 no-op 쓰기로 프로브한다:

```sh
# 1. 현재 값 읽기 (예: CH0B)
sudo smc -k CH0B -r
# 2. 읽은 값을 그대로 다시 쓰기 (상태 변화 없음)
sudo smc -k CH0B -w <읽은 값>
```

- 성공하면: 쓰기 가능 → Legacy 후보.
- `kIOReturnNotPrivileged` 또는 권한 오류면: 게이팅됨 → Native/Adapter 후보.
- 동일 프로브를 CH0C, CHTE, CH0I, bfF0(존재 시)에 반복한다. **CH0I는 방전 키이므로 no-op 쓰기라도 현재 값이 00인지 먼저 확인하고, 00이 아니면 쓰지 않는다.**
- 이 단계는 `smc` CLI가 필요하다(체크 1의 iSMC는 읽기 전용이므로 프로브 불가). smc는 smcFanControl 소스 빌드 또는 actuallymentor/battery 설치로 얻는다. battery CLI 전체 설치는 `battery maintain` 같은 제어 기능까지 포함하므로, **프로브 목적이면 소스 빌드가 낫다.**
- ⚠️ 프로브 중 충전 상태가 바뀌는 것을 느끼면 즉시 중단하고 현재 값을 확인한다.

### 체크 4: 보정 로그 신호 확인

```sh
/usr/bin/log show --last 2h --style compact --predicate 'process == "PowerUIAgent"' | grep -Ei 'ChargingUpForGauging|mitigations are in place'
```

- 지금 보정 중이 아니면 빈 출력이 정상이다. 명령어가 오류 없이 실행되는지와, `GaugingMitigationActions` 항목이 보이는지를 기록한다(로그 접근 자체의 확인).
- OSLogStore 경로의 실기 검증은 구현 초기 프로토타입에서 수행한다 (§12 항목).

### 체크 5: 서명 정체성 확인 (SMAppService 전제)

- Xcode → Settings → Accounts에 Apple ID가 등록되어 있고, Personal Team이 보이는지 확인한다.
- Step 1 프로젝트의 Signing이 해당 팀으로 되어 있는지 확인한다.
- 실제 데몬 등록 테스트는 구현 초기(헬퍼 뼈대 완성 후)에 수행한다. 등록 실패 시 §4.5 폴백을 따른다.

### 체크 6 (선택): batt 교차 검증

```sh
brew install batt
```

- batt를 설치만 하고 데몬은 시작하지 않는다(`sudo brew services start batt`는 실행하지 않음 — MactteryGuard와 충돌 방지).
- batt 문서의 capability 확인 경로가 있으면 참고한다. 단, batt CLI는 데몬과 통신하므로 데몬 없이는 capability를 못 볼 수 있다. **[미검증]** — 이 체크는 선택 사항이며, 체크 0~3이 우선이다.
- batt를 실제로 써 보는 것은 별개 결정이다. MactteryGuard와 동시 실행은 금지한다.

### 체크 7: 결과 기록 양식

| 항목 | 결과 | 판정 |
|---|---|---|
| 펌웨어 버전 | (기록) | 게이팅 구간 / Firmware 구간 / Legacy 구간 |
| 키 존재 (읽기) | CH0B ○/✗, CH0C ○/✗, … (전체 목록) | |
| 쓰기 프로브 | CH0B 성공/`kIOReturnNotPrivileged`, … | |
| 보정 로그 명령어 | 실행 성공/실패, 출력 있음/없음 | |
| 서명 팀 | Personal Team 있음/없음, Team ID | |
| **선택된 주 백엔드** | (위 결과로부터 결정) | Legacy / Firmware / Native / Adapter / 불가 |
| **v1 구현 범위** | (백엔드 + 포함 기능) | |

---

## 11. 사용자 미결정 질문

구현 전 사용자에게 확인할 것:

1. **기본 상한**: 80%로 할까? (권장: 80% — Apple 내장 하한이자 batt/Battery-Toolkit 기본값과 동일)
2. **히스테리시스 폭**: 상한 −5% (80/75, Apple·Battery-Toolkit과 동일) vs 상한 −3% (80/77, Gemini 초안)? 권장: 5%.
3. **유료 Apple Developer 계정 보유 여부**: 개인 사용에는 불필요하나, GitHub 배포를 염두에 둔다면 Developer ID($99/년) 가입 여부를 알아야 한다.
4. **배포 의도**: 개인용만 / GitHub 오픈소스 배포 / Homebrew Cask까지? 배포 범위에 따라 서명·공증·라이선스 결정이 달라진다.
5. **하한 슬라이더 범위**: 상한 50~100%로 시작할까, 네이티브 백엔드가 확인되면 10~99%까지 열까? 80% 미만에서는 macOS가 드레인 쪽으로 끌고 갈 수 있다.
6. **방전(되돌리기) 시 트레이드오프 인지**: Legacy/Adapter 모드의 방전은 배터리 사이클을 소모한다(하루 1사이클 수준). 네이티브 모드에서는 macOS가 드레인을 관리한다. 이 트레이드오프를 수용하는가?
7. **메뉴바 UI**: 보정 중 상태를 메뉴바에 표시할까? (권장: 표시 — "macOS 보정 중" 문구)
8. **로그 저장 동의**: 모든 SMC/네이티브 쓰기를 타임스탬프와 함께 로컬 로그 파일에 저장한다. 위치와 보관 기간(예: 30일)에 이견이 있는가?
9. **앱 종료 시 제어 유지 여부**: 메뉴바 앱을 종료해도 데몬이 계속 제어하는 것을 기본으로 할까? (권장: 계속 제어 + 설정에서 변경 가능)
10. **1회 완충 기능 필요 여부**: 여행 전 100% 1회 충전 버튼이 필요한가? (권장: 포함 — batt/AlDente 모두 둔다)

---

## 12. 리스크와 미검증 항목

| # | 항목 | 상태 | 검증 방법 |
|---|---|---|---|
| R1 | 이 기기 펌웨어의 게이팅 여부 | **미검증 (최우선)** | §10 체크 0+3 |
| R2 | 네이티브 백엔드 메커니즘 (PowerUIAgent 목표 동기화의 실제 방법) | **미검증** | batt 소스 연구 (`pkg/` 네이티브 백엔드), 실기 테스트 |
| R3 | CH0I가 batt의 "어댑터 키"인지 여부 | 미검증 | batt 소스 연구 |
| R4 | CHLS/CHWA 쓰기 가능 여부 | 미검증 (근거 없음 — 쓰기 경로로 채택 안 함) | 게이트 체크에서 읽기만 확인. 쓰기 시도는 하지 않음 |
| R5 | CH0J/CH0K/CHIE의 정확한 역할 | 미검증 | 게이트 체크에서 존재 여부만 확인 |
| R6 | CH0B/CH0C 값 02 vs 03의 차이 | 미검증 | v1은 02만 사용. 필요 시 batt/BatFi 소스 대조 |
| R7 | OSLogStore.local()이 이 기기·이 서명에서 PowerUIAgent 로그를 읽는지 | 조건부 검증 (문헌상 가능) | 구현 초기 프로토타입으로 실기 확인 |
| R8 | 개인 팀 서명으로 SMAppService 데몬 등록이 되는지 | 조건부 검증 (문헌상 가능) | 구현 초기 헬퍼 뼈대로 실기 확인 |
| R9 | 네이티브 모드에서 보정 후 드레인이 실제로 시작되는지, 얼마나 걸리는지 | 미검증 | 실측 (보정 발생 시 관찰) |
| R10 | 보정 종료 판정 조건 (100% + 신호 소멸의 정확성) | 미검증 | 실측 |
| R11 | SMC 키가 향후 macOS 업데이트로 바뀌거나 막힐 가능성 | 상시 리스크 (과거 사례: 27 베타 4 게이팅, AlDente 15.5 이슈) | 업데이트 후 백엔드 재감지 (§9.1), 릴리스 노트 모니터링 |
| R12 | 데몬 설정 저장 위치·권한 모델 | 미검증 | 구현 시 확인 |
| R13 | XPC 단절 24시간 후 FAIL_OPEN 정책의 적절성 | 초안 수치 | 사용자 피드백 |
| R14 | 쓰기 속도 제한·방전 시간 상한 등 초안 수치 | 초안 수치 | 실측 후 조정 |
| R15 | batt/GPL-2.0 등 참고 구현 라이선스 | batt만 확인됨 (GPL-2.0) | 코드 참조 전 개별 확인 |

---

## 13. 출처

### 백엔드·게이팅·SMC 키
- batt 문서 (백엔드, 호환성, 아키텍처): https://charlie0129.github.io/batt/
- batt GitHub (README, 게이팅 구간 설명): https://github.com/charlie0129/batt
- batt v0.9.0 (게이팅 발표, 네이티브 폴백): https://newreleases.io/project/github/charlie0129/batt/release/v0.9.0
- batt v0.10.0 (네이티브 신뢰성 개선): https://newreleases.io/project/github/charlie0129/batt/release/v0.10.0
- batt Go 패키지 문서: https://pkg.go.dev/github.com/charlie0129/batt
- actuallymentor/battery SMC 통합: https://deepwiki.com/actuallymentor/battery/5.1-smc-integration
- actuallymentor/battery 스크립트 (키 값, dual-key 근거): https://raw.githubusercontent.com/actuallymentor/battery/main/battery.sh
- Linux macsmc-power 드라이버 v7 (CHLS/CHWA 읽기): https://lkml.indiana.edu/2602.2/01555.html
- Linux macsmc-power 드라이버 v3: https://lkml.indiana.edu/2601.1/10088.html
- BatteryOptimizer 권한 관리 (CH0J/CH0K/CHIE, visudo 모델): https://deepwiki.com/js4jiang5/BatteryOptimizer_for_Mac/5.3-privilege-management
- BatFi SMC 연동 (CH0B/CH0C 2 or 3, CH0I=1): https://deepwiki.com/rurza/BatFi/4.2-smc-interaction

### 보정 감지
- AlDente "MacBook Charging to 100% Despite Charge Limit?" (로그 진단 명령어, "AlDente can't interrupt this"): https://apphousekitchen.com/macbook-charges-to-100-despite-charge-limit/
- AlDente 기능 페이지 (After macOS Calibration): https://apphousekitchen.com/aldente-overview/features/
- MacFix Support 답변 (보정 요청은 완충 시에만 해제): https://www.macfix.de/entries/view/1136403
- AlDente 1.39 (재구축 charge control, macOS 27 지원): https://www.studentappcentre.com/Blog/AlDente_1_39
- OSLogStore on Monterey (엔타이틀먼트 불필요, 샌드박스 제한): https://mjtsai.com/blog/2021/12/10/oslogstore-on-monterey/
- OSLogStore 개요 (`.local()` 전체 로그, 관리자 권한): https://www.irurueta.com/apps/apple/logging-metrics-and-crash-reports.html
- HG4MAC (OSLogStore 무엔타이틀먼트 동작 확인, 폴링 비용): https://github.com/jensyleo/hg4mac/blob/HEAD/README.md

### 특권 헬퍼·서명
- XNU, launchd & XPC (SMAppService 데몬 등록 방식): https://folio.gurgul.pro/macos/xnu-launchd-xpc.html
- macOS 자동화·백그라운드 레퍼런스 (SMAppService, Developer ID 요구): https://github.com/laramarcodes/claude-apple-dev-skills/blob/HEAD/macos-dev/references/automation-and-background.md
- Blessed (SMJobBless 래퍼, 13+는 SMAppService 권장): https://swiftpackageregistry.com/trilemma-dev/Blessed
- Procexp-Mac (비-ad-hoc 서명 요구, self-signed 로컬 개발 가능): https://github.com/microsoft/Procexp-Mac
- etc-hosts (무료 Apple ID 서명으로 SMAppService 데몬 가능): https://etc-hosts.com/
- Agent SECURITY.md (Team ID 강제, 재서명 시 채널 단절): https://github.com/AgentiLoop/Agent/blob/HEAD/docs/SECURITY.md
- StaticRouteHelper SMAppService 마이그레이션 설계 (13 신뢰성 문제, 폴백): https://github.com/jdjingdian/StaticRouteHelper/blob/HEAD/openspec/changes/archive/2026-03-17-smappservice-privilege-migration/design.md
- privileged_helper_help (5가지 필수 요구사항): https://github.com/malpern/privileged_helper_help/commit/c1b46a79e7cb31fcfcae2bee1e717983cd6546e9
- Spotiglass EQ 문서 (Personal Team 서명 동작, Developer ID는 배포 시): https://github.com/isaaclins/spotiglass/blob/HEAD/docs/equalizer.md
- auto-wifi 스택 조사 (서명·공증 파이프라인, $99/년): https://github.com/coderask/auto-wifi/blob/HEAD/.planning/research/STACK.md

### 참고 구현
- Battery-Toolkit 데몬 관리: https://deepwiki.com/mhaeuser/Battery-Toolkit/5-daemon-management
- Battery-Toolkit 전원 관리 코어: https://deepwiki.com/mhaeuser/Battery-Toolkit/2-power-management-core
- Battery-Toolkit 설정 관리 (min 75/max 80 기본값): https://deepwiki.com/mhaeuser/Battery-Toolkit/6-settings-management
- iSMC (읽기 전용 SMC 조회, Homebrew tap): https://pkg.go.dev/github.com/dkorunic/iSMC

---

## 부록: 용어 정리

- **SMC**: System Management Controller. 충전·전원·팬·온도 등 하드웨어 저수준 제어 칩. Apple Silicon에서는 키-값 인터페이스로 접근한다.
- **게이팅 (entitlement gating)**: 특정 SMC 키 쓰기에 Apple 비공개 엔타이틀먼트(`com.apple.private.iokit.soc-limit`)를 요구하는 것. 서드파티는 이 엔타이틀먼트를 받을 수 없어 root라도 쓰기가 거부된다.
- **보정 (Calibration)**: macOS가 잔량 추정치 정확도를 위해 가끔 100%까지 강제 충전하는 것. 보정 중에는 모든 충전 제한이 무시된다.
- **섀도 상태 (Shadow state)**: 데몬이 마지막으로 쓴 값을 메모리에 유지해 불필요한 쓰기를 피하고 외부 변경을 감지하는 패턴.
- **세일링 (Sailing)**: 상한과 하한 사이에서 충전 허용/차단을 오가며 배터리를 일정 구간에 머무르게 하는 방식.
- **FAIL-OPEN**: 오류·종료·제거 시 충전 허용(기본값)으로 돌아가는 안전 원칙. 차단 상태로 고착되지 않는다.
- **클램셸 (Clamshell)**: 뚜껑을 닫고 외부 모니터·전원만으로 사용하는 상태. macOS는 깨어 있다.

## 14. 사용자 결정 (2026-11-16) — §11 답변, 구현 기준

사용자가 2026-11-16 04:16에 §11 10개 질문에 모두 답했다. 아래는 Step 2 구현의 구속력 있는 기준이다.

1. **기본 상한 80%**.
2. **히스테리시스 상한 −5%**: 80% 도달 시 차단, 75% 이하 시 재충전. 불필요한 미세 재충전 방지 목적.
3. **유료 Apple Developer 계정 없음** ($99/년 미보유). 공식 배포(유료 공증) 계획 없음.
4. **배포 의도: GitHub 오픈소스 무료 배포 (MIT 라이선스)**. 추후 Homebrew Cask 등록을 고려해 .dmg 또는 .zip 릴리즈 패키징 구조를 갖춘다. 유료 공증이 없으므로 README에 Gatekeeper 우회 실행 방법을 명확히 포함한다.
5. **상한 슬라이더 범위 50–100%**로 시작. 80% 미만으로 내릴 때는 "macOS 기본 동작과 충돌하거나 드레인이 발생할 수 있다"는 안내 문구를 UI에 표시한다.
6. **강제 방전(Discharge)은 기본 비활성화(옵트인)**. 켤 때 배터리 사이클이 소모된다는 경고 안내를 표시한다. 방전 트레이드오프 자체는 사용자가 수용했다.
7. **메뉴바(및 팝오버)에 "macOS 보정 중" 상태 명확히 표시**. 팝오버에 배터리 **사이클 수, 현재 상태(Condition), 온도**도 함께 표시한다.
8. **로그 저장 동의**. 로컬 경로 `~/Library/Logs/MactteryGuard/`에 타임스탬프와 함께 저장, **30일 자동 보관 후 삭제**. 설정에 로그 파일을 쉽게 열 수 있는 버튼을 추가한다 (디버깅/이슈 제보용).
9. **앱 종료 시 제어 유지가 기본값**: 메뉴바 UI 앱을 종료해도 백그라운드 데몬이 충전 제한을 계속 유지한다. 설정에 '앱 종료 시 충전 제한 해제' 토글을 두어 변경 가능하게 한다.
10. **1회 완충(Top Up) 포함**. '1회 100% 완충' 버튼을 두고, 100% 도달 후 어댑터를 뽑았다가 다시 연결하거나 일정 시간이 지나면 원래 설정(80%)으로 자동 복귀한다.

### 게이트 체크 결과 (2026-11-16, §10 완료)

- 펌웨어 **20457.41.3** (게이팅 구간). ismc raw 3,374개 키 확인: CH0B/CH0C/CHTE/CH0I/CH0J/CH0K/CHLS/CHWA/bfF0/bfD0/bfE0 부재, **CHIE 존재(00)**. 직접 SMC 제어 + Firmware 백엔드 불가 확정.
- 배터리: 172사이클, 최대 용량 99%, 상태 Normal. `pmset -g battlimit`는 "No battery level limits set" (배터리 전원 + 보정 중이라 등록 해제 상태).
- **보정 실기 포착**: ChargingUpForGauging(mode 7)이 02:46→03:45+ 연속 로그, MCL 목표 80%인데 최적화 상한 100% — 설계의 보정 감지 신호가 이 맥에서 그대로 확인됨.
- 체크 3 쓰기 프로브는 무의미해짐 (키 자체가 열거되지 않아 프로브 대상 없음).
- **백엔드 확정: Native(주) + Adapter CHIE(폴백·되돌리기)**. Native 메커니즘은 BATT_NATIVE_RESEARCH.md에서 검증 완료. 단, 설정 경로 쓰기(MCLFeatureState/mclLimitValue)는 보정이 끝난 뒤 프로토타입으로 실기 검증해야 한다.
