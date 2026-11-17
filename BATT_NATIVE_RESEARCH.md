# batt Native 백엔드·Adapter 모드 조사 노트

> **읽기 전용 조사 노트. 구현 코드 없음.**
> 작성일: 2026-11-16 · 대상: MactteryGuard Step 2 설계 문서(`STEP2_DESIGN.md`)의 미검증 항목 R2(네이티브 메커니즘), R3(어댑터 키) 해소
>
> **라이선스 주의**: batt는 GPL-2.0이다. 이 노트는 batt 소스를 읽고 메커니즘을 **아이디어 수준으로 서술**한 것이며, batt 코드를 MactteryGuard에 복사·이식하지 않는다. chargnr은 MIT, ampere는 라이선스 미확인(코드 참조 시 확인 필요).

## 0. 조사 대상 소스 (버전 고정)

| 프로젝트 | 버전/커밋 | 용도 |
|---|---|---|
| charlie0129/batt | `cab16c7` (v0.10.0-1-gcab16c7), 2026-11-15 기준 master | 주 조사 대상. Go + cgo(ObjC) |
| rokib16x/chargnr | `749d83d` (v0.2.1) | 독립 교차 검증. Swift, MIT |
| az-code-lab/ampere | `dbe16de` (v0.0.72) | 네이티브 설정 경로 독립 확인. Swift |

batt 소스는 `/tmp/batt`에 읽기 전용 클론으로 조사했고, MactteryGuard 프로젝트에는 복사하지 않았다.

## 1. 결론 요약

| 질문 | 답 (한 줄) | 검증 수준 |
|---|---|---|
| (a) Native 백엔드가 PowerUIAgent 상한을 어떻게 설정하나 | macOS 27에서는 root 데몬이 `com.apple.smartcharging.topoffprotection` 도메인에 `MCLFeatureState=1`, `mclLimitValue=N`을 쓰고 `com.apple.smartcharging.defaultschanged` notify를 보내 PowerUIAgent가 다시 읽게 한다. 80~100%는 슬라이더 API(`setMCLLimit:`)로도 되지만 80 미만은 클램프된다. | **검증됨** (batt 소스 + ampere 독립 구현 일치) |
| (b) Adapter 모드가 벽전원을 어떻게 토글하나, 게이팅되나 | SMC 키 CH0I/CH0J/CHIE 중 가용한 것 (20457.1에서는 사실상 CHIE만). CHIE는 `08`=차단, `00`=허용. 어댑터 키는 게이팅되지 않음이 batt 주석 + chargnr 실측으로 확인됨. | **검증됨** (chargnr이 Mac16,8·20457.1.29에서 실측) |
| (c) 데몬이 백엔드를 어떻게 선택하나 | 버전 분기 없음. SMC KeyInfo + DataSize>0 프로브로 키 가용성을 확인한 뒤 Firmware → Legacy → (옵트인 시) Adapter → Native 순으로 폴백. | **검증됨** (소스) |
| (d) Native 모드에서 macOS 보정 충전을 어떻게 처리하나 | 막지도, 능동적으로 되돌리지도 않는다. 오버라이드 상태를 읽기만 해서 보고하고, 상한 복귀는 macOS 자체 드레인에 위임한다. | **검증됨** (소스 + 문서) |

**판정: 네이티브 백엔드 메커니즘은 구현 가능한 수준으로 이해됐다.** 다만 전제 조건이 있다: 정확한 목표(10~99%) 경로는 비공개 프레임워크 + root 소유 설정 + 비공개 notify에 의존하므로, Apple 업데이트로 깨질 수 있는 비공식 경로다. 80~100%만 필요하다면 슬라이더 API만으로 root 없이도 가능하고, 그 경로는 chargnr이 root 없이 실측 검증했다.

---

## 2. (a) Native 백엔드 — PowerUIAgent 상한 설정 메커니즘

### 2.1 두 개의 경로가 있다

batt의 네이티브 백엔드는 목표 범위에 따라 두 경로를 쓴다 (`pkg/powerui/powerui.go` 머리말 주석, `pkg/powerui/powerui.h` L22-25):

| 경로 | 방법 | 범위 | root 필요 | 확인 위치 |
|---|---|---|---|---|
| 슬라이더 API | `PowerUISmartChargeClient`의 `setMCLLimit:error:` | 80~100% (80 미만은 macOS 27에서 클램프됨) | 아니오 | `powerui.m` `batt_powerui_set_limit` |
| 설정 직접 쓰기 (exact targets) | root의 CFPreferences에 목표를 쓰고 reload notify 전송 | 10~99% | **예** (geteuid()==0 검사) | `powerui.m` `batt_powerui_write_preferences` (L262) |

### 2.2 슬라이더 API 경로 (80~100%)

- 비공개 프레임워크를 런타임에 로드한다: `/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI` (`powerui.m` L11, `dlopen` + `NSClassFromString`).
- 클래스 `PowerUISmartChargeClient`, `initWithClientName:`으로 생성 (클라이언트 이름은 `"batt"`). `powerui.h` 머리말 주석에 따르면 이 클라이언트는 XPC로 PowerUIAgent(`com.apple.powerui.smartChargeManager`)와 통신하며, **시스템 설정이 내장 충전 상한에 쓰는 경로와 동일**하다.
- 사용하는 셀렉터 (macOS 27.0 26A428에서 관찰된 타입 인코딩, `powerui.m` L13-20 주석):
  - `isMCLSupported` → `B16@0:8`
  - `getMCLLimitWithError:` → `C24@0:8^@16` (unsigned char 반환)
  - `setMCLLimit:error:` → `B28@0:8C16^@20`
  - `isMCLCurrentlyEnabled:` → `Q24@0:8^@16`
  - `availableChargeLimitsWithError:` → `@24@0:8^@16` (NSArray\<NSNumber\>)
  - `disableMCL:` → `B24@0:8^@16`
  - `enableMCL:` → 존재 여부로 exact-target 경로 가용성을 판단 (`batt_powerui_custom_limits`, L197-201)
- `setMCLLimit:error:`은 macOS 27에서 80 미만 목표를 클램프한다. 그래서 batt는 80 미만 목표에 설정 경로를 쓴다.

### 2.3 설정 직접 쓰기 경로 (10~99%, exact targets)

`batt_powerui_write_preferences` (`powerui.m` L262-280)의 절차:

1. **게이트 확인** (`checkPreferenceAccess`, L207-220): macOS 메이저 버전이 27이고 클라이언트가 `enableMCL:`에 응답하며(`batt_powerui_custom_limits`), **실행 주체가 root**(`geteuid() == 0`)일 것. root의 도메인이 root로 실행되는 PowerUIAgent의 도메인과 일치하기 때문이다.
2. **설정 쓰기** — 도메인 `com.apple.smartcharging.topoffprotection` (`kCFPreferencesCurrentUser`, `kCFPreferencesAnyHost`):
   - `MCLFeatureState` = `1` (NSNumber, 기능 켜짐)
   - `mclLimitValue` = 목표값 (NSNumber, 1~99)
   - `CFPreferencesSetValue` 후 `CFPreferencesSynchronize`로 저장 확인.
