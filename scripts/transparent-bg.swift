#!/usr/bin/env swift
//
// Reads a PNG, flood-fills the background from the four corners,
// turning every connected near-white pixel transparent. Inner white
// regions (e.g. the white "paper" inside the P-card) are preserved
// because they are not reachable from the edges. This gives the
// macOS Dock a free-form icon instead of a solid white square.
//
// Usage:  transparent-bg.swift <input.png> <output.png>
//

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: transparent-bg.swift <input.png> <output.png>\n", stderr)
    exit(1)
}

let inputPath  = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let inputData = try? Data(contentsOf: URL(fileURLWithPath: inputPath)),
      let rep = NSBitmapImageRep(data: inputData) else {
    fputs("error: couldn't load \(inputPath)\n", stderr)
    exit(1)
}

let width  = rep.pixelsWide
let height = rep.pixelsHigh

// Render into a known RGBA8 buffer so pixel addressing is predictable
// regardless of how the source was encoded.
let bytesPerPixel = 4
let bytesPerRow   = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let cgImage = rep.cgImage else {
    fputs("error: couldn't create RGBA buffer\n", stderr)
    exit(1)
}

ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

// Flood-fill from each corner. Anything connected to an edge whose
// RGB is close to white gets its alpha zeroed out.
let whiteThreshold: UInt8 = 240
var visited = [Bool](repeating: false, count: width * height)
var stack: [(Int, Int)] = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]

@inline(__always)
func isWhiteish(at i: Int) -> Bool {
    pixels[i] >= whiteThreshold && pixels[i + 1] >= whiteThreshold && pixels[i + 2] >= whiteThreshold
}

while let (x, y) = stack.popLast() {
    if x < 0 || y < 0 || x >= width || y >= height { continue }
    let idx = y * width + x
    if visited[idx] { continue }
    let p = idx * bytesPerPixel
    if !isWhiteish(at: p) { continue }
    visited[idx] = true
    pixels[p]     = 0
    pixels[p + 1] = 0
    pixels[p + 2] = 0
    pixels[p + 3] = 0
    stack.append((x + 1, y))
    stack.append((x - 1, y))
    stack.append((x, y + 1))
    stack.append((x, y - 1))
}

guard let outImage = ctx.makeImage() else {
    fputs("error: makeImage failed\n", stderr)
    exit(1)
}

let outRep = NSBitmapImageRep(cgImage: outImage)
guard let png = outRep.representation(using: .png, properties: [:]) else {
    fputs("error: PNG encode failed\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("error: write failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
