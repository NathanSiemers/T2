import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import T2Kit

/// A figure of a real size. The preview and the exported file are the SAME view
/// (SceneCanvas at widthIn x heightIn inches, 72 points per inch); the file is that view
/// rendered at dpi / 72 pixels per point (PNG, with the resolution recorded in the file),
/// or as vector PDF.
struct PublishView: View {
    @Environment(AppModel.self) private var model
    @State private var exported: URL?
    @State private var message = ""
    @State private var presetID = FigurePreset.all[0].id

    var body: some View {
        NavigationStack {
            Group {
                if model.meta == nil {
                    NoDatasetView()
                } else {
                    form
                }
            }
            .navigationTitle("Publish")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var form: some View {
        @Bindable var model = model
        let scene = model.scene(fitLine: model.figure.style.showFit)
        Form {
            Section {
                GeometryReader { geo in
                    let scale = min(1, geo.size.width / CGFloat(model.figure.widthIn * 72))
                    figureView(scene)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: CGFloat(model.figure.widthIn * 72) * scale, height: CGFloat(model.figure.heightIn * 72) * scale, alignment: .topLeading)
                        .border(Color.gray.opacity(0.4), width: 0.5)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: previewHeight)
                .accessibilityElement()
                .accessibilityLabel("Figure preview")
                .accessibilityIdentifier("publish-preview")
                Text(readout).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("publish-readout")
            } header: {
                Text("Preview (the figure itself, scaled to fit)")
            }
            Section("Size") {
                Picker("Start from", selection: $presetID) {
                    ForEach(FigurePreset.all) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("publish-preset")
                .onChange(of: presetID) { _, new in apply(new) }
                Stepper(String(format: "Width %.2f in", model.figure.widthIn), value: $model.figure.widthIn, in: 1...20, step: 0.25)
                Stepper(String(format: "Height %.2f in", model.figure.heightIn), value: $model.figure.heightIn, in: 1...20, step: 0.25)
                Picker("Resolution", selection: $model.figure.dpi) {
                    ForEach([150.0, 200, 300, 450, 600], id: \.self) { Text("\(Int($0)) dpi").tag($0) }
                }
            }
            Section("Sizes at final print size (points)") {
                Stepper("Title \(Int(model.figure.style.titleSize))", value: $model.figure.style.titleSize, in: 0...40)
                Stepper("Subtitle \(Int(model.figure.style.subtitleSize))", value: $model.figure.style.subtitleSize, in: 0...40)
                Stepper("Axis titles \(Int(model.figure.style.axisTitleSize))", value: $model.figure.style.axisTitleSize, in: 0...40)
                Stepper("Axis labels \(Int(model.figure.style.axisTextSize))", value: $model.figure.style.axisTextSize, in: 0...40)
                Stepper("Legend \(Int(model.figure.style.legendSize))", value: $model.figure.style.legendSize, in: 0...40)
                LabeledContent("Point size") { Slider(value: $model.figure.style.pointSize, in: 0...6) }
                Toggle("Legend", isOn: $model.figure.style.showLegend)
                Toggle("Fit line", isOn: $model.figure.style.showFit)
                Toggle("Source line", isOn: $model.figure.style.showSourceLine)
                if !model.figure.style.showSourceLine {
                    Text("You removed the source line. Please cite T2 in anything that uses this figure: \(t2Citation)")
                        .font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Section {
                Button("Plot: PNG") { export(scene, pdf: false) }.accessibilityIdentifier("export-png")
                Button("Plot: PDF (vector)") { export(scene, pdf: true) }.accessibilityIdentifier("export-pdf")
                if let exported {
                    ShareLink(item: exported) { Label("Share or save the file", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("publish-share")
                    Text(exported.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("publish-message") }
            } header: {
                Text("Export")
            } footer: {
                Text("Citing T2: \(t2Citation)")
            }
        }
    }

    /// the preview is as wide as the screen allows, never larger than the figure itself
    private var previewHeight: CGFloat {
        let available: CGFloat = 330
        let scale = min(1, available / CGFloat(model.figure.widthIn * 72))
        return CGFloat(model.figure.heightIn * 72) * scale + 4
    }
    private var readout: String {
        let f = model.figure
        return String(format: "%.2f x %.2f in (%.0f x %.0f mm) at %ld dpi = %ld x %ld pixels",
                      f.widthIn, f.heightIn, f.widthIn * 25.4, f.heightIn * 25.4, Int(f.dpi), f.pixelWidth, f.pixelHeight)
    }
    private func figureView(_ scene: PlotScene) -> some View {
        SceneCanvas(scene: scene, style: model.figure.style)
            .frame(width: CGFloat(model.figure.widthIn * 72), height: CGFloat(model.figure.heightIn * 72))
    }
    private func apply(_ id: String) {
        guard let p = FigurePreset.all.first(where: { $0.id == id }) else { return }
        model.figure.widthIn = p.widthIn
        model.figure.heightIn = p.heightIn
        model.figure.dpi = p.dpi
        model.figure.style = p.style
        exported = nil
        message = ""
    }

    @MainActor private func export(_ scene: PlotScene, pdf: Bool) {
        let f = model.figure
        let base = "T2_\(model.x)_vs_\(model.y)_\(String(format: "%.2fx%.2fin", f.widthIn, f.heightIn))"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let renderer = ImageRenderer(content: figureView(scene))
        let dir = FileManager.default.temporaryDirectory
        exported = nil
        if pdf {
            let url = dir.appendingPathComponent(base + ".pdf")
            var ok = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
                ok = true
            }
            guard ok else { message = "Could not write the PDF."; return }
            exported = url
            message = String(format: "PDF, %.2f x %.2f in, vector", f.widthIn, f.heightIn)
        } else {
            // the same ceiling as the website (T2_FIG_MAX_PIXELS): a phone must not run out of memory
            guard Double(f.pixelWidth) * Double(f.pixelHeight) <= 60e6 else {
                message = "That is \(f.pixelWidth * f.pixelHeight / 1_000_000) megapixels; the limit is 60. Choose a lower resolution, or PDF."
                return
            }
            renderer.scale = CGFloat(f.dpi / 72)
            renderer.isOpaque = true
            guard let image = renderer.cgImage else { message = "Could not render the figure."; return }
            let url = dir.appendingPathComponent(base + "_\(Int(f.dpi))dpi.png")
            // ImageIO, so that the file records its resolution (a 300 dpi PNG opens at 3.5 in, not 14.6)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                message = "Could not create the PNG file."; return
            }
            let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: f.dpi, kCGImagePropertyDPIHeight: f.dpi]
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { message = "Could not write the PNG file."; return }
            exported = url
            message = "PNG, \(image.width) x \(image.height) pixels at \(Int(f.dpi)) dpi"
        }
    }
}