3. **Reload notify 전송**: `notify_post("com.apple.smartcharging.defaultschanged")` (L276). PowerUIAgent가 이를 보고 설정을 다시 읽는다.
4. **저장 확인**: 쓴 값을 다시 읽어(`batt_powerui_get_preferences`, L222) 목표·활성 상태가 일치하는지 검증한다. 불일치 시 에러.

**선행 공개 문서**: batt 소스 주석은 이 메커니즘을 az-code-lab/ampere v0.0.71(`Sources/Shared/NativeChargeLimit.swift`, `Sources/SMCWriter/main.swift`)에서 문서화된 것으로 명시한다. ampere 소스(본 조사에서 v0.0.72 확인)는 동일 도메인·키·notify를 정의하고, 에이전트가 notify를 받는 순간 로그에 "Loaded Settings"를 남긴다고 기록한다. **두 독립 구현이 완전히 일치하므로 메커니즘 자체는 검증된 것으로 본다.**

**참고 — 원래 값 복원**: ampere는 처음 오버라이드하기 전에 기존 `MCLFeatureState`/`mclLimitValue`를 마커 파일(`"<state> <limit>"`, 없음은 `-`)로 저장해 두었다가 해제 시 사용자의 원래 설정으로 복원한다(`Originals` 구조체). MactteryGuard 설계 문서 §9.1의 "네이티브 상한 복원" 항목은 이 패턴을 따르면 된다.

### 2.4 목표 적용 확인 — `pmset -g battlimit` 파싱

저장된 설정이 실제로 적용됐는지는 별도로 확인해야 한다 (`pkg/powerui/registration.go`):

- `/usr/bin/pmset -g battlimit`를 실행하고 출력을 파싱한다 (`readRegistrationOutput`, L19).
- 행 중 `chargeSocLimitReason`이 `"manualChargeLimit"`이고 `Terminated`가 `0`인 항목의 `chargeSocLimitSoc` 값을 읽는다 (`manualLimitTargets`, L119-120). `"No battery level limits set"`이면 등록 없음.
- 출력 형식이 예상과 다르면 빈 목록으로 취급하지 않고 에러를 낸다 (확인 불가 = 미확인, 조용히 성공으로 처리하지 않음).

**등록 지연(pending) 동작** (`powerui.go` L65 `ErrRegistrationPending`, L93-94, `SetLimit` L197-268, `customState` L164):

- PowerUIAgent가 목표를 로드했어도 powerd가 아직 등록하지 않은 상태가 있다. 충전 중에는 배터리의 %가 바뀌거나 충전이 멈출 때만 에이전트가 새 목표를 등록한다.
- `SetLimit`은 최대 10회, 100ms 간격으로 등록을 폴링한다. 등록이 안 되면 `ErrRegistrationPending`을 반환하고, 호출자(데몬)는 다음 유지보수 패스에서 재시도한다. 재시도가 등록을 앞당기지는 않는다.
- **배터리 전원에서는 약 5분 후 macOS가 등록을 철회**하고, 전원 연결 시 다시 등록한다. 배터리 전원에서는 등록 대기가 무의미하므로 데몬은 별도 안내를 띄운다 (`managedlimit.go`의 `onBattery()` / `pendingNativeLimitNotice`).

### 2.5 해제(Disable) 시의 주의점

`powerui.go` `disable()` (L270-): 저장된 설정이 비활성화되어 있어도 powerd 등록이 남아 있을 수 있다. 에이전트는 자신이 활성화되어 있다고 믿을 때만 `disableMCL:`로 등록을 제거하므로, batt는 필요 시 `enableMCL:`을 먼저 호출한 뒤 `disableMCL:`을 호출하고, 에이전트 상태·저장된 설정·powerd 등록 세 가지를 모두 확인한다. 해제 확인이 안 되면 에러를 낸다.

### 2.6 `enableMCL:`의 역할

`SetLimit`에서 에이전트가 비활성화 상태이면 설정 쓰기 전에 `enableMCL:`을 호출한다. 설정 notify만으로는 에이전트가 `ChargingToFull` 상태에 머물 수 있기 때문이다. 단, `enableMCL:`은 Apple의 80% 기본값을 먼저 선택하므로, 에이전트가 이미 활성화되어 있을 때는 호출을 건너뛰고 설정 쓰기+reload만 한다 (`powerui.go` L218-232 주석).

## 3. 부록: No-drain 정책 (실험적, v1 범위 밖 권고)

batt v0.10.0+의 opt-in 기능. PowerUIAgent의 MCL은 상한 위에 있을 때 배터리를 드레인하는데, 이를 원치 않을 때 powerd에 batt 자체의 상한 정책을 설치한다 (`pkg/powerui/policy.m`, `pkg/daemon/nodrain.go`).

- **저장소**: CFPreferences 도메인 `com.apple.powerd.charging` (`kCFPreferencesAnyUser`, `kCFPreferencesCurrentHost`), 키 `bootSessionUUID` + `policies` (L10, L69-72).
- **정책 형식**: `ChargeCtrlPolicy`라는 이름으로 NSKeyedArchiver 인코딩된 객체 배열. 필드: `soclimit`(상한), `owner`(pid), `reason`, `token`(NSUUID), `drain`, `noChargeToFull`, `isEndOfCharge`, `terminated` (L17-44). batt 정책은 `reason = "battChargeLimit"`, `drain = NO`, `noChargeToFull = NO`, `isEndOfCharge = YES`, `terminated = NO`.
- **적용**: 정책 저장 후 **powerd를 SIGHUP으로 재시작**해야 반영된다 (`reloadPolicies`, L139-186, SIGHUP L178; launchd가 교체 프로세스를 띄울 때까지 최대 15초 대기).
- **안전장치**: 재시작 전 다른 앱의 sleep/display-sleep assertion이 있는지 검사하고(`battCopySleepAssertions`, `assertions.m` — `IOPMCopyAssertionsStatus` 계열), 있으면 재시작을 연기한다 (`ErrRestartDeferred`). powerd 재시작은 다른 앱의 assertion을 날릴 수 있기 때문이다. 부트 세션이 바뀌면 이전 정책은 폐기한다.
- **상호작용**: no-drain 설치 시 PowerUIAgent의 드레인 정책을 먼저 해제하고(`batt_powerui_disable`), 시스템 설정이나 전원 변경으로 에이전트가 다시 켜지면 매 패스마다 해제한다 (`nodrain.go` `ensureNoDrainLimit`, L188). 정책 스토어를 읽을 수 없으면 opt-in을 끄고 일반 네이티브 제어로 폴백한다 (`noDrainFailure`).
- **판정**: powerd 재시작을 수반하는 실험적 기능이다. MactteryGuard v1에서는 채택하지 않고, 일반 네이티브 모드(macOS 드레인에 위임)를 기본으로 하는 것이 맞다.

