#!/usr/bin/env swift
// Makes the Watchpost demo media from code: flat-coloured, brand-free "dashcam"
// clips for a car with six cameras. Nothing here is footage; every pixel is
// drawn with CoreGraphics and piped to ffmpeg as raw frames.
//
// Both sets are small 3D worlds seen through pinhole cameras fixed to the car,
// so switching cameras shows the same moment from another point of view.
//
//   Parked set (sentry style)  demo-<camera>.mp4
//     The car stands nose-in in a bay of a fictional car park. Nothing that
//     belongs to the car park moves: the parked cars, kerb, hedge and lamp
//     posts stay exactly where they are. Three things pass through in twelve
//     seconds: a featureless figure walks up to the car and along its left
//     flank (front camera, then left repeater, then left pillar, then behind),
//     a boxy van drives through the aisle behind the car (right pillar, back,
//     left pillar) and a second figure crosses the far footway (front camera).
//
//   Driving set               demo-drive-<camera>.mp4  (front, back, repeaters)
//     The car drives at about 30 km/h along a two-lane street with cars
//     parked along both kerbs. The car ahead
//     brakes from 6.2 s to 7.6 s, we brake with it (the only span in which any
//     brake light shows), then the right indicator comes on at 9 s and the car
//     turns right at a crossroads. The repeaters
//     look back along the car's flank, front wheel arch at the leading edge:
//     kerb, lane lines and parked cars stream past at the speed the telemetry
//     says.
//
// Every frame carries a small burned-in "DEMO · <CAMERA>" label.
//
// Export samples
//   demo-export-<camera>.mp4, demo-drive-export-<camera>.mp4
//     The same clips with the strip the server burns into an exported file: the
//     place on the left and, when the clip carries telemetry, the readings of
//     that moment on the right (see drawWatermark). The app's demo hands these
//     out when someone exports.
//
// Language
//   Only two kinds of file carry words: the export samples and demo-events.json
//   (its place names). Each language gets its own copy of those, in its own
//   .lproj folder, and the app reads the copy that matches its own language.
//   The clips, the thumbnails and the telemetry are the same for every language.
//
// Output (written to <output-directory>; demo-* files from earlier runs that
// this run does not produce in the same place are removed):
//   demo-<camera>.mp4            parked set, 640x480, 30 fps, 12 s, H.264
//   demo-drive-<camera>.mp4      driving set
//   demo-thumb-<camera>.png      the 5 s frame of a parked clip, 400x300
//   demo-drive-thumb-<camera>.png
//   demo-telemetry.json          the driving clips' telemetry in the server's
//                                /api/telemetry wire format (25 samples)
//   zh-Hans.lproj/, en.lproj/    one folder per language, holding:
//     demo-export-<camera>.mp4   export samples, see "Export samples"
//     demo-drive-export-<camera>.mp4
//     demo-events.json           the demo's events (demoEvents below): where each
//                                one sits relative to the moment the demo is
//                                opened, which footage it uses, and what its
//                                event.json would say
//
//   swift make-demo-media.swift <output-directory>
//     everything, for every language
//   swift make-demo-media.swift <output-directory> --only <zh-Hans|en>
//     just that language's files; nothing else in the directory is written or
//     removed (to add a language, or redo one, without touching the rest)
//   swift make-demo-media.swift --still <out.png> <parked|drive> <camera> <seconds>
//     (one frame as PNG, for looking at a moment while working on the scenes)
//
// Needs ffmpeg on PATH. This machine's ffmpeg has no drawtext, so text is
// drawn with CoreText.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Constants

let width = 640
let height = 480
let framesPerSecond = 30
let seconds = 12
let frameCount = framesPerSecond * seconds
let thumbnailTime = 5.0 // the thumbnail frame: the figure is beside the left flank
let thumbnailWidth = 400

enum Cam: String, CaseIterable {
    case front
    case back
    case leftPillar = "left_pillar"
    case rightPillar = "right_pillar"
    case leftRepeater = "left_repeater"
    case rightRepeater = "right_repeater"

    var label: String {
        switch self {
        case .front: "FRONT"
        case .back: "BACK"
        case .leftPillar: "LEFT PILLAR"
        case .rightPillar: "RIGHT PILLAR"
        case .leftRepeater: "LEFT REPEATER"
        case .rightRepeater: "RIGHT REPEATER"
        }
    }

    var isLeft: Bool { self == .leftPillar || self == .leftRepeater }

    /// The side cameras, which see part of the car they are mounted on.
    var isSide: Bool { self == .leftPillar || self == .rightPillar || self == .leftRepeater || self == .rightRepeater }
}

enum ClipSet: String, CaseIterable {
    case parked
    case drive

    /// The driving set has the four cameras a typical car has.
    var cameras: [Cam] {
        self == .parked ? Cam.allCases : [.front, .back, .leftRepeater, .rightRepeater]
    }

    func clipName(_ camera: Cam) -> String {
        self == .parked ? "demo-\(camera.rawValue).mp4" : "demo-drive-\(camera.rawValue).mp4"
    }

    func thumbName(_ camera: Cam) -> String {
        self == .parked ? "demo-thumb-\(camera.rawValue).png" : "demo-drive-thumb-\(camera.rawValue).png"
    }

    /// The same clip with the export strip burned in.
    func exportName(_ camera: Cam) -> String {
        self == .parked ? "demo-export-\(camera.rawValue).mp4" : "demo-drive-export-\(camera.rawValue).mp4"
    }


    /// Only clips recorded while driving carry telemetry.
    var hasTelemetry: Bool { self == .drive }
}

// MARK: - Telemetry and motion (driving set)

let cruiseSpeedKmh = 30.0
let brakeStart = 6.2
let brakeEnd = 7.6
let signalStart = 9.0
let signalEnd = 11.0
let wheelbase = 2.9
let steeringRatio = 12.0 // steering wheel degrees per degree of road wheel

/// The language of the words that only some files carry: the export strip's text and the
/// place names in `demo-events.json`. The demo ships one set of those files per language,
/// each in its `.lproj` folder; the app reads the one that matches its own language.
enum Language: String, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"

    /// The folder inside the output directory that holds this language's files.
    var folder: String { "\(rawValue).lproj" }

    /// The font of the export strip. It has to have the language's glyphs.
    var stripFont: String { self == .chinese ? "PingFangSC-Medium" : "Helvetica" }
    var stripTextSize: CGFloat { self == .chinese ? 17 : 16 }

    /// What the export strip says before the place, where a real export could be mistaken for a recording.
    var demoFootage: String { self == .chinese ? "演示画面" : "Demo footage" }
    var brake: String { self == .chinese ? "刹车" : "BRAKE" }

    /// A made-up city and street, the same for every demo event that uses a set
    /// (the export strip carries them too, so they cannot disagree with the list).
    var city: String { self == .chinese ? "示例市" : "Sample City" }
    func street(for set: ClipSet) -> String {
        switch (self, set) {
        case (.chinese, .parked): "虚构停车场A区"
        case (.chinese, .drive): "演示路12号"
        case (.english, .parked): "Sample Car Park A"
        case (.english, .drive): "12 Demo Road"
        }
    }
}

func smoothstep(_ value: Double) -> Double {
    let x = min(max(value, 0), 1)
    return x * x * (3 - 2 * x)
}

/// Rises from 0 to 1 over [0, 1] with soft ends: ramps up for `ramp`, flat, ramps down.
func trapezoid(_ value: Double, ramp: Double) -> Double {
    let u = min(max(value, 0), 1)
    if u < ramp { return u * u / (2 * ramp) }
    if u > 1 - ramp { return 1 - (1 - u) * (1 - u) / (2 * ramp) }
    return u - ramp / 2
}

func speedWave(_ time: Double) -> Double { cruiseSpeedKmh + 1.6 * sin(time * 0.9) }

/// Speed in km/h: cruise, brake from 6.2 s to 7.6 s, coast, hold through the
/// turn, pick up again at the end. The scenes move by its integral, so the
/// world slows exactly when the telemetry says it does.
func speedKmh(at time: Double) -> Double {
    if time < brakeStart { return speedWave(time) }
    let braked = 19.0
    if time <= brakeEnd {
        let drop = speedWave(brakeStart) - braked
        return speedWave(brakeStart) - drop * trapezoid((time - brakeStart) / (brakeEnd - brakeStart), ramp: 0.2)
    }
    let turning = 14.0
    if time < 9.2 { return braked + (turning - braked) * smoothstep((time - brakeEnd) / 1.6) }
    if time < 11.4 { return turning - 0.2 * sin((time - 9.2) / 2.2 * .pi) }
    return turning + 3.0 * smoothstep((time - 11.4) / 0.6)
}

func isBraking(_ time: Double) -> Bool { time >= brakeStart && time <= brakeEnd }

/// Steering wheel angle in degrees. Left of centre is positive (ISO 8855), so
/// the right turn goes negative. A small drift while cruising, too small to
/// take the car out of its lane.
func steeringDegrees(at time: Double) -> Double {
    let drift = 0.9 * sin(time * 1.6) + 0.4 * sin(time * 2.3 + 1.0)
    // Right turn: winds on from 8.8 s, full lock 10 s to 11.3 s, unwinds after.
    let on = smoothstep((time - 8.8) / 1.2)
    let off = time > 11.3 ? smoothstep((time - 11.3) / 1.0) : 0
    return drift * (1 - on) - 240.0 * on * (1 - off)
}

func throttlePercent(at time: Double) -> Int {
    if time >= brakeStart - 0.1 && time < 9.2 { return 0 }
    if time < brakeStart { return Int((17 + 4 * sin(time * 1.3)).rounded()) }
    if time < 11.4 { return Int((15 + 3 * sin(time * 2.1)).rounded()) }
    return Int((15 + 20 * smoothstep((time - 11.4) / 0.6)).rounded())
}

func turnSignal(at time: Double) -> Int { time >= signalStart && time <= signalEnd ? 2 : 0 }

/// One row of the telemetry file, in the server's order: time, gear, speed,
/// throttle, steering, brake, turn signal, autopilot, lat, lon, heading, ax, ay, az.
struct Sample {
    let time: Double
    let speedKmh: Double
    let throttle: Int
    let steering: Double
    let brake: Int
    let turnSignal: Int
    let heading: Double
    let ax: Double
    let ay: Double
    let az: Double
}

/// Where the car is on its drive, in world coordinates (x east, z south; the
/// car starts in the right-hand lane heading north).
let laneX = 1.7 // the middle of the northbound lane

struct Pose {
    var position = V3(laneX, 0, 0)
    var yaw = 0.0
    var distance = 0.0
}

/// The drive at 100 Hz: speed and steering from the telemetry, integrated.
let driveStepsPerSecond = 100

let drivePath: [Pose] = {
    let stepsPerSecond = driveStepsPerSecond
    var table = [Pose()]
    for step in 1...(seconds * stepsPerSecond + 20) {
        let time = (Double(step) - 0.5) / Double(stepsPerSecond)
        let metresPerSecond = speedKmh(at: time) / 3.6
        let roadWheel = tan(steeringDegrees(at: time) / steeringRatio * .pi / 180)
        var pose = table[step - 1]
        // Left is positive steering and a left turn takes yaw negative.
        pose.yaw -= metresPerSecond / wheelbase * roadWheel / Double(stepsPerSecond)
        pose.position.x += metresPerSecond * sin(pose.yaw) / Double(stepsPerSecond)
        pose.position.z -= metresPerSecond * cos(pose.yaw) / Double(stepsPerSecond)
        pose.distance += metresPerSecond / Double(stepsPerSecond)
        table.append(pose)
    }
    return table
}()

