import CoreGraphics

/// **The point size, owned in one place** (PLAN.md §5.7).
///
/// It was the literal `14` in six of them — `AppDelegate`, `Screenshot`,
/// `SceneDump`, `SceneStates` twice and `TextBench` — which is survivable while
/// a number is a constant and is exactly the shape of bug that appears the
/// moment it stops being one. The tools would have gone on drawing 14 pt while
/// the window drew something else, and the screenshots would have quietly
/// stopped describing the product.
///
/// **The ladder is free to be chosen for how it feels**, which it was not
/// before §5.7. Every one of these sizes keeps the cell at a clean 1:2 — the
/// ratio the rail icons and the join code's block digits are built on — because
/// the cell height is now *derived* as twice the width rather than falling out
/// of a designed line height that only four sizes in thirteen happened to
/// agree with. So the steps are fine where people actually adjust and coarser
/// at the ends, rather than being whichever sizes the grid tolerated.
enum Zoom {
    static let steps: [CGFloat] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24]
    /// 14 pt — the size §5.2 designed the palette, the metrics and the
    /// composition at, and the size every screenshot in `docs/shots` is taken
    /// at so a design conversation has one baseline.
    static let defaultIndex = 4
    static var defaultPointSize: CGFloat { steps[defaultIndex] }

    static func clamp(_ i: Int) -> Int { min(max(0, i), steps.count - 1) }
}
