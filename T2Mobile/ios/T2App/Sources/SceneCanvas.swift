import SwiftUI
import T2Kit

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// Draws a PlotScene (T2Kit works it out; see PlotBuilder). ONE drawing routine for the
/// screen, the Publish preview and the exported files: a figure is this view at
/// widthIn x heightIn inches (1 point = 1/72 inch) rendered at dpi / 72 pixels per point.
///
/// Nothing is computed here: every position comes from the scene's data coordinates, mapped
/// linearly into the panel. The background is white in light and dark mode, as a figure is.
struct SceneCanvas: View {
    let scene: PlotScene
    let style: PlotStyle
    /// true when the host gave the canvas extra height for the whole legend (the Plot screen,
    /// which can scroll); a figure of a fixed size fits its legend into part of its height
    var legendRoom = false

    var body: some View {
        Canvas { ctx, size in
            SceneDrawing(scene: scene, s: style, legendRoom: legendRoom).draw(&ctx, size)
        }
        .background(Color.white)
    }
}

struct SceneDrawing {
    let scene: PlotScene
    let s: PlotStyle
    var legendRoom = false

    let ink = Color(white: 0.2)
    let faint = Color(white: 0.42)
    let grid = Color(white: 0.88)

    // MARK: text

    private func label(_ string: String, _ size: Double, _ color: Color, bold: Bool = false) -> Text {
        Text(string).font(.system(size: CGFloat(size), weight: bold ? .semibold : .regular)).foregroundColor(color)
    }
    private func measure(_ ctx: GraphicsContext, _ t: Text, width: CGFloat = 10_000) -> CGSize {
        ctx.resolve(t).measure(in: CGSize(width: width, height: 10_000))
    }
    /// shortened to about `width` points at this font size
    private func fitted(_ string: String, size: Double, width: CGFloat) -> String { Self.fitted(string, size: size, width: width) }

    // MARK: the whole figure

    func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let pad: CGFloat = 5
        let fullWidth = max(10, size.width - 2 * pad)
        var top = pad
        var bottom = size.height - pad

        if s.titleSize > 0, !scene.title.isEmpty {
            let t = label(scene.title, s.titleSize, ink, bold: true)
            let h = measure(ctx, t, width: fullWidth).height
            ctx.draw(t, in: CGRect(x: pad, y: top, width: fullWidth, height: h))
            top += h + 1
        }
        if s.subtitleSize > 0, !scene.subtitle.isEmpty {
            let t = label(scene.subtitle, s.subtitleSize, faint)
            let h = measure(ctx, t, width: fullWidth).height
            ctx.draw(t, in: CGRect(x: pad, y: top, width: fullWidth, height: h))
            top += h + 2
        }
        if s.showSourceLine {
            let t = label(t2Citation, max(4, s.axisTextSize * 0.8), faint)
            let h = measure(ctx, t, width: fullWidth).height
            ctx.draw(t, in: CGRect(x: pad, y: bottom - h, width: fullWidth, height: h))
            bottom -= h + 2
        }
        guard scene.kind != .empty, !scene.panels.isEmpty, bottom - top > 20 else {
            let t = label(scene.message.isEmpty ? "Nothing to plot" : scene.message, max(9, s.axisTitleSize), faint)
            ctx.draw(t, in: CGRect(x: pad + 10, y: top + 20, width: fullWidth - 20, height: max(20, bottom - top - 20)))
            return
        }

