import SwiftUI

/// 아이폰 스타일 배터리 아이콘 — %와 번개를 아이콘 안에 표시한다.
/// 팝오버 헤더와 메뉴바 라벨이 공유한다 (기하값·색상 모드만 프리셋으로 구분).
///
/// - 채움 너비는 잔량에 비례한다.
/// - 충전 중이면 번개 표시.
/// - % 텍스트는 채움 위에서는 반대색, 빈 부분에서는 기본색으로 보여
///   라이트/다크 모드 모두에서 읽힌다 (마스크로 두 레이어 분리).
/// - 컬러 모드 (팝오버 헤더): 외곽선·단자 흰색 고정, 채움은 사용자가
///   지정한 민트(#66E68A, 2026-11-17 스와치 샘플), 20% 이하면 빨강.
/// - 단색 모드 (메뉴바, macOS 기본 배터리 표시 방식): 외곽선 없음 —
///   채움은 한 가지 잉크색, 단자·빈 부분은 잉크 45%로 faint하게 표시.
///   라벨은 숫자 + 번개(충전 중)를 가운데 정렬, 둘 다 반대색 단색
///   (사용자 요청, 2026-11-17). 어두운 곳에서는 흰색, 밝은 곳에서는 검은색.
struct BatteryLevelIcon: View {
    struct Geometry {
        let bodyWidth: CGFloat
        let bodyHeight: CGFloat
        let cornerRadius: CGFloat
        let strokeWidth: CGFloat
        let inset: CGFloat
        let nubWidth: CGFloat
        let nubHeight: CGFloat
        let nubCornerRadius: CGFloat
        let nubSpacing: CGFloat
        let fontSize: CGFloat
        let boltSize: CGFloat
        let labelSpacing: CGFloat

        /// 팝오버 헤더용 (116×48).
        static let header = Geometry(
            bodyWidth: 116, bodyHeight: 48, cornerRadius: 11, strokeWidth: 2.5, inset: 4,
            nubWidth: 6, nubHeight: 18, nubCornerRadius: 2, nubSpacing: 2,
            fontSize: 20, boltSize: 13, labelSpacing: 3
        )

        /// 메뉴바 라벨용 (30×15, % 기호 없이 숫자만 — "100" + 번개가 들어가는 고정 너비).
        /// 단색 모드로 쓴다 (아래 monochrome 참조).
        static let menuBar = Geometry(
            bodyWidth: 30, bodyHeight: 15, cornerRadius: 4.5, strokeWidth: 1.2, inset: 1.5,
            nubWidth: 2, nubHeight: 6, nubCornerRadius: 1, nubSpacing: 1,
            fontSize: 11, boltSize: 8, labelSpacing: 1.5
        )
    }

    static let fillGreen = Color(red: 102/255, green: 230/255, blue: 138/255)
    static let fillRed = Color(red: 0.78, green: 0.42, blue: 0.36)

    let percent: Int
    let isCharging: Bool
    let geometry: Geometry
    /// true면 번개를 항상 흰색으로 그린다 (컬러 모드 메뉴바용; 단색 모드에서는 무시됨).
    /// false면 %와 같은 두 레이어 방식 (헤더: 채움 위 흰색, 빈 부분 기본색).
    let whiteBolt: Bool
    /// 단색 모드 (메뉴바, macOS 기본 배터리 표시 방식).
    /// 채움은 한 가지 잉크색, 단자·빈 부분은 잉크 45%.
    /// 라벨은 숫자 + 번개(충전 중) 가운데 정렬, 둘 다 반대색 단색.
    /// 어두운 곳에서는 흰색 잉크 + 검은 글자, 밝은 곳에서는 검은 잉크 + 흰 글자.
    let monochrome: Bool
    /// 단색 모드의 잉크색을 정한다 (메뉴바 라벨의 colorScheme을 전달받는다).
    let colorScheme: ColorScheme
    /// % 기호 표시 여부. 메뉴바는 숫자만 표시한다 (사용자 요청, 2026-11-17).
    let showPercentSign: Bool

    init(
        percent: Int,
        isCharging: Bool,
        geometry: Geometry,
        whiteBolt: Bool,
        monochrome: Bool = false,
        colorScheme: ColorScheme = .dark,
        showPercentSign: Bool = true
    ) {
        self.percent = percent
        self.isCharging = isCharging
        self.geometry = geometry
        self.whiteBolt = whiteBolt
        self.monochrome = monochrome
        self.colorScheme = colorScheme
        self.showPercentSign = showPercentSign
    }

    /// 단색 모드의 잉크색 (채움·단자·빈 부분의 바탕색).
    /// 컬러 모드에서는 외곽선·단자용 흰색이다.
    private var inkColor: Color {
        guard monochrome else { return .white }
        return colorScheme == .dark ? .white : .black
    }

    /// 단색 모드에서 채움 위 글자색 (잉크의 반대색).
    private var inverseColor: Color {
        colorScheme == .dark ? .black : .white
    }

    /// 채움색. 단색 모드에서는 잉크색, 컬러 모드에서는 민트/빨강.
    private var fillColor: Color {
        if monochrome { return inkColor }
        return percent <= 20 ? Self.fillRed : Self.fillGreen
    }

