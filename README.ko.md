# MactteryGuard

English version: [README.md](README.md)

맥북 배터리 충전 상한을 하드한 규칙으로 지키는 네이티브 macOS 앱.
메뉴바 전용(`LSUIElement`, Dock 아이콘 없음). 오픈소스(MIT).

## 왜 만드는가

macOS 내장 80% 충전 제한(Charge Limit)은 케이블을 계속 연결해 두면
macOS가 배터리 보정(Calibration)을 위해 가끔 **100%까지 강제 충전**한다.
보정 중에는 내장 제한을 포함해 모든 제한이 무시된다.

MactteryGuard의 목표는 패턴 학습 없이, 정해진 규칙대로 충전 상한을 지키고,
보정 충전이 끝난 뒤 상한으로 되돌리는 것이다.
**보정 충전 자체는 막을 수 없다** (macOS가 강제한다) — 목표는
100%에 머무는 시간을 최소화하는 것이다.

## 기능 (Step 2)

- **충전 상한 슬라이더 50–100%** (기본 80%). 80% 도달 시 충전 차단,
  75% 이하로 떨어지면 재충전(히스테리시스 limit−5%).
- **두 가지 제어 백엔드**
  - **Native (주)**: macOS PowerUI 충전 상한과 동기화. 80–100%는
    PowerUI 슬라이더 API, 80% 미만은 시스템 설정 경로로 쓴다.
  - **Adapter (폴백·되돌리기)**: SMC 어댑터 키(CHIE)로 충전을
    물리적으로 끊고 다시 연결한다. 보정 후 되돌리기(방전)에 사용한다.
- **보정 감지**: 보정 중에는 메뉴바와 팝오버에 **"macOS 보정 중"** 표시.
  보정 중에는 절대 제어 쓰기를 하지 않고, 보정 종료 후 상한으로 되돌린다.
- **1회 100% 완충 (Top Up)**: 버튼 한 번으로 100%까지 완충한 뒤,
  어댑터 분리·재연결 시 또는 24시간 후 원래 상한으로 자동 복귀.
- **강제 방전 (기본 OFF, 옵트인)**: 상한 초과 시 어댑터를 끊어
  배터리로 방전시킨다. 배터리 사이클을 소모하므로 켤 때 경고한다.
- **데몬 유지**: UI 앱을 종료해도 특권 헬퍼 데몬이 충전 제한을 계속 유지한다.
  (설정에서 '앱 종료 시 충전 제한 해제'로 변경 가능)
- **배터리 상세 정보**: 사이클 수, 상태(Condition), 온도를 팝오버에 표시.
- **안전장치 (FAIL-OPEN)**: 오류·데몬 종료·제거 시 항상 충전 허용 상태로 복귀.
  잔량 20% 미만에서는 충전을 차단하지 않는다.
- **로그**: 앱/데몬 로그를 날짜별 파일로 저장, 30일 후 자동 삭제.

## 요구 사항

- macOS 26.0 이상, Apple Silicon
- 빌드 시 Xcode 27

## 소스에서 빌드하기

**Xcode로 실행**

1. `BatteryGuard.xcodeproj`를 Xcode에서 연다.
2. 상단 실행 대상이 **My Mac**인지 확인한다.
3. `Cmd+R`로 실행한다. 처음 한 번은 서명용 팀 선택이 필요할 수 있다.
   (개인 Apple ID 서명으로 충분하다. 유료 Developer 계정 불필요.)

**터미널로 빌드**

```sh
cd MactteryGuard
xcodebuild -project BatteryGuard.xcodeproj -target BatteryGuard -configuration Debug build
```

**릴리즈 패키징 (.zip + .dmg)**

```sh
./Packaging/package.sh
# → dist/MactteryGuard-<버전>.zip, dist/MactteryGuard-<버전>.dmg
```

## 첫 실행 — 데몬 등록

충전 제어는 root 권한의 헬퍼 데몬이 담당한다. 앱 팝오버에서
**충전 제어**를 켜면 데몬 등록을 안내한다.

1. **데몬 등록** 버튼을 누르면 관리자 암호를 묻는다.
2. macOS가 로그인 항목 승인을 요구하면
   **시스템 설정 → 일반 → 로그인 항목**에서 MactteryGuard를 허용한다.
   (팝오버의 **시스템 설정 열기** 버튼이 해당 화면으로 이동한다.)
3. 등록이 완료되면 팝오버에 데몬 상태(백엔드·제어 상태·상한 등록 여부)가 표시된다.

## Gatekeeper 우회 (공증 없는 앱 실행)

이 앱은 유료 Apple Developer 공증을 받지 않았으므로, 다운로드한 앱을
처음 실행할 때 macOS가 차단할 수 있다. 다음 중 하나로 실행한다.