## 4. (b) Adapter 모드 — 벽전원 토글

### 4.1 키와 값

`pkg/smc/consts_arm64.go` L16-19, `pkg/smc/adapter.go`:

| 우선순위 | 키 | 켜기 (어댑터 허용) | 끄기 (어댑터 차단) | 비고 |
|---|---|---|---|---|
| 1 | `CH0I` | `00` (1바이트) | `01` (1바이트) | 구형 펌웨어 |
| 2 | `CH0J` | `00` | `01` | |
| 3 | `CHIE` | `00` | **`08`** | Tahoe 펌웨어용 |

- 상태 읽기: 해당 키 1바이트가 `0x00`이면 켜짐 (`IsAdapterEnabled`, `adapter.go` L19-45).
- **설계 문서 R3 해소**: batt의 "어댑터 키"는 CH0I/CH0J/CHIE이며, 설계 문서 §3.3에서 "어댑터 모드 관련 키일 가능성"으로만 적혀 있던 CH0I가 batt에서는 1순위 어댑터 키다. (actuallymentor/battery가 CH0I를 "방전 강제"로 부른 것과 모순되지 않는다 — 어댑터를 끄면 맥이 배터리로 동작하므로 결과적으로 방전이 된다.)

### 4.2 게이팅 여부 — 20457.1에서 어댑터 키는 살아 있다

두 독립 출처가 일치한다:

- **batt 소스 주석**: `pkg/daemon/charger.go` — "when those keys are gated by Apple (macOS 27 beta 4+ firmware) — cutting wall power via the adapter key, which is not entitlement-gated." `pkg/compatibility/compatibility.go` L20-25도 동일하게 "the adapter SMC key, which is not entitlement-gated"라고 명시한다.
- **chargnr 실측** (`docs/hardware.md`, Mac16,8 M4 Pro, 펌웨어 20457.1.29, macOS 27.0, 2026-09-23 확인): `CHIE`는 root로 읽기·쓰기 가능. 실측 수치: `CHIE = 08` 후 어댑터 입력(PDTR) 63~67W → 0.1W, 배터리 전류(B0AC) +2.4~+3.5A → −1.4~−1.9A(배터리로 동작). `CHIE = 00` 후 약 6초 내 63W로 복귀. 차단 중에도 충전기는 연결된 것으로 읽힌다(`AC-W = 04`, IOKit `ExternalConnected = Yes`; 실제 뽑으면 `AC-W = ff`, `ExternalConnected = No`로 구분 가능).

**단, 20457.1에서는 CH0I/CH0J가 아니다.** chargnr 동일 실측표에 따르면 `CH0B`, `CH0C`, `CHTE`, `CH0I`는 접근 불가(zero-size placeholder로 보고됨), `CH0J`는 `kIOReturnNotPrivileged`로 거부된다. 즉 20457.1에서는 batt의 1·2순위(CH0I/CH0J)가 capability 프로브를 통과하지 못하고 **3순위 CHIE만 동작**한다. MactteryGuard의 어댑터 모드도 CHIE를 실질적인 키로 봐야 하며, CH0I/CH0J는 구형 펌웨어용 폴백으로만 둔다.

### 4.3 동작 방식

- 레거시 모드와 동일한 히스테리시스 루프를 쓰되, 토글 대상이 충전 상태가 아니라 벽전원이다 (`pkg/daemon/charger.go`의 `chargeSwitch` 추상화: `chargeKeySwitch` vs `adapterSwitch`; `pkg/daemon/loop.go` `maintainActiveCharging`, L559).
- 상한 도달 시 벽전원 차단 → 맥이 배터리로 동작하며 잔량 하락 → 하한 도달 시 벽전원 복원 → 충전 재개.
- **최소 밴드 5%** (`adapterMinBand`, `loop.go` L24): 벽전원 차단-복원은 사이클을 소모하므로, 밴드가 좁으면 빈번한 사이클과 SMC 쓰기가 생긴다. 밴드는 하한을 낮추는 방향으로만 넓히고, 상한을 올리지는 않는다.
- 플러그가 뽑혀 있으면 어댑터를 건드리지 않는다 (자를 벽전원이 없으므로). 재연결 후 다음 루프에서 강제 재개.
- **깨어 있을 때만 동작**한다. batt는 수면 직전 안전 상태를 복원/유지하는 훅을 두고, 수면 중에는 상한을 강제할 수 없다 (`docs/compatibility.md` adapter 모드 절).
- **클램셸 주의**: 뚜껑을 닫고 외부 모니터를 쓰는 상태에서 벽전원을 차단하면 맥이 잠든다. batt는 `prevent-sleep-on-adapter-disable` 옵트인으로 대응하는데, 이는 가방 안에서 과열·완전 방전 위험이 있어 안전 경고가 붙는다. chargnr은 반대로 뚜껑 닫힘 상태에서는 절단을 일시정지한다 (§7.3 참조). **MactteryGuard는 chargnr 방식(일시정지)이 안전하다.**
- Adapter 모드에서는 수동 어댑터 제어/강제 방전 기능과 자동 보정이 비활성화된다 (어댑터 소유권 충돌 방지, `compatibility.go` `detectCapabilities`).

## 5. (c) 백엔드 선택 — 런타임 가용성 검사

### 5.1 선택 순서 (`pkg/daemon/compatibility.go` `detectCapabilities`, L13)

```
1. mode = smc.ChargeControlMode()        # SMC 키 가용성으로 판정
2. mode == Unsupported 이면:
     - 어댑터 키 가용 AND 사용자 옵트인(AdapterMode 설정) → Adapter
     - 아니면 detectNativeChargeControl() → Native (가능 시) / Unsupported
3. 선택된 모드 + 근거를 capabilities로 저장해 CLI/GUI에 노출
```

**버전(펌웨어/macOS)으로 분기하지 않는다.** batt 문서와 chargnr 블로그가 모두 이 원칙을 명시한다 ("`batt` probes usable SMC keys or PowerUIAgent at runtime"; chargnr "never branches on versions").

### 5.2 SMC 키 가용성 프로브 — 게이팅 감지가 간접적이다

`pkg/smc/smc.go` `test()` (L88-93), `Open()`에서 모든 키에 대해 1회 수행 후 캐시:

```text
usable(key) = KeyInfo(key) 성공 AND info.DataSize > 0
```

