// PowerUIClient.swift — 비공개 PowerUI 프레임워크 클라이언트 (슬라이더 API 경로).
//
// macOS 27에서 PowerUIAgent 상한을 설정하는 두 경로 중 하나 (BATT_NATIVE_RESEARCH.md §2):
//  - 슬라이더 API (이 파일): 80–100%. root 불필요. 시스템 설정이 내장 충전 상한에
//    쓰는 경로와 동일하다.
//  - 설정 직접 쓰기 (NativeBackend): 10–99%. root 필요.
//
// 비공개 프레임워크이므로 런타임에 dlopen + NSClassFromString으로 로드하고,
// 셀렉터는 IMP 캐스트로 호출한다 (타입 인코딩은 연구 노트 §2.2의 macOS 27.0 관찰값).
// 프레임워크·클래스·셀렉터가 없으면 nil로 실패하고, 호출자는 설정 경로 또는
// Adapter 백엔드로 폴백한다. Apple 업데이트로 깨질 수 있는 비공식 경로임을 전제로 한다.
//
// 이 파일의 코드는 연구 노트에 기록된 API 사실(셀렉터 이름·타입 인코딩)만을 근거로
// 새로 작성한 것이며, batt 등 다른 프로젝트의 코드를 복사하지 않았다.

import Foundation
import ObjectiveC
import Darwin

/// PowerUISmartChargeClient 래퍼. 실패 시 nil을 반환하는 failable initializer로,
/// 가용성 프로브와 클라이언트 생성을 겸한다.
public final class PowerUIClient {
    private let client: NSObject
    /// dlopen 핸들. 프레임워크를 프로세스 수명 동안 로드 상태로 유지한다 (닫지 않는다).
    private let handle: UnsafeMutableRawPointer

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"

    // MARK: - Init

    public init?() {
        guard let handle = Self.frameworkPath.withCString({ dlopen($0, RTLD_NOW) }) else {
            return nil
        }
        guard let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
            return nil
        }
        let initSel = NSSelectorFromString("initWithClientName:")
        guard cls.instancesRespond(to: initSel),
              let imp = class_getMethodImplementation(cls, initSel)
        else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
        let fn = unsafeBitCast(imp, to: InitFn.self)
        // cls.alloc()은 Swift에서 사용할 수 없으므로 런타임 함수로 동일하게 할당한다.
        // class_createInstance는 alloc()과 같은 +1 미초기화 인스턴스를 돌려준다.
        guard let allocated = class_createInstance(cls, 0) as? AnyObject else { return nil }
        guard let obj = fn(allocated, initSel, "MactteryGuard" as NSString) as? NSObject else {
            return nil
        }
        // 소유권 균형 (실측 크래시 수정): @convention(c) 반환은 Swift가 +1로
        // 간주해 retain하지 않는다. init이 반환한 +1만으로는 `allocated`의
        // 스코프 종료 해제(-1)를 버티지 못해 객체가 해제되고 self.client이
        // 댕글링 포인터가 되어 isSupported()에서 EXC_BAD_ACCESS로 죽는다.
        // 명시적으로 한 번 retain해 client의 수명을 보장한다.
        // (반대 가설이어도 +1 누수에 그치고 크래시는 안 나므로 안전하다.)
        _ = Unmanaged.passUnretained(obj).retain()
        self.client = obj
        self.handle = handle
    }

    // MARK: - Capability

    /// 이 기기가 MCL(최대 충전 상한)을 지원하는지 (isMCLSupported → B).
    public func isSupported() -> Bool {
        guard let imp = implementation(of: "isMCLSupported") else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> ObjCBool
        return unsafeBitCast(imp, to: Fn.self)(client, NSSelectorFromString("isMCLSupported")).boolValue
    }

    /// 에이전트가 현재 활성화되어 있는지 (isMCLCurrentlyEnabled: → Q, 0이 아니면 활성).
    /// 비활성 상태에서는 설정 쓰기 전에 enableMCL:을 호출해야 한다 (연구 노트 §2.6).
    public func isEnabled() -> Bool {
        guard let imp = implementation(of: "isMCLCurrentlyEnabled:") else { return false }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> UInt64
        var error: NSError?
        let value = unsafeBitCast(imp, to: Fn.self)(
            client, NSSelectorFromString("isMCLCurrentlyEnabled:"), &error
        )
        return value != 0
    }

    // MARK: - Limit get/set

    /// 현재 상한 목표를 읽는다 (getMCLLimitWithError: → C). 실패하면 nil.
    public func getLimit() -> Int? {
        guard let imp = implementation(of: "getMCLLimitWithError:") else { return nil }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> CUnsignedChar
        var error: NSError?
        let value = unsafeBitCast(imp, to: Fn.self)(
            client, NSSelectorFromString("getMCLLimitWithError:"), &error
        )
        guard error == nil else { return nil }
        let limit = Int(value)
        guard (1...100).contains(limit) else { return nil }
        return limit
    }

    /// 상한을 설정한다 (setMCLLimit:error: → B). 80 미만은 macOS 27에서 클램프된다.
    /// - Returns: 성공 여부.
    public func setLimit(_ limit: Int) -> Bool {
        guard (1...100).contains(limit) else { return false }
        guard let imp = implementation(of: "setMCLLimit:error:") else { return false }
        typealias Fn = @convention(c) (
            AnyObject, Selector, CUnsignedChar, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> ObjCBool
        var error: NSError?
        let ok = unsafeBitCast(imp, to: Fn.self)(
            client, NSSelectorFromString("setMCLLimit:error:"), CUnsignedChar(limit), &error
        ).boolValue
        return ok && error == nil
    }

    // MARK: - Enable / Disable

    /// 에이전트 활성화 (enableMCL: → B). 비활성 상태에서만 호출한다.
    /// 주의: enableMCL:은 Apple 80% 기본값을 먼저 선택하므로, 호출 후 설정 쓰기로 덮어쓴다.
    public func enable() -> Bool {
        callBoolErrorSelector("enableMCL:")
    }

    /// 에이전트 비활성화 (disableMCL: → B). 등록 제거 시 사용한다.
    public func disable() -> Bool {
        callBoolErrorSelector("disableMCL:")
    }

    // MARK: - Helpers

    /// 셀렉터에 응답하는지 확인한 뒤 IMP를 반환한다.
    /// class_getMethodImplementation은 없는 메서드에도 포워딩 IMP를 돌려주므로,
    /// 반드시 responds(to:) 검사를 먼저 한다.
    private func implementation(of selectorName: String) -> IMP? {
        let sel = NSSelectorFromString(selectorName)
        guard client.responds(to: sel) else { return nil }
        return class_getMethodImplementation(type(of: client), sel)
    }

    private func callBoolErrorSelector(_ selectorName: String) -> Bool {
        guard let imp = implementation(of: selectorName) else { return false }
        typealias Fn = @convention(c) (
            AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> ObjCBool
        var error: NSError?
        let ok = unsafeBitCast(imp, to: Fn.self)(
            client, NSSelectorFromString(selectorName), &error
        ).boolValue
        return ok && error == nil
    }
}
