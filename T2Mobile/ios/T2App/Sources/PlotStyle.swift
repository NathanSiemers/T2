// NOT YET COMPILED: written on a machine without Xcode. Expect small fixes on first build.
import SwiftUI
import T2Kit

/// Sizes in points, as on the T2 website's Appearance tab (0 = hide).
struct PlotStyle: Equatable {
    var pointSize: Double = 3
    var alpha: Double = 0.35
    var titleSize: Double = 15
    var axisTitleSize: Double = 13
    var axisTextSize: Double = 10
    var legendSize: Double = 10
    var showLegend = true
    var showFit = true
    var showSourceLine = true
}

/// A figure of a real size: inches and dots per inch, as on the website's Publish tab.
struct FigureSpec: Equatable {
    var widthIn: Double = 3.5
    var heightIn: Double = 3.2
    var dpi: Double = 300
    /// print-scale appearance, separate from the on-screen one
    var style = PlotStyle(pointSize: 1.2, alpha: 0.4, titleSize: 8, axisTitleSize: 7, axisTextSize: 6, legendSize: 6)
    var pixelWidth: Int { Int((widthIn * dpi).rounded()) }
    var pixelHeight: Int { Int((heightIn * dpi).rounded()) }
}

let t2Citation = "T2 Database and Search Tool, Nathan O. Siemers, Ph.D., https://www.fiveprime.org"

struct PlotData {
    let x: Column
    let y: [Double]
    let color: Column?
    let keep: Mask
    let xName: String, yName: String, dataset: String
    let selected: Int, universe: Int
}

/// ONE drawing routine for the screen and for exported figures: a figure is this same code
/// drawn into a canvas of widthIn x heightIn inches (1 point = 1/72 inch) and rendered at
/// dpi / 72 pixels per point. What the preview shows is what the file contains.
struct PlotCanvas: View {
    let data: PlotData
    let style: PlotStyle

