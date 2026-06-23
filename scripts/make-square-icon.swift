#!/usr/bin/env swift
//
// Scales an input PNG onto a transparent square canvas at a requested
// size, preserving aspect ratio. macOS `sips` can pad to a square, but
// only with an opaque background colour — using this for app icons made
// the dock render an awkward white box around the logo. This script
// uses Cocoa/AppKit drawing so the padded area stays fully transparent.
//
// Usage:  make-square-icon.swift <input.png> <output.png> <size>

import AppKit
import Foundation

guard CommandLine.arguments.count == 4,
      let size = Double(CommandLine.arguments[3]) else {
    fputs("usage: make-square-icon.swift <input.png> <output.png> <size>\n", stderr)
    exit(1)
}

let inputPath  = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let dimension  = CGFloat(size)

guard let source = NSImage(contentsOfFile: inputPath) else {
    fputs("error: couldn't load \(inputPath)\n", stderr)
    exit(1)
}

let canvas = NSImage(size: NSSize(width: dimension, height: dimension))
canvas.lockFocus()

NSColor.clear.set()
NSRect(x: 0, y: 0, width: dimension, height: dimension).fill()

// Aspect-fit the source inside the square canvas.
let aspect = source.size.width / source.size.height
let drawW: CGFloat
let drawH: CGFloat
if aspect >= 1.0 {
    drawW = dimension
    drawH = dimension / aspect
} else {
    drawW = dimension * aspect
    drawH = dimension
}
let drawX = (dimension - drawW) / 2
let drawY = (dimension - drawH) / 2

source.draw(in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep  = NSBitmapImageRep(data: tiff),
      let png  = rep.representation(using: .png, properties: [:]) else {
    fputs("error: PNG encode failed\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("error: write failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