- **우클릭 실행**: 앱을 우클릭 → **열기** → 확인 대화상자에서 **열기**.
- **터미널로 검역 해제**:

```sh
xattr -dr com.apple.quarantine /Applications/MactteryGuard.app
```

소스에서 직접 빌드한 앱은 검역 속성이 없어 이 과정이 필요 없다.

## 사용법

- **충전 제어 토글**: 상한 제어를 켜고 끈다.
- **상한 슬라이더**: 50–100%. 80% 미만 선택 시
  "macOS 기본 동작과 충돌하거나 드레인이 발생할 수 있다"는 안내가 표시된다.
  (80% 미만은 실험적 기능이다. 검증된 동작은 80%이다.)
- **1회 100% 완충**: 100%까지 한 번 완충한다. 도달 후 어댑터를
  분리했다 다시 연결하거나 24시간이 지나면 원래 상한으로 복귀한다.
- **강제 방전**: 상한 초과 시 어댑터를 끊어 방전한다. 기본 OFF.
  켜면 배터리 사이클 소모 경고가 표시된다.
- **앱 종료 시 충전 제한 해제**: 켜면 앱 종료 시 데몬 제어를 해제한다.
  (기본 OFF — 앱을 종료해도 데몬이 제한을 유지한다.)
- **로그 폴더 열기**: 앱 로그 폴더를 Finder로 연다.
- **제거**: 충전 허용 상태로 복원한 뒤 데몬 등록을 해제하고 앱을 종료한다.

## 로그

| 주체 | 경로 |
| --- | --- |
| 앱 | `~/Library/Logs/MactteryGuard/` |
| 데몬 (root) | `/Library/Logs/MactteryGuard/` |

데몬 로그는 root 소유이므로 터미널에서 `sudo`로 확인한다.

```sh
sudo ls /Library/Logs/MactteryGuard/
sudo tail -f /Library/Logs/MactteryGuard/helper-*.log
```

두 로그 모두 날짜별 파일(`mactteryguard-YYYY-MM-DD.log`, `helper-YYYY-MM-DD.log`)이며
30일이 지난 파일은 자동 삭제된다.

## 문제 해결

- **데몬 상태가 "찾을 수 없음"**: 앱 번들에 헬퍼가 임베딩되지 않았다.
  Clean Build 후 다시 빌드한다
  (`MactteryGuard.app/Contents/Library/LaunchDaemons/` 안에
  `MactteryGuardHelper`와 `com.loveaimg.mactteryguard.helper.plist`가 있어야 한다).
- **"승인 대기 중"**: 시스템 설정 → 일반 → 로그인 항목에서 허용한다.
- **상한이 등록되지 않음 ("미등록")**: 노트북이 배터리 전원으로 동작 중이면
  macOS가 상한 등록을 철회한다. 어댑터 연결 후 1분 정도 기다린다.
  보정 중에도 상한 등록이 일시 해제된다.
- **100%까지 충전됨**: 보정이 진행 중일 가능성이 가장 크다.
  메뉴바에 "macOS 보정 중"이 표시되는지 확인한다. 보정은 막을 수 없고,
  종료 후 MactteryGuard가 상한으로 되돌린다.
- **상한 등록 상태 직접 확인**:

```sh
pmset -g battlimit
```

## 수동 제거 (앱 제거 버튼이 동작하지 않을 때)

```sh
# 데몬 중지·등록 해제
sudo launchctl bootout system/com.loveaimg.mactteryguard.helper
sudo rm -rf "/Library/Application Support/MactteryGuard"
sudo rm -rf /Library/Logs/MactteryGuard
rm -rf ~/Library/Logs/MactteryGuard
# 앱 삭제
rm -rf /Applications/MactteryGuard.app
```

데몬이 중지되면 충전은 허용 상태로 복귀한다(FAIL-OPEN).

## 알려진 한계

- macOS 보정 충전은 어떤 앱도 막을 수 없다. MactteryGuard는 보정 종료 후
  되돌리는 것만 할 수 있다.
- 80% 미만 상한은 시스템 설정 경로(비공개 메커니즘)에 의존하며,
  macOS 업데이트로 동작이 바뀔 수 있다.
- 직접 SMC 충전 차단 키(CH0B/CH0C)는 최신 펌웨어에서 게이팅되어
  사용할 수 없다. 어댑터 키(CHIE)만 사용한다.
- XPC 연결은 v1에서 호출자 코드 서명을 검증하지 않는다
  (로컬 mach 서비스, 동일 기기 내에서만 접근 가능).

## 라이선스

MIT License — [LICENSE](LICENSE) 참조.
