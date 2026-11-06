import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let colors = CGColorSpace(name: CGColorSpace.sRGB)!

private func ink(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func shade(_ context: CGContext, _ path: CGPath, from: UInt32, to: UInt32,
                   start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: colors, colors: [ink(from), ink(to)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

private func fill(_ context: CGContext, _ path: CGPath, _ color: CGColor, shadow: CGFloat = 0) {
    context.saveGState()
    if shadow > 0 { context.setShadow(offset: CGSize(width: 0, height: -shadow), blur: shadow * 1.7, color: ink(0x032333, alpha: 0.38)) }
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
    context.restoreGState()
}

private func drawIcon(_ context: CGContext) {
    let plate = CGPath(roundedRect: CGRect(x: 92, y: 88, width: 840, height: 840), cornerWidth: 187, cornerHeight: 187, transform: nil)
    fill(context, plate, ink(0x0D314A), shadow: 14)
    shade(context, plate, from: 0x1D8888, to: 0x102D48, start: point(195, 130), end: point(800, 915))
    context.addPath(plate)
    context.setStrokeColor(ink(0xD6FFFF, alpha: 0.18))
    context.setLineWidth(2)
    context.strokePath()

    let back = CGMutablePath()
    back.move(to: point(254, 721))
    back.addLine(to: point(254, 512))
    back.addQuadCurve(to: point(299, 467), control: point(254, 467))
    back.addLine(to: point(391, 467))
    back.addQuadCurve(to: point(426, 483), control: point(410, 467))
    back.addLine(to: point(455, 515))
    back.addLine(to: point(726, 515))
    back.addQuadCurve(to: point(770, 559), control: point(770, 515))
    back.addLine(to: point(770, 721))
    back.closeSubpath()
    fill(context, back, ink(0xCE812A), shadow: 19)

    for left in [true, false] {
        let page = CGMutablePath()
        // The center crease stays visible after the folder overlaps the lower pages.
        page.move(to: point(509, 365))
        page.addCurve(to: point(330, 321), control1: point(454, 325), control2: point(390, 311))
        page.addQuadCurve(to: point(312, 342), control: point(312, 325))
        page.addLine(to: point(312, 548))
        page.addQuadCurve(to: point(333, 565), control: point(312, 567))
        page.addCurve(to: point(509, 600), control1: point(397, 557), control2: point(454, 570))
        page.closeSubpath()

        var reflection = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1024, ty: 0)
        let sheet = left ? page : page.copy(using: &reflection)!
        fill(context, sheet, ink(0xFFFFFF), shadow: 9)
        shade(context, sheet, from: 0xFFFFFF, to: 0xD6E7E7, start: point(470, 318), end: point(490, 594))
        for index in 0..<2 {
            let line = CGMutablePath()
            let y = CGFloat(index * 41)
            line.move(to: point(355, 393 + y))
            line.addQuadCurve(to: point(465, 415 + y), control: point(414, 388 + y))
            context.addPath(left ? line : line.copy(using: &reflection)!)
            context.setStrokeColor(ink(0x6E9EA6, alpha: 0.58))
            context.setLineWidth(11)
            context.setLineCap(.round)
            context.strokePath()
        }
    }

    let front = CGMutablePath()
    front.move(to: point(258, 564))
    front.addQuadCurve(to: point(285, 534), control: point(252, 534))
    front.addLine(to: point(739, 534))
    front.addQuadCurve(to: point(766, 564), control: point(772, 534))
    front.addLine(to: point(742, 718))
    front.addQuadCurve(to: point(696, 757), control: point(735, 757))
    front.addLine(to: point(328, 757))
    front.addQuadCurve(to: point(282, 718), control: point(289, 757))
    front.closeSubpath()
    fill(context, front, ink(0xE99B3D), shadow: 14)
    shade(context, front, from: 0xFFCB70, to: 0xE98C2F, start: point(430, 535), end: point(555, 756))

    let arrow = CGMutablePath()
    arrow.move(to: point(456, 649))
    arrow.addLine(to: point(563, 649))
    arrow.move(to: point(532, 618))
    arrow.addLine(to: point(563, 649))
    arrow.addLine(to: point(532, 680))
    context.addPath(arrow)
    context.setLineWidth(18)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(ink(0x6F3E17))
    context.strokePath()
}

func iconPNG(pixels: Int) throws -> Data {
    let data = NSMutableData()
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.translateBy(x: 0, y: CGFloat(pixels))
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: -scale)
    drawIcon(context)
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

// An ICNS block is a FourCC and a big-endian length (including its header), followed by its bytes.
func block(_ type: String, _ payload: Data) -> Data {
    var result = Data(type.utf8)
    let length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: length) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
}

let preview = try iconPNG(pixels: 256)
var representations = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                     ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    representations.append(block(type, size == 256 ? preview : try iconPNG(pixels: size)))
}
try block("icns", representations).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try preview.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
