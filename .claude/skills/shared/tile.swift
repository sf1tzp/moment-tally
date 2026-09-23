import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// tile <out.png> <cellWidth> <columns> <in.png>... — a contact sheet: every
// input scaled to `cellWidth` points wide (aspect kept), laid out in a grid
// of `columns`, one PNG out. One image read instead of N, at review
// density rather than capture density.
let args = CommandLine.arguments
guard args.count >= 5, let cellWidth = Int(args[2]), let columns = Int(args[3]), columns > 0 else {
    FileHandle.standardError.write("usage: tile <out.png> <cellWidth> <columns> <in.png>...\n".data(using: .utf8)!)
    exit(2)
}
let out = args[1]
let inputs = Array(args[4...])

func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

let images = inputs.compactMap(load)
guard images.count == inputs.count else {
    FileHandle.standardError.write("tile: could not read every input\n".data(using: .utf8)!)
    exit(1)
}

// Cell size: the width is fixed, the height the tallest scaled input, so a
// portrait phone and a landscape iPad can share a sheet.
let gap = 8
let scaled: [(w: Int, h: Int)] = images.map { img in
    let scale = Double(cellWidth) / Double(img.width)
    return (cellWidth, Int(Double(img.height) * scale))
}
let cellHeight = scaled.map(\.h).max() ?? 0
let rows = (images.count + columns - 1) / columns
let sheetWidth = columns * cellWidth + (columns + 1) * gap
let sheetHeight = rows * cellHeight + (rows + 1) * gap

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
ctx.interpolationQuality = .high

for (i, img) in images.enumerated() {
    let col = i % columns, row = i / columns
    let x = gap + col * (cellWidth + gap)
    // CG's origin is bottom-left: row 0 goes at the top.
    let y = sheetHeight - (gap + (row + 1) * cellHeight + row * gap)
    let size = scaled[i]
    // Top-align within the cell so shorter images don't float.
    ctx.draw(img, in: CGRect(x: x, y: y + (cellHeight - size.h), width: size.w, height: size.h))
}

guard let sheet = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, sheet, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("\(out): \(images.count) images, \(sheetWidth)x\(sheetHeight)")
