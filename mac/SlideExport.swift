// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppKit

extension SlidesModel {
    func host(_ i: Int) -> StaticSlideHost { StaticSlideHost(slide: slides[i], deck: deck, number: i + 1, images: images) }
    private var fileBase: String { title.isEmpty ? "slides" : title }

    // MARK: PDF / PNG
    @MainActor func exportPDF() {
        guard let u = savePanel(fileBase + ".pdf") else { return }
        writePDF(to: u)
    }
    @MainActor func writePDF(to u: URL) {
        var box = CGRect(x: 0, y: 0, width: slideW, height: slideH)
        guard let ctx = CGContext(u as CFURL, mediaBox: &box, nil) else { return }
        for i in slides.indices {
            let r = ImageRenderer(content: CanvasPage(m: host(i), interactive: false))
            r.render { _, draw in ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage() }
        }
        ctx.closePDF()
    }
    @MainActor func png(_ i: Int) -> Data? {
        let r = ImageRenderer(content: CanvasPage(m: host(i), interactive: false)); r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    @MainActor func exportPNGCurrent() { if let u = savePanel(fileBase + " – slide \(cur + 1).png"), let d = png(cur) { try? d.write(to: u) } }
    @MainActor func exportPNGAll() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.prompt = "Export here"; p.message = "Choose a folder for the slide images"
        guard p.runModal() == .OK, let dir = p.url else { return }
        for i in slides.indices { if let d = png(i) { try? d.write(to: dir.appendingPathComponent(String(format: "%@ %02d.png", fileBase, i + 1))) } }
    }

