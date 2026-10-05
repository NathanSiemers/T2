import Foundation

// The colours T2 draws with: viridis' "plasma" map (points, boxes, colour scales) and the
// cool-to-warm set of the survival view. Platform-neutral numbers; the app turns them
// into its own colour type.
//
// Colour is presentation, not data: the map is stored as 33 anchors taken from
// viridisLite::plasma(256) and interpolated linearly, which stays within 3/255 per channel
// of the original (checked in the unit tests against R).

/// A colour in sRGB, each channel 0 ... 1.
public struct RGB: Sendable, Equatable, Hashable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    /// from 0 ... 255 integers
    public init(_ r: Int, _ g: Int, _ b: Int) { self.init(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255) }
    /// from 0xRRGGBB
    public init(hex: UInt32) { self.init(Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF)) }
    /// each channel rounded to 0 ... 255
    public var bytes: (r: Int, g: Int, b: Int) { (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    /// "#RRGGBB"
    public var hexString: String { let v = bytes; return String(format: "#%02X%02X%02X", v.r, v.g, v.b) }
    /// between two colours: `f` = 0 gives `self`, 1 gives `other`
    public func mixed(with other: RGB, _ f: Double) -> RGB {
        RGB(r: r + (other.r - r) * f, g: g + (other.g - g) * f, b: b + (other.b - b) * f)
    }
    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let white = RGB(r: 1, g: 1, b: 1)
}

public enum Palette {
    // viridisLite::plasma(256) at 33 evenly spread positions
    static let plasmaAnchors: [RGB] = [
        RGB(13, 8, 135), RGB(34, 6, 144), RGB(49, 5, 151), RGB(63, 4, 156), RGB(76, 2, 161), RGB(89, 1, 165),
        RGB(102, 0, 167), RGB(114, 1, 168), RGB(126, 3, 168), RGB(138, 9, 165), RGB(149, 17, 161), RGB(160, 26, 156),
        RGB(170, 35, 149), RGB(179, 44, 142), RGB(188, 53, 135), RGB(196, 62, 127), RGB(203, 70, 121), RGB(210, 79, 113),
        RGB(217, 88, 106), RGB(223, 98, 99), RGB(229, 107, 93), RGB(235, 117, 86), RGB(240, 127, 79), RGB(244, 137, 72),
        RGB(248, 148, 65), RGB(251, 159, 58), RGB(253, 171, 51), RGB(254, 183, 45), RGB(253, 195, 40), RGB(252, 208, 37),
        RGB(249, 221, 37), RGB(245, 235, 39), RGB(240, 249, 33)]

    /// the plasma map at `t` in 0 ... 1 (clamped; a missing value gives the dark end)
    public static func plasma(_ t: Double) -> RGB {
        let last = plasmaAnchors.count - 1
        let u = (t.isNaN ? 0 : min(max(t, 0), 1)) * Double(last)
        let i = min(Int(u), last - 1)
        return plasmaAnchors[i].mixed(with: plasmaAnchors[i + 1], u - Double(i))
    }

    /// `count` colours for the levels of a categorical variable: evenly spaced on the map from
    /// its dark end to `end`, as scale_colour_viridis(discrete = TRUE, end = 0.7) gives them
    public static func discrete(count: Int, end: Double = 0.7) -> [RGB] {
        guard count > 0 else { return [] }
        if count == 1 { return [plasma(0)] }
        return (0..<count).map { plasma(end * Double($0) / Double(count - 1)) }
    }

    /// the colour of a numeric value placed at `fraction` (0 = lowest, 1 = highest) of its
    /// range, as scale_color_viridis(end = 0.8) does
    public static func continuous(_ fraction: Double, end: Double = 0.8) -> RGB { plasma(min(max(fraction, 0), 1) * end) }

    /// the default colour of points and lines when nothing is mapped to colour (plasma(1))
    public static let single = plasma(0)

    /// cool-to-warm colours for the groups of a survival plot, low to high (t2_km_palette)
    public static func survival(count: Int) -> [RGB] {
        switch count {
        case ..<1: return []
        case 1: return [RGB(hex: 0x3B7DB4)]
        case 2: return [RGB(hex: 0x3B7DB4), RGB(hex: 0xC0392B)]
        case 3: return [RGB(hex: 0x3B7DB4), RGB(hex: 0xE3A93A), RGB(hex: 0xC0392B)]
        default:
            // colorRampPalette(c(...))(n): linear in RGB through the stops, n points end to end
            let stops = [RGB(hex: 0x2C6FAD), RGB(hex: 0x2E9E88), RGB(hex: 0xE3A93A), RGB(hex: 0xC0392B)]
            return (0..<count).map { k in
                let u = Double(k) / Double(count - 1) * Double(stops.count - 1)
                let i = min(Int(u), stops.count - 2)
                return stops[i].mixed(with: stops[i + 1], u - Double(i))
            }
        }
    }
}