func pose(at time: Double) -> Pose { pose(atStep: time * Double(driveStepsPerSecond)) }

/// The pose between two rows of the path table.
func pose(atStep position: Double) -> Pose {
    let position = min(max(position, 0), Double(drivePath.count - 2))
    let index = Int(position.rounded(.down))
    let weight = position - Double(index)
    let a = drivePath[index]
    let b = drivePath[index + 1]
    return Pose(position: V3(a.position.x + (b.position.x - a.position.x) * weight, 0,
                             a.position.z + (b.position.z - a.position.z) * weight),
                yaw: a.yaw + (b.yaw - a.yaw) * weight,
                distance: a.distance + (b.distance - a.distance) * weight)
}

/// Where the car has got to after driving `distance` metres. Before the start
/// of the path, the same lane carries straight on behind it.
func pose(atDistance distance: Double) -> Pose {
    guard distance >= 0 else { return Pose(position: V3(laneX, 0, -distance), yaw: 0, distance: distance) }
    var index = 0
    while index < drivePath.count - 2 && drivePath[index + 1].distance < distance { index += 1 }
    let a = drivePath[index]
    let b = drivePath[index + 1]
    let weight = b.distance > a.distance ? (distance - a.distance) / (b.distance - a.distance) : 0
    return Pose(position: V3(a.position.x + (b.position.x - a.position.x) * weight, 0,
                             a.position.z + (b.position.z - a.position.z) * weight),
                yaw: a.yaw + (b.yaw - a.yaw) * weight,
                distance: distance)
}

/// Speed of the car ahead: it cruises half a km/h faster than we do, brakes
/// over the same 6.2 s to 7.6 s as its brake lights are lit, slows a little
/// more for the junction and then pulls away straight on while we turn.
func leadSpeedKmh(at time: Double) -> Double {
    let cruising = speedWave(time) + 0.5
    if time < brakeStart { return cruising }
    let braked = 19.5
    if time <= brakeEnd {
        let drop = speedWave(brakeStart) + 0.5 - braked
        return speedWave(brakeStart) + 0.5 - drop * trapezoid((time - brakeStart) / (brakeEnd - brakeStart), ramp: 0.2)
    }
    if time < 8.6 { return braked - smoothstep(time - brakeEnd) }
    return braked - 1 + 24 * smoothstep((time - 8.6) / 3.2)
}

let leadPath: [Double] = {
    let stepsPerSecond = driveStepsPerSecond
    var z = [-11.5] // just under 7 m between its tail and our nose: close enough for its lights to read at 640x480
    for step in 1...(seconds * stepsPerSecond + 20) {
        let time = (Double(step) - 0.5) / Double(stepsPerSecond)
        z.append(z[step - 1] - leadSpeedKmh(at: time) / 3.6 / Double(stepsPerSecond))
    }
    return z
}()

func leadZ(at time: Double) -> Double {
    let position = min(max(time, 0), Double(leadPath.count - 2)) * Double(driveStepsPerSecond)
    let index = Int(position.rounded(.down))
    return leadPath[index] + (leadPath[index + 1] - leadPath[index]) * (position - Double(index))
}

let telemetrySamples: [Sample] = (0...(seconds * 2)).map { index in
    let time = Double(index) * 0.5
    let dt = 0.05
    let metresPerSecond = speedKmh(at: time) / 3.6
    let yawRate = (pose(at: time + dt).yaw - pose(at: time - dt).yaw) / (2 * dt)
    return Sample(
        time: time,
        speedKmh: speedKmh(at: time),
        throttle: throttlePercent(at: time),
        steering: steeringDegrees(at: time),
        brake: isBraking(time) ? 1 : 0,
        turnSignal: turnSignal(at: time),
        heading: (12.0 + pose(at: time).yaw * 180 / .pi).truncatingRemainder(dividingBy: 360),
        ax: metresPerSecond * yawRate,
        ay: (speedKmh(at: time + dt) - speedKmh(at: time - dt)) / 3.6 / (2 * dt),
        az: 9.8
    )
}

// MARK: - Geometry

struct V3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = V3(0, 0, 0)

    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, scalar: Double) -> V3 { V3(a.x * scalar, a.y * scalar, a.z * scalar) }
    static prefix func - (a: V3) -> V3 { V3(-a.x, -a.y, -a.z) }

    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var length: Double { sqrt(dot(self)) }
    func normalized() -> V3 { self * (1 / length) }

    subscript(axis: Int) -> Double {
        get { axis == 0 ? x : axis == 1 ? y : z }
    }

    /// Turn about the vertical axis: 0 keeps -z forward, positive turns towards +x.
    func rotatedY(_ angle: Double) -> V3 {
        V3(x * cos(angle) - z * sin(angle), y, x * sin(angle) + z * cos(angle))
    }
}

/// A pinhole camera fixed to the car: x right, y up, z towards the rear.
struct Shot {
    var position: V3
    /// 0 looks forward (-z), π looks back, positive turns right.
    var yaw: Double
    /// Positive looks down.
    var pitch: Double
    var focal: Double

    static func focal(horizontalDegrees: Double) -> Double {
        Double(width) / 2 / tan(horizontalDegrees / 2 * .pi / 180)
    }

    func toCamera(_ point: V3) -> V3 {
        let d = point - position
        let sy = sin(yaw), cy = cos(yaw), sp = sin(pitch), cp = cos(pitch)
        return V3(d.dot(V3(cy, 0, sy)), -d.dot(V3(sy * sp, cp, -cy * sp)), d.dot(V3(sy * cp, -sp, -cy * cp)))
    }

    func screen(_ point: V3) -> CGPoint {
        CGPoint(x: Double(width) / 2 + focal * point.x / point.z, y: Double(height) / 2 + focal * point.y / point.z)
    }

    /// Screen height of the horizon.
    var horizonY: CGFloat { CGFloat(Double(height) / 2 - focal * tan(pitch)) }
}

/// Where the camera looks, and where the car is in the world.
struct View {
    let shot: Shot
    let carPosition: V3
    let carYaw: Double

    init(shot: Shot, carPosition: V3 = .zero, carYaw: Double = 0) {
        self.shot = shot
        self.carPosition = carPosition
        self.carYaw = carYaw
    }

    /// World to the car's frame.
    func toCar(_ point: V3) -> V3 { (point - carPosition).rotatedY(-carYaw) }
    func toCarDirection(_ direction: V3) -> V3 { direction.rotatedY(-carYaw) }

    /// Clips a world polygon to the view and returns its screen points.
    func project(_ world: [V3]) -> [CGPoint]? {
        let near = 0.06
        let tanX = (Double(width) / 2 + 8) / shot.focal
        let tanY = (Double(height) / 2 + 8) / shot.focal
        var polygon = world.map { shot.toCamera(toCar($0)) }
        guard polygon.count >= 3 else { return nil }
        polygon = clip(polygon) { $0.z - near }
        guard polygon.count >= 3 else { return nil }
        polygon = clip(polygon) { $0.z * tanX - $0.x }
        guard polygon.count >= 3 else { return nil }
        polygon = clip(polygon) { $0.z * tanX + $0.x }
        guard polygon.count >= 3 else { return nil }
        polygon = clip(polygon) { $0.z * tanY - $0.y }
        guard polygon.count >= 3 else { return nil }
        polygon = clip(polygon) { $0.z * tanY + $0.y }
        guard polygon.count >= 3 else { return nil }
        return polygon.count >= 3 ? polygon.map(shot.screen) : nil
    }

    /// Whether a surface facing `normal` (world) can be seen.
    func facesCamera(_ point: V3, normal: V3) -> Bool {
        (shot.position - toCar(point)).dot(toCarDirection(normal)) > 0
    }
}

/// Sutherland–Hodgman clip of a polygon against one half-space (`inside` ≥ 0).
func clip(_ polygon: [V3], _ inside: (V3) -> Double) -> [V3] {
    var result: [V3] = []
    result.reserveCapacity(polygon.count + 1)
    guard var last = polygon.last else { return result }
    var lastValue = inside(last)
    for point in polygon {
        let value = inside(point)
        if (value >= 0) != (lastValue >= 0) {
            result.append(last + (point - last) * (lastValue / (lastValue - value)))
        }
        if value >= 0 { result.append(point) }
        last = point
        lastValue = value
    }
    return result
}

/// An oriented box, for sorting things back to front.
struct OBB {
    var centre: V3
    var axes: [V3]
    var half: V3

    init(centre: V3, yaw: Double, half: V3) {
        self.centre = centre
        self.axes = [V3(cos(yaw), 0, sin(yaw)), V3(0, 1, 0), V3(-sin(yaw), 0, cos(yaw))]
        self.half = half
    }

    func corner(_ index: Int) -> V3 {
        var point = centre
        for axis in 0..<3 where index & (1 << axis) != 0 {
            point = point + axes[axis] * half[axis]
        }
        return point
    }
}

/// Separating-axis test between two boxes seen from `camera`: the index of the
/// one in front, or nil when they interpenetrate. For boxes that do not touch
/// this is exact, so the painter's order never hides the wrong thing.
func boxInFront(_ a: OBB, _ b: OBB, camera: V3) -> Int? {
    let difference = b.centre - a.centre
    var axes = a.axes + b.axes
    for i in 0..<3 {
        for j in 0..<3 {
            let cross = a.axes[i].cross(b.axes[j])
            if cross.length > 1e-6 { axes.append(cross) }
        }
    }
    for axis in axes {
        let length = axis.length
        guard length > 1e-9 else { continue }
        let direction = axis * (1 / length)
        let distance = abs(difference.dot(direction))
        var radiusA = 0.0
        var radiusB = 0.0
        for k in 0..<3 {
            radiusA += a.half[k] * abs(a.axes[k].dot(direction))
            radiusB += b.half[k] * abs(b.axes[k].dot(direction))
        }
        if distance <= radiusA + radiusB { continue } // this axis does not separate them
        // The camera sits on the side of whichever box it is nearer to along the axis.
        let cameraSide = (camera - a.centre).dot(direction) * difference.dot(direction)
        return cameraSide >= 0 ? 1 : 0
    }
    return nil
}

/// Newell's method: a normal for a polygon, whether or not it is convex.
func polygonNormal(_ points: [V3]) -> V3 {
    var normal = V3.zero
    for index in points.indices {
        let a = points[index]
        let b = points[(index + 1) % points.count]
        normal.x += (a.y - b.y) * (a.z + b.z)
        normal.y += (a.z - b.z) * (a.x + b.x)
        normal.z += (a.x - b.x) * (a.y + b.y)
    }
    return normal
}

// MARK: - Drawing helpers

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func fill(_ context: CGContext, _ color: CGColor, in rect: CGRect) {
    context.setFillColor(color)
    context.fill(rect)
}

func strokeLine(_ context: CGContext, _ color: CGColor, from: CGPoint, to: CGPoint, lineWidth: CGFloat) {
    context.setStrokeColor(color)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.move(to: from)
    context.addLine(to: to)
    context.strokePath()
}

func fillCircle(_ context: CGContext, _ color: CGColor, centre: CGPoint, radius: CGFloat) {
    guard radius > 0.2 else { return }
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
}

func fillPolygon(_ context: CGContext, _ points: [CGPoint], _ color: CGColor) {
    guard points.count >= 3 else { return }
    context.setFillColor(color)
    context.addLines(between: points)
    context.closePath()
    context.fillPath()
}

func path(of points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    path.addLines(between: Array(points.dropFirst()))
    path.closeSubpath()
    return path
}

func verticalGradient(_ context: CGContext, in rect: CGRect, top: CGColor, bottom: CGColor) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    context.saveGState()
    context.clip(to: rect)
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
    context.restoreGState()
}