    private static let palette: [Color] = [
        Color(red: 0.05, green: 0.03, blue: 0.53), Color(red: 0.61, green: 0.09, blue: 0.62),
        Color(red: 0.93, green: 0.47, blue: 0.33), Color(red: 0.42, green: 0.0, blue: 0.66),
        Color(red: 0.80, green: 0.28, blue: 0.47), Color(red: 0.98, green: 0.65, blue: 0.21),
        Color(red: 0.24, green: 0.02, blue: 0.61), Color(red: 0.74, green: 0.21, blue: 0.52)]

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .background(Color.white)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let s = style
        let rows = data.keep.indices.filter { data.keep[$0] && !data.y[$0].isNaN && !data.x.isMissing($0) }
        let title = "Relationship of \(data.xName) and \(data.yName) across \(data.dataset)"
        let top = s.titleSize > 0 ? s.titleSize * 2.6 : 6
        let bottom = s.axisTextSize * 1.6 + s.axisTitleSize * 1.5 + (s.showSourceLine ? s.axisTextSize * 1.4 : 0) + 4
        let left = s.axisTextSize * 3.2 + s.axisTitleSize * 1.4
        let legendLevels = s.showLegend ? (data.color?.levels ?? []) : []
        let right = legendLevels.isEmpty ? 8 : min(size.width * 0.34, s.legendSize * 0.62 * Double(legendLevels.map(\.count).max() ?? 0) + s.legendSize * 2.4)
        let panel = CGRect(x: left, y: top, width: max(10, size.width - left - right), height: max(10, size.height - top - bottom))
        if s.titleSize > 0 {
            ctx.draw(Text(title).font(.system(size: s.titleSize)).foregroundColor(.gray),
                     in: CGRect(x: left, y: 2, width: size.width - left - 4, height: top - 2))
        }
        guard !rows.isEmpty else {
            ctx.draw(Text("No samples have both variables").font(.system(size: s.axisTitleSize)), at: CGPoint(x: panel.midX, y: panel.midY))
            return
        }
        let ys = rows.map { data.y[$0] }
        let (ylo, yhi) = Self.padded(ys.min()!, ys.max()!)
        func py(_ v: Double) -> CGFloat { panel.maxY - CGFloat((v - ylo) / (yhi - ylo)) * panel.height }
        // horizontal grid + y axis labels
        for t in Self.ticks(ylo, yhi) {
            var p = Path(); p.move(to: CGPoint(x: panel.minX, y: py(t))); p.addLine(to: CGPoint(x: panel.maxX, y: py(t)))
            ctx.stroke(p, with: .color(.gray.opacity(0.35)), lineWidth: 0.4)
            if s.axisTextSize > 0 {
                ctx.draw(Text(Self.label(t)).font(.system(size: s.axisTextSize)).foregroundColor(.gray),
                         at: CGPoint(x: panel.minX - 3, y: py(t)), anchor: .trailing)
            }
        }
        func colorOf(_ i: Int) -> Color {
            guard let c = data.color, let codes = c.codes, codes[i] >= 0 else { return Self.palette[0] }
            return Self.palette[codes[i] % Self.palette.count]
        }
        let r = CGFloat(s.pointSize) / 2
        func dot(_ x: CGFloat, _ y: CGFloat, _ i: Int) {
            guard s.pointSize > 0 else { return }
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(colorOf(i).opacity(s.alpha)))
        }
        switch data.x.data {
        case .numeric(let xv):
            let xs = rows.map { xv[$0] }
            let (xlo, xhi) = Self.padded(xs.min()!, xs.max()!)
            func px(_ v: Double) -> CGFloat { panel.minX + CGFloat((v - xlo) / (xhi - xlo)) * panel.width }
            for i in rows { dot(px(xv[i]), py(data.y[i]), i) }
            if s.showFit, let line = Stats.regression(x: xs, y: ys) {
                var p = Path()
                p.move(to: CGPoint(x: px(xs.min()!), y: py(line.intercept + line.slope * xs.min()!)))
                p.addLine(to: CGPoint(x: px(xs.max()!), y: py(line.intercept + line.slope * xs.max()!)))
                ctx.stroke(p, with: .color(Self.palette[0]), lineWidth: max(0.6, s.pointSize * 0.4))
            }
            if s.axisTextSize > 0 {
                for t in Self.ticks(xlo, xhi) {
                    ctx.draw(Text(Self.label(t)).font(.system(size: s.axisTextSize)).foregroundColor(.gray),
                             at: CGPoint(x: px(t), y: panel.maxY + 3), anchor: .top)
                }
            }
        case .categorical(let levels, let codes):
            // one box per level present, points jittered around it (deterministic jitter)
            let present = levels.indices.filter { l in rows.contains { codes[$0] == l } }
            let slot = panel.width / CGFloat(max(1, present.count))
            for (k, l) in present.enumerated() {
                let cx = panel.minX + slot * (CGFloat(k) + 0.5)
                let members = rows.filter { codes[$0] == l }
                for i in members {
                    let jitter = (CGFloat((i &* 2654435761) % 1000) / 1000 - 0.5) * slot * 0.5
                    dot(cx + jitter, py(data.y[i]), i)
                }
                if let b = Stats.box(members.map { data.y[$0] }) {
                    let w = slot * 0.6
                    var p = Path(CGRect(x: cx - w / 2, y: py(b.q3), width: w, height: py(b.q1) - py(b.q3)))
                    p.move(to: CGPoint(x: cx - w / 2, y: py(b.median))); p.addLine(to: CGPoint(x: cx + w / 2, y: py(b.median)))
                    p.move(to: CGPoint(x: cx, y: py(b.q3))); p.addLine(to: CGPoint(x: cx, y: py(b.upperWhisker)))
                    p.move(to: CGPoint(x: cx, y: py(b.q1))); p.addLine(to: CGPoint(x: cx, y: py(b.lowerWhisker)))
                    ctx.stroke(p, with: .color(Self.palette[0]), lineWidth: max(0.5, s.pointSize * 0.25))
                }
                if s.axisTextSize > 0 {   // vertical labels when the slots are narrow, as Thanos does
                    let text = Text(levels[l]).font(.system(size: s.axisTextSize)).foregroundColor(.gray)
                    if slot < CGFloat(levels[l].count) * s.axisTextSize * 0.6 {
                        var c = ctx
                        c.translateBy(x: cx, y: panel.maxY + 3); c.rotate(by: .degrees(-90))
                        c.draw(text, at: .zero, anchor: .trailing)
                    } else {
                        ctx.draw(text, at: CGPoint(x: cx, y: panel.maxY + 3), anchor: .top)
                    }
                }
            }
        }
        // axis line, titles, legend, source line
        var axis = Path(); axis.move(to: CGPoint(x: panel.minX, y: panel.maxY)); axis.addLine(to: CGPoint(x: panel.maxX, y: panel.maxY))
        ctx.stroke(axis, with: .color(.black), lineWidth: 0.6)
        if s.axisTitleSize > 0 {
            ctx.draw(Text(data.xName).font(.system(size: s.axisTitleSize)).foregroundColor(.gray),
                     at: CGPoint(x: panel.midX, y: size.height - (s.showSourceLine ? s.axisTextSize * 1.4 : 0) - 2), anchor: .bottom)
            var c = ctx
            c.translateBy(x: s.axisTitleSize * 0.7, y: panel.midY); c.rotate(by: .degrees(-90))
            c.draw(Text(data.yName).font(.system(size: s.axisTitleSize)).foregroundColor(.gray), at: .zero)
        }
        for (k, name) in legendLevels.enumerated() {
            let ly = panel.minY + CGFloat(k) * s.legendSize * 1.5 + s.legendSize
            guard ly < panel.maxY else { break }
            ctx.fill(Path(ellipseIn: CGRect(x: panel.maxX + 6, y: ly - s.legendSize * 0.3, width: s.legendSize * 0.6, height: s.legendSize * 0.6)),
                     with: .color(Self.palette[k % Self.palette.count]))
            ctx.draw(Text(name).font(.system(size: s.legendSize)), at: CGPoint(x: panel.maxX + 6 + s.legendSize, y: ly), anchor: .leading)
        }
        if s.showSourceLine {
            ctx.draw(Text(t2Citation).font(.system(size: max(4, s.axisTextSize * 0.8))).foregroundColor(.gray),
                     at: CGPoint(x: left, y: size.height - 2), anchor: .bottomLeading)
        }
    }

    static func padded(_ lo: Double, _ hi: Double) -> (Double, Double) {
        let span = hi > lo ? hi - lo : 1
        return (lo - span * 0.04, hi + span * 0.04)
    }
    /// about five round tick values inside lo...hi
    static func ticks(_ lo: Double, _ hi: Double) -> [Double] {
        let raw = (hi - lo) / 5, mag = pow(10, floor(log10(raw))), f = raw / mag
        let step = (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag
        return stride(from: (lo / step).rounded(.up) * step, through: hi, by: step).map { $0 }
    }
    static func label(_ v: Double) -> String { String(format: "%g", (v * 1e6).rounded() / 1e6) }
}