    // MARK: web slideshow
    func slideshowHTML() -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let th = theme
        let pages = slides.enumerated().map { i, s -> String in
            let bg = s.bg.isEmpty ? "bg" : s.bg
            var chrome = ""
            if !deck.footer.isEmpty { chrome += "<div style=\"position:absolute;left:44px;bottom:14px;font:14px 'Helvetica Neue',sans-serif;color:\(th.muted)\">\(esc(deck.footer))</div>" }
            if deck.numbers { chrome += "<div style=\"position:absolute;right:44px;bottom:14px;font:14px 'Helvetica Neue',sans-serif;color:\(th.muted)\">\(i + 1)</div>" }
            let page = PosterModel.pageHTML(s.els, bg: bg, w: slideW, h: slideH, resolveColor: { slideHex($0, th) }, resolveFont: { slideFont($0, th) })
            return "<section class=\"slide\"><div class=\"inner\">\(page)\(chrome)</div></section>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(esc(title))</title>
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}.slide{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;opacity:0;pointer-events:none;transition:opacity .45s}.slide.on{opacity:1;pointer-events:auto}.inner{position:relative;width:960px;height:540px;transform-origin:center center;flex:none}</style></head><body>
        \(pages)
        <script>
        const S=[...document.querySelectorAll('.slide')];let i=Math.max(0,(parseInt(location.hash.slice(1))||1)-1);
        function fit(){const k=Math.min(innerWidth/960,innerHeight/540);S.forEach(s=>s.firstChild.style.transform='scale('+k+')')}
        function go(n){i=Math.max(0,Math.min(S.length-1,n));S.forEach((s,j)=>s.classList.toggle('on',j==i));history.replaceState(null,'','#'+(i+1))}
        onkeydown=e=>{if(['ArrowRight','ArrowDown',' ','PageDown','Enter'].includes(e.key))go(i+1);else if(['ArrowLeft','ArrowUp','PageUp','Backspace'].includes(e.key))go(i-1);else if(e.key=='Home')go(0);else if(e.key=='End')go(S.length-1)};
        onclick=e=>go(e.clientX<innerWidth*0.25?i-1:i+1);onresize=fit;fit();go(i);
        </script></body></html>
        """
    }
    func exportHTML() { if let u = savePanel(fileBase + ".html") { try? slideshowHTML().write(to: u, atomically: true, encoding: .utf8) } }
    func exportPPTX() {
        guard let u = savePanel(fileBase + ".pptx") else { return }
        do { try PPTX.write(slides, deck: deck, to: u) } catch { NSAlert(error: error).runModal() }
    }
}

// MARK: - PowerPoint (.pptx)

enum PPTX {
    private static let emu = 12700.0                                    // 1 slide px = 1pt = 12700 EMU
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func hex6(_ s: String) -> String { let h = s.replacingOccurrences(of: "#", with: "").uppercased(); return h.count == 6 ? h : "000000" }
    private static func e(_ v: Double) -> Int { Int((v * emu).rounded()) }
    private static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main", nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships", nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let grp = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    private static let relPrefix = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func write(_ slides: [Slide], deck: DeckSettings, to url: URL) throws {
        let fm = FileManager.default, th = themeFor(deck.theme)
        let root = fm.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)", isDirectory: true)
        for d in ["_rels", "ppt/_rels", "ppt/slides/_rels", "ppt/slideMasters/_rels", "ppt/slideLayouts/_rels", "ppt/theme", "ppt/media"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        func put(_ path: String, _ s: String) throws { try s.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        func rels(_ items: [(String, String, String)]) -> String {
            head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + items.map { "<Relationship Id=\"\($0.0)\" Type=\"\(relPrefix)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
        }

        var mediaExts = Set<String>()
        for (n, s) in slides.enumerated() {
            var shapes = "", rid = 2, slideRels: [(String, String, String)] = [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")], nid = 2
            for el in s.els {
                let x = e(el.x), y = e(el.y), w = e(el.w), h = e(el.type == "line" ? max(el.sw, 1) : el.h)
                let xfrm = "<a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm>"
                func fill(_ c: String) -> String { c.isEmpty ? "<a:noFill/>" : "<a:solidFill><a:srgbClr val=\"\(hex6(slideHex(c, th)))\"/></a:solidFill>" }
                func line(_ c: String, _ wpx: Double) -> String { c.isEmpty || wpx <= 0 ? "<a:ln><a:noFill/></a:ln>" : "<a:ln w=\"\(e(wpx))\"><a:solidFill><a:srgbClr val=\"\(hex6(slideHex(c, th)))\"/></a:solidFill></a:ln>" }
                let id = nid; nid += 1
                switch el.type {
                case "text":
                    let anchor = el.valign == "middle" ? "ctr" : el.valign == "bottom" ? "b" : "t", algn = el.align == "center" ? "ctr" : el.align == "right" ? "r" : "l"
                    let paras = el.text.components(separatedBy: "\n").map { line -> String in
                        let ppr = el.bullets ? "<a:pPr marL=\"342900\" indent=\"-342900\" algn=\"\(algn)\"><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr>" : "<a:pPr algn=\"\(algn)\"><a:buNone/></a:pPr>"
                        let sz = Int(el.size * 100)
                        if line.isEmpty { return "<a:p>\(ppr)<a:endParaRPr lang=\"en-GB\" sz=\"\(sz)\"/></a:p>" }
                        return "<a:p>\(ppr)<a:r><a:rPr lang=\"en-GB\" sz=\"\(sz)\" b=\"\(el.bold ? 1 : 0)\" i=\"\(el.italic ? 1 : 0)\" dirty=\"0\">\(fill(el.color))<a:latin typeface=\"\(esc(slideFont(el.font, th)))\"/></a:rPr><a:t>\(esc(line))</a:t></a:r></a:p>"
                    }.joined()
                    shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Text \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>\(fill(el.fill))<a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"\(anchor)\"><a:noAutofit/></a:bodyPr><a:lstStyle/>\(paras)</p:txBody></p:sp>"
                case "rect", "ellipse":
                    let geom = el.type == "ellipse" ? "<a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>" : (el.rad > 0 ? "<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val \(Int(min(50000, el.rad / max(1, min(el.w, el.h)) * 100000)))\"/></a:avLst></a:prstGeom>" : "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>")
                    shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Shape \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\(xfrm)\(geom)\(fill(el.fill))\(line(el.stroke, el.sw))</p:spPr></p:sp>"
                case "line":
                    let lineColor = el.stroke.isEmpty ? "fg" : el.stroke
                    shapes += "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"\(id)\" name=\"Line \(id)\"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(w)\" cy=\"0\"/></a:xfrm><a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>\(line(lineColor, max(el.sw, 1)))</p:spPr></p:cxnSp>"
                default:
                    guard let comma = el.src.firstIndex(of: ","), let data = Data(base64Encoded: String(el.src[el.src.index(after: comma)...])) else { continue }
                    let ext = el.src.hasPrefix("data:image/png") ? "png" : "jpeg"; mediaExts.insert(ext)
                    let name = "image\(n + 1)-\(id).\(ext)"; try data.write(to: root.appendingPathComponent("ppt/media/\(name)"))
                    let r = "rId\(rid)"; rid += 1; slideRels.append((r, "image", "../media/\(name)"))
                    shapes += "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Picture \(id)\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(r)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(xfrm)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
                }
            }
            let bg = hex6(slideHex(s.bg.isEmpty ? "bg" : s.bg, th))
            try put("ppt/slides/slide\(n + 1).xml", head + "<p:sld xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(bg)\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\(grp)\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            try put("ppt/slides/_rels/slide\(n + 1).xml.rels", rels(slideRels))
        }

        let sp = "<p:cSld><p:spTree>\(grp)</p:spTree></p:cSld>"
        try put("ppt/slideLayouts/slideLayout1.xml", head + "<p:sldLayout xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\" type=\"blank\" preserve=\"1\">\(sp)<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        try put("ppt/slideMasters/slideMaster1.xml", head + "<p:sldMaster xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(grp)</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>")
        try put("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]))
        try put("ppt/theme/theme1.xml", head + "<a:theme xmlns:a=\"\(nsA)\" name=\"FreeOffice\"><a:themeElements><a:clrScheme name=\"FreeOffice\"><a:dk1><a:srgbClr val=\"000000\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"1F2937\"/></a:dk2><a:lt2><a:srgbClr val=\"F3F4F6\"/></a:lt2><a:accent1><a:srgbClr val=\"\(hex6(th.accent))\"/></a:accent1><a:accent2><a:srgbClr val=\"F6A33B\"/></a:accent2><a:accent3><a:srgbClr val=\"12B76A\"/></a:accent3><a:accent4><a:srgbClr val=\"D92D20\"/></a:accent4><a:accent5><a:srgbClr val=\"7A3FF2\"/></a:accent5><a:accent6><a:srgbClr val=\"0BA5EC\"/></a:accent6><a:hlink><a:srgbClr val=\"2E6DF6\"/></a:hlink><a:folHlink><a:srgbClr val=\"7A3FF2\"/></a:folHlink></a:clrScheme><a:fontScheme name=\"FreeOffice\"><a:majorFont><a:latin typeface=\"\(esc(th.heading))\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"\(esc(th.body))\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"FreeOffice\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"19050\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>")
        try put("ppt/presentation.xml", head + "<p:presentation xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>"
            + slides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\($0 + 2)\"/>" }.joined() + "</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        try put("ppt/_rels/presentation.xml.rels", rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml")] + slides.indices.map { ("rId\($0 + 2)", "slide", "slides/slide\($0 + 1).xml") } + [("rId\(slides.count + 2)", "theme", "theme/theme1.xml")]))
        try put("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml")]))
        let types = head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + mediaExts.sorted().map { "<Default Extension=\"\($0)\" ContentType=\"image/\($0)\"/>" }.joined()
            + "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
            + slides.indices.map { "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" }.joined() + "</Types>"
        try put("[Content_Types].xml", types)

        try? fm.removeItem(at: url)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.arguments = ["-q", "-X", "-r", url.path, "[Content_Types].xml", "_rels", "ppt"]; p.currentDirectoryURL = root
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw XLSXError("Couldn't create the .pptx file.") }
    }
}