/// Menlo, with the origin at the top-left of the line.
func drawText(_ context: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: CGColor, bold: Bool = false,
              fontName: String = "Menlo") {
    var font = CTFontCreateWithName(fontName as CFString, size, nil)
    if bold, let heavier = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) {
        font = heavier
    }
    let string = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(string)
    context.saveGState()
    context.textMatrix = .identity
    context.translateBy(x: point.x, y: point.y + size)
    context.scaleBy(x: 1, y: -1)
    CTLineDraw(line, context)
    context.restoreGState()
}

/// How wide `drawText` makes a string.
func textWidth(_ string: String, size: CGFloat, bold: Bool = false, fontName: String = "Menlo") -> CGFloat {
    var font = CTFontCreateWithName(fontName as CFString, size, nil)
    if bold, let heavier = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) {
        font = heavier
    }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
    ]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

let lightDirection = V3(-0.45, 1.0, -0.55).normalized()

/// A flat colour lit a little from above: top faces lightest.
func shaded(_ colour: (Double, Double, Double), normal: V3) -> CGColor {
    let k = 0.70 + 0.30 * max(0, normal.dot(lightDirection))
    return rgb(CGFloat(colour.0 * k), CGFloat(colour.1 * k), CGFloat(colour.2 * k))
}

// MARK: - Scene graph

struct Face {
    var points: [V3]
    var color: CGColor
    /// Outward normal for a patch on a body (glass, a light). Nil: the body's interior point decides.
    var normal: V3?
}

struct GroundItem {
    let points: [V3]
    let color: CGColor
}

/// Something that stands on the ground and has to be sorted against the others.
struct Unit {
    let obb: OBB
    let screen: CGRect
    let distance: Double
    let draw: () -> Void
}

/// One frame. Everything is added in world coordinates; `flush` draws it back to front.
final class Frame {
    let context: CGContext
    let view: View
    private var groundItems: [GroundItem] = []
    private var shadowItems: [GroundItem] = []
    private var units: [Unit] = []
    private var overlays: [() -> Void] = []

    init(context: CGContext, view: View) {
        self.context = context
        self.view = view
    }

    // MARK: Ground

    /// Ground and what is painted on it, in the order added.
    func ground(_ points: [V3], _ color: CGColor) {
        groundItems.append(GroundItem(points: points, color: color))
    }

    /// Painted after all the ground: cast shadows.
    func shadow(_ points: [V3]) {
        shadowItems.append(GroundItem(points: points, color: rgb(10, 12, 18, alpha: 0.22)))
    }

    /// A circle lying on the ground.
    func disc(_ centre: V3, _ radius: Double, count: Int = 14) -> [V3] {
        (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi
            return V3(centre.x + radius * cos(angle), 0, centre.z + radius * sin(angle))
        }
    }

    func groundRect(_ x1: Double, _ x2: Double, _ z1: Double, _ z2: Double, _ color: CGColor) {
        ground([V3(x1, 0, z1), V3(x2, 0, z1), V3(x2, 0, z2), V3(x1, 0, z2)], color)
    }

    /// A painted line of constant width from (x1, z1) to (x2, z2).
    func groundLine(x1: Double, z1: Double, x2: Double, z2: Double, width: Double, _ color: CGColor) {
        let dx = x2 - x1, dz = z2 - z1
        let length = sqrt(dx * dx + dz * dz)
        guard length > 0 else { return }
        let nx = -dz / length * width / 2, nz = dx / length * width / 2
        ground([V3(x1 + nx, 0, z1 + nz), V3(x2 + nx, 0, z2 + nz), V3(x2 - nx, 0, z2 - nz), V3(x1 - nx, 0, z1 - nz)], color)
    }

    // MARK: Things that stand up

    /// Adds a thing that stands on the ground. `centre` is in world coordinates
    /// at the middle of its height, `yaw` its heading in the world.
    func unit(centre: V3, yaw: Double, half: V3, draw: @escaping () -> Void) {
        let obb = OBB(centre: view.toCar(centre), yaw: yaw - view.carYaw, half: half)
        guard let screen = screenRect(of: obb) else { return }
        units.append(Unit(obb: obb, screen: screen, distance: (obb.centre - view.shot.position).length, draw: draw))
    }

    /// Drawn after everything else: the car the cameras are on, which nothing
    /// beside it can ever be in front of from where they look.
    func overlay(_ draw: @escaping () -> Void) {
        overlays.append(draw)
    }

    /// The box's extent on screen, or nil when the camera is inside or behind it.
    private func screenRect(of obb: OBB) -> CGRect? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var seen = false
        for index in 0..<8 {
            let point = view.shot.toCamera(obb.corner(index))
            guard point.z > 0.06 else { continue }
            seen = true
            let u = min(max(Double(width) / 2 + view.shot.focal * point.x / point.z, -5000), 9000)
            let v = min(max(Double(height) / 2 + view.shot.focal * point.y / point.z, -5000), 9000)
            minX = min(minX, u); maxX = max(maxX, u)
            minY = min(minY, v); maxY = max(maxY, v)
        }
        guard seen else { return nil }
        let rect = CGRect(x: minX - 2, y: minY - 2, width: maxX - minX + 4, height: maxY - minY + 4)
        return rect.intersects(CGRect(x: -4, y: -4, width: width + 8, height: height + 8)) ? rect : nil
    }

    /// Draws the faces of one thing that face the camera. Faces are drawn in
    /// the order given, so a patch (glass, a light) follows the face it sits
    /// on. The whole silhouette is filled with `base` first, so that no seam
    /// between two faces lets the background show through.
    func solid(_ faces: [Face], base: CGColor, interior: V3) {
        let visible: [([CGPoint], CGColor)] = faces.compactMap { face in
            var normal = face.normal ?? polygonNormal(face.points)
            guard normal.length > 1e-12 else { return nil }
            if face.normal == nil, normal.dot(face.points[0] - interior) < 0 { normal = -normal }
            guard view.facesCamera(face.points[0], normal: normal) else { return nil }
            var points = face.points
            // One winding for every face, so that the silhouette fills without holes.
            if polygonNormal(points).dot(normal) < 0 { points.reverse() }
            guard let screen = view.project(points) else { return nil }
            return (screen, face.color)
        }
        guard !visible.isEmpty else { return }
        let silhouette = CGMutablePath()
        for (points, _) in visible { silhouette.addPath(path(of: points)) }
        // No clip to the silhouette: on this CoreGraphics an antialiased clip
        // under a flipped context fills a rectangle as a triangle, and every
        // face lies inside the silhouette anyway.
        context.setFillColor(base)
        context.addPath(silhouette)
        context.fillPath(using: .winding)
        for (points, color) in visible { fillPolygon(context, points, color) }
    }

    // MARK: Drawing

    func flush() {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        verticalGradient(context, in: canvas, top: rgb(96, 156, 214), bottom: rgb(214, 232, 246))
        // Haze along the horizon, so that the ground does not end in a hard line.
        let horizon = view.shot.horizonY
        fill(context, rgb(206, 222, 232, alpha: 0.55), in: CGRect(x: 0, y: horizon - 9, width: CGFloat(width), height: 10))

        for item in groundItems {
            if let points = view.project(item.points) { fillPolygon(context, points, item.color) }
        }
        for item in shadowItems {
            if let points = view.project(item.points) { fillPolygon(context, points, item.color) }
        }
        for unit in orderedUnits() { unit.draw() }
        for overlay in overlays { overlay() }
        groundItems.removeAll()
        shadowItems.removeAll()
        units.removeAll()
        overlays.removeAll()
    }

    /// Back to front. Two things whose pictures overlap are ordered by the
    /// separating axis of their boxes; the rest can go in any order.
    private func orderedUnits() -> [Unit] {
        let count = units.count
        guard count > 1 else { return units }
        let camera = view.shot.position
        var successors = [Set<Int>](repeating: [], count: count)
        var predecessors = [Int](repeating: 0, count: count)
        for i in 0..<count {
            guard units[i].screen.width < Double(width) * 4 else { continue } // off-screen slivers
            for j in (i + 1)..<count where units[i].screen.intersects(units[j].screen) {
                let front: Int
                if let separated = boxInFront(units[i].obb, units[j].obb, camera: camera) {
                    front = separated
                } else {
                    // Props that interpenetrate (touching kerb pieces): the nearer one is in front.
                    front = units[i].distance < units[j].distance ? i : j
                }
                let back = front == i ? j : i
                successors[back].insert(front)
                predecessors[front] += 1
            }
        }
        var placed = [Bool](repeating: false, count: count)
        var order: [Unit] = []
        order.reserveCapacity(count)
        while order.count < count {
            var best = -1
            for i in 0..<count where !placed[i] && predecessors[i] == 0 {
                if best < 0 || units[i].distance > units[best].distance { best = i }
            }
            if best < 0 {
                // Only reachable when props interpenetrate: finish by distance.
                for i in 0..<count where !placed[i] { order.append(units[i]); placed[i] = true }
                break
            }
            placed[best] = true
            order.append(units[best])
            for next in successors[best] { predecessors[next] -= 1 }
        }
        return order
    }
}

// MARK: - Props

/// Faces of a box standing on the ground at `centre`, `size` wide, tall and deep.
func boxFaces(centre: V3, yaw: Double, size: V3, colour: (Double, Double, Double)) -> [Face] {
    let hx = size.x / 2, hy = size.y, hz = size.z / 2
    func point(_ x: Double, _ y: Double, _ z: Double) -> V3 { V3(x, y, z).rotatedY(yaw) + centre }
    func face(_ points: [V3], _ normal: V3) -> Face {
        let turned = normal.rotatedY(yaw)
        return Face(points: points, color: shaded(colour, normal: turned), normal: turned)
    }
    return [
        face([point(-hx, hy, -hz), point(hx, hy, -hz), point(hx, hy, hz), point(-hx, hy, hz)], V3(0, 1, 0)),
        face([point(-hx, 0, -hz), point(hx, 0, -hz), point(hx, hy, -hz), point(-hx, hy, -hz)], V3(0, 0, -1)),
        face([point(hx, 0, hz), point(-hx, 0, hz), point(-hx, hy, hz), point(hx, hy, hz)], V3(0, 0, 1)),
        face([point(hx, 0, -hz), point(hx, 0, hz), point(hx, hy, hz), point(hx, hy, -hz)], V3(1, 0, 0)),
        face([point(-hx, 0, hz), point(-hx, 0, -hz), point(-hx, hy, -hz), point(-hx, hy, hz)], V3(-1, 0, 0)),
    ]
}

extension Frame {
    /// A plain box standing on the ground.
    func box(centre: V3, yaw: Double = 0, size: V3, colour: (Double, Double, Double)) {
        let middle = V3(centre.x, centre.y + size.y / 2, centre.z)
        let base = shaded(colour, normal: V3(0, 1, 0).rotatedY(yaw))
        let faces = boxFaces(centre: centre, yaw: yaw, size: size, colour: colour)
        unit(centre: middle, yaw: yaw, half: V3(size.x / 2, size.y / 2, size.z / 2)) { [self] in
            solid(faces, base: base, interior: middle)
        }
    }

