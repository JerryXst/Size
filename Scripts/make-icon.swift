// Turns a full-bleed generated image into a macOS-style app icon master PNG.
//
// Two things are wrong with a raw model output when used as a macOS icon:
//
//   1. The rounded square is usually painted onto an opaque backdrop, so the
//      corners show up as a black (or white) block in the Dock. macOS icons are
//      square canvases with real transparency outside the rounded body.
//   2. The artwork fills the whole canvas, whereas Apple's icon grid gives the
//      body about 80% of the canvas. Filling the canvas makes the icon look
//      oversized next to every system app.
//
// This fixes both and writes a 1024×1024 RGBA master. `Scripts/make-icon.sh`
// then slices it into a .icns.
//
// Usage: swift Scripts/make-icon.swift <input.png> <output.png>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <input.png> <output.png>\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

let canvas = 1024
/// Apple's macOS icon grid: the rounded body occupies 824 of 1024 points.
let bodySize = 824
let margin = (canvas - bodySize) / 2

guard
    let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("cannot read \(inputURL.path)\n".utf8))
    exit(1)
}

let width = image.width
let height = image.height
let colourSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

// Pull the pixels out as straight RGBA so the backdrop can be turned into alpha.
guard let readContext = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colourSpace,
    bitmapInfo: bitmapInfo
) else { exit(1) }
readContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let readData = readContext.data else { exit(1) }
let pixels = readData.bindMemory(to: UInt8.self, capacity: width * height * 4)

// The generated backdrop is near-black. Treat it as alpha rather than guessing a
// fixed colour, and ramp across a small range so the rounded edge stays smooth.
// The darkest part of the actual artwork is a saturated blue (max channel > 100),
// so a low threshold cannot eat into it.
let transparentBelow: Double = 6
let opaqueAbove: Double = 30

var opaqueCount = 0
for index in 0..<(width * height) {
    let offset = index * 4
    let red = Double(pixels[offset])
    let green = Double(pixels[offset + 1])
    let blue = Double(pixels[offset + 2])
    let strongest = max(red, max(green, blue))

    let alpha: Double
    if strongest <= transparentBelow {
        alpha = 0
    } else if strongest >= opaqueAbove {
        alpha = 255
    } else {
        alpha = ((strongest - transparentBelow) / (opaqueAbove - transparentBelow)) * 255
    }

    let factor = alpha / 255
    // Premultiplied storage: scale colour by the new alpha.
    pixels[offset] = UInt8((red * factor).rounded())
    pixels[offset + 1] = UInt8((green * factor).rounded())
    pixels[offset + 2] = UInt8((blue * factor).rounded())
    pixels[offset + 3] = UInt8(alpha.rounded())
    if alpha > 250 { opaqueCount += 1 }
}

let opaqueRatio = Double(opaqueCount) / Double(width * height)
FileHandle.standardError.write(Data(String(format: "opaque area: %.1f%%\n", opaqueRatio * 100).utf8))
if opaqueRatio < 0.4 {
    FileHandle.standardError.write(Data("warning: most of the image became transparent; is the backdrop really black?\n".utf8))
}

guard let masked = readContext.makeImage() else { exit(1) }

// Compose onto the transparent macOS grid.
guard let outputContext = CGContext(
    data: nil,
    width: canvas,
    height: canvas,
    bitsPerComponent: 8,
    bytesPerRow: canvas * 4,
    space: colourSpace,
    bitmapInfo: bitmapInfo
) else { exit(1) }
outputContext.interpolationQuality = .high
outputContext.setAllowsAntialiasing(true)
outputContext.draw(
    masked,
    in: CGRect(x: margin, y: margin, width: bodySize, height: bodySize)
)

guard let composed = outputContext.makeImage() else { exit(1) }
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else { exit(1) }
CGImageDestinationAddImage(destination, composed, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }

print("wrote \(outputURL.path) (\(canvas)×\(canvas), body \(bodySize))")
