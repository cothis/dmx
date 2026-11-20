import Foundation

extension Bench {
    /// Memory over time for every engine that finished the 2 GiB workload, as a static SVG that
    /// GitHub can show in the README (no scripts, so no hover; the README's table holds the
    /// numbers). One line per engine on one axis, aligned on the moment the container freed the
    /// memory; a legend once there are two engines, and each line labelled at its end.
    public static func svg(_ report: Report) -> String {
        let series = report.engines.compactMap { e in e.takeAndFree.map { (e.name, $0) } }
        let width = 760.0, height = 400.0
        let left = 64.0, right = 132.0, top = series.count > 1 ? 92.0 : 72.0, bottom = 52.0
        let plotW = width - left - right, plotH = height - top - bottom
        let points = series.flatMap { $0.1.timeline }
        let minT = (points.map(\.atS).min() ?? -10).rounded(.down)
        let maxT = (points.map(\.atS).max() ?? 30).rounded(.up)
        let maxMb = max(500, ((points.map(\.footprintMb).max() ?? 500) / 500).rounded(.up) * 500)
        func x(_ t: Double) -> Double { left + (t - minT) / max(1, maxT - minT) * plotW }
        func y(_ mb: Double) -> Double { top + plotH - mb / maxMb * plotH }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }

        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(width)) \(Int(height))" width="\(Int(width))" height="\(Int(height))" role="img" aria-labelledby="t d">
        <style>
        .bg{fill:#fcfcfb}.t1{fill:#0b0b0b}.t2{fill:#52514e}.grid{stroke:#e4e3df}.axis{stroke:#a3a29c}
        .s1{stroke:#2a78d6}.s2{stroke:#eb6834}.s3{stroke:#1baf7a}.s4{stroke:#eda100}
        .k1{fill:#2a78d6}.k2{fill:#eb6834}.k3{fill:#1baf7a}.k4{fill:#eda100}
        @media (prefers-color-scheme: dark){.bg{fill:#1a1a19}.t1{fill:#f0efec}.t2{fill:#c3c2b7}.grid{stroke:#33332f}.axis{stroke:#6b6a64}
        .s1{stroke:#3987e5}.s2{stroke:#d95926}.s3{stroke:#199e70}.s4{stroke:#c98500}
        .k1{fill:#3987e5}.k2{fill:#d95926}.k3{fill:#199e70}.k4{fill:#c98500}}
        text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
        .line{fill:none;stroke-width:2;stroke-linejoin:round;stroke-linecap:round}
        </style>
        <title id="t">Host memory while a container takes 2 GiB and frees it</title>
        <desc id="d">\(esc(series.map { "\($0.0): \(Int($0.1.baselineMb)) MB before, \(Int($0.1.holdingMb)) MB holding, \(Int($0.1.afterTenSecondsMb)) MB ten seconds after freeing" }.joined(separator: "; ")))</desc>
        <rect class="bg" width="100%" height="100%" rx="8"/>
        <text class="t1" x="\(f(left))" y="30" font-size="16" font-weight="600">Host memory while a container takes 2 GiB and frees it</text>
        <text class="t2" x="\(f(left))" y="50" font-size="12">MB charged to each engine (ri_phys_footprint, VM included), every 100 ms · dmx bench \(esc(report.dmxVersion)), \(esc(String(report.at.prefix(10))))</text>

        """
        if series.count > 1 {
            var lx = left
            for (i, s) in series.enumerated() {
                out += "<rect class=\"k\(i % 4 + 1)\" x=\(q(f(lx))) y=\"64\" width=\"12\" height=\"12\" rx=\"3\"/>"
                out += "<text class=\"t1\" x=\(q(f(lx + 18))) y=\"74\" font-size=\"12\">\(esc(s.0))</text>\n"
                lx += 36 + Double(s.0.count) * 7.5
            }
        }
        var mb = 0.0
        while mb <= maxMb {
            out += "<line class=\"grid\" x1=\(q(f(left))) x2=\(q(f(left + plotW))) y1=\(q(f(y(mb)))) y2=\(q(f(y(mb))))/>"
            out += "<text class=\"t2\" x=\(q(f(left - 8))) y=\(q(f(y(mb) + 4))) font-size=\"11\" text-anchor=\"end\">\(Int(mb))</text>\n"
            mb += 500
        }
        out += "<text class=\"t2\" x=\(q(f(left - 8))) y=\(q(f(top - 12))) font-size=\"11\" text-anchor=\"end\">MB</text>\n"
        var t = (minT / 5).rounded(.up) * 5
        while t <= maxT {
            out += "<line class=\"axis\" x1=\(q(f(x(t)))) x2=\(q(f(x(t)))) y1=\(q(f(top + plotH))) y2=\(q(f(top + plotH + 4)))/>"
            out += "<text class=\"t2\" x=\(q(f(x(t)))) y=\(q(f(top + plotH + 18))) font-size=\"11\" text-anchor=\"middle\">\(t == 0 ? "0" : String(format: "%+.0f", t))</text>\n"
            t += 5
        }
        out += "<line class=\"axis\" x1=\(q(f(left))) x2=\(q(f(left + plotW))) y1=\(q(f(top + plotH))) y2=\(q(f(top + plotH)))/>\n"
        out += "<text class=\"t2\" x=\(q(f(left + plotW / 2))) y=\(q(f(height - 12))) font-size=\"11\" text-anchor=\"middle\">seconds from the moment the container frees its 2 GiB</text>\n"
        if minT < 0 {
            out += "<line class=\"axis\" stroke-dasharray=\"3 3\" x1=\(q(f(x(0)))) x2=\(q(f(x(0)))) y1=\(q(f(top))) y2=\(q(f(top + plotH)))/>"
            out += "<text class=\"t2\" x=\(q(f(x(0) + 6))) y=\(q(f(top + plotH - 8))) font-size=\"11\">2 GiB freed</text>\n"
        }
        // End labels, pushed apart so they never overlap.
        var labels = series.enumerated().map { (i, s) in (i, s.0, s.1.timeline.last?.footprintMb ?? 0, y(s.1.timeline.last?.footprintMb ?? 0)) }
        labels.sort { $0.3 < $1.3 }
        for k in labels.indices.dropFirst() where labels[k].3 < labels[k - 1].3 + 15 { labels[k].3 = labels[k - 1].3 + 15 }
        for (i, s) in series.enumerated() {
            let path = s.1.timeline.map { "\(f(x($0.atS))),\(f(y($0.footprintMb)))" }.joined(separator: " ")
            out += "<polyline class=\"line s\(i % 4 + 1)\" points=\(q(path))/>\n"
        }
        for (i, name, last, ly) in labels {
            out += "<rect class=\"k\(i % 4 + 1)\" x=\(q(f(left + plotW + 8))) y=\(q(f(ly - 5))) width=\"10\" height=\"3\" rx=\"1.5\"/>"
            out += "<text class=\"t1\" x=\(q(f(left + plotW + 22))) y=\(q(f(ly + 4))) font-size=\"12\">\(esc(name)) \(Int(last)) MB</text>\n"
        }
        return out + "</svg>\n"
    }

    private static func q(_ s: String) -> String { "\"\(s)\"" }
}
