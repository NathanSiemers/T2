// NOT YET COMPILED: written on a machine without Xcode. Expect small fixes on first build.
import SwiftUI
import UniformTypeIdentifiers
import T2Kit

/// A figure of a real size. The preview and the exported file are the SAME view (PlotCanvas
/// at widthIn x heightIn inches, 72 points per inch); the file is that view rendered at
/// dpi / 72 pixels per point, or as vector PDF.
struct PublishView: View {
    @Environment(AppModel.self) private var model
    @State private var exported: URL?
    @State private var message = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Size") {
                    Picker("Preset", selection: Binding(get: { "" }, set: { apply($0) })) {
                        Text("Choose...").tag("")
                        Text("Half page wide, 1/3 page high (3.5 x 3.2 in)").tag("half")
                        Text("Full page wide, half page high (7 x 4.75 in)").tag("full")
                        Text("Nature single column (89 x 80 mm)").tag("nature1")
                        Text("Slide 16:9 (13.33 x 7.5 in)").tag("slide")
                    }
                    Stepper(String(format: "Width %.2f in", model.figure.widthIn), value: $model.figure.widthIn, in: 1...20, step: 0.25)
                    Stepper(String(format: "Height %.2f in", model.figure.heightIn), value: $model.figure.heightIn, in: 1...20, step: 0.25)
                    Picker("Resolution", selection: $model.figure.dpi) { ForEach([150.0, 200, 300, 450, 600], id: \.self) { Text("\(Int($0)) dpi").tag($0) } }
                    Text("\(model.figure.pixelWidth) x \(model.figure.pixelHeight) pixels").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sizes at final print size (points)") {
                    Stepper("Title \(Int(model.figure.style.titleSize))", value: $model.figure.style.titleSize, in: 0...40)
                    Stepper("Axis titles \(Int(model.figure.style.axisTitleSize))", value: $model.figure.style.axisTitleSize, in: 0...40)
                    Stepper("Axis labels \(Int(model.figure.style.axisTextSize))", value: $model.figure.style.axisTextSize, in: 0...40)
                    Stepper("Legend \(Int(model.figure.style.legendSize))", value: $model.figure.style.legendSize, in: 0...40)
                    LabeledContent("Point size") { Slider(value: $model.figure.style.pointSize, in: 0...6) }
                    Toggle("Legend", isOn: $model.figure.style.showLegend)
                    Toggle("Source line", isOn: $model.figure.style.showSourceLine)
                    if !model.figure.style.showSourceLine {
                        Text("You removed the source line. Please cite T2 in anything that uses this figure: \(t2Citation)")
                            .font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                Section("Preview (the figure itself, scaled to fit)") {
                    if let data = model.plotData() {
                        figureView(data).scaleEffect(previewScale, anchor: .topLeading)
                            .frame(width: model.figure.widthIn * 72 * previewScale, height: model.figure.heightIn * 72 * previewScale, alignment: .topLeading)
                    } else { Text("Choose variables on the Select tab first.") }
                }
                Section {
                    Button("Plot: PNG") { export(pdf: false) }
                    Button("Plot: PDF (vector)") { export(pdf: true) }
                    if let exported { ShareLink("Share or save \(exported.lastPathComponent)", item: exported) }
                    if !message.isEmpty { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Publish")
        }
    }

    private var previewScale: CGFloat { min(1, 330 / (model.figure.widthIn * 72)) }
    private func figureView(_ data: PlotData) -> some View {
        PlotCanvas(data: data, style: model.figure.style).frame(width: model.figure.widthIn * 72, height: model.figure.heightIn * 72)
    }
    private func apply(_ preset: String) {
        switch preset {
        case "half": (model.figure.widthIn, model.figure.heightIn, model.figure.dpi) = (3.5, 3.2, 300)
        case "full": (model.figure.widthIn, model.figure.heightIn, model.figure.dpi) = (7, 4.75, 300)
        case "nature1": (model.figure.widthIn, model.figure.heightIn, model.figure.dpi) = (89 / 25.4, 80 / 25.4, 450)
        case "slide":
            (model.figure.widthIn, model.figure.heightIn, model.figure.dpi) = (13.33, 7.5, 150)
            model.figure.style = PlotStyle(pointSize: 4, alpha: 0.4, titleSize: 24, axisTitleSize: 20, axisTextSize: 16, legendSize: 16)
        default: break
        }
    }
    @MainActor private func export(pdf: Bool) {
        guard let data = model.plotData() else { return }
        let name = "T2_\(data.xName)_vs_\(data.yName)_\(model.figure.widthIn)x\(model.figure.heightIn)in"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let renderer = ImageRenderer(content: figureView(data))
        let dir = FileManager.default.temporaryDirectory
        do {
            if pdf {
                let url = dir.appendingPathComponent(name + ".pdf")
                renderer.render { size, draw in
                    var box = CGRect(origin: .zero, size: size)
                    guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
                    pdf.beginPDFPage(nil); draw(pdf); pdf.endPDFPage(); pdf.closePDF()
                }
                exported = url
            } else {
                renderer.scale = model.figure.dpi / 72
                guard let png = renderer.uiImage?.pngData() else { message = "Could not render the figure"; return }
                let url = dir.appendingPathComponent(name + "_\(Int(model.figure.dpi))dpi.png")
                try png.write(to: url)
                exported = url
            }
            message = "Ready: \(exported?.lastPathComponent ?? "")"
        } catch { message = "Export failed: \(error.localizedDescription)" }
    }
}