    var body: some View {
        let g = geometry
        let level = CGFloat(max(0, min(100, percent))) / 100
        let fillWidth = max(0, (g.bodyWidth - g.inset * 2) * level)

        return HStack(spacing: 0) {
            ZStack {
                // 빈 부분. 단색 모드에서는 잉크 45%로 배터리 전체 형태를
                // faint하게 표시한다 (참고 이미지 실측값, 2026-11-17).
                RoundedRectangle(cornerRadius: g.cornerRadius)
                    .fill(monochrome ? inkColor.opacity(0.45) : Color.primary.opacity(0.12))
                // 외곽선 (컬러 모드만 — 단색 모드에서는 아웃라인 없음, 사용자 요청).
                if !monochrome {
                    RoundedRectangle(cornerRadius: g.cornerRadius)
                        .stroke(inkColor, lineWidth: g.strokeWidth)
                }
                // 채움 (잔량 비례 너비). 직사각형을 몸통 안쪽 모양으로 클립한다 —
                // 왼쪽 모서리는 몸통에 맞게 둥글고, 오른쪽 경계는 잔량 위치에
                // 정확히 수직으로 선다. 둥근 채움을 쓰면 오른쪽 경계가 곡선으로
                // 밀려 보여 50%인데도 적어 보이는 문제가 있었다 (2026-11-17).
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(fillColor)
                        .frame(width: fillWidth)
                    Spacer(minLength: 0)
                }
                .frame(width: g.bodyWidth - g.inset * 2, height: g.bodyHeight - g.inset * 2)
                .clipShape(RoundedRectangle(cornerRadius: max(1, g.cornerRadius - g.inset)))
                .animation(.easeInOut(duration: 0.25), value: percent)
                // 라벨. 단색 모드는 가운데 정렬 라벨(아래 참조), 컬러 모드는
                // 기본 레이어 + 채움 모양으로 마스킹한 반대색 레이어.
                if monochrome {
                    monochromeLabel
                } else {
                    ZStack {
                        labelContent(whiteLayer: false)
                        labelContent(whiteLayer: true)
                            .frame(width: g.bodyWidth, height: g.bodyHeight)
                            .mask(fillMask(fillWidth: fillWidth))
                    }
                }
            }
            .frame(width: g.bodyWidth, height: g.bodyHeight)
            // 양극 단자. 단색 모드에서는 빈 부분과 같은 색(잉크 45%) — 사용자 더미 기준.
            RoundedRectangle(cornerRadius: g.nubCornerRadius)
                .fill(monochrome ? inkColor.opacity(0.45) : inkColor)
                .frame(width: g.nubWidth, height: g.nubHeight)
                .padding(.leading, g.nubSpacing)
        }
    }

    /// 단색 모드(메뉴바) 라벨 — 사용자 요청(2026-11-17).
    /// 충전 중이면 숫자 오른쪽에 번개를 붙여 함께 가운데 정렬하고,
    /// 배터리만 쓸 때는 숫자만 가운데 정렬한다. 둘 다 반대색 단색.
    private var monochromeLabel: some View {
        let g = geometry
        return HStack(spacing: g.labelSpacing) {
            Text(showPercentSign ? "\(percent)%" : "\(percent)")
                .font(.system(size: g.fontSize, weight: .semibold))
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: g.boltSize, weight: .bold))
            }
        }
        .foregroundStyle(inverseColor)
        .frame(width: g.bodyWidth, height: g.bodyHeight)
    }

    /// 채움 모양 마스크 (흰색 레이어용). 채움과 같은 위치·크기·클립이다.
    private func fillMask(fillWidth: CGFloat) -> some View {
        let g = geometry
        return HStack(spacing: 0) {
            Rectangle()
                .frame(width: fillWidth)
            Spacer(minLength: 0)
        }
        .frame(width: g.bodyWidth - g.inset * 2, height: g.bodyHeight - g.inset * 2)
        .clipShape(RoundedRectangle(cornerRadius: max(1, g.cornerRadius - g.inset)))
        .frame(width: g.bodyWidth, height: g.bodyHeight)
    }

    /// 번개 + % 라벨 (컬러 모드 전용 — 단색 모드는 spreadLabel을 쓴다).
    /// 기본 레이어는 기본색(번개는 whiteBolt면 흰색),
    /// 채움 위 레이어는 둘 다 흰색.
    private func labelContent(whiteLayer: Bool) -> some View {
        let g = geometry
        let boltColor: Color
        let textColor: Color
        if whiteLayer {
            boltColor = .white
            textColor = .white
        } else {
            boltColor = whiteBolt ? .white : .primary
            textColor = .primary
        }
        // 충전 중이면 숫자 오른쪽에 번개를 붙여 함께 중앙 정렬하고,
        // 배터리만 쓸 때는 숫자만 중앙 정렬한다 (사용자 요청, 2026-11-17).
        return HStack(spacing: g.labelSpacing) {
            Text(showPercentSign ? "\(percent)%" : "\(percent)")
                .font(.system(size: g.fontSize, weight: .semibold))
                .foregroundStyle(textColor)
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: g.boltSize, weight: .bold))
                    .foregroundStyle(boltColor)
            }
        }
    }
}
