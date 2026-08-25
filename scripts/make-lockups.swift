#!/usr/bin/env swift
// Derives the bundled wordmark/tagline lockups from the licensed-face renders
// in Resources/ (which are export-only masters — the faces themselves must
// never be committed, see Brand.swift). Run from the repo root:
//
//   swift scripts/make-lockups.swift
//
// The masters are rendered for dark backgrounds: the "ink" words (Moment /
// Count what) are a fixed light grey, only Tally / counts. carry the brand
// gradient. Each master therefore yields a pair:
//   *-dark.png   — the master, downscaled to bundle size
//   *-light.png  — the same, with low-saturation (ink) pixels recolored to
//                  near-black; gradient pixels pass through untouched
// Output lands in Sources/MomentTally/Resources/ and ships in the SwiftPM
// resource bundle (Package.swift).

import AppKit

/// (master, output basename, bundled pixel height — ~3× the largest point
/// size the app draws it at, so Retina stays sharp with headroom)
let jobs: [(source: String, name: String, height: Int)] = [
    ("Resources/Moment Tally Text.png", "Wordmark", 256),
    ("Resources/Count what Counts.png", "Tagline", 256),
]

/// Light-mode ink: the mirror of the master's #e9e9e9-on-dark — slightly
/// muted rather than pure black, per the website's grey-on-dark lockup.
let ink: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.16, 0.16, 0.16)

func downscale(_ image: NSImage, toHeight height: Int) -> NSBitmapImageRep {
    let scale = CGFloat(height) / image.size.height
    let width = Int((image.size.width * scale).rounded())
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func recolored(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let copy = rep.copy() as! NSBitmapImageRep
    for y in 0..<copy.pixelsHigh {
        for x in 0..<copy.pixelsWide {
            guard let c = copy.colorAt(x: x, y: y), c.alphaComponent > 0
            else { continue }
            let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
            // Saturation, not lightness, separates ink from gradient: the
            // grey stays grey through the anti-aliased alpha falloff, while
            // even the palest gradient pixel keeps a clear hue spread.
            guard max(r, g, b) - min(r, g, b) < 0.10 else { continue }
            copy.setColor(NSColor(calibratedRed: ink.r, green: ink.g,
                                  blue: ink.b, alpha: c.alphaComponent),
                          atX: x, y: y)
        }
    }
    return copy
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh), \(png.count / 1024)K)")
}

for job in jobs {
    guard let image = NSImage(contentsOfFile: job.source) else {
        fatalError("missing master: \(job.source) — run from the repo root")
    }
    let dark = downscale(image, toHeight: job.height)
    let out = "Sources/MomentTally/Resources/\(job.name)"
    write(dark, to: "\(out)-dark.png")
    write(recolored(dark), to: "\(out)-light.png")
}

/// The tally-motif exports are already a light/dark pair (fully gradient
/// ink, so no recoloring applies) — just the same downscale to ~3× the
/// About masthead's point size.
let paired: [(source: String, name: String, height: Int)] = [
    ("Resources/tally_motif_dark.png", "Motif-dark", 384),
    ("Resources/tally_motif_light.png", "Motif-light", 384),
]
for job in paired {
    guard let image = NSImage(contentsOfFile: job.source) else {
        fatalError("missing master: \(job.source) — run from the repo root")
    }
    write(downscale(image, toHeight: job.height),
          to: "Sources/MomentTally/Resources/\(job.name).png")
}
