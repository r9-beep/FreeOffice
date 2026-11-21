import SwiftUI
import AppKit

// Full-screen presenter: transitions, a notes view with next-slide preview and timer, blackout.

final class ShowState: ObservableObject {
    let slides: [Slide], deck: DeckSettings, images: ImageCache
    @Published var i: Int
    @Published var forward = true
    @Published var notes = false
    @Published var cover: Color?          // b = black, w = white
    let started = Date()
    init(_ s: [Slide], _ d: DeckSettings, _ im: ImageCache, _ i: Int) { slides = s; deck = d; images = im; self.i = i }
    var transitionName: String { let t = slides[i].transition; return t.isEmpty ? deck.transition : t }
}

final class PresentWindow: NSWindow {
    var state: ShowState!
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func go(_ n: Int, forward: Bool) {
        guard n >= 0, n < state.slides.count, n != state.i else { return }
        state.forward = forward
        withAnimation(.easeInOut(duration: state.slides[n].transition == "none" || (state.slides[n].transition.isEmpty && state.deck.transition == "none") ? 0 : 0.45)) { state.i = n }
    }
    func next() { if state.i < state.slides.count - 1 { go(state.i + 1, forward: true) } else { close() } }
    func prev() { go(state.i - 1, forward: false) }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: close()                                         // esc
        case 124, 125, 49, 121, 36: next()                       // → ↓ space pgdn return
        case 123, 126, 116, 51: prev()                           // ← ↑ pgup delete
        case 115: go(0, forward: false)                          // home
        case 119: go(state.slides.count - 1, forward: true)      // end
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "n": state.notes.toggle()
            case "b": state.cover = state.cover == .black ? nil : .black
            case "w": state.cover = state.cover == .white ? nil : .white
            default: super.keyDown(with: e)
            }
        }
    }
    override func mouseDown(with e: NSEvent) { next() }
    override func rightMouseDown(with e: NSEvent) { prev() }
}

enum Presenter {
    static var window: PresentWindow?
    static func start(_ slides: [Slide], _ deck: DeckSettings, _ images: ImageCache, from: Int) {
        guard let screen = NSScreen.main, !slides.isEmpty else { return }
        window?.close()
        let st = ShowState(slides, deck, images, min(max(0, from), slides.count - 1))
        let w = PresentWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.state = st; w.isReleasedWhenClosed = false; w.backgroundColor = .black; w.level = .mainMenu + 1
        w.contentView = NSHostingView(rootView: ShowView(state: st))
        window = w; w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct ShowView: View {
    @ObservedObject var state: ShowState

    func transition(_ n: String) -> AnyTransition {
        let edge: Edge = state.forward ? .trailing : .leading, out: Edge = state.forward ? .leading : .trailing
        switch n {
        case "none": return .identity
        case "slide": return .asymmetric(insertion: .move(edge: edge), removal: .opacity)
        case "push": return .asymmetric(insertion: .move(edge: edge), removal: .move(edge: out))
        case "zoom": return .scale(scale: 0.86).combined(with: .opacity)
        default: return .opacity
        }
    }

    var body: some View {
        GeometryReader { g in
            let k = min(g.size.width / slideW, g.size.height / slideH)
            ZStack {
                Color.black
                SlideThumb(slide: state.slides[state.i], deck: state.deck, number: state.i + 1, images: state.images, width: slideW * k)
                    .id(state.i).transition(transition(state.transitionName))
                if let c = state.cover { c.ignoresSafeArea() }
                VStack {
                    Spacer()
                    if state.notes { notesPanel.padding(20) }
                    else { HStack { Spacer(); Text("\(state.i + 1) / \(state.slides.count)").font(.fo(.caption)).foregroundStyle(.white.opacity(0.4)).padding(14) } }
                }
            }
            .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .ignoresSafeArea()
    }

    var notesPanel: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.fo(.caption).weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                ScrollView { Text(state.slides[state.i].notes.isEmpty ? "No notes for this slide." : state.slides[state.i].notes).font(.fo(size: 20)).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading) }
            }
            VStack(alignment: .trailing, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = Int(ctx.date.timeIntervalSince(state.started))
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(.system(size: 26, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                }
                Text("Slide \(state.i + 1) of \(state.slides.count)").font(.fo(.caption)).foregroundStyle(.white.opacity(0.6))
                if state.i + 1 < state.slides.count {
                    SlideThumb(slide: state.slides[state.i + 1], deck: state.deck, number: state.i + 2, images: state.images, width: 230).clipShape(.rect(cornerRadius: 6))
                    Text("Next").font(.fo(.caption)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(18).frame(maxHeight: 280).background(.black.opacity(0.82), in: .rect(cornerRadius: 18))
    }
}
