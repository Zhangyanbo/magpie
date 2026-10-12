import AppKit
import SwiftUI

/// 双击打开的大图窗口：捏合/⌘滚轮缩放，拖动平移，双击在「适合窗口」和「100%」之间切换
struct ImageViewerView: View {
    let target: ViewerTarget
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(white: 0.1)
            if let image {
                ZoomableImage(image: image)
            } else if failed {
                ContentUnavailableView("无法读取图片", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .ignoresSafeArea()
        .task(id: target.path) {   // 原图在后台读，NAS 慢也不卡界面
            let url = URL(fileURLWithPath: target.path)
            image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { return nil }
                // 以像素尺寸为 100%
                if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                    img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
                return img
            }.value
            failed = image == nil
        }
        .navigationTitle(target.title)
        .frame(minWidth: 400, minHeight: 300)
    }
}

private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> FitScrollView {
        let sv = FitScrollView()
        sv.contentView = CenteringClipView()
        sv.allowsMagnification = true
        sv.minMagnification = 0.02
        sv.maxMagnification = 32
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.backgroundColor = NSColor(white: 0.1, alpha: 1)
        sv.drawsBackground = true

        let iv = NSImageView()
        iv.imageScaling = .scaleAxesIndependently
        iv.image = image
        iv.frame = NSRect(origin: .zero, size: image.size)
        sv.documentView = iv
        return sv
    }

    func updateNSView(_ nsView: FitScrollView, context: Context) {}
}

final class FitScrollView: NSScrollView {
    private var didFit = false

    override func layout() {
        super.layout()
        if !didFit, bounds.width > 0 {
            didFit = true
            fit()
        }
    }

    private var fitMagnification: CGFloat {
        guard let doc = documentView, doc.frame.width > 0, doc.frame.height > 0 else { return 1 }
        return min(1, min(bounds.width / doc.frame.width, bounds.height / doc.frame.height))
    }

    func fit() { magnification = fitMagnification }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let doc = documentView {
            let atFit = abs(magnification - fitMagnification) < 0.001
            if atFit {
                let p = doc.convert(event.locationInWindow, from: nil)
                animator().setMagnification(1, centeredAt: p)
            } else {
                animator().magnification = fitMagnification
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "0": fit()
        case "1": magnification = 1
        case "=", "+": magnification *= 1.25
        case "-": magnification /= 1.25
        case " ": window?.performClose(nil)   // 空格关闭，与网格的空格预览一致
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

/// 图片小于窗口时居中显示
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}