- 이 검사는 커밋 `10c9b9c` ("feat: macos 27 firmware support and capability checks (#142)", 2026-07-13)에서 도입됐다. 이전에는 Read 성공 여부로 판정했다.
- 주석: "Some firmware exposes placeholder key metadata with a zero data size. Such a key cannot be read or written and must not select a control mode."
- chargnr 실측과 대조하면, 20457.1에서 일어나는 일은 두 가지다:
  - `bfF0`/`bfD0`/`bfE0`, `CH0J`: KeyInfo 자체가 `kIOReturnNotPrivileged`(`0xe00002c1`)로 실패 → `err != nil` → 사용 불가.
  - `CH0B`/`CH0C`/`CHTE`/`CH0I`: KeyInfo는 되지만 DataSize 0인 placeholder → 사용 불가.
- 즉 batt은 게이팅을 **쓰기 프로브나 에러 문자열로 직접 감지하지 않는다.** 소스 전체에 `kIOReturnNotPrivileged` 문자열은 문서(`docs/compatibility.md`)에만 있고 Go 코드에는 없다. 키가 프로브를 통과하지 못하면 해당 백엔드는 선택지에서 빠지고, 결과적으로 Native/Adapter로 폴백된다. **게이팅 감지 = 가용성 프로브의 부산물**이다.
- 이 점은 설계 문서 §10 체크 3(쓰기 프로브)과 다르다. batt 방식대로라면 KeyInfo + DataSize 확인만으로 백엔드 선택이 가능하고, 쓰기 프로브는 선택의 전제 조건이 아니라 **선택 후의 확인**에 가깝다. 단, 프로브를 통과한 키의 쓰기가 실제로 성공하는지는 별개 문제이므로, 쓰기 프로브를 완전히 없앨 수는 없다 (§9 참조).

### 5.3 모드 판정 (`pkg/smc/charging.go` `ChargeControlMode`, L23)

```text
bfF0 AND bfD0 AND bfE0 가용 → Firmware   (bfF0 우선: 구형 macOS에 신형 펌웨어가 실릴 수 있음)
(CH0B AND CH0C) OR CHTE 가용 → Legacy
그 외 → Unsupported
```

### 5.4 Native 폴백 판정 (`detectNativeChargeControl`, L95)

1. `PowerUIAgent`의 `isMCLSupported`가 YES일 것 (`d.native.Supported()`).
2. `AvailableLimits()`가 비어 있지 않을 것. (exact-target 경로에서는 10~99 전체, 슬라이더 경로에서는 macOS가 제시하는 값들.)
3. 둘 다 만족하면 Native, 아니면 Unsupported(제어 불가 → 읽기 전용 모드).

### 5.5 선택 후 실행 형태

| 구분 | 백엔드 | 데몬의 일 | 루프 |
|---|---|---|---|
| 관리형 (Apple이 강제) | Firmware, Native | 설정된 상한을 주기적으로 재동기화(reconcile)할 뿐, 충전 토글을 직접 하지 않음 (`isManagedChargeControl`, `maintainManagedChargeLimit`, `loop.go` L454) | `ensureManagedChargeLimit` — 이미 맞으면 쓰지 않음 |
| 능동형 (batt이 강제) | Legacy, Adapter | 배터리를 읽고 히스테리시스 루프로 스위치를 토글 (`maintainActiveCharging`, `loop.go` L559) | `chargeSwitch` 추상화로 레거시/어댑터를 동일 로직으로 처리 |

- **루프 간격 10초** (`pkg/daemon/daemon.go` L104 `loopInterval`).
- **놓친 루프 보호**: 유지보수 루프가 너무 많이 건너뛰어졌는데 충전이 켜져 있으면 즉시 충전을 끄고, 루프가 안정될 때까지 충전을 다시 켜지 않는다 (수면 알림을 못 받았을 때의 과충전 방지, `loop.go` `checkMissedMaintainLoops` / `handleChargingLogic`).
- **재감지**: 어댑터 모드 설정 변경 시 `reapplyChargeControlMode`로 capabilities를 재감지하고 모드를 전환한다 (Native → Adapter 전환 시 네이티브 상한을 먼저 해제, Adapter 이탈 시 벽전원 복원). OS/펌웨어 업그레이드 후에는 `disableUnsupportedConfiguredFeatures`가 미지원 기능·설정을 비활성화하고, 지원하지 않는 상한은 다음 지원 값으로 올린다 (내리지 않는다 — 사용자가 정한 것보다 더 충전하지 않기 위해).

### 5.6 Firmware 백엔드 상세 (참고용 — 이 기기 해당 가능성 낮음)

`pkg/smc/charging.go` `EnsureFirmwareChargeLimit` (L154):

- `bfD0`(상한)/`bfE0`(하한)는 ui32 백분율을 **little-endian**으로 저장한다 (80% = `50 00 00 00`). 일반 SMC 정수와 반대라 `bits.ReverseBytes32`로 변환한다.
- `bfF0`은 1바이트 활성화 플래그: `0x00`=비활성, `0x02`=활성.
- **쓰기 순서가 강제됨**: `bfF0=00` → 상한 → 하한 → `bfF0=02`. 이미 원하는 상태면 쓰지 않는다.
- 펌웨어가 범위를 강제하므로 수면 중에도 유지되고, 상한 위에서는 벽전원을 끊고 배터리로 동작할 수 있다.
- 비활성화는 `bfF0=00`만 쓴다 (`EnsureFirmwareChargeLimitDisabled`, L186).

## 6. (d) 보정 처리 — Native 모드에서 macOS 보정 충전이 일어나면

### 6.1 batt은 보정을 막지 않는다 (막을 수 없다)

- batt 문서(`docs/compatibility.md`): "macOS may also temporarily charge fully" — 네이티브 모드에서도 macOS가 일시적으로 완충할 수 있다. `docs/usage.md` L10: "In native mode, macOS controls enforcement timing and full-charge overrides."
- ampere 주석(독립 확인): powerd의 배터리 게이징 정책이 완충을 시작하면 `chargingtofulloverride` notify 상태가 1이 되고, 그 동안 에이전트가 목표를 등록해도 powerd가 무시한다 ("SOC limit policy suspend due to mitigation active:1"). powerd 로그: "Last full charge date was 21.4 days ago, try and charge to full" — 보정은 수 주 간격으로 일어난다.

### 6.2 batt의 대응: 감지·보고만 하고, 되돌리기는 macOS에 위임