    /// A tree: a trunk and a round canopy, standing at `base`.
    func tree(at base: V3, height: Double, radius: Double) {
        let trunk = boxFaces(centre: base, yaw: 0, size: V3(0.28, height - radius * 0.6, 0.28), colour: (104, 82, 62))
        let trunkTop = V3(base.x, (height - radius * 0.6) / 2, base.z)
        let canopyCentre = V3(base.x, height - radius * 0.85, base.z)
        shadow(disc(base, radius * 0.9))
        unit(centre: V3(base.x, height / 2, base.z), yaw: 0, half: V3(radius * 1.1, height / 2, radius * 1.1)) { [self] in
            solid(trunk, base: rgb(80, 62, 47), interior: trunkTop)
            let cameraSpace = view.shot.toCamera(view.toCar(canopyCentre))
            guard cameraSpace.z > 0.06 else { return }
            let centre = view.shot.screen(cameraSpace)
            let scale = CGFloat(view.shot.focal / cameraSpace.z)
            fillCircle(context, rgb(70, 112, 62), centre: CGPoint(x: centre.x, y: centre.y + 0.12 * CGFloat(radius) * scale), radius: CGFloat(radius) * scale)
            fillCircle(context, rgb(88, 134, 74), centre: CGPoint(x: centre.x - 0.3 * CGFloat(radius) * scale, y: centre.y - 0.15 * CGFloat(radius) * scale), radius: CGFloat(radius) * 0.72 * scale)
            fillCircle(context, rgb(104, 150, 86), centre: CGPoint(x: centre.x + 0.34 * CGFloat(radius) * scale, y: centre.y - 0.05 * CGFloat(radius) * scale), radius: CGFloat(radius) * 0.6 * scale)
        }
    }

    /// A street lamp: pole, arm reaching over the road towards `armYaw`, head.
    func lampPost(at base: V3, armYaw: Double) {
        let poleHeight = 5.2
        let arm = V3(sin(armYaw), 0, -cos(armYaw))
        let armLength = 1.5
        let pole = boxFaces(centre: base, yaw: 0, size: V3(0.16, poleHeight, 0.16), colour: (92, 96, 100))
        let armBase = base + V3(0, poleHeight - 0.12, 0) + arm * (armLength / 2)
        let armBox = boxFaces(centre: armBase, yaw: armYaw, size: V3(0.1, 0.12, armLength), colour: (92, 96, 100))
        let headBase = base + V3(0, poleHeight - 0.2, 0) + arm * (armLength - 0.3)
        let head = boxFaces(centre: headBase, yaw: armYaw, size: V3(0.26, 0.14, 0.62), colour: (176, 180, 184))
        let top = armBase
        let middle = base + V3(0, poleHeight / 2, 0)
        unit(centre: middle, yaw: armYaw, half: V3(max(0.2, armLength), poleHeight / 2, max(0.2, armLength))) { [self] in
            solid(pole, base: rgb(70, 74, 78), interior: middle)
            solid(armBox, base: rgb(70, 74, 78), interior: top)
            solid(head, base: rgb(160, 164, 168), interior: headBase + V3(0, 0.07, 0))
        }
    }

    /// A house with a pitched roof and windows on the side that faces -z of its own frame.
    func house(centre: V3, yaw: Double, w: Double, d: Double, h: Double, colour: (Double, Double, Double)) {
        let rise = min(d * 0.28, 2.2)
        func point(_ x: Double, _ y: Double, _ z: Double) -> V3 { V3(x, y, z).rotatedY(yaw) + centre }
        let walls = boxFaces(centre: centre, yaw: yaw, size: V3(w, h, d), colour: colour)
        let roofColour: (Double, Double, Double) = (84, 74, 70)
        let roof = [
            Face(points: [point(-w / 2, h, d / 2), point(w / 2, h, d / 2), point(w / 2, h + rise, 0), point(-w / 2, h + rise, 0)],
                 color: shaded(roofColour, normal: V3(0, d / 2, rise).rotatedY(yaw))),
            Face(points: [point(-w / 2, h, -d / 2), point(w / 2, h, -d / 2), point(w / 2, h + rise, 0), point(-w / 2, h + rise, 0)],
                 color: shaded(roofColour, normal: V3(0, d / 2, -rise).rotatedY(yaw))),
            Face(points: [point(-w / 2, h, -d / 2), point(-w / 2, h, d / 2), point(-w / 2, h + rise, 0)], color: shaded(colour, normal: V3(-1, 0, 0).rotatedY(yaw))),
            Face(points: [point(w / 2, h, -d / 2), point(w / 2, h, d / 2), point(w / 2, h + rise, 0)], color: shaded(colour, normal: V3(1, 0, 0).rotatedY(yaw))),
        ]
        // Windows and a door on the side facing the street, a centimetre proud of the wall.
        let frontNormal = V3(0, 0, -1).rotatedY(yaw)
        var windows: [Face] = []
        func window(_ x1: Double, _ x2: Double, _ y1: Double, _ y2: Double, _ color: CGColor) {
            windows.append(Face(points: [point(x1, y1, -d / 2 - 0.012), point(x2, y1, -d / 2 - 0.012), point(x2, y2, -d / 2 - 0.012), point(x1, y2, -d / 2 - 0.012)],
                                color: color, normal: frontNormal))
        }
        let glass = rgb(60, 78, 98)
        let columns = max(1, Int((w - 1.6) / 2.2))
        for column in 0..<columns {
            let x = -w / 2 + 1.1 + Double(column) * 2.2
            window(x, x + 1.25, 1.0, 2.3, glass)
            if h > 5.6 { window(x, x + 1.25, 3.5, 4.7, glass) }
        }
        window(w / 2 - 1.6, w / 2 - 0.6, 0, 2.1, rgb(78, 64, 56))
        let middle = V3(centre.x, h / 2, centre.z)
        let base = shaded(colour, normal: V3(0, 1, 0).rotatedY(yaw))
        unit(centre: V3(centre.x, (h + rise) / 2, centre.z), yaw: yaw, half: V3(w / 2, (h + rise) / 2, d / 2)) { [self] in
            solid(walls + roof, base: base, interior: middle)
            solid(windows, base: glass, interior: middle + frontNormal * (d / 2 + 1))
        }
    }

    /// A featureless figure: round head, capsule body, two legs, two arms. No face.
    func figure(at feet: V3, heading: V3, phase: Double, top: CGColor, legs: CGColor) {
        shadow(disc(V3(feet.x, 0, feet.z), 0.3, count: 10))
        unit(centre: V3(feet.x, 0.88, feet.z), yaw: 0, half: V3(0.34, 0.88, 0.34)) { [self] in
            let up = V3(0, 1, 0)
            let stride = 0.24 * sin(phase)
            func screen(_ point: V3) -> CGPoint? {
                let cameraSpace = view.shot.toCamera(view.toCar(point))
                guard cameraSpace.z > 0.06 else { return nil }
                return view.shot.screen(cameraSpace)
            }
            let hip = feet + up * (0.86 + 0.02 * abs(cos(phase)))
            let shoulder = feet + up * 1.40
            guard let hipScreen = screen(hip), let shoulderScreen = screen(shoulder) else { return }
            let scale = CGFloat(view.shot.focal / view.shot.toCamera(view.toCar(hip)).z)
            let leftFoot = screen(feet + heading * stride + up * (0.09 * max(0, cos(phase))))
            let rightFoot = screen(feet - heading * stride + up * (0.09 * max(0, -cos(phase))))
            let leftHand = screen(shoulder - up * 0.52 - heading * (0.14 * sin(phase)))
            let rightHand = screen(shoulder - up * 0.52 + heading * (0.14 * sin(phase)))
            let head = screen(feet + up * 1.58)
            func limb(_ from: CGPoint?, _ to: CGPoint?, _ color: CGColor, _ thickness: CGFloat) {
                guard let from, let to else { return }
                strokeLine(context, color, from: from, to: to, lineWidth: thickness * scale)
            }
            limb(hipScreen, leftFoot, legs, 0.13)
            limb(hipScreen, rightFoot, legs, 0.13)
            limb(shoulderScreen, leftHand, top, 0.09)
            limb(shoulderScreen, rightHand, top, 0.09)
            strokeLine(context, top, from: hipScreen, to: shoulderScreen, lineWidth: 0.36 * scale)
            if let head { fillCircle(context, rgb(222, 196, 176), centre: head, radius: 0.115 * scale) }
        }
    }
}

// MARK: - Cars

struct CarStyle {
    let length: Double
    let width: Double
    /// The side silhouette, from the front bumper's foot up over the roof to the rear bumper's foot.
    let profile: [(z: Double, y: Double)]
    /// Side windows, as (z, y).
    let glass: [(z: Double, y: Double)]
    let axles: [Double]

    static let sedan = CarStyle(
        length: 4.72, width: 1.86,
        profile: [(-2.36, 0.42), (-2.36, 0.80), (-1.45, 0.93), (-0.50, 1.43), (0.95, 1.41), (1.80, 1.02), (2.36, 0.95), (2.36, 0.42)],
        glass: [(-0.42, 1.03), (-0.08, 1.35), (0.82, 1.33), (1.08, 1.06)],
        axles: [-1.45, 1.45]
    )

    static let hatch = CarStyle(
        length: 4.30, width: 1.84,
        profile: [(-2.15, 0.44), (-2.15, 0.86), (-1.30, 1.00), (-0.30, 1.56), (1.25, 1.54), (1.95, 1.12), (2.15, 0.70), (2.15, 0.44)],
        glass: [(-0.24, 1.10), (0.06, 1.47), (1.10, 1.45), (1.30, 1.14)],
        axles: [-1.32, 1.32]
    )

    static let van = CarStyle(
        length: 4.90, width: 1.94,
        profile: [(-2.45, 0.46), (-2.45, 1.05), (-1.75, 1.98), (1.90, 1.98), (2.45, 1.85), (2.45, 0.46)],
        glass: [(-1.58, 1.28), (-1.10, 1.86), (-0.28, 1.86), (-0.28, 1.28)],
        axles: [-1.55, 1.50]
    )
}

let wheelRadius = 0.33
let archRadius = 0.45

