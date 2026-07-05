import Foundation

// AI CONTEXT — Models/ArtworkURL.swift
// Best-effort artwork URL upscaling for large displays (tvOS especially, where
// a 300×300 feed image looks soft blown up to a 440pt hero on a 4K panel).
// Apple/iTunes-hosted podcast art (mzstatic.com) encodes the requested size in
// the LAST path component, e.g. `.../<hash>/600x600bb.jpg`; swapping the
// leading `WxH` for a larger square yields a higher-res variant from the same
// CDN. We ONLY rewrite URLs that match that resizable pattern and are already
// SMALLER than the target — every other URL (self-hosted art at a fixed size,
// unknown hosts) is returned unchanged, so this can never break an image.
public enum ArtworkURL {

    /// Returns `url` upgraded to at least `minimumPixels` on its short side when
    /// it is a recognized resizable (mzstatic-style) art URL; otherwise returns
    /// `url` unchanged. `nil` in → `nil` out.
    public static func upscaled(_ url: URL?, toMinimumPixels minimumPixels: Int) -> URL? {
        guard let url else { return nil }
        guard minimumPixels > 0 else { return url }

        let last = url.lastPathComponent
        // Match a leading `<W>x<H>` on the final path component, optionally
        // followed by a suffix like `bb`, then `.<ext>`. e.g. "600x600bb.jpg".
        guard let match = resizableComponentMatch(last) else { return url }

        // Only upscale — never shrink an already-large source.
        guard match.width < minimumPixels || match.height < minimumPixels else { return url }

        let newComponent = "\(minimumPixels)x\(minimumPixels)\(match.suffix).\(match.ext)"
        var components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return url }
        components[components.count - 1] = newComponent

        guard var built = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        built.path = "/" + components.joined(separator: "/")
        return built.url ?? url
    }

    private struct ResizableComponent { let width: Int; let height: Int; let suffix: String; let ext: String }

    private static func resizableComponentMatch(_ component: String) -> ResizableComponent? {
        // Split "600x600bb.jpg" → name "600x600bb", ext "jpg".
        guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return nil }
        let name = String(component[component.startIndex..<dot])
        let ext = String(component[component.index(after: dot)...]).lowercased()
        guard ["jpg", "jpeg", "png", "webp"].contains(ext) else { return nil }

        // Parse "<digits>x<digits><suffix>".
        guard let xIndex = name.firstIndex(of: "x") else { return nil }
        let widthStr = String(name[name.startIndex..<xIndex])
        let rest = String(name[name.index(after: xIndex)...])
        guard let width = Int(widthStr), !widthStr.isEmpty else { return nil }

        // Leading digits of `rest` are the height; whatever follows is the suffix.
        let heightDigits = rest.prefix { $0.isNumber }
        guard let height = Int(heightDigits), !heightDigits.isEmpty else { return nil }
        let suffix = String(rest.dropFirst(heightDigits.count))

        return ResizableComponent(width: width, height: height, suffix: suffix, ext: ext)
    }
}
