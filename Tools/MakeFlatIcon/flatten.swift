// Flattens a rendered icon PNG (rounded corners, transparent outside) onto one solid
// colour and writes an opaque PNG without an alpha channel. App Store artwork and the
// project avatar read this file; iOS itself draws the looks from AppIcon.icon.
//   flatten <input.png> <output.png> <r> <g> <b>        (r, g, b in 0...1, sRGB)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 6,
      let r = Double(CommandLine.arguments[3]), let g = Double(CommandLine.arguments[4]),
      let b = Double(CommandLine.arguments[5]) else {
    FileHandle.standardError.write("usage: flatten <in.png> <out.png> <r> <g> <b>\n".data(using: .utf8)!)
    exit(2)
}
let src = URL(fileURLWithPath: CommandLine.arguments[1])
let dst = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("cannot read \(src.path)\n".data(using: .utf8)!)
    exit(1)
}
let width = image.width, height = image.height
let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
// kCGImageAlphaNone: the written file has no alpha channel at all.
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: colourSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    FileHandle.standardError.write("cannot create context\n".data(using: .utf8)!)
    exit(1)
}
context.setFillColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let flattened = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot write \(dst.path)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, flattened, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("cannot finalize \(dst.path)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(dst.lastPathComponent) \(width)x\(height)")