extension Frame {
    /// A boxy car standing at `centre` (on the ground) heading `yaw` (its nose
    /// towards -z before the turn). `own` draws it after everything else.
    func car(centre: V3, yaw: Double, style: CarStyle, colour: (Double, Double, Double), braking: Bool = false, headlights: Bool = false, lit: Bool = true, own: Bool = false) {
        let halfWidth = style.width / 2
        let roof = style.profile.map(\.y).max() ?? 1.4
        let floor = style.profile[0].y
        let body = shaded(colour, normal: V3(0, 0, -1).rotatedY(yaw))
        func place(_ point: V3) -> V3 { point.rotatedY(yaw) + centre }
        func disc(_ x: Double, _ axle: Double, _ radius: Double, _ normalSide: Double, _ color: CGColor) -> Face {
            let points = (0..<18).map { index in
                let angle = Double(index) / 18 * 2 * .pi
                return place(V3(x, wheelRadius + radius * sin(angle), axle + radius * cos(angle)))
            }
            return Face(points: points, color: color, normal: V3(normalSide, 0, 0).rotatedY(yaw))
        }
        func at(_ z: Double, _ y: Double, _ x: Double) -> V3 { place(V3(x, y, z)) }

        // Wheels first: the body's side covers their tops and leaves the arches.
        var faces: [Face] = []
        for side in [-1.0, 1.0] {
            for axle in style.axles {
                faces.append(disc(side * (halfWidth - 0.012), axle, archRadius + 0.03, side, rgb(24, 25, 28)))
                faces.append(disc(side * (halfWidth - 0.03), axle, wheelRadius, side, rgb(38, 39, 43)))
                faces.append(disc(side * (halfWidth - 0.028), axle, 0.19, side, rgb(132, 135, 140)))
            }
        }

        // The sides with the wheel arches cut out of their bottom edge.
        let archHalfWidth = sqrt(archRadius * archRadius - (floor - wheelRadius) * (floor - wheelRadius))
        let archStart = atan2(floor - wheelRadius, archHalfWidth)
        var bottom: [(z: Double, y: Double)] = []
        for axle in style.axles.reversed() {
            bottom.append((axle + archHalfWidth, floor))
            for step in 1...10 {
                let angle = archStart + (Double(step) / 10) * (.pi - 2 * archStart)
                bottom.append((axle + archRadius * cos(angle), wheelRadius + archRadius * sin(angle)))
            }
        }
        for side in [-1.0, 1.0] {
            let outline = (style.profile + bottom).map { at($0.z, $0.y, side * halfWidth) }
            faces.append(Face(points: outline, color: shaded(colour, normal: V3(side, 0, 0).rotatedY(yaw)), normal: V3(side, 0, 0).rotatedY(yaw)))
        }
        // Bonnet, windscreen, roof, rear window, boot, front and rear.
        let profile = style.profile
        for index in 0..<(profile.count - 1) {
            let a = profile[index], b = profile[index + 1]
            let normal = V3(0, b.z - a.z, a.y - b.y).normalized() // the profile runs nose to tail, so this points outwards
            faces.append(Face(points: [at(a.z, a.y, -halfWidth), at(b.z, b.y, -halfWidth), at(b.z, b.y, halfWidth), at(a.z, a.y, halfWidth)],
                              color: shaded(colour, normal: normal.rotatedY(yaw)), normal: normal.rotatedY(yaw)))
        }
        // A strip between two fractions of the edge from `a` to `b`, lifted `lift` off the surface along its outward normal.
        func patch(_ a: (z: Double, y: Double), _ b: (z: Double, y: Double), from: Double, to: Double, x1: Double, x2: Double, lift: Double, outward normal: V3, _ color: CGColor) -> Face {
            let dz = b.z - a.z, dy = b.y - a.y
            func at(_ t: Double, _ x: Double) -> V3 {
                V3(x, a.y + dy * t, a.z + dz * t).rotatedY(yaw) + (normal * lift).rotatedY(yaw) + centre
            }
            return Face(points: [at(from, x1), at(to, x1), at(to, x2), at(from, x2)], color: color, normal: normal.rotatedY(yaw))
        }
        /// Outward normal of the silhouette edge from `a` to `b`, the profile being listed nose to tail.
        func outward(_ a: (z: Double, y: Double), _ b: (z: Double, y: Double)) -> V3 {
            V3(0, b.z - a.z, a.y - b.y).normalized()
        }
        let glassColour = rgb(46, 58, 72)
        let roofFront = profile[2], windscreenTop = profile[3], roofRear = profile[4], boot = profile[5]
        for side in [-1.0, 1.0] {
            faces.append(Face(points: style.glass.map { place(V3(side * (halfWidth + 0.006), $0.1, $0.0)) }, color: glassColour, normal: V3(side, 0, 0).rotatedY(yaw)))
            // B-pillar over the glass.
            let pillarZ = (style.glass.map(\.0).min()! + style.glass.map(\.0).max()!) / 2
            faces.append(Face(points: [place(V3(side * (halfWidth + 0.012), style.glass.map(\.1).min()! + 0.02, pillarZ - 0.06)),
                                       place(V3(side * (halfWidth + 0.012), style.glass.map(\.1).max()! - 0.02, pillarZ - 0.06)),
                                       place(V3(side * (halfWidth + 0.012), style.glass.map(\.1).max()! - 0.02, pillarZ + 0.08)),
                                       place(V3(side * (halfWidth + 0.012), style.glass.map(\.1).min()! + 0.02, pillarZ + 0.08))],
                              color: body, normal: V3(side, 0, 0).rotatedY(yaw)))
        }
        faces.append(patch((roofFront.z, roofFront.y), (windscreenTop.z, windscreenTop.y), from: 0.14, to: 0.86, x1: -(halfWidth - 0.10), x2: halfWidth - 0.10, lift: 0.012, outward: outward(roofFront, windscreenTop), glassColour))
        faces.append(patch((roofRear.z, roofRear.y), (boot.z, boot.y), from: 0.14, to: 0.80, x1: -(halfWidth - 0.12), x2: halfWidth - 0.12, lift: 0.012, outward: outward(roofRear, boot), glassColour))
        // Lights and blank plates on the front and rear faces. A parked car's lights are not lit.
        let frontBottom = profile[0], frontTop = profile[1], rearTop = profile[profile.count - 2], rearBottom = profile[profile.count - 1]
        let headlight = !lit ? rgb(186, 188, 192) : headlights ? rgb(255, 246, 200) : rgb(222, 226, 232)
        let tail = !lit ? rgb(112, 30, 28) : braking ? rgb(255, 58, 46) : rgb(176, 36, 34)
        // The lower bumper at each end, so that the car stands on the ground and does not float over its shadow.
        let under = rgb(46, 48, 52)
        for (edge, facing) in [(frontBottom, V3(0, 0, -1)), (rearBottom, V3(0, 0, 1))] {
            faces.append(Face(points: [at(edge.z, 0.02, -halfWidth), at(edge.z, edge.y, -halfWidth), at(edge.z, edge.y, halfWidth), at(edge.z, 0.02, halfWidth)],
                              color: under, normal: facing.rotatedY(yaw)))
        }
        for side in [-1.0, 1.0] {
            faces.append(patch((frontBottom.z, frontBottom.y), (frontTop.z, frontTop.y), from: 0.66, to: 0.90, x1: side < 0 ? -halfWidth + 0.10 : halfWidth - 0.58, x2: side < 0 ? -halfWidth + 0.58 : halfWidth - 0.10, lift: 0.012, outward: V3(0, 0, -1), headlight))
            faces.append(patch((rearBottom.z, rearBottom.y), (rearTop.z, rearTop.y), from: 0.46, to: 0.90, x1: side < 0 ? -halfWidth + 0.10 : halfWidth - 0.66, x2: side < 0 ? -halfWidth + 0.66 : halfWidth - 0.10, lift: 0.012, outward: V3(0, 0, 1), tail))
        }
        faces.append(patch((frontBottom.z, frontBottom.y), (frontTop.z, frontTop.y), from: 0.16, to: 0.46, x1: -0.18, x2: 0.18, lift: 0.012, outward: V3(0, 0, -1), rgb(214, 216, 218)))
        faces.append(patch((rearBottom.z, rearBottom.y), (rearTop.z, rearTop.y), from: 0.12, to: 0.36, x1: -0.18, x2: 0.18, lift: 0.012, outward: V3(0, 0, 1), rgb(214, 216, 218)))

        let footprint = [V3(-halfWidth - 0.12, 0, -style.length / 2 - 0.08), V3(halfWidth + 0.12, 0, -style.length / 2 - 0.08),
                         V3(halfWidth + 0.12, 0, style.length / 2 + 0.08), V3(-halfWidth - 0.12, 0, style.length / 2 + 0.08)].map { $0.rotatedY(yaw) + centre }
        shadow(footprint)
        let middle = V3(centre.x, roof / 2, centre.z)
        let interior = place(V3(0, (roof + floor) / 2, 0))
        if own {
            overlay { [self] in solid(faces, base: shaded(colour, normal: V3(0, 1, 0)), interior: interior) }
        } else {
            unit(centre: middle, yaw: yaw, half: V3(halfWidth + 0.02, roof / 2, style.length / 2 + 0.02)) { [self] in
                solid(faces, base: shaded(colour, normal: V3(0, 1, 0)), interior: interior)
            }
        }
    }
}

// MARK: - Scenes

struct Scene {
    /// Ground and what is painted on it.
    var ground: [(Frame) -> Void]
    /// What stands on the ground and never moves.
    var props: [(Frame) -> Void]
    /// What moves, and the car's own body: adds shadows, props and overlays for one moment.
    var movers: (Double, Frame) -> Void
}

let asphalt = rgb(98, 101, 106)
let parkingAsphalt = rgb(112, 114, 118)
let concrete = rgb(192, 190, 182)
let grass = rgb(112, 144, 90)
let paint = rgb(236, 236, 232)
let yellowPaint = rgb(234, 204, 86)
let kerbColour: (Double, Double, Double) = (204, 202, 194)

typealias Colour = (Double, Double, Double)
let carColours: [Colour] = [(150, 52, 54), (222, 224, 226), (52, 78, 122), (168, 172, 178), (62, 104, 72), (196, 166, 120), (208, 206, 200), (58, 122, 128), (118, 86, 70), (88, 92, 100)]
let ownCarColour: Colour = (200, 204, 210)

/// A line of boxes, so that no single box is long enough to confuse the ordering or the clipping.
func boxRun(from: V3, to: V3, height: Double, thickness: Double, colour: Colour, piece: Double = 12) -> (Frame) -> Void {
    let length = (to - from).length
    let pieces = max(1, Int((length / piece).rounded(.up)))
    return { frame in
        for index in 0..<pieces {
            let a = from + (to - from) * (Double(index) / Double(pieces))
            let b = from + (to - from) * (Double(index + 1) / Double(pieces))
            let direction = (b - a).normalized()
            let yaw = atan2(direction.x, -direction.z)
            frame.box(centre: V3((a.x + b.x) / 2, 0, (a.z + b.z) / 2) - direction * 0.0005, yaw: yaw,
                      size: V3(thickness, height, (b - a).length + 0.001), colour: colour)
        }
    }
}

func groundRect(_ x1: Double, _ x2: Double, _ z1: Double, _ z2: Double, _ color: CGColor) -> (Frame) -> Void {
    { frame in frame.groundRect(x1, x2, z1, z2, color) }
}

/// A painted line of constant width from (x1, z1) to (x2, z2).
func groundLine(x1: Double, z1: Double, x2: Double, z2: Double, width: Double, _ color: CGColor) -> (Frame) -> Void {
    { frame in frame.groundLine(x1: x1, z1: z1, x2: x2, z2: z2, width: width, color) }
}

/// Where a walker who leaves `points[0]` at 0 s and walks at `speed` is at `time`.
func walk(_ points: [V3], speed: Double, time: Double) -> (position: V3, heading: V3) {
    var remaining = speed * max(time, 0)
    for index in 0..<(points.count - 1) {
        let leg = points[index + 1] - points[index]
        let length = leg.length
        if remaining <= length || index == points.count - 2 {
            let t = min(max(remaining / length, 0), 1)
            return (points[index] + leg * t, leg.normalized())
        }
        remaining -= length
    }
    return (points[0], V3(1, 0, 0))
}

// MARK: Parked set