- **오버라이드 상태 읽기** (`pkg/powerui/powerui.m` `batt_powerui_full_charge_override`, L45-58): notify `com.apple.system.powersources.chargingtofulloverride`의 상태를 `notify_register_check` + `notify_get_state`로 읽는다. 권한 불필요, 정책 변경 없음.
- **표시만 한다**: 데몬은 네이티브 모드에서 배터리 상태 응답에 `ChargingToFullOverride` 플래그를 포함시킬 뿐 (`pkg/daemon/handlers.go` L518 부근), 오버라이드에 반응해 뭔가를 쓰지는 않는다. CLI/GUI는 "macOS full-charge override active; charge limit paused to allow charging to 100%." 같은 안내를 보여준다 (`pkg/powerinfo/types.go` L36-37).
- **되돌리기는 macOS 자체 드레인**: 상한 위에 있는 배터리는 macOS가 플러그 연결 상태에서도 상한 쪽으로 드레인한다 (`docs/compatibility.md`: "If the battery is above the limit, macOS may drain it toward the target even while the Mac is plugged in."). chargnr도 동일 현상을 실측했다 (상한 위에서 PDTR ≈ 0W로 배터리로 동작). 즉 **보정 후 되돌리기는 별도 로직이 아니라 네이티브 상한의 기본 동작**이다.
- **no-drain 모드에서는 다르다** (`docs/usage.md` L114): 오버라이드 후 no-drain 상한을 복원할 뿐, 강제로 드레인해서 내리지는 않는다.

### 6.3 batt 자체 보정 워크플로우 (별개 기능 — 혼동 주의)

`pkg/daemon/calibration.go`의 보정은 **batt이 주도하는** 보정(사용자가 시작하거나 스케줄)이다. 단계: 방전(어댑터 차단으로 임계값까지) → 충전(상한 100%로, 100%까지) → 유지(기본 120분) → post-hold(어댑터 차단으로 스냅샷 상한까지 방전) → 복원. macOS 강제 보정에 대한 대응이 아니며, Adapter 모드에서는 어댑터 소유권 충돌 때문에 비활성화된다.

### 6.4 설계 문서 §7과의 관계

- 설계 문서 §7.2의 "보정 중에는 어떤 쓰기도 하지 않는다"는 batt의 동작과 일치한다 (batt도 오버라이드 중에는 쓰지 않고 보고만 한다).
- 설계 문서 §7.3의 "Native: macOS 자체 드레인에 위임한다"는 batt의 실제 동작과 일치한다. 단, **드레인이 시작되기까지의 지연과 소요 시간은 batt 소스·문서 어디에도 수치로 없다** — 설계 문서의 R9(미검증)는 그대로 유지된다.
- 설계 문서 §7.1의 로그 기반 감지(`ChargingUpForGauging`)와 별개로, **notify 상태 읽기가 더 직접적인 보정 감지 경로**다. notify는 권한 없이 읽을 수 있고, 로그 문구에 의존하지 않는다. MactteryGuard는 1차 감지로 notify를, 2차로 OSLogStore/관찰 기반을 두는 것을 검토할 만하다 (§9 참조).

## 7. chargnr 교차 검증

### 7.1 일치하는 것

| 항목 | batt | chargnr | 비고 |
|---|---|---|---|
| 게이팅 사실 | 펌웨어 20457.0.125.0.2+, 엔타이틀먼트 `com.apple.private.iokit.soc-limit`, root라도 `kIOReturnNotPrivileged` (`docs/compatibility.md`) | 펌웨어 20457.1, 동일 엔타이틀먼트, root라도 거부 (블로그, `docs/hardware.md`) | 완전 일치 |
| 게이팅 범위 | CH0B/CH0C/CHTE + bfF0/bfD0/bfE0 | 동일 + CH0J도 거부, CH0I 접근 불가 | chargnr이 키별로 더 세밀하게 실측 |
| 어댑터 키 비게이팅 | "not entitlement-gated" (소스 주석) | CHIE root 읽기·쓰기 가능 실측, PDTR/B0AC 수치 포함 | 실측이 주석을 뒷받침 |
| CHIE 값 | `00`=켜기, `08`=끄기 (`adapter.go`) | 동일 (`docs/hardware.md`) | 일치 |
| bf* 키 형식 | ui32 little-endian, bfF0 00/02, 쓰기 순서 00→상한→하한→02 | 동일하게 문서화 | 일치 |
| 버전 분기 없음 | 런타임 프로브만으로 선택 | "never branches on versions", 시작 시 키 프로브 | 원칙 일치 |
| PowerUI 슬라이더 API | `setMCLLimit:` 등 동일 셀렉터·타입 인코딩 | 동일 셀렉터·인코딩을 실측 기록 (80→ok, 83→ok, 70→code 4 실패) | 타입 인코딩까지 일치 |
| 상한 위 드레인 | "macOS may drain it toward the target even while plugged in" | "macOS's own limit, when the battery is above it, runs the Mac from the battery … until it drops to the limit" (PDTR ≈ 0W 실측) | 일치 |
| 보정 완충 | "macOS may also temporarily charge fully" | (블로그·문서에서 보정 자체는 별도 언급 없음) | 모순 없음 |

### 7.2 보완 관계 (모순이 아닌 차이)

| 항목 | batt | chargnr | MactteryGuard에 주는 의미 |
|---|---|---|---|
| 네이티브 목표 범위 | 설정 직접 쓰기로 10~99% (root 필요) | 슬라이더 API만으로 80~100% (root 불필요) | 80~100%만 필요하면 슬라이더 API가 더 단순하고 안전. 80 미만 네이티브 목표가 필요할 때만 설정 경로를 쓴다 |
| 서브-80% 방식 | 네이티브 설정 경로로 10~99% 지원 (어댑터 모드는 옵트인 대안) | 20~79%는 어댑터 절단 (CHIE) + 수면 중 백스톱으로 네이티브 80% 상한 | 두 접근법이 공존 가능. 네이티브 설정 경로가 깨지면 어댑터 모드가 폴백 |
| 클램셸에서 어댑터 절단 | `prevent-sleep-on-adapter-disable` 옵트인 (수면 방지, 과열 경고) | 뚜껑 닫힘 상태에서는 절단 일시정지 (`AppleClamshellState` + `kIOPMMessageClamshellStateChange` 감시) | **chargnr 방식이 안전** — MactteryGuard는 일시정지 방식을 채택할 것 |
| 수면 중 서브-80% 유지 | 어댑터 모드는 깨어 있을 때만 동작, 수면 직전 안전 상태 복원 | 네이티브 80% 상한을 "수면 중 하한선(sleep floor)"으로 병행 설정 | 서브-80% 사용 시 수면 중 80%까지는 올라가도 100%까지는 안 가는 절충안. 설계에 반영 검토 |
| 안전 하한 | (방전 시간 상한 등은 batt 문서에 별도 수치 없음) | ≤10%에서는 어떤 설정으로도 어댑터 절단 금지. 어댑터 절단만 가능한 열 보호는 40%에서 중단 | 설계 문서 §9.3의 "20% 미만 충전 차단 금지"와 별개로 **어댑터 절단 하한(10%)** 을 명시할 것 |

