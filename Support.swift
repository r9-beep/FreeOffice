import SwiftUI
import AppKit

/// Debounced writer for one document file. Each native editor fills in `make`.
final class AutoSaver {
    let url: URL
    var make: () -> Data? = { nil }
    var onSaved: (() -> Void)?
    private var work: DispatchWorkItem?
    private(set) var dirty = false
    init(url: URL) { self.url = url }
    func touch() {
        dirty = true; work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }; work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    func flush() { work?.cancel(); if dirty { save() } }
    func save() { if let d = make() { try? d.write(to: url, options: .atomic); dirty = false; onSaved?() } }
}

func docURL(_ dir: URL, _ app: String, _ id: String) -> URL { dir.appendingPathComponent("office__\(app)__\(id).json") }
func nowMillis() -> Double { Date().timeIntervalSince1970 * 1000 }

extension Color {
    /// "#rrggbb" / "#rgb" (empty or invalid -> clear)
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .clear; return }
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: 1)
    }
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

func savePanel(_ name: String, types: [String] = []) -> URL? {
    let p = NSSavePanel(); p.nameFieldStringValue = name
    return p.runModal() == .OK ? p.url : nil
}

/// Snapshot-based undo/redo. Rapid edits (typing, dragging) within 0.7s merge into one step.
final class UndoHistory<S> {
    private var undoStack: [S] = [], redoStack: [S] = []
    private var last = Date.distantPast
    var applying = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func record(_ old: S) {
        guard !applying else { return }
        if undoStack.isEmpty || Date().timeIntervalSince(last) > 0.7 {
            undoStack.append(old); if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        last = Date()
    }
    /// Returns the state to restore, or nil when there's nothing to undo.
    func undo(current: S) -> S? {
        guard let s = undoStack.popLast() else { return nil }
        redoStack.append(current); last = .distantPast; return s
    }
    func redo(current: S) -> S? {
        guard let s = redoStack.popLast() else { return nil }
        undoStack.append(current); last = .distantPast; return s
    }
}

/// Lays children out left-to-right and wraps them onto new rows (used for the Writer and Sheets ribbons).
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    private func arrange(_ maxW: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0, frames: [CGRect] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            frames.append(CGRect(x: x, y: y, width: sz.width, height: sz.height))
            x += sz.width + spacing; rowH = max(rowH, sz.height); widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowH), frames)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { arrange(proposal.width ?? .infinity, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, f) in zip(subviews, arrange(bounds.width, subviews).frames) { s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size)) }
    }
}