let parkedScene: Scene = {
    var ground: [(Frame) -> Void] = []
    var props: [(Frame) -> Void] = []

    // Ground: grass, the car park, the footway behind the bays and its kerb.
    ground.append(groundRect(-200, 200, -200, 200, grass))
    ground.append(groundRect(-60, 60, -2.9, 15.2, parkingAsphalt))
    ground.append(groundRect(-60, 60, -5.9, -2.9, concrete))
    ground.append(groundRect(-60, 60, -10.5, -6.6, grass))
    ground.append(groundRect(-60, 60, 15.2, 17.6, concrete))
    props.append(boxRun(from: V3(-60, 0, -2.83), to: V3(60, 0, -2.83), height: 0.12, thickness: 0.16, colour: kerbColour, piece: 6))

    // Bays: 2.65 m wide, two rows facing each other across the aisle.
    let bayWidth = 2.65
    let nearRow = (-11...11).map { (Double($0) + 0.5) * bayWidth }
    for x in nearRow {
        ground.append(groundLine(x1: x, z1: -2.9, x2: x, z2: 2.9, width: 0.1, paint))
        ground.append(groundLine(x1: x, z1: 8.9, x2: x, z2: 14.7, width: 0.1, paint))
    }
    for index in -6...6 {
        let centre = (Double(index) + 0.5) * bayWidth
        if index != -1 { // the bay next to ours on the left stays empty
            props.append { frame in frame.box(centre: V3(centre, 0, -2.72), size: V3(1.6, 0.12, 0.16), colour: (176, 174, 166)) }
        }
        props.append { frame in frame.box(centre: V3(-centre, 0, 9.35), size: V3(1.6, 0.12, 0.16), colour: (176, 174, 166)) }
    }

    // Hedge and trees behind the bays, a long low building behind them.
    props.append(boxRun(from: V3(-60, 0, -6.15), to: V3(60, 0, -6.15), height: 1.0, thickness: 0.9, colour: (74, 116, 64), piece: 3.3))
    for x in [-24.0, -17.0, -10.0, -3.5, 3.5, 10.0, 17.0, 24.0] {
        props.append { frame in frame.tree(at: V3(x, 0, -8.4), height: 6.2, radius: 2.1) }
    }
    props.append { frame in frame.house(centre: V3(0, 0, -15.5), yaw: .pi, w: 64, d: 11, h: 7.4, colour: (206, 198, 186)) }

    // The far side of the aisle: a wall, trees and another building.
    props.append(boxRun(from: V3(-60, 0, 15.5), to: V3(60, 0, 15.5), height: 2.2, thickness: 0.6, colour: (170, 168, 160), piece: 3.6))
    for x in [-19.0, -12.0, -5.0, 6.0, 13.0, 20.0] {
        props.append { frame in frame.tree(at: V3(x, 0, 18.3), height: 6.0, radius: 2.0) }
    }
    props.append { frame in frame.house(centre: V3(4, 0, 26.5), yaw: 0, w: 70, d: 10, h: 5.6, colour: (198, 202, 204)) }

    // Lamp posts stand on the bay lines at the edge of the aisle.
    props.append { frame in frame.lampPost(at: V3(-6.6, 0, 2.75), armYaw: .pi) }
    props.append { frame in frame.lampPost(at: V3(6.6, 0, 2.75), armYaw: .pi) }
    props.append { frame in frame.lampPost(at: V3(-11.9, 0, 2.75), armYaw: .pi) }
    props.append { frame in frame.lampPost(at: V3(11.9, 0, 2.75), armYaw: .pi) }
    props.append { frame in frame.lampPost(at: V3(-1.325, 0, 9.05), armYaw: 0) }
    props.append { frame in frame.lampPost(at: V3(6.6, 0, 9.05), armYaw: 0) }
    props.append { frame in frame.lampPost(at: V3(-11.9, 0, 9.05), armYaw: 0) }

    // Parked cars. Ours is the bay at x = 0, nose in; its neighbours and the rest never move.
    func parked(_ style: CarStyle, _ colour: Colour, x: Double, z: Double = 0.3, yaw: Double = 0) -> (Frame) -> Void {
        { frame in frame.car(centre: V3(x, 0, z), yaw: yaw, style: style, colour: colour, lit: false) }
    }
    props.append(parked(.hatch, carColours[0], x: 2.625 + 1.325)) // right neighbour
    props.append(parked(.sedan, carColours[1], x: -5.3 - 1.325))
    props.append(parked(.van, carColours[2], x: 7.95 + 1.325))
    props.append(parked(.sedan, carColours[3], x: 10.6 + 1.325))
    props.append(parked(.hatch, carColours[4], x: -10.6 - 1.325))
    props.append(parked(.sedan, carColours[5], x: 13.25 + 1.325))
    props.append(parked(.hatch, carColours[6], x: -13.25 - 1.325))
    props.append(parked(.van, carColours[1], x: -15.9 - 1.325))
    props.append(parked(.hatch, carColours[8], x: 15.9 + 1.325))
    props.append(parked(.van, carColours[2], x: 0, z: 11.4, yaw: .pi)) // straight ahead across the aisle
    props.append(parked(.van, carColours[1], x: -5.3 - 1.325, z: 11.4, yaw: .pi))
    props.append(parked(.sedan, carColours[0], x: 5.3 + 1.325, z: 11.4, yaw: .pi))
    props.append(parked(.sedan, carColours[7], x: -10.6 - 1.325, z: 11.4, yaw: .pi))
    props.append(parked(.hatch, carColours[4], x: 10.6 + 1.325, z: 11.4, yaw: .pi))
    props.append(parked(.sedan, carColours[5], x: -15.9 - 1.325, z: 11.4, yaw: .pi))
    props.append(parked(.van, carColours[8], x: 15.9 + 1.325, z: 11.4, yaw: .pi))

    ground.append { frame in frame.shadow([V3(-1.05, 0, -2.1), V3(1.05, 0, -2.1), V3(1.05, 0, 2.9), V3(-1.05, 0, 2.9)]) }

    // What passes through. Figure A comes up to the car from the front left,
    // walks along its left flank and crosses the aisle behind it. Van B drives
    // through the aisle from right to left. Figure C crosses the far footway.
    let figureA = [V3(-5.0, 0, -4.4), V3(-1.75, 0, -2.5), V3(-1.75, 0, 2.4), V3(-1.75, 0, 5.3), V3(9.0, 0, 5.3)]
    return Scene(ground: ground, props: props, movers: { time, frame in
        let a = walk(figureA, speed: 1.28, time: time)
        frame.figure(at: a.position, heading: a.heading, phase: time * 2 * .pi * 1.75, top: rgb(86, 108, 140), legs: rgb(58, 60, 68))
        frame.figure(at: V3(-14 + 1.3 * time, 0, -4.4), heading: V3(1, 0, 0), phase: time * 2 * .pi * 1.7 + 1.1, top: rgb(132, 118, 78), legs: rgb(70, 66, 60))
        frame.car(centre: V3(14 - 3.6 * time, 0, 5.25), yaw: -.pi / 2, style: .van, colour: (64, 124, 130), headlights: true)
    })
}()

// MARK: Driving set

let driveSideZ: Double = {
    let turnStart = drivePath.first { $0.yaw > 0.5 * .pi / 180 } ?? drivePath[0]
    return turnStart.position.z - 8.0 - 1.7
}()

let driveScene: Scene = {
    // The crossroads sits where the path starts to turn: the car swings right
    // with a radius of about 8 m into the eastbound lane.
    let sideZ = driveSideZ
    let laneHalf = 3.4 // from the centre line to the parking line
    let half = 5.9 // half the width of each street: a 3.4 m lane and a 2.5 m parking strip on each side
    let outer = half + 2.8 // the far edge of the pavements
    let lane = laneX
    let parkX = laneHalf + 1.25 // the middle of the parking strip

    var ground: [(Frame) -> Void] = []
    var props: [(Frame) -> Void] = []

    ground.append(groundRect(-900, 900, -900, 900, grass))
    ground.append(groundRect(-half, half, -900, 900, asphalt))
    ground.append(groundRect(-900, 900, sideZ - half, sideZ + half, asphalt))
    // Pavements, leaving the crossing open.
    ground.append(groundRect(half, outer, sideZ + half, 900, concrete))
    ground.append(groundRect(half, outer, -900, sideZ - half, concrete))
    ground.append(groundRect(-outer, -half, sideZ + half, 900, concrete))
    ground.append(groundRect(-outer, -half, -900, sideZ - half, concrete))
    ground.append(groundRect(outer, 900, sideZ - outer, sideZ - half, concrete))
    ground.append(groundRect(outer, 900, sideZ + half, sideZ + outer, concrete))
    ground.append(groundRect(-900, -outer, sideZ - outer, sideZ - half, concrete))
    ground.append(groundRect(-900, -outer, sideZ + half, sideZ + outer, concrete))
    // Kerbs.
    props.append(boxRun(from: V3(half + 0.075, 0, sideZ + half), to: V3(half + 0.075, 0, 900), height: 0.13, thickness: 0.15, colour: kerbColour))
    props.append(boxRun(from: V3(half + 0.075, 0, -900), to: V3(half + 0.075, 0, sideZ - half), height: 0.13, thickness: 0.15, colour: kerbColour))
    props.append(boxRun(from: V3(-half - 0.075, 0, sideZ + half), to: V3(-half - 0.075, 0, 900), height: 0.13, thickness: 0.15, colour: kerbColour))
    props.append(boxRun(from: V3(-half - 0.075, 0, -900), to: V3(-half - 0.075, 0, sideZ - half), height: 0.13, thickness: 0.15, colour: kerbColour))
    props.append(boxRun(from: V3(half, 0, sideZ + half + 0.075), to: V3(900, 0, sideZ + half + 0.075), height: 0.13, thickness: 0.15, colour: kerbColour))
    props.append(boxRun(from: V3(half, 0, sideZ - half - 0.075), to: V3(900, 0, sideZ - half - 0.075), height: 0.13, thickness: 0.15, colour: kerbColour))
    props.append(boxRun(from: V3(-900, 0, sideZ + half + 0.075), to: V3(-half, 0, sideZ + half + 0.075), height: 0.13, thickness: 0.15, colour: kerbColour))
    props.append(boxRun(from: V3(-900, 0, sideZ - half - 0.075), to: V3(-half, 0, sideZ - half - 0.075), height: 0.13, thickness: 0.15, colour: kerbColour))

    // Centre lines: dashes, stopped short of the crossing. Yellow, as in China.
    var z = 60.0
    while z > sideZ + 6.0 {
        ground.append(groundLine(x1: 0, z1: -z, x2: 0, z2: -z + 3, width: 0.15, yellowPaint))
        z -= 6
    }
    z = sideZ - 6.0
    while z > -700 {
        ground.append(groundLine(x1: 0, z1: -z, x2: 0, z2: -z + 3, width: 0.15, yellowPaint))
        z -= 6
    }
    var x = 6.0
    while x < 700 {
        ground.append(groundLine(x1: x, z1: sideZ, x2: x + 3, z2: sideZ, width: 0.15, yellowPaint))
        ground.append(groundLine(x1: -x, z1: sideZ, x2: -x - 3, z2: sideZ, width: 0.15, yellowPaint))
        x += 6
    }
    // Parking lines, and a zebra crossing just before the junction.
    let line = laneHalf - 0.1
    for side in [-1.0, 1.0] {
        ground.append(groundLine(x1: side * line, z1: 60, x2: side * line, z2: sideZ + 5.0, width: 0.12, paint))
        ground.append(groundLine(x1: side * line, z1: sideZ - 5.0, x2: side * line, z2: -700, width: 0.12, paint))
        ground.append(groundLine(x1: half + 1.0, z1: sideZ + side * line, x2: 700, z2: sideZ + side * line, width: 0.12, paint))
        ground.append(groundLine(x1: -(half + 1.0), z1: sideZ + side * line, x2: -700, z2: sideZ + side * line, width: 0.12, paint))
    }
    var stripe = -(half - 0.45)
    while stripe < half - 0.45 {
        ground.append(groundRect(stripe, stripe + 0.45, sideZ + 5.2, sideZ + 8.0, paint))
        stripe += 0.9
    }

    // Parked cars along both kerbs, and the houses behind the pavements.
    for (index, z) in [-8.0, -15.0, -22.0, -36.0, -43.0, -50.0, -57.0, sideZ - 14.0, sideZ - 22.0].enumerated() {
        let style: CarStyle = index % 3 == 0 ? .hatch : index % 3 == 1 ? .sedan : .van
        props.append { frame in frame.car(centre: V3(parkX, 0, z), yaw: 0, style: style, colour: carColours[index % carColours.count], lit: false) }
    }
    for (index, z) in [-12.0, -20.0, -33.0, -41.0, -54.0, sideZ - 16.0].enumerated() {
        props.append { frame in frame.car(centre: V3(-parkX, 0, z), yaw: .pi, style: .sedan, colour: carColours[(index + 3) % carColours.count], lit: false) }
    }
    for (index, z) in [-4.0, -16.0, -27.0, -39.0, -51.0, -62.0, sideZ - 19.0].enumerated() {
        props.append { frame in
            frame.house(centre: V3(outer + 7.8, 0, z), yaw: -.pi / 2, w: 9.5, d: 9.5, h: [6.4, 5.4, 6.0, 5.2, 6.6, 5.6, 6.0][index], colour: [(216, 206, 190), (196, 204, 210), (214, 196, 178), (206, 210, 204), (204, 192, 172), (190, 200, 208), (222, 214, 198)][index])
            frame.box(centre: V3(outer + 0.9, 0, z), size: V3(0.6, 0.8, 8.0), colour: (80, 120, 70))
        }
    }
    for (index, z) in [-8.0, -19.0, -31.0, -43.0, -55.0, sideZ - 20.0].enumerated() {
        props.append { frame in
            frame.house(centre: V3(-(outer + 7.8), 0, z), yaw: .pi / 2, w: 10.0, d: 9.0, h: [5.6, 6.2, 5.4, 6.4, 5.2, 6.0][index], colour: [(204, 198, 184), (210, 206, 196), (190, 198, 206), (218, 208, 192), (200, 206, 200), (212, 200, 186)][index])
        }
    }
    // Houses along the cross street, and its corner lamp post.
    for (index, x) in [17.0, 29.0, 41.0, 54.0].enumerated() {
        props.append { frame in frame.house(centre: V3(x, 0, sideZ + (outer + 7.8)), yaw: 0, w: 10.0, d: 9.0, h: [5.8, 6.4, 5.4, 6.2][index], colour: [(210, 200, 184), (198, 206, 212), (220, 210, 196), (204, 208, 200)][index]) }
    }
    for (index, x) in [17.0, 30.0, 43.0].enumerated() {
        props.append { frame in frame.house(centre: V3(x, 0, sideZ - (outer + 7.8)), yaw: .pi, w: 10.0, d: 9.0, h: [6.0, 5.4, 6.4][index], colour: [(206, 196, 180), (212, 208, 198), (192, 200, 208)][index]) }
    }

    // Trees and lamp posts along the pavements.
    for z in [-3.0, -15.0, -27.0, -39.0, -51.0, -63.0, sideZ - 30.0, sideZ - 46.0, sideZ - 62.0] {
        props.append { frame in frame.tree(at: V3(-(half + 1.5), 0, z), height: 6.4, radius: 2.2) }
    }
    for z in [-11.0, -47.0, sideZ - 38.0] {
        props.append { frame in frame.tree(at: V3(half + 1.6, 0, z), height: 5.8, radius: 2.0) }
    }
    for z in [-6.0, -30.0, -54.0, sideZ - 28.0, sideZ - 52.0] {
        props.append { frame in frame.lampPost(at: V3(half + 1.7, 0, z), armYaw: -.pi / 2) }
    }
    for z in [-18.0, -42.0, -66.0, sideZ - 40.0] {
        props.append { frame in frame.lampPost(at: V3(-(half + 1.7), 0, z), armYaw: .pi / 2) }
    }
    props.append { frame in frame.lampPost(at: V3(outer + 3.8, 0, sideZ + (half + 1.7)), armYaw: .pi) }
    props.append { frame in frame.lampPost(at: V3(outer + 3.8, 0, sideZ - (half + 1.7)), armYaw: 0) }

    return Scene(ground: ground, props: props, movers: { time, frame in
        let own = pose(at: time)
        // The car ahead brakes with us from 6.2 s to 7.6 s and goes straight on at the junction.
        frame.car(centre: V3(lane, 0, leadZ(at: time)), yaw: 0, style: .sedan, colour: (168, 172, 178), braking: isBraking(time), headlights: true)
        // The car behind follows our line, ten metres back, braking over the same span.
        let behind = pose(atDistance: own.distance - 10)
        frame.car(centre: behind.position, yaw: behind.yaw, style: .sedan, colour: (52, 78, 122), braking: isBraking(time), headlights: true)
        // Two cars coming the other way.
        frame.car(centre: V3(-lane, 0, -46 + 8.4 * time), yaw: .pi, style: .sedan, colour: (150, 52, 54), headlights: true)
        frame.car(centre: V3(-lane, 0, -170 + 8.4 * time), yaw: .pi, style: .van, colour: (222, 224, 226), headlights: true)
    })
}()