### 7.3 미묘한 차이 — 15.8 예외와 게이트 집행 주체

- batt 문서: "macOS 15.8 updates bring the same firmware, but their SMC firmware-limit keys stay usable" (이슈 #160, #162). macOS 26.7도 같을 가능성이 있으나 미검증.
- chargnr 블로그: 펌웨어 20457.1이 "macOS 27과 15.8·26.7 보안 업데이트"에 포함됐다고 서술.
- 두 서술은 모순이 아니다. 펌웨어는 같아도 **게이트의 집행은 macOS 27의 AppleSMC 사용자 클라이언트(드라이버 스택)에 의존**할 가능성이 있다: 15.8의 구형 드라이버는 게이트를 집행하지 않아 bf* 키가 계속 쓰이고, 27의 신형 드라이버가 집행한다. chargnr의 게이팅 실측은 macOS 27.0에서 수행됐다.
- **의미**: "판정 기준은 펌웨어 버전이지 macOS 버전이 아니다"(설계 문서 §0)는 다소 단순화다. 펌웨어와 macOS 버전이 모두 관여할 수 있으므로, **런타임 프로브가 유일한 기준**이라는 결론은 더 강해진다. (집행 주체에 대한 추론 자체는 미검증으로 표시한다.)

### 7.4 chargnr이 추가로 확인한 것 (MactteryGuard 설계에 직접 유용)

- `IOPSCopyBatteryLevelLimits()`도 동일하게 게이팅된다. **MactteryGuard는 상한 조회에 이 API를 쓰지 말 것** — `pmset -g battlimit` 파싱 또는 PowerUI getter를 쓴다.
- MagSafe LED: `ACLC` 쓰기는 받아들여지지만 macOS가 자기 값으로 되돌려 읽기 불일치가 생긴다 (20457.1.29). 이 펌웨어에서 LED 제어는 불가로 봐야 한다. (설계 문서는 LED를 다루지 않으므로 영향 없음. 참고만 한다.)
- 온도: macOS 27에서 IORegistry에 `Temperature`가 없다. SMC `TB0T`(`flt` little-endian, 일부 맥은 `sp78`)를 읽어야 한다. (열 보호는 v1 범위 밖이나, 장래 기능 시 참고.)
- `DesignCapacity`/`NominalChargeCapacity`는 macOS 27에서 `BatteryData` 딕셔너리 안에 있다.
- 펌웨어 버전은 `IODeviceTree:/chosen` → `system-firmware-version` (`"mBoot-20457.1.29"`)에서도 읽을 수 있다.
- SMC 드라이버 호출 규격: `IOConnectCallStructMethod` selector 2, 80바이트 파라미터 블록 (key 0, data size 28, data type 32, result 40, command 42 — 5 읽기, 6 쓰기, 8 인덱스별 키, 9 키 정보). 결과 `0x84`는 키 없음. 쓰기는 root 필요.
- 안전 규칙(설계 문서 §9와 대조해 반영할 것): 모든 쓰기는 읽어보고(read-back) 3회 재시도. 스위치 변경 전 의도한 상태를 `/Library/Application Support/chargnr/switched.json`에 저장하고, 시작 시 정상 충전으로 먼저 복원한 뒤 정책을 재적용한다. SIGTERM/SIGINT/SIGHUP 시 정상 충전 복원 후 종료. 수면 직전: 어댑터 방식은 어댑터를 다시 켜고, inhibit 방식은 충전을 멈춘다. 폴링 간격은 상한과의 거리 따라 3분/1분/20초로 조절한다.

## 8. VERIFIED vs UNVERIFIED

### VERIFIED (소스 또는 독립 실측으로 확인)

| # | 항목 | 근거 |
|---|---|---|
| V1 | 네이티브 설정 경로의 도메인·키·notify (`com.apple.smartcharging.topoffprotection`, `MCLFeatureState`, `mclLimitValue`, `com.apple.smartcharging.defaultschanged`) | batt `powerui.m` L204-280 + ampere `NativeChargeLimit.swift` 독립 일치 |
| V2 | PowerUI 슬라이더 API의 셀렉터·타입 인코딩·80~100 범위·80 미만 거부 | batt `powerui.m` L13-20 + chargnr 실측 (83 ok, 70 code 4) |
| V3 | 슬라이더 API는 root 불필요, 설정 경로는 root 필요 | batt `checkPreferenceAccess` (geteuid 검사) + chargnr "works without root" |
| V4 | 등록 확인은 `pmset -g battlimit` 파싱 (`manualChargeLimit`, `Terminated=0`, `chargeSocLimitSoc`) | batt `registration.go` + ampere 동일 파싱 |
| V5 | 등록 지연 사유 (충전 중 레벨 변화/충전 중단 시에만 등록, 배터리 전원 5분 후 철회) | batt `powerui.go` + `docs/compatibility.md` |
| V6 | 어댑터 키 CHIE (`00`/`08`)가 20457.1에서 root로 읽기·쓰기 가능 | chargnr Mac16,8·20457.1.29 실측 (PDTR/B0AC 수치) + batt 주석 |
| V7 | 20457.1에서 CH0B/CH0C/CHTE/CH0I 접근 불가, CH0J/bf*는 `kIOReturnNotPrivileged` | chargnr 실측표 |
| V8 | 백엔드 선택이 KeyInfo+DataSize 프로브 기반, 버전 분기 없음 | batt `smc.go` `test()` + `charging.go` `ChargeControlMode` + `daemon/compatibility.go` |
| V9 | Native 모드에서 macOS 보정 완충을 막지 않고, 되돌리기는 macOS 드레인에 위임 | batt 소스(오버라이드 표시만 함) + 문서 + ampere 주석 |
| V10 | 오버라이드 상태는 notify `com.apple.system.powersources.chargingtofulloverride`로 권한 없이 읽을 수 있음 | batt `powerui.m` L45 + ampere 동일 정의 |
| V11 | no-drain 정책의 저장소·형식·powerd 재시작 절차 | batt `policy.m` (단, v1 범위 밖) |
| V12 | Firmware 백엔드의 bf* 키 형식·쓰기 순서 | batt `charging.go` + chargnr `hardware.md` 일치 |

### UNVERIFIED (여전히 확인되지 않음)

| # | 항목 | 비고 |
|---|---|---|
| U1 | **이 기기(사용자의 Mac, macOS 27.2)의 실제 펌웨어 버전과 키 상태** | 모든 문헌은 20457.1.29/macOS 27.0 기준. 사용자는 27.2이므로 §10 게이트 체크(펌웨어 확인 + KeyInfo 프로브)가 여전히 필수 |
| U2 | 네이티브 모드에서 보정 후 macOS 드레인이 시작되기까지의 지연·소요 시간 | batt·chargnr·ampere 어디에도 수치 없음 (설계 문서 R9 유지) |
| U3 | KeyInfo 실패 vs DataSize 0 중 어느 것이 20457.1의 게이팅 신호인지 (키별) | chargnr 실측표가 답을 준다(bf*/CH0J는 KeyInfo 거부, CH0B/CH0C/CHTE/CH0I는 placeholder). batt 프로브는 두 경우를 동일하게 처리하므로 실무적 영향은 없음. 사실상 해소됐으나, batt 소스만으로는 구분이 안 된다는 점은 기록한다 |
| U4 | 게이트 집행 주체 (펌웨어 자체 vs macOS 27 AppleSMC 드라이버) | 15.8 예외로부터의 추론. 런타임 프로브를 쓰는 한 실무적 영향 없음 |
| U5 | `temporarilyDisableMCL:`의 동작 (완충 후 자동 해제 여부) | chargnr "reported not to clear itself" — 미검증. 1회 완충 기능 설계 시 확인 필요 |
| U6 | 설정 경로(`MCLFeatureState`/`mclLimitValue`)가 macOS 27.2에서도 동일하게 동작하는지 | batt·ampere 확인은 macOS 27.0 기준. 27.2에서의 동작은 실기 확인 필요 (게이트 체크 + 초기 프로토타입) |
| U7 | `enableMCL:`/`disableMCL:`의 정확한 상태 전이 (ChargingToFull 탈출 조건 등) | batt 주석 수준의 이해만 있음. 실측으로 보완 필요 |

## 9. MactteryGuard 설계 반영 사항 (아이디어 수준 — 코드 복사 없음)

설계 문서(`STEP2_DESIGN.md`)에 반영해야 할 사항. **batt 코드를 복사하지 않고, 메커니즘만 참조한다.**

### 9.1 R2 해소 — §5.2 "네이티브 백엔드 메커니즘은 미검증이다"를 업데이트

- 네이티브 메커니즘은 이제 검증됐다 (§2 참조). §5.2의 미검증 표시를 해제하고, 두 경로(슬라이더 API / 설정 직접 쓰기)를 명시한다.
- **구현 시 필요 요소 체크리스트**:
  1. root 데몬에서 CFPreferences 쓰기 (도메인 `com.apple.smartcharging.topoffprotection`, `kCFPreferencesCurrentUser` + `kCFPreferencesAnyHost` — root 데몬의 current user가 root이므로 root 도메인에 쓰인다).
  2. 쓰기 후 `CFPreferencesSynchronize` + `notify_post("com.apple.smartcharging.defaultschanged")`.
  3. `enableMCL:` 호출 조건 (에이전트 비활성 시에만, ChargingToFull 탈출용).
  4. `pmset -g battlimit` 파싱으로 등록 확인 (`manualChargeLimit` + `Terminated=0` + `chargeSocLimitSoc` 일치). 출력 형식 불일치 시 미확인으로 처리 (성공으로 간주하지 않음).
  5. 등록 대기(pending) 상태 처리: 충전 중에는 등록이 늦어질 수 있으므로, pending을 오류가 아닌 진행 중 상태로 UI에 표시하고 다음 패스에서 재확인한다.
  6. 배터리 전원 5분 후 등록 철회: 배터리 전원에서는 등록 대기를 하지 않고 전원 연결을 기다린다.
  7. 해제 시 원래 값 복원: 처음 오버라이드하기 전에 사용자의 기존 `MCLFeatureState`/`mclLimitValue`를 저장해 두었다가(설계 문서 §9.1), 해제·제거 시 복원한다. 원래 값이 없으면(기능을 쓴 적 없음) `disableMCL:`로 해제한다.
  8. 설정 경로 실패 시 슬라이더 API(80~100%)로 폴백하는 것을 검토한다. 설정 경로는 비공식 스키마이므로, 스키마가 바뀌면 슬라이더 경로라도 동작해야 한다.

### 9.2 R3 해소 — §3.3 어댑터 키 정리

- batt의 어댑터 키는 CH0I(1순위)/CH0J(2순위)/CHIE(3순위)이며, **20457.1에서는 CHIE만 동작**한다. §3.3의 CH0I "미검증" 표시를 해소하고, CHIE `08`/`00` 값을 명시한다.
- 어댑터 모드의 실질 키는 CHIE이므로, 게이트 체크에서 CHIE 존재·쓰기 가능 여부를 우선 확인한다.

### 9.3 게이트 체크(§10) 보완

- **체크 1(iSMC 읽기)에 KeyInfo + DataSize 개념을 추가한다.** batt의 실제 선택 기준은 "KeyInfo 성공 AND DataSize > 0"이다. `ismc raw` 덤프에서 키 존재 여부뿐 아니라 **값이 비어 있는 placeholder인지**도 확인한다. CH0B/CH0C/CHTE/CH0I가 placeholder로 보이면 게이팅 구간의 신호다.
- **체크 3(쓰기 프로브)의 우선순위를 조정한다.** batt 방식대로라면 KeyInfo 프로브만으로 백엔드 선택이 가능하다. 쓰기 프로브는 선택의 전제가 아니라, 선택된 백엔드의 키(CHIE 등)에 대해 쓰기가 실제로 되는지 확인하는 용도로 유지한다. CH0B/CH0C 쓰기 프로브는 게이팅 구간에서 거부될 것이 예상되므로, 거부 자체를 정상 결과로 기록한다.
- **체크 추가: `pmset -g battlimit` 실행.** 네이티브 등록 확인 경로가 이 기기에서 동작하는지, 출력 형식이 batt이 파싱하는 형식과 같은지 미리 확인한다.
- **체크 추가: `IOPSCopyBatteryLevelLimits()` 사용 금지 명시.** chargnr 확인에 따르면 이 API도 동일하게 게이팅된다. MactteryGuard는 상한 조회에 이 API를 쓰지 않는다.

### 9.4 보정 감지(§7.1) — notify 경로를 1차로 검토

- 설계 문서는 OSLogStore 폴링을 1차로 두었으나, **notify `com.apple.system.powersources.chargingtofulloverride` 상태 읽기가 더 직접적이다**: 권한 불필요, 로그 문구 변경에 영향받지 않음, batt·ampere 양쪽에서 확인됨. 1차 감지로 notify를, 2차로 OSLogStore/관찰 기반을 두는 것을 검토한다.
- 단, notify 상태는 부팅 후 powerd가 처음 post하기 전까지 0으로 읽힌다(ampere 주석). 초기값 0을 "보정 아님"으로 단정하기 전에 powerd가 한 번이라도 post했는지 알 수 없으므로, 초기 상태에서는 로그·관찰 경로와 교차 확인한다.

### 9.5 Adapter 모드 설계 보완 (§5.2, §8)

- **클램셸 처리**: batt식 수면 방지 옵션이 아니라 **chargnr식 일시정지**를 채택한다. `AppleClamshellState` 보고 중에는 어댑터 절단을 하지 않고(상한·방전·보정 모두 일시정지), `kIOPMMessageClamshellStateChange`로 뚜껑 상태 변화를 즉시 감지한다. 사용자 기기는 외부 모니터 상시 연결 환경이므로 이 항목은 중요도가 높다.
- **수면 직전**: 어댑터 방식은 수면 직전에 어댑터를 다시 켠다(수면 중 절단 상태로 방전되는 것을 방지). chargnr·batt 공통 원칙.
- **Sleep floor 아이디어**: 서브-80% 어댑터 모드 사용 시 네이티브 80% 상한을 병행 설정해, 수면 중(헬퍼가 토글할 수 없을 때)에도 80%까지만 올라가게 한다. chargnr의 방식이다. v1 포함 여부는 사용자 결정 사항으로 §11에 추가한다.
- **어댑터 절단 하한**: 설계 문서 §9.3의 "20% 미만 충전 차단 금지"와 별개로, **어댑터 절단 하한을 10%로 명시**한다(chargnr 안전 규칙). 잔량이 10% 이하면 어떤 설정으로도 어댑터를 차단하지 않는다.

### 9.6 그 외

- **No-drain 정책은 v1 범위 밖**으로 확정한다 (powerd SIGHUP 재시작 필요, 실험적 기능, sleep assertion 검사 등 복잡도). 일반 네이티브 모드의 macOS 드레인을 기본으로 한다. 설계 문서 §1.3의 "no-drain 옵션은 v1 범위 밖"과 일치하므로, 본 조사로 그 결정이 뒷받침된다.
- **원래 값 복원(§9.1)**: ampere의 Originals/마커 패턴을 참조한다. 네이티브 상한을 처음 건드리기 전에 기존 값을 저장하고, 제거 시 복원한다.
- **MagSafe LED**: 20457.1에서는 macOS가 값을 되돌리므로 LED 제어가 불가하다(chargnr 실측). 설계 문서에 LED 항목이 없으므로 추가하지 않는다.
- **폴링 간격 참고**: chargnr은 상한과의 거리에 따라 3분/1분/20초로 조절한다. 설계 문서 §6.1의 고정 10초 폴링 대비 배터리·CPU 부담이 적다. 구현 시 적응형 간격을 검토한다.
- **충전 상태 읽기 참고**: macOS 27에서 `DesignCapacity` 등은 `BatteryData` 딕셔너리 안에 있고, 온도는 IORegistry가 아닌 SMC `TB0T`에서 읽어야 한다. Step 1의 `BatteryMonitor`는 IOKit 전원 API만 쓰므로 영향이 없으나, 장래 용량·온도 표시 시 참고한다.

## 10. 남은 최상위 질문 (구현 전)

1. **이 기기의 펌웨어 버전과 키 상태 실측** (U1) — 모든 문헌은 20457.1.29/macOS 27.0 기준이고 사용자는 macOS 27.2다. §10 게이트 체크 0~1이 여전히 최우선이다.
2. **설정 경로가 macOS 27.2에서 동작하는가** (U6) — batt·ampere 확인은 27.0 기준. 초기 프로토타입에서 `MCLFeatureState`/`mclLimitValue` 쓰기 + notify 후 `pmset -g battlimit` 등록을 직접 확인할 것.
3. **보정 후 macOS 드레인의 지연·소요 시간** (U2) — 문헌에 수치가 없다. 보정 발생 시 실측으로만 알 수 있다. 되돌리기 UX(예상 소요 시간 안내)는 실측 후에 정한다.
4. **서브-80% 목표를 네이티브 설정 경로로 할 것인가, 어댑터 모드로 할 것인가** — 두 경로 모두 검증됐다. 설정 경로는 수면 중에도 유지되고 사이클을 소모하지 않지만 비공식 스키마 의존도가 높고, 어댑터 모드는 검증된 SMC 키를 쓰지만 깨어 있을 때만 동작하고 사이클을 소모한다. v1의 기본 전략을 정해야 한다 (권고: 네이티브 설정 경로를 주, 어댑터 모드를 폴백 — 단, 설정 경로가 27.2에서 확인된 뒤에).
5. **`temporarilyDisableMCL:`의 동작** (U5) — 1회 완충 기능 설계 시 확인 필요. 자동 해제가 안 되면 완충 후 상한 복원을 직접 해야 한다.

## 11. 출처

### batt (주 조사 대상)
- 저장소: https://github.com/charlie0129/batt (조사 커밋 `cab16c7`, v0.10.0-1-gcab16c7)
- 네이티브 백엔드: `pkg/powerui/powerui.go`, `pkg/powerui/powerui.m`, `pkg/powerui/powerui.h`, `pkg/powerui/registration.go`, `pkg/powerui/policy.m`
- SMC/백엔드 선택: `pkg/smc/smc.go`, `pkg/smc/charging.go`, `pkg/smc/adapter.go`, `pkg/smc/consts_arm64.go`, `pkg/compatibility/compatibility.go`, `pkg/daemon/compatibility.go`, `pkg/daemon/loop.go`, `pkg/daemon/managedlimit.go`, `pkg/daemon/charger.go`, `pkg/daemon/nodrain.go`, `pkg/daemon/calibration.go`
- 문서: `docs/compatibility.md` (게이팅·네이티브·어댑터 모드), `docs/usage.md` (no-drain·보정), `README.md`
- 게이팅 이슈: https://github.com/charlie0129/batt/issues/152
- DataSize 프로브 도입 커밋: `10c9b9c` ("feat: macos 27 firmware support and capability checks (#142)")

### chargnr (교차 검증)
- 저장소: https://github.com/rokib16x/chargnr (조사 커밋 `749d83d`, v0.2.1, MIT)
- 블로그: https://www.rokib.dev/blog/chargnr-battery-limit-macos-27 (2026-10-04)
- 키별 실측표: `docs/hardware.md` (Mac16,8 M4 Pro, 펌웨어 20457.1.29, macOS 27.0, 2026-09-23 확인)
- 헬퍼·안전 규칙: `docs/helper.md`
- 네이티브 상한(Swift, 슬라이더 API만): `Sources/ChargnrCore/Hardware/NativeChargeLimit.swift`
- 제어 방식 선택: `Sources/ChargnrCore/Control/ChargePolicy.swift`

### ampere (네이티브 설정 경로 독립 확인)
- 저장소: https://github.com/az-code-lab/ampere (조사 커밋 `dbe16de`, v0.0.72)
- `Sources/Shared/NativeChargeLimit.swift` (도메인·키·notify·오버라이드·원래 값 복원·pmset 파싱)