        var right = size.width - pad
        if s.showLegend, s.legendSize > 0, !scene.legend.isEmpty {
            let available = bottom - top
            let column = min(size.width * 0.3, 170)
            let beside = size.width >= 430 ? Self.legendPlan(scene.legend, s, width: column, maxHeight: available - 4, shrink: false) : nil
            if let beside, beside.columns == 1, beside.fontSize == s.legendSize {
                // beside the panel: every entry in one column at full size
                drawLegend(&ctx, beside, origin: CGPoint(x: right - column + 4, y: top + 2))
                right -= column
            } else {
                // under the panel, complete: the Plot screen made room for all of it; a figure
                // gives it up to 45% of its height, with more columns and a smaller type if it must
                let maxH = legendRoom ? max(available - 120, available * 0.45) : available * 0.45
                let items = Self.legendPlan(scene.legend, s, width: fullWidth, maxHeight: maxH, shrink: true)
                bottom -= items.height + 2
                drawLegend(&ctx, items, origin: CGPoint(x: pad, y: bottom + 2))
            }
        }
        drawPanels(&ctx, CGRect(x: pad, y: top, width: max(10, right - pad), height: max(10, bottom - top)))
    }

    /// The height the legend takes under the panel when the canvas is `width` wide, so that a
    /// scrolling host can give the canvas that much extra room (0 when the legend goes beside
    /// the panel or is not shown).
    static func legendHeightBelow(_ scene: PlotScene, _ s: PlotStyle, width: CGFloat) -> CGFloat {
        guard s.showLegend, s.legendSize > 0, !scene.legend.isEmpty, scene.kind != .empty else { return 0 }
        let w = max(10, width - 10)
        if width >= 430 {
            let beside = legendPlan(scene.legend, s, width: min(width * 0.3, 170), maxHeight: 10_000, shrink: false)
            if beside.columns == 1, beside.height <= 300 { return 0 }
        }
        return legendPlan(scene.legend, s, width: w, maxHeight: 10_000, shrink: false).height + 2
    }

    // MARK: legend

    struct LegendItems {
        var title: String = ""
        var fontSize: Double = 10
        var columns = 1
        var swatches: [(rect: CGRect, color: Color, text: String)] = []
        /// a colour bar for a numeric variable: its rectangle and the two end labels
        var bar: CGRect?
        var barLabels: (String, String) = ("", "")
        var lines: [(point: CGPoint, text: String)] = []
        var height: CGFloat = 0
    }

    /// about the width of a string at this size (0.56 em per character: no GraphicsContext needed)
    private static func textWidth(_ string: String, _ size: Double) -> CGFloat { CGFloat(string.count) * CGFloat(size) * 0.56 }
    private static func fitted(_ string: String, size: Double, width: CGFloat) -> String {
        let room = max(3, Int(width / CGFloat(max(1, size) * 0.56)))
        if string.count <= room { return string }
        return String(string.prefix(max(1, room - 1))) + "\u{2026}"
    }

    /// Lays the legend out in a box `width` wide, relative to its top-left corner. EVERY entry
    /// is placed: columns are added as the height requires, and if the columns would get too
    /// narrow to read and `shrink` allows it, the type is made smaller (never below 5 pt).
    static func legendPlan(_ legend: PlotLegend, _ s: PlotStyle, width: CGFloat, maxHeight: CGFloat, shrink: Bool) -> LegendItems {
        var fs = s.legendSize
        while true {
            let rowH = CGFloat(fs * 1.35)
            var out = LegendItems()
            out.fontSize = fs
            var y: CGFloat = 0
            if !legend.title.isEmpty {
                out.title = fitted(legend.title, size: fs, width: width)
                y += rowH
            }
            var fixed = y
            if legend.range != nil { fixed += CGFloat(fs * 0.7) + 2 + rowH }
            if legend.sizeRange != nil { fixed += rowH }
            if !legend.entries.isEmpty {
                let swatch = CGFloat(fs * 0.75)
                let widest = legend.entries.map { textWidth($0.label, fs) }.max() ?? 0
                let natural = widest + swatch + 12
                let n = legend.entries.count
                let rowsAvailable = max(1, Int((maxHeight - fixed) / rowH))
                // as many columns as the height requires, or as fit side by side at their natural width
                let needed = max(1, Int((Double(n) / Double(rowsAvailable)).rounded(.up)))
                let fitting = max(1, Int(width / natural))
                let columns = max(needed, min(n, fitting))
                let cell = min(natural, width / CGFloat(columns))
                // a cell must show the swatch and about six characters; otherwise try a smaller type
                if shrink, fs > 5, cell < swatch + 8 + CGFloat(fs) * 0.56 * 6 { fs -= 1; continue }
                let rows = Int((Double(n) / Double(columns)).rounded(.up))
                out.columns = columns
                for (k, e) in legend.entries.enumerated() {
                    // fill column by column, so the order reads downwards
                    let col = k / max(1, rows), row = k % max(1, rows)
                    let x = CGFloat(col) * cell, yy = y + CGFloat(row) * rowH
                    out.swatches.append((CGRect(x: x, y: yy + (rowH - swatch) / 2, width: swatch, height: swatch), e.color.color,
                                         fitted(e.label, size: fs, width: cell - swatch - 8)))
                }
                y += CGFloat(rows) * rowH
            }
            if let range = legend.range {
                let barW = min(width, 150)
                out.bar = CGRect(x: 0, y: y + 2, width: barW, height: CGFloat(fs * 0.7))
                out.barLabels = (PlotFormat.number(range.lowerBound), PlotFormat.number(range.upperBound))
                y += CGFloat(fs * 0.7) + 2 + rowH
            }
            if let sizes = legend.sizeRange {
                let text = "Size: \(legend.sizeTitle) (\(PlotFormat.number(sizes.lowerBound)) to \(PlotFormat.number(sizes.upperBound)))"
                out.lines.append((CGPoint(x: 0, y: y), fitted(text, size: fs, width: width)))
                y += rowH
            }
            out.height = y
            return out
        }
    }

    private func drawLegend(_ ctx: inout GraphicsContext, _ items: LegendItems, origin: CGPoint) {
        let fs = items.fontSize
        let rowH = CGFloat(fs * 1.35)
        if !items.title.isEmpty {
            ctx.draw(label(items.title, fs, ink, bold: true), at: CGPoint(x: origin.x, y: origin.y + rowH / 2), anchor: .leading)
        }
        for sw in items.swatches {
            let r = sw.rect.offsetBy(dx: origin.x, dy: origin.y)
            ctx.fill(Path(ellipseIn: r), with: .color(sw.color))
            ctx.draw(label(sw.text, fs, ink), at: CGPoint(x: r.maxX + 4, y: r.midY), anchor: .leading)
        }
        if let bar = items.bar {
            let r = bar.offsetBy(dx: origin.x, dy: origin.y)
            let steps = 40
            for k in 0..<steps {
                let f = Double(k) / Double(steps - 1)
                let piece = CGRect(x: r.minX + r.width * CGFloat(k) / CGFloat(steps), y: r.minY, width: r.width / CGFloat(steps) + 0.5, height: r.height)
                ctx.fill(Path(piece), with: .color(Palette.continuous(f).color))
            }
            ctx.draw(label(items.barLabels.0, fs, ink), at: CGPoint(x: r.minX, y: r.maxY + 1), anchor: .topLeading)
            ctx.draw(label(items.barLabels.1, fs, ink), at: CGPoint(x: r.maxX, y: r.maxY + 1), anchor: .topTrailing)
        }
        for line in items.lines {
            ctx.draw(label(line.text, fs, faint), at: CGPoint(x: origin.x + line.point.x, y: origin.y + line.point.y + rowH / 2), anchor: .leading)
        }
    }

    // MARK: panels

    /// how many panels side by side: the style's choice, or 1, 2, 3 or 4 by their number
    static func panelColumns(_ n: Int, _ s: PlotStyle) -> Int {
        if n <= 1 { return 1 }
        if s.facetColumns > 0 { return min(n, s.facetColumns) }
        return n <= 4 ? 2 : n <= 9 ? 3 : 4
    }

    private func drawPanels(_ ctx: inout GraphicsContext, _ area: CGRect) {
        let n = scene.panels.count
        let columns = Self.panelColumns(n, s)
        let rows = Int((Double(n) / Double(columns)).rounded(.up))
        let gap: CGFloat = 6
        let w = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let h = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (i, panel) in scene.panels.enumerated() {
            let r = CGRect(x: area.minX + CGFloat(i % columns) * (w + gap), y: area.minY + CGFloat(i / columns) * (h + gap), width: w, height: h)
            drawPanel(&ctx, panel, r)
        }
    }

    private func drawPanel(_ ctx: inout GraphicsContext, _ panel: PlotPanel, _ rect: CGRect) {
        let ts = s.axisTextSize, tt = s.axisTitleSize
        let xa = panel.xAxis, ya = panel.yAxis
        var top = rect.minY + 3
        if !panel.title.isEmpty, ts > 0 {
            ctx.draw(label(fitted(panel.title, size: ts, width: rect.width), ts, ink, bold: true), at: CGPoint(x: rect.midX, y: top), anchor: .top)
            top += CGFloat(ts * 1.35)
        }

        // left margin: the y axis title (turned) and the widest tick label
        let yTitleW: CGFloat = tt > 0 && !ya.title.isEmpty ? CGFloat(tt * 1.3) : 0
        let yLabelRoom = rect.width * (ya.kind == .categorical ? 0.34 : 0.2)
        let yLabels = ts > 0 ? ya.labels.map { fitted($0, size: ts, width: yLabelRoom) } : []
        let yLabelW = yLabels.map { measure(ctx, label($0, ts, faint)).width }.max() ?? 0
        let left = rect.minX + yTitleW + yLabelW + 5

        // bottom margin: the x axis title and the tick labels, turned when they do not fit side by side
        let xTitleH: CGFloat = tt > 0 && !xa.title.isEmpty ? CGFloat(tt * 1.35) : 0
        let plotWidth = max(10, rect.maxX - 4 - left)
        var xLabels: [String] = ts > 0 ? xa.labels : []
        var turned = false
        var xLabelH: CGFloat = ts > 0 ? CGFloat(ts * 1.3) : 0
        if xa.kind == .categorical, ts > 0, !xLabels.isEmpty {
            let slot = plotWidth / CGFloat(max(1, xLabels.count))
            let widest = xLabels.map { measure(ctx, label($0, ts, faint)).width }.max() ?? 0
            if widest + 4 > slot {
                turned = true
                let room = min(rect.height * 0.3, 120)
                xLabels = xLabels.map { fitted($0, size: ts, width: room) }
                xLabelH = min(room, (xLabels.map { measure(ctx, label($0, ts, faint)).width }.max() ?? 0)) + 3
            }
        }
        // a survival plot's numbers at risk go under the x axis title, one row per group
        let riskRowH = CGFloat(ts * 1.25)
        let riskRows = ts > 0 ? (panel.riskTable?.rows.count ?? 0) : 0
        let riskH: CGFloat = riskRows > 0 ? CGFloat(riskRows) * riskRowH + CGFloat(ts * 1.5) : 0
        let plot = CGRect(x: left, y: top, width: plotWidth, height: max(10, rect.maxY - xTitleH - xLabelH - 4 - riskH - top))

        func px(_ v: Double) -> CGFloat { plot.minX + CGFloat(xa.fraction(v)) * plot.width }
        func py(_ v: Double) -> CGFloat { plot.maxY - CGFloat(ya.fraction(v)) * plot.height }

        // grid (numeric axes) and tick labels
        for (k, t) in ya.ticks.enumerated() {
            if ya.kind == .numeric {
                var p = Path(); p.move(to: CGPoint(x: plot.minX, y: py(t))); p.addLine(to: CGPoint(x: plot.maxX, y: py(t)))
                ctx.stroke(p, with: .color(grid), lineWidth: 0.5)
            }
            if k < yLabels.count {
                ctx.draw(label(yLabels[k], ts, faint), at: CGPoint(x: plot.minX - 3, y: py(t)), anchor: .trailing)
            }
        }
        // a crowded categorical axis shows every level when turned; a numeric one never crowds
        let slotH = turned ? CGFloat(ts * 1.05) : 0
        let every = turned ? max(1, Int((slotH * CGFloat(xLabels.count) / plot.width).rounded(.up))) : 1
        for (k, t) in xa.ticks.enumerated() {
            if xa.kind == .numeric {
                var p = Path(); p.move(to: CGPoint(x: px(t), y: plot.minY)); p.addLine(to: CGPoint(x: px(t), y: plot.maxY))
                ctx.stroke(p, with: .color(grid), lineWidth: 0.5)
            }
            guard k < xLabels.count, k % every == 0 else { continue }
            let text = label(xLabels[k], ts, faint)
            if turned {
                var c = ctx
                c.translateBy(x: px(t), y: plot.maxY + 3)
                c.rotate(by: .degrees(-90))
                c.draw(text, at: .zero, anchor: .trailing)
            } else {
                ctx.draw(text, at: CGPoint(x: px(t), y: plot.maxY + 3), anchor: .top)
            }
        }

        // marks, clipped to the panel
        var inside = ctx
        inside.clip(to: Path(plot.insetBy(dx: -2, dy: -2)))
        for band in panel.bands where band.xs.count >= 2 {
            var p = Path()
            p.move(to: CGPoint(x: px(band.xs[0]), y: py(band.upper[0])))
            for i in 1..<band.xs.count { p.addLine(to: CGPoint(x: px(band.xs[i]), y: py(band.upper[i]))) }
            for i in stride(from: band.xs.count - 1, through: 0, by: -1) { p.addLine(to: CGPoint(x: px(band.xs[i]), y: py(band.lower[i]))) }
            p.closeSubpath()
            inside.fill(p, with: .color(band.color.color.opacity(band.opacity)))
        }
        let rule = CGFloat(max(0.5, s.pointSize * 0.3))
        if s.pointSize > 0 {
            let radius = CGFloat(s.pointSize) / 2
            for pt in panel.points {
                let r = radius * CGFloat(pt.size)
                inside.fill(Path(ellipseIn: CGRect(x: px(pt.x) - r, y: py(pt.y) - r, width: 2 * r, height: 2 * r)),
                            with: .color(pt.color.color.opacity(s.alpha)))
            }
        }
        for box in panel.boxes {
            let b = box.stats
            var p = Path()
            if box.horizontal {
                let y0 = py(box.position + box.halfWidth), y1 = py(box.position - box.halfWidth), mid = py(box.position)
                p.addRect(CGRect(x: px(b.q1), y: y0, width: px(b.q3) - px(b.q1), height: y1 - y0))
                p.move(to: CGPoint(x: px(b.median), y: y0)); p.addLine(to: CGPoint(x: px(b.median), y: y1))
                p.move(to: CGPoint(x: px(b.q3), y: mid)); p.addLine(to: CGPoint(x: px(b.upperWhisker), y: mid))
                p.move(to: CGPoint(x: px(b.q1), y: mid)); p.addLine(to: CGPoint(x: px(b.lowerWhisker), y: mid))
            } else {
                let x0 = px(box.position - box.halfWidth), x1 = px(box.position + box.halfWidth), mid = px(box.position)
                p.addRect(CGRect(x: x0, y: py(b.q3), width: x1 - x0, height: py(b.q1) - py(b.q3)))
                p.move(to: CGPoint(x: x0, y: py(b.median))); p.addLine(to: CGPoint(x: x1, y: py(b.median)))
                p.move(to: CGPoint(x: mid, y: py(b.q3))); p.addLine(to: CGPoint(x: mid, y: py(b.upperWhisker)))
                p.move(to: CGPoint(x: mid, y: py(b.q1))); p.addLine(to: CGPoint(x: mid, y: py(b.lowerWhisker)))
            }
            inside.stroke(p, with: .color(box.color.color), lineWidth: rule)
        }
        for line in panel.lines where line.xs.count >= 2 {
            var p = Path()
            p.move(to: CGPoint(x: px(line.xs[0]), y: py(line.ys[0])))
            for i in 1..<line.xs.count { p.addLine(to: CGPoint(x: px(line.xs[i]), y: py(line.ys[i]))) }
            let width = rule * CGFloat(line.width)
            inside.stroke(p, with: .color(line.color.color), style: StrokeStyle(lineWidth: width, dash: line.dashed ? [width * 3, width * 2] : []))
        }
        if !panel.bubbles.isEmpty {
            let cellW = plot.width / CGFloat(max(1, xa.hi - xa.lo)), cellH = plot.height / CGFloat(max(1, ya.hi - ya.lo))
            let biggest = min(cellW, cellH) / 2 * 0.92
            for bubble in panel.bubbles {
                let r = max(1.5, biggest * CGFloat(bubble.radius))
                let c = CGPoint(x: px(bubble.x), y: py(bubble.y))
                inside.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(bubble.color.color.opacity(0.55)))
                if ts > 0 { inside.draw(label("\(bubble.count)", ts, ink), at: c) }
            }
        }

        // axis lines, titles, the panel's note
        var axes = Path()
        axes.move(to: CGPoint(x: plot.minX, y: plot.minY)); axes.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        axes.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.stroke(axes, with: .color(ink), lineWidth: 0.6)
        if tt > 0, !xa.title.isEmpty {
            ctx.draw(label(fitted(xa.title, size: tt, width: plot.width), tt, ink), at: CGPoint(x: plot.midX, y: rect.maxY - 2 - riskH), anchor: .bottom)
        }
        if tt > 0, !ya.title.isEmpty {
            var c = ctx
            c.translateBy(x: rect.minX + CGFloat(tt * 0.65), y: plot.midY)
            c.rotate(by: .degrees(-90))
            c.draw(label(fitted(ya.title, size: tt, width: plot.height), tt, ink), at: .zero)
        }
        if let risk = panel.riskTable, riskH > 0 {
            let y0 = rect.maxY - riskH
            ctx.draw(label("Number at risk", ts, faint), at: CGPoint(x: plot.minX, y: y0 + CGFloat(ts * 0.75)), anchor: .leading)
            for (g, row) in risk.rows.enumerated() {
                let y = y0 + CGFloat(ts * 1.5) + (CGFloat(g) + 0.5) * riskRowH
                let color = g < risk.colors.count ? risk.colors[g].color : ink
                let dot = CGFloat(ts * 0.6)
                ctx.fill(Path(ellipseIn: CGRect(x: plot.minX - dot - 12, y: y - dot / 2, width: dot, height: dot)), with: .color(color))
                for (k, t) in risk.times.enumerated() where k < row.count {
                    ctx.draw(label("\(row[k])", ts, color), at: CGPoint(x: px(t), y: y))
                }
            }
        }
        if !panel.note.isEmpty, ts > 0 {
            ctx.draw(label(panel.note, ts, ink), at: CGPoint(x: plot.minX + 4, y: plot.maxY - 4), anchor: .bottomLeading)
        }
    }
}