/// Where each camera sits on the car, in the car's frame.
func shot(for set: ClipSet, camera: Cam) -> Shot {
    let side = camera.isLeft ? -1.0 : 1.0
    switch camera {
    case .front:
        return Shot(position: V3(0, 1.38, -1.2), yaw: 0, pitch: 6 * .pi / 180, focal: Shot.focal(horizontalDegrees: 112))
    case .back:
        return Shot(position: V3(0, 1.28, 2.3), yaw: .pi, pitch: 5 * .pi / 180, focal: Shot.focal(horizontalDegrees: 112))
    case .leftRepeater, .rightRepeater:
        // Front corner of the flank, looking back along the car: the front
        // wheel arch sits at the leading edge of the picture.
        return Shot(position: V3(side * 1.13, 0.92, -2.12), yaw: .pi + side * -31 * .pi / 180, pitch: 4 * .pi / 180, focal: Shot.focal(horizontalDegrees: 116))
    case .leftPillar, .rightPillar:
        return Shot(position: V3(side * 1.13, 1.12, 0.1), yaw: .pi + side * -33 * .pi / 180, pitch: 5 * .pi / 180, focal: Shot.focal(horizontalDegrees: 116))
    }
}

func render(set: ClipSet, camera: Cam, time: Double, context: CGContext) {
    let shot = shot(for: set, camera: camera)
    let scene: Scene
    let view: View
    switch set {
    case .parked:
        scene = parkedScene
        view = View(shot: shot)
    case .drive:
        let own = pose(at: time)
        scene = driveScene
        view = View(shot: shot, carPosition: own.position, carYaw: own.yaw)
    }
    let frame = Frame(context: context, view: view)
    for item in scene.ground { item(frame) }
    for prop in scene.props { prop(frame) }
    scene.movers(time, frame)
    if camera.isSide {
        // The car the cameras sit on, seen only by the side cameras.
        switch set {
        case .parked: frame.car(centre: V3(0, 0, 0.3), yaw: 0, style: .sedan, colour: ownCarColour, lit: false, own: true)
        case .drive:
            let own = pose(at: time)
            frame.car(centre: own.position, yaw: own.yaw, style: .sedan, colour: ownCarColour, headlights: true, own: true)
        }
    }
    frame.flush()
    drawLabel(context, camera)
}

func drawLabel(_ context: CGContext, _ camera: Cam) {
    fill(context, rgb(0, 0, 0, alpha: 0.45), in: CGRect(x: 0, y: CGFloat(height) - 40, width: CGFloat(width), height: 40))
    let text = "DEMO · \(camera.label)"
    let point = CGPoint(x: 16, y: CGFloat(height) - 31)
    drawText(context, text, at: CGPoint(x: point.x + 1, y: point.y + 1), size: 20, color: rgb(0, 0, 0, alpha: 0.75), bold: true)
    drawText(context, text, at: point, size: 20, color: rgb(255, 255, 255), bold: true)
}

// MARK: - Export strip

/// The band the server burns into an exported clip, drawn the same way: the
/// place on the left and, for a clip that carries telemetry, the readings of
/// that moment on the right. Two things differ on purpose. The text says it is
/// demo footage, so an exported demo file is never mistaken for a recording.
/// And there is no date: demo events are placed relative to the day the app is
/// opened, so a date fixed in the file could disagree with the list.
func drawWatermark(_ context: CGContext, set: ClipSet, time: Double, language: Language) {
    let strip: CGFloat = 36
    let font = language.stripFont
    fill(context, rgb(16, 20, 26, alpha: 0.62), in: CGRect(x: 0, y: 0, width: CGFloat(width), height: strip))

    // The place never runs into the readings: a name that is long in this language gives a little.
    // 272 is what the readings below take at their widest, 13 the left margin.
    let place = "\(language.demoFootage) · \(language.city) · \(language.street(for: set))"
    var placeSize = language.stripTextSize
    let room = CGFloat(width) - 13 - (set.hasTelemetry ? 272 : 10)
    while placeSize > 13, textWidth(place, size: placeSize, fontName: font) > room { placeSize -= 1 }
    drawText(context, place, at: CGPoint(x: 13, y: 9), size: placeSize, color: rgb(255, 255, 255), fontName: font)
    guard set.hasTelemetry else { return }

    let index = min(max(Int((time * 2).rounded()), 0), telemetrySamples.count - 1)
    let sample = telemetrySamples[index]
    let centre = strip / 2
    var x = CGFloat(width) - 10

    func pill(_ text: String, width pillWidth: CGFloat, background: CGColor, textColour: CGColor = rgb(255, 255, 255), font: String) {
        x -= pillWidth
        let rect = CGRect(x: x, y: centre - 12, width: pillWidth, height: 24)
        context.saveGState()
        context.setFillColor(background)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        context.restoreGState()
        drawText(context, text, at: CGPoint(x: x + (pillWidth - textWidth(text, size: 14, fontName: font)) / 2, y: centre - 9),
                 size: 14, color: textColour, fontName: font)
    }

    // Throttle, then brake (lit only while the pedal is down), then the gear.
    pill("\(sample.throttle)%", width: 52, background: rgb(47, 124, 246, alpha: 0.92), font: "Helvetica-Bold")
    x -= 8
    let braking = sample.brake == 1
    pill(language.brake, width: max(52, textWidth(language.brake, size: 14, fontName: font) + 16),
         background: braking ? rgb(255, 69, 58, alpha: 0.95) : rgb(50, 40, 32, alpha: 0.75),
         textColour: braking ? rgb(255, 255, 255) : rgb(214, 204, 195, alpha: 0.8), font: font)
    x -= 10
    x -= 26
    fillCircle(context, rgb(89, 199, 52), centre: CGPoint(x: x + 13, y: centre), radius: 13)
    drawText(context, "D", at: CGPoint(x: x + 13 - textWidth("D", size: 15, bold: true) / 2, y: centre - 9),
             size: 15, color: rgb(255, 255, 255), bold: true)
    x -= 12

    // The indicator flashes, as it does on the car and in the server's strip.
    if sample.turnSignal != 0, Int(time / 0.2) % 2 == 0 {
        let right = sample.turnSignal == 2
        let tip = CGPoint(x: right ? x : x - 16, y: centre)
        fillPolygon(context, [tip,
                              CGPoint(x: right ? x - 16 : x, y: centre - 9),
                              CGPoint(x: right ? x - 16 : x, y: centre + 9)], rgb(11, 158, 245))
        x -= 22
    }

    // Speed, right-aligned so it does not jump as the number widens.
    x -= textWidth("km/h", size: 13) + 6
    drawText(context, "km/h", at: CGPoint(x: x, y: centre - 8), size: 13, color: rgb(248, 243, 238))
    let number = String(Int(sample.speedKmh.rounded()))
    x -= textWidth(number, size: 21, bold: true) + 6
    drawText(context, number, at: CGPoint(x: x, y: centre - 13), size: 21, color: rgb(255, 255, 255), bold: true)
}
// MARK: - Demo events

/// One event of the demo, as `demo-events.json` describes it to the app.
struct DemoEvent {
    let category: String // SentryClips | SavedClips | RecentClips
    let minutesAgo: Double
    /// Minutes of footage, one after another.
    let groups: Int
    let footage: ClipSet
    var reason: String? = nil
    /// The raw `camera` number of event.json.
    var camera: Int? = nil
    /// Where in the first minute the trigger is; nil when the car wrote no timestamp.
    var triggerOffset: Double? = nil
    /// Only when the event does not have every camera of its set.
    var cameras: [Cam]? = nil
    /// A car that wrote no place into event.json.
    var hasPlace: Bool = true
}

