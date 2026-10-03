#!/usr/bin/env swift
// Draws the Headway app icon: a route with stops and a live bus whose position pulses.
//
//   swift tools/make_icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
//
// Writes icon-light.png, icon-dark.png and icon-tinted.png (1024 x 1024, no transparency, no text) and the matching
// Contents.json. iOS rounds the corners itself.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024

struct Variant {
  let name: String
  let backgroundTop: CGColor
  let backgroundBottom: CGColor
  let casing: CGColor
  let route: CGColor
  let stopFill: CGColor
  let stopRing: CGColor
  let bus: CGColor
  let busCore: CGColor
  let pulse: CGColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
    alpha: alpha)
}

let variants = [
  Variant(
    name: "light", backgroundTop: rgb(0x2F80ED), backgroundBottom: rgb(0x0B2E83), casing: rgb(0x061B52, 0.35),
    route: rgb(0xFFFFFF), stopFill: rgb(0xFFFFFF), stopRing: rgb(0x0B2E83), bus: rgb(0xFFB020),
    busCore: rgb(0xFFFFFF), pulse: rgb(0xFFFFFF)),
  Variant(
    name: "dark", backgroundTop: rgb(0x16233F), backgroundBottom: rgb(0x070C18), casing: rgb(0x000000, 0.4),
    route: rgb(0x8EC5FF), stopFill: rgb(0x0B1220), stopRing: rgb(0x8EC5FF), bus: rgb(0xFFB020),
    busCore: rgb(0x0B1220), pulse: rgb(0xFFB020)),
  Variant(
    name: "tinted", backgroundTop: rgb(0x000000), backgroundBottom: rgb(0x000000), casing: rgb(0x000000, 0.5),
    route: rgb(0xFFFFFF), stopFill: rgb(0x000000), stopRing: rgb(0xFFFFFF), bus: rgb(0xFFFFFF),
    busCore: rgb(0x000000), pulse: rgb(0xFFFFFF)),
]

// The route: two cubic segments, from the lower left up to the upper right (coordinates from the top left).
let p0 = CGPoint(x: 190, y: 800)
let seg1 = (c1: CGPoint(x: 190, y: 560), c2: CGPoint(x: 330, y: 560), end: CGPoint(x: 520, y: 560))
let seg2 = (c1: CGPoint(x: 760, y: 560), c2: CGPoint(x: 600, y: 250), end: CGPoint(x: 840, y: 230))

func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
  let u = 1 - t
  return CGPoint(
    x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
    y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
}

func render(_ v: Variant) -> CGImage {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  // Work with the origin at the top left.
  ctx.translateBy(x: 0, y: size)
  ctx.scaleBy(x: 1, y: -1)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)

  // Background
  let gradient = CGGradient(colorsSpace: space, colors: [v.backgroundTop, v.backgroundBottom] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])

  let path = CGMutablePath()
  path.move(to: p0)
  path.addCurve(to: seg1.end, control1: seg1.c1, control2: seg1.c2)
  path.addCurve(to: seg2.end, control1: seg2.c1, control2: seg2.c2)

  // Route with a soft casing for depth.
  ctx.addPath(path)
  ctx.setStrokeColor(v.casing)
  ctx.setLineWidth(96)
  ctx.strokePath()
  ctx.addPath(path)
  ctx.setStrokeColor(v.route)
  ctx.setLineWidth(68)
  ctx.strokePath()

  // Stops at the start, the junction of the two segments, and the end.
  let stops = [p0, seg1.end, seg2.end]
  for point in stops {
    ctx.setFillColor(v.stopFill)
    ctx.fillEllipse(in: CGRect(x: point.x - 46, y: point.y - 46, width: 92, height: 92))
    ctx.setStrokeColor(v.stopRing)
    ctx.setLineWidth(22)
    ctx.strokeEllipse(in: CGRect(x: point.x - 46, y: point.y - 46, width: 92, height: 92))
  }

  // The live bus, a little way along the second segment, with pulse rings around it.
  let bus = bezier(seg1.end, seg2.c1, seg2.c2, seg2.end, 0.46)
  for (radius, alpha) in [(215.0, 0.16), (150.0, 0.30)] as [(CGFloat, CGFloat)] {
    ctx.setStrokeColor(v.pulse.copy(alpha: alpha)!)
    ctx.setLineWidth(14)
    ctx.strokeEllipse(in: CGRect(x: bus.x - radius, y: bus.y - radius, width: radius * 2, height: radius * 2))
  }
  ctx.setFillColor(v.stopFill.copy(alpha: 0.0)!)
  ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: rgb(0x000000, 0.35))
  ctx.setFillColor(v.bus)
  ctx.fillEllipse(in: CGRect(x: bus.x - 92, y: bus.y - 92, width: 184, height: 184))
  ctx.setShadow(offset: .zero, blur: 0, color: nil)
  ctx.setFillColor(v.busCore)
  ctx.fillEllipse(in: CGRect(x: bus.x - 42, y: bus.y - 42, width: 84, height: 84))

  return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let output = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for variant in variants {
  writePNG(render(variant), to: output.appendingPathComponent("icon-\(variant.name).png"))
}

let contents = """
  {
    "images" : [
      { "filename" : "icon-light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
      {
        "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
        "filename" : "icon-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024"
      },
      {
        "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
        "filename" : "icon-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024"
      }
    ],
    "info" : { "author" : "xcode", "version" : 1 }
  }
  """
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote 3 icons to \(output.path)")