/// Sentry events are parked; saved and recent clips are from driving, which is
/// where telemetry comes from. The list is in the order the server gives it,
/// newest first.
let demoEvents: [DemoEvent] = [
    DemoEvent(category: "SentryClips", minutesAgo: 6, groups: 1, footage: .parked,
              reason: "sentry_aware_object_detection", camera: 5, triggerOffset: 6.5),
    DemoEvent(category: "SentryClips", minutesAgo: 3 * 60 + 4, groups: 1, footage: .parked,
              reason: "sentry_aware_handle", camera: 6, triggerOffset: 3.2,
              cameras: [.front, .back, .leftRepeater, .rightRepeater]),
    // A car that wrote no place.
    DemoEvent(category: "SentryClips", minutesAgo: 26 * 60 + 12, groups: 1, footage: .parked,
              reason: "sentry_aware_door", triggerOffset: 2,
              cameras: [.front, .back, .leftRepeater, .rightRepeater], hasPlace: false),
    // A reason this app does not know, so it is shown as the car wrote it.
    DemoEvent(category: "SentryClips", minutesAgo: 3 * 24 * 60 + 31, groups: 1, footage: .parked,
              reason: "sentry_aware_proximity", camera: 7, triggerOffset: 8,
              cameras: [.front, .back, .leftPillar, .rightPillar]),
    // The trigger camera (5, left repeater) has no footage in this event.
    DemoEvent(category: "SentryClips", minutesAgo: 5 * 24 * 60 + 47, groups: 1, footage: .parked,
              reason: "sentry_aware_object_detection", camera: 5, triggerOffset: 5,
              cameras: [.front, .back, .leftPillar, .rightPillar, .rightRepeater]),
    DemoEvent(category: "SavedClips", minutesAgo: 26 * 60 + 5, groups: 1, footage: .drive,
              reason: "user_interaction_dashcam_saved", triggerOffset: 4),
    DemoEvent(category: "SavedClips", minutesAgo: 2 * 24 * 60 + 40, groups: 1, footage: .drive,
              reason: "user_interaction_honk", triggerOffset: 1.5),
    DemoEvent(category: "RecentClips", minutesAgo: 21, groups: 2, footage: .drive),
    DemoEvent(category: "RecentClips", minutesAgo: 9, groups: 1, footage: .drive),
]

/// What `/api/live` would say for this car: the last sync ended a few minutes ago
/// and the archive is a fifth full. Fields a car does not report are left out.
let demoSync: [String: Any] = [
    "syncRunning": false, "lastSyncAgo": 384, "ffmpegAvailable": true,
    "archiveUsedBytes": 412_000_000_000, "archiveLimitBytes": 2_000_000_000_000,
]

func demoEventsJSON(language: Language) throws -> Data {
    let events: [[String: Any]] = demoEvents.map { event in
        var row: [String: Any] = [
            "category": event.category, "minutesAgo": event.minutesAgo, "groups": event.groups,
            "footage": event.footage.rawValue,
        ]
        if event.hasPlace {
            row["city"] = language.city
            row["street"] = language.street(for: event.footage)
        }
        row["reason"] = event.reason
        row["camera"] = event.camera
        row["triggerOffset"] = event.triggerOffset
        row["cameras"] = event.cameras?.map(\.rawValue)
        return row
    }
    return try JSONSerialization.data(withJSONObject: ["clipSeconds": seconds, "events": events, "sync": demoSync],
                                       options: [.prettyPrinted, .sortedKeys])
}
// MARK: - Telemetry file

/// The driving clips' telemetry exactly as `/api/telemetry` writes it.
func telemetryJSON() -> String {
    func one(_ value: Double) -> String { String(format: "%.1f", value) }
    func two(_ value: Double) -> String { String(format: "%.2f", value) }
    let speeds = telemetrySamples.map(\.speedKmh)
    let header = [
        "{",
        "  \"ok\": true,",
        "  \"fps\": 30,",
        "  \"count\": \(telemetrySamples.count),",
        "  \"duration\": 12.0,",
        "  \"max_speed\": \(one(speeds.max() ?? 0)),",
        "  \"avg_speed\": \(one(speeds.reduce(0, +) / Double(max(speeds.count, 1)))),",
        "  \"brake_ratio\": \(one(Double(telemetrySamples.filter { $0.brake == 1 }.count) / Double(telemetrySamples.count) * 100)),",
        "  \"frames\": [",
    ]
    let rows = telemetrySamples.enumerated().map { index, sample in
        let comma = index == telemetrySamples.count - 1 ? "" : ","
        return "    [\(one(sample.time)), \"D\", \(one(sample.speedKmh)), \(sample.throttle), \(one(sample.steering)), \(sample.brake), \(sample.turnSignal), 0, 0, 0, \(one(sample.heading)), \(two(sample.ax)), \(two(sample.ay)), \(two(sample.az))]\(comma)"
    }
    return (header + rows + ["  ]", "}", ""]).joined(separator: "\n")
}

// MARK: - Encoding

func makeContext() -> CGContext {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    return context
}

func frameData(_ context: CGContext) -> Data {
    guard let data = context.data else { return Data() }
    return Data(bytes: data, count: context.bytesPerRow * height)
}

/// Clears to opaque black, so that the alpha of the bitmap stays 1 everywhere.
func beginFrame(_ context: CGContext) {
    context.setAlpha(1)
    context.setBlendMode(.normal)
    context.setFillColor(rgb(0, 0, 0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
}

final class H264File {
    private let process = Process()
    private let input = Pipe()
    private let errors = Pipe()

    init(url: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                             "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)", "-r", "\(framesPerSecond)", "-i", "pipe:0",
                             "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "27", "-pix_fmt", "yuv420p",
                             "-profile:v", "main", "-movflags", "+faststart", url.path]
        process.standardInput = input
        process.standardError = errors
        try process.run()
    }

    func append(_ frame: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func finish() throws {
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "MakeDemoMedia", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
    }
}

func makeImage(_ frame: Data) throws -> CGImage {
    guard let provider = CGDataProvider(data: frame as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
        throw NSError(domain: "MakeDemoMedia", code: 2)
    }
    return image
}

/// Scales a frame to `newWidth` wide, keeping its 4:3 shape.
func scaled(_ image: CGImage, toWidth newWidth: Int) -> CGImage {
    let newHeight = Int((Double(newWidth) * Double(image.height) / Double(image.width)).rounded())
    let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: newWidth * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "MakeDemoMedia", code: 3) }
}

func failure(_ message: String) -> NSError {
    NSError(domain: "MakeDemoMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN) // a dead ffmpeg is reported by write(), not by a silent exit

let arguments = CommandLine.arguments

/// One frame as a PNG, to look at while working on the scenes.
if arguments.count == 6, arguments[1] == "--still" {
    do {
        guard let set = ClipSet(rawValue: arguments[3]), let camera = Cam(rawValue: arguments[4]) else {
            throw failure("unknown set or camera")
        }
        let context = makeContext()
        beginFrame(context)
        render(set: set, camera: camera, time: Double(arguments[5]) ?? 0, context: context)
        try writePNG(makeImage(frameData(context)), to: URL(fileURLWithPath: arguments[2]))
    } catch {
        FileHandle.standardError.write(Data("make-demo-media: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

// `--only <language>`: just that language's files. Otherwise everything, for every language.
let only = arguments.count == 4 && arguments[2] == "--only"
guard arguments.count == 2 || only else {
    let usage = "usage: make-demo-media.swift <output-directory>\n"
        + "       make-demo-media.swift <output-directory> --only <zh-Hans|en>\n"
        + "       make-demo-media.swift --still <out.png> <parked|drive> <camera> <seconds>\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
let everything = !only
let languages: [Language]
if only {
    guard let one = Language(rawValue: arguments[3]) else {
        FileHandle.standardError.write(Data("make-demo-media.swift: unknown language \(arguments[3]); zh-Hans or en\n".utf8))
        exit(2)
    }
    languages = [one]
} else {
    languages = Language.allCases
}
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func languageDirectory(_ language: Language) -> URL {
    let url = outputDirectory.appendingPathComponent(language.folder, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Deletes the demo-* files in `directory` that are not in `kept` (a directory of that name is left alone).
func removeStale(in directory: URL, keeping kept: Set<String>) throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix("demo-") && !kept.contains(name) {
        let stale = directory.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: stale.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try FileManager.default.removeItem(at: stale)
            print("removed stale \(name)")
        }
    }
}

do {
    // Remove what earlier runs left behind, but only when this run produces everything (for instance
    // demo-export-*.mp4 at the top level, from before the files that carry words were split by language).
    let shared = Set(ClipSet.allCases.flatMap { set in set.cameras.flatMap { [set.clipName($0), set.thumbName($0)] } }
                     + ["demo-telemetry.json"])
    let perLanguage = Set(ClipSet.allCases.flatMap { set in set.cameras.map { set.exportName($0) } } + ["demo-events.json"])
    if everything {
        try removeStale(in: outputDirectory, keeping: shared)
        for language in Language.allCases { try removeStale(in: languageDirectory(language), keeping: perLanguage) }
    }

    let context = makeContext()
    let frameBytes = context.bytesPerRow * height
    for set in ClipSet.allCases {
        for camera in set.cameras {
            let clip = everything ? try H264File(url: outputDirectory.appendingPathComponent(set.clipName(camera))) : nil
            let exported = try languages.map { try H264File(url: languageDirectory($0).appendingPathComponent(set.exportName(camera))) }
            var thumbnail = Data()
            for index in 0..<frameCount {
                let time = Double(index) / Double(framesPerSecond)
                beginFrame(context)
                render(set: set, camera: camera, time: time, context: context)
                let data = frameData(context)
                try clip?.append(data)
                if index == Int(thumbnailTime * Double(framesPerSecond)) { thumbnail = data }
                // Every language's strip goes onto the clean frame, never onto another language's.
                for (file, language) in zip(exported, languages) {
                    if let bitmap = context.data { data.copyBytes(to: bitmap.assumingMemoryBound(to: UInt8.self), count: frameBytes) }
                    drawWatermark(context, set: set, time: time, language: language)
                    try file.append(frameData(context))
                }
            }
            try clip?.finish()
            for file in exported { try file.finish() }
            if everything {
                guard !thumbnail.isEmpty else { throw failure("no frame at \(thumbnailTime) s for \(camera.rawValue)") }
                try writePNG(scaled(try makeImage(thumbnail), toWidth: thumbnailWidth), to: outputDirectory.appendingPathComponent(set.thumbName(camera)))
            }
            print("wrote \(everything ? set.clipName(camera) + " and " + set.thumbName(camera) + ", " : "")\(set.exportName(camera)) for \(languages.map(\.rawValue).joined(separator: ", "))")
        }
    }

    if everything {
        try telemetryJSON().write(to: outputDirectory.appendingPathComponent("demo-telemetry.json"), atomically: true, encoding: .utf8)
        print("wrote demo-telemetry.json (\(telemetrySamples.count) samples)")
    }
    for language in languages {
        try demoEventsJSON(language: language).write(to: languageDirectory(language).appendingPathComponent("demo-events.json"), options: .atomic)
    }
    print("wrote demo-events.json (\(demoEvents.count) events) for \(languages.map(\.rawValue).joined(separator: ", "))")
} catch {
    FileHandle.standardError.write(Data("make-demo-media: \(error)\n".utf8))
    exit(1)
}
