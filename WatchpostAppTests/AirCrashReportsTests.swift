import Foundation
import MachO
import Testing
@testable import WatchpostApp

// Tests of the crash-report parser in AirCrashReports.swift: MetricKit's call
// stack tree as it is read (`scan`), the report built from it (`report`,
// `bodies`), and the limits around both (`threads`, `images`, `encoded`,
// `operatingSystem`). MetricKit delivers nothing in a unit test, so the tests
// stand in for its object layer: the JSON below is what
// `MXCallStackTree.jsonRepresentation()` writes, and `AirCrashReports.Crash` is
// filled the way `didReceive` fills it. Nothing here starts, queues or posts
// anything.

// MARK: - Fixtures

/// Image UUIDs of the fixture trees, as MetricKit writes them (upper case, hyphenated).
private enum Images {
    static let app = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
    static let uiKit = "A5E65A19-17A4-3A4E-9A4E-3C3F5E5C5E5C"
    static let foundation = "19B3EF85-DFC1-3A73-8B70-103EE9D2DAF6"
    static let objc = "2E7D3B7F-0AE5-3C8A-9D5E-6F1B2C3D4E5F"
    static let libc = "5A8F6B3E-0F5C-4A2D-9B3E-1C7D2E9F6A4B"
    static let libcxx = "6D0FA7E3-5C2B-4E9F-8A1D-3B7C9E2F5A48"
    static let kernel = "BBA30A96-EEC4-3E19-903F-2A4B2FA2A5A0"
    static let xpc = "7D0D3C0F-93A0-3BD5-9C53-4F9F0D5E7C11"
    static let dispatch = "E23C7A8E-1A40-34F1-8AB1-9C8A5D3F0E27"
    static let pthread = "9F1C6E2A-3D47-4B8E-9A21-C4D5E6F70819"
    static let swiftCore = "3CB0B5D1-2B7E-3F6A-8C1D-0E2A4B6C8D0F"
    static let all = [app, uiKit, foundation, objc, libc, libcxx, kernel, xpc, dispatch, pthread, swiftCore]
}

private enum CrashFixtures {
    /// An install id, as `installID()` stores it: a lower-case UUID.
    static let installID = "6b1f4d0e-2c3a-4b5c-8d9e-0f1a2b3c4d5e"
    /// When the delivery's run ended: `timeStampEnd` of `Payloads.delivery`.
    static let endedAt = Date(timeIntervalSince1970: 1_793_491_200)
}

private enum Payloads {
    /// One frame, on one line: small enough to be cut at every byte.
    static let oneFrameTree = #"{"callStacks":[{"threadAttributed":true,"queueName":"com.apple.main-thread","callStackRootFrames":[{"binaryName":"WatchpostApp","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":21504,"sampleCount":1,"subFrames":[]}]}]}"#

    /// The tree of an uncaught Objective-C exception: the main thread, eight frames deep, and two others.
    static let exceptionTree = #"""
    {
      "callStacks" : [
        {
          "callStackRootFrames" : [
            {
              "address" : 4371981312,
              "binaryName" : "WatchpostApp",
              "binaryUUID" : "\#(Images.app)",
              "offsetIntoBinaryTextSegment" : 21504,
              "sampleCount" : 1,
              "subFrames" : [
                {
                  "address" : 4371983872,
                  "binaryName" : "WatchpostApp",
                  "binaryUUID" : "\#(Images.app)",
                  "offsetIntoBinaryTextSegment" : 18392,
                  "sampleCount" : 1,
                  "subFrames" : [
                    {
                      "address" : 4371986632,
                      "binaryName" : "WatchpostApp",
                      "binaryUUID" : "\#(Images.app)",
                      "offsetIntoBinaryTextSegment" : 45872,
                      "sampleCount" : 1,
                      "subFrames" : [
                        {
                          "address" : 18316724184,
                          "binaryName" : "UIKitCore",
                          "binaryUUID" : "\#(Images.uiKit)",
                          "offsetIntoBinaryTextSegment" : 29280,
                          "sampleCount" : 1,
                          "symbolName" : "-[UIApplication _runWithMainScene:transitionContext:completion:]",
                          "subFrames" : [
                            {
                              "address" : 18340603992,
                              "binaryName" : "Foundation",
                              "binaryUUID" : "\#(Images.foundation)",
                              "offsetIntoBinaryTextSegment" : 48392,
                              "sampleCount" : 1,
                              "symbolName" : "-[NSObject(NSObject) doesNotRecognizeSelector:] \"quoted\" \\ backslash",
                              "subFrames" : [
                                {
                                  "address" : 18097865104,
                                  "binaryName" : "libobjc.A.dylib",
                                  "binaryUUID" : "\#(Images.objc)",
                                  "offsetIntoBinaryTextSegment" : 8176,
                                  "sampleCount" : 1,
                                  "symbolName" : "caf\u00e9 \ud83d\ude00 a/b:,,c objc_exception_throw",
                                  "subFrames" : [
                                    {
                                      "address" : 18095396916,
                                      "binaryName" : "libc++abi.dylib",
                                      "binaryUUID" : "\#(Images.libcxx)",
                                      "offsetIntoBinaryTextSegment" : 17020,
                                      "sampleCount" : 1,
                                      "subFrames" : [
                                        {
                                          "address" : 18066579836,
                                          "binaryName" : "libsystem_c.dylib",
                                          "binaryUUID" : "\#(Images.libc)",
                                          "offsetIntoBinaryTextSegment" : 397388,
                                          "sampleCount" : 1,
                                          "symbolName" : "abort",
                                          "subFrames" : [

                                          ]
                                        }
                                      ]
                                    }
                                  ]
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ],
          "queueName" : "com.apple.main-thread",
          "threadAttributed" : true
        },
        {
          "callStackRootFrames" : [
            {
              "address" : 6687182864,
              "binaryName" : "libsystem_kernel.dylib",
              "binaryUUID" : "\#(Images.kernel)",
              "offsetIntoBinaryTextSegment" : 7960,
              "sampleCount" : 1,
              "symbolName" : "mach_msg2_trap",
              "subFrames" : [
                {
                  "address" : 6683954660,
                  "binaryName" : "libxpc.dylib",
                  "binaryUUID" : "\#(Images.xpc)",
                  "offsetIntoBinaryTextSegment" : 36760,
                  "sampleCount" : 1,
                  "subFrames" : [
                    {
                      "address" : 18341274256,
                      "binaryName" : "Foundation",
                      "binaryUUID" : "\#(Images.foundation)",
                      "offsetIntoBinaryTextSegment" : 110648,
                      "sampleCount" : 1,
                      "subFrames" : [
                        {
                          "address" : 18341274072,
                          "binaryName" : "Foundation",
                          "binaryUUID" : "\#(Images.foundation)",
                          "offsetIntoBinaryTextSegment" : 110432,
                          "sampleCount" : 1,
                          "subFrames" : [

                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ],
          "queueName" : "com.apple.root.default-qos",
          "threadAttributed" : false
        },
        {
          "callStackRootFrames" : [
            {
              "address" : 6687195848,
              "binaryName" : "libsystem_pthread.dylib",
              "binaryUUID" : "\#(Images.pthread)",
              "offsetIntoBinaryTextSegment" : 12440,
              "sampleCount" : 1,
              "subFrames" : [
                {
                  "address" : 6682562228,
                  "binaryName" : "libdispatch.dylib",
                  "binaryUUID" : "\#(Images.dispatch)",
                  "offsetIntoBinaryTextSegment" : 69308,
                  "sampleCount" : 1,
                  "subFrames" : [
                    {
                      "address" : 18341274256,
                      "binaryName" : "Foundation",
                      "binaryUUID" : "\#(Images.foundation)",
                      "offsetIntoBinaryTextSegment" : 110648,
                      "sampleCount" : 1,
                      "subFrames" : [

                      ]
                    }
                  ]
                }
              ]
            }
          ],
          "threadAttributed" : false
        }
      ]
    }
    """#

    /// The tree of a bad access on a background queue: the attributed thread is listed second, and the first
    /// thread has three roots.
    static let badAccessTree = #"""
    {
      "callStacks" : [
        {
          "callStackRootFrames" : [
            {
              "address" : 6687195848,
              "binaryName" : "libsystem_pthread.dylib",
              "binaryUUID" : "\#(Images.pthread)",
              "offsetIntoBinaryTextSegment" : 12440,
              "sampleCount" : 1,
              "subFrames" : [
                {
                  "address" : 6682562228,
                  "binaryName" : "libdispatch.dylib",
                  "binaryUUID" : "\#(Images.dispatch)",
                  "offsetIntoBinaryTextSegment" : 69308,
                  "sampleCount" : 1,
                  "subFrames" : [
                    {
                      "address" : 4371977384,
                      "binaryName" : "WatchpostApp",
                      "binaryUUID" : "\#(Images.app)",
                      "offsetIntoBinaryTextSegment" : 30712,
                      "sampleCount" : 1,
                      "subFrames" : [
                        {
                          "address" : 4371989216,
                          "binaryName" : "WatchpostApp",
                          "binaryUUID" : "\#(Images.app)",
                          "offsetIntoBinaryTextSegment" : 52088,
                          "sampleCount" : 1,
                          "subFrames" : [

                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "address" : 6687184264,
              "binaryName" : "libsystem_kernel.dylib",
              "binaryUUID" : "\#(Images.kernel)",
              "offsetIntoBinaryTextSegment" : 13960,
              "sampleCount" : 1,
              "symbolName" : "__semwait_signal",
              "subFrames" : [
                {
                  "address" : 6682567972,
                  "binaryName" : "libdispatch.dylib",
                  "binaryUUID" : "\#(Images.dispatch)",
                  "offsetIntoBinaryTextSegment" : 3972,
                  "sampleCount" : 1,
                  "subFrames" : [

                  ]
                }
              ]
            },
            {
              "address" : 6618013272,
              "binaryName" : "libc++.1.dylib",
              "binaryUUID" : "\#(Images.libcxx)",
              "offsetIntoBinaryTextSegment" : 11944,
              "sampleCount" : 1,
              "subFrames" : [

              ]
            }
          ],
          "queueName" : "com.apple.root.user-initiated-qos.cooperative",
          "threadAttributed" : false
        },
        {
          "callStackRootFrames" : [
            {
              "address" : 4371989672,
              "binaryName" : "WatchpostApp",
              "binaryUUID" : "\#(Images.app)",
              "offsetIntoBinaryTextSegment" : 65200,
              "sampleCount" : 1,
              "subFrames" : [
                {
                  "address" : 6621124932,
                  "binaryName" : "libswiftCore.dylib",
                  "binaryUUID" : "\#(Images.swiftCore)",
                  "offsetIntoBinaryTextSegment" : 498764,
                  "sampleCount" : 1,
                  "subFrames" : [
                    {
                      "address" : 6620783296,
                      "binaryName" : "libswiftCore.dylib",
                      "binaryUUID" : "\#(Images.swiftCore)",
                      "offsetIntoBinaryTextSegment" : 142128,
                      "sampleCount" : 1,
                      "subFrames" : [
                        {
                          "address" : 18066579836,
                          "binaryName" : "libsystem_c.dylib",
                          "binaryUUID" : "\#(Images.libc)",
                          "offsetIntoBinaryTextSegment" : 397388,
                          "sampleCount" : 1,
                          "symbolName" : "abort",
                          "subFrames" : [
                            {
                              "address" : 6687182864,
                              "binaryName" : "libsystem_kernel.dylib",
                              "binaryUUID" : "\#(Images.kernel)",
                              "offsetIntoBinaryTextSegment" : 7960,
                              "sampleCount" : 1,
                              "symbolName" : "mach_msg2_trap",
                              "subFrames" : [

                              ]
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ],
          "queueName" : "com.apple.root.utility-qos",
          "threadAttributed" : true
        },
        {
          "callStackRootFrames" : [
            {
              "address" : 6687182864,
              "binaryName" : "libsystem_kernel.dylib",
              "binaryUUID" : "\#(Images.kernel)",
              "offsetIntoBinaryTextSegment" : 7960,
              "sampleCount" : 1,
              "subFrames" : [
                {
                  "address" : 18341274072,
                  "binaryName" : "Foundation",
                  "binaryUUID" : "\#(Images.foundation)",
                  "offsetIntoBinaryTextSegment" : 110432,
                  "sampleCount" : 1,
                  "subFrames" : [

                  ]
                }
              ]
            }
          ],
          "threadAttributed" : false
        }
      ]
    }
    """#

    /// The tree of a hang, which has the same shape as a crash's.
    static let hangTree = #"""
    {
      "callStacks" : [
        {
          "callStackRootFrames" : [
            {
              "address" : 6687182864,
              "binaryName" : "libsystem_kernel.dylib",
              "binaryUUID" : "\#(Images.kernel)",
              "offsetIntoBinaryTextSegment" : 3916,
              "sampleCount" : 1,
              "symbolName" : "semaphore_wait_trap",
              "subFrames" : [
                {
                  "address" : 4371991544,
                  "binaryName" : "WatchpostApp",
                  "binaryUUID" : "\#(Images.app)",
                  "offsetIntoBinaryTextSegment" : 88432,
                  "sampleCount" : 1,
                  "subFrames" : [

                  ]
                }
              ]
            }
          ],
          "queueName" : "com.apple.main-thread",
          "threadAttributed" : true
        }
      ]
    }
    """#

    /// A delivery as MetricKit writes it: two crashes, a hang and a CPU exception, each with its own tree.
    static let delivery = #"""
    {
      "appBuildVersion" : "3",
      "appVersion" : "1.0",
      "crashDiagnostics" : [
        {
          "callStackTree" : \#(exceptionTree),
          "exceptionCode" : 0,
          "exceptionReason" : {
            "className" : "NSException",
            "composedMessage" : "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
            "exceptionName" : "NSInvalidArgumentException",
            "exceptionType" : "NSInvalidArgumentException"
          },
          "exceptionType" : 6,
          "signal" : "SIGABRT",
          "terminationReason" : "Namespace SIGNAL, Code 6 Abort trap: 6"
        },
        {
          "callStackTree" : \#(badAccessTree),
          "exceptionCode" : 1,
          "exceptionType" : 1,
          "signal" : "SEGV",
          "terminationReason" : "Namespace SIGNAL, Code 11 Segmentation fault: 11",
          "virtualMemoryRegionInfo" : "0x0000000000000020 is not in any region. This process has a thread backtrace that may include the cause of the crash."
        }
      ],
      "hangDiagnostics" : [
        {
          "callStackTree" : \#(hangTree),
          "hangDuration" : { "unit" : "s", "value" : 4.5 }
        }
      ],
      "cpuExceptionDiagnostics" : [
        {
          "callStackTree" : \#(hangTree),
          "totalCPUTime" : { "unit" : "ms", "value" : 4800 },
          "totalSampledTime" : { "unit" : "ms", "value" : 60000 }
        }
      ],
      "diskWriteExceptionDiagnostics" : [

      ],
      "timeStampBegin" : "2026-10-31 00:00:00 +0000",
      "timeStampEnd" : "2026-11-01 00:00:00 +0000"
    }
    """#
}

/// MetricKit's JSON as Apple's own sample decodes it (`Diag.swift`), with only the keys the tests read.
private struct MetricKitPayload: Codable {
    struct Frame: Codable {
        let binaryName: String?
        let binaryUUID: String?
        let address: UInt64?
        let offsetIntoBinaryTextSegment: UInt64?
        let sampleCount: Int?
        let symbolName: String?
        let symbolAddress: UInt64?
        let subFrames: [Frame]?
    }

    struct CallStack: Codable {
        let callStackRootFrames: [Frame]
        let threadAttributed: Bool?
        let queueName: String?
    }

    struct Tree: Codable {
        let callStacks: [CallStack]
    }

    struct ExceptionReason: Codable {
        let composedMessage: String
        let exceptionName: String
    }

    struct Crash: Codable {
        let callStackTree: Tree
        let exceptionType: Int?
        let exceptionCode: Int?
        let exceptionReason: ExceptionReason?
        let terminationReason: String?
        let virtualMemoryRegionInfo: String?
    }

    /// Any other diagnostic: all carry a tree the crash parser must never see.
    struct OtherDiagnostic: Codable {
        let callStackTree: Tree
    }

    let appBuildVersion: String
    let appVersion: String
    let timeStampBegin: String
    let timeStampEnd: String
    let crashDiagnostics: [Crash]
    let hangDiagnostics: [OtherDiagnostic]
    let cpuExceptionDiagnostics: [OtherDiagnostic]
    let diskWriteExceptionDiagnostics: [OtherDiagnostic]

    /// `timeStampEnd` as MetricKit writes it: `2026-11-01 00:00:00 +0000`.
    var endedAt: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZ"
        return formatter.date(from: timeStampEnd)
    }
}

/// A report body as `POST /v1/ingest/crashes` reads it, with strict types.
private struct WireReport: Decodable, Equatable {
    struct App: Decodable, Equatable {
        let version: String
        let build: String
        let bundleID: String
    }

    struct Device: Decodable, Equatable {
        let model: String
        let os: String
        let osVersion: String
        let osBuild: String
        let arch: String
        let locale: String
    }

    struct Exception: Decodable, Equatable {
        let type: Int?
        let code: Int?
        let signal: Int?
        let name: String?
        let message: String?
        let terminationReason: String?
    }

    struct Frame: Decodable, Equatable {
        let image: String
        let uuid: UUID
        let offset: UInt64
        let inApp: Bool
        let symbol: String?
        let symbolOffset: UInt64?
    }

    struct Thread: Decodable, Equatable {
        let crashed: Bool
        let frames: [Frame]
    }

    struct Image: Decodable, Equatable, Hashable {
        let name: String
        let uuid: UUID
        let inApp: Bool
    }

    var id: String
    var occurredAt: String
    var installID: String
    var app: App
    var device: Device
    var exception: Exception
    var threads: [Thread]
    var images: [Image]
}

/// What the two fixture trees read as, written out by hand from the JSON above.
private enum Expected {
    static let exception = [
        thread(true, [
            frame("WatchpostApp", Images.app, 21_504),
            frame("WatchpostApp", Images.app, 18_392),
            frame("WatchpostApp", Images.app, 45_872),
            frame("UIKitCore", Images.uiKit, 29_280),
            frame("Foundation", Images.foundation, 48_392),
            frame("libobjc.A.dylib", Images.objc, 8_176),
            frame("libc++abi.dylib", Images.libcxx, 17_020),
            frame("libsystem_c.dylib", Images.libc, 397_388),
        ]),
        thread(false, [
            frame("libsystem_kernel.dylib", Images.kernel, 7_960),
            frame("libxpc.dylib", Images.xpc, 36_760),
            frame("Foundation", Images.foundation, 110_648),
            frame("Foundation", Images.foundation, 110_432),
        ]),
        thread(false, [
            frame("libsystem_pthread.dylib", Images.pthread, 12_440),
            frame("libdispatch.dylib", Images.dispatch, 69_308),
            frame("Foundation", Images.foundation, 110_648),
        ]),
    ]

    static let badAccess = [
        thread(false, [
            frame("libsystem_pthread.dylib", Images.pthread, 12_440),
            frame("libdispatch.dylib", Images.dispatch, 69_308),
            frame("WatchpostApp", Images.app, 30_712),
            frame("WatchpostApp", Images.app, 52_088),
            frame("libsystem_kernel.dylib", Images.kernel, 13_960),
            frame("libdispatch.dylib", Images.dispatch, 3_972),
            frame("libc++.1.dylib", Images.libcxx, 11_944),
        ]),
        thread(true, [
            frame("WatchpostApp", Images.app, 65_200),
            frame("libswiftCore.dylib", Images.swiftCore, 498_764),
            frame("libswiftCore.dylib", Images.swiftCore, 142_128),
            frame("libsystem_c.dylib", Images.libc, 397_388),
            frame("libsystem_kernel.dylib", Images.kernel, 7_960),
        ]),
        thread(false, [
            frame("libsystem_kernel.dylib", Images.kernel, 7_960),
            frame("Foundation", Images.foundation, 110_432),
        ]),
    ]

    /// `badAccess` as a report orders it: the attributed thread first.
    static let badAccessReport = [badAccess[1], badAccess[0], badAccess[2]]
}

/// `osVersion` strings and what `operatingSystem(_:model:)` reads from them.
private enum OSVersions {
    /// A line of `osVersion`, and the name, version and build read from it.
    struct Line: Sendable {
        var text: String
        var name: String
        var version: String
        var build: String
        var model = "iPhone15,2"
    }

    /// MetricKit's own strings.
    static let metricKit: [Line] = [
        Line(text: "iPhone OS 26.1 (23B85)", name: "iOS", version: "26.1", build: "23B85"),
        Line(text: "iPhone OS 17.1 (21B80)", name: "iOS", version: "17.1", build: "21B80"),
        Line(text: "iPhone OS 17.1 (21B80)", name: "iPadOS", version: "17.1", build: "21B80", model: "iPad16,2"),
        Line(text: "iPadOS 18.0 (22A3351)", name: "iPadOS", version: "18.0", build: "22A3351", model: "iPad16,2"),
        Line(text: "iPadOS 26.1 (23B85)", name: "iPadOS", version: "26.1", build: "23B85"),
        Line(text: "macOS 14.1 (23B74)", name: "macOS", version: "14.1", build: "23B74", model: "Mac14,2"),
        Line(text: "Mac OS X 13.6 (22G120)", name: "macOS", version: "13.6", build: "22G120", model: "Mac14,2"),
        Line(text: "xrOS 1.0 (21N305)", name: "visionOS", version: "1.0", build: "21N305", model: "RealityDevice14,1"),
        Line(text: "tvOS 17.1 (21B80)", name: "tvOS", version: "17.1", build: "21B80"),
        Line(text: "watchOS 10.1 (21S67)", name: "watchOS", version: "10.1", build: "21S67"),
        // Extra spaces around the parts change nothing.
        Line(text: "  iPhone OS 26.1   ( 23B85 ) ", name: "iOS", version: "26.1", build: "23B85"),
    ]

    /// The same systems, with no build given.
    static let withoutABuild: [Line] = [
        Line(text: "iOS 27.0", name: "iOS", version: "27.0", build: ""),
        Line(text: "iPhone OS 26.1", name: "iOS", version: "26.1", build: ""),
        Line(text: "iPadOS 18.0", name: "iPadOS", version: "18.0", build: ""),
        Line(text: "macOS 15.0", name: "macOS", version: "15.0", build: ""),
        Line(text: "visionOS 2.0", name: "visionOS", version: "2.0", build: ""),
        Line(text: "iPhone OS", name: "iOS", version: "", build: ""),
        Line(text: "macOS", name: "macOS", version: "", build: ""),
    ]

    /// Other spellings: no name at all is this platform, and other systems keep their own name.
    static let elsewhere: [Line] = [
        Line(text: "Version 17.0 (Build 21A328)", name: thisPlatform, version: "17.0", build: "21A328"),
        Line(text: "17.4 (21E219)", name: thisPlatform, version: "17.4", build: "21E219"),
        Line(text: "Windows 11 22H2 (Build 22621.2506)", name: "Windows", version: "11", build: "22621.2506"),
        Line(text: "Ubuntu 24.04 (Noble)", name: "Ubuntu", version: "24.04", build: "Noble"),
        Line(text: "unknown", name: "unknown", version: "", build: ""),
        Line(text: "", name: thisPlatform, version: "", build: ""),
    ]

    static func metricKit(_ text: String) -> Line? { metricKit.first { $0.text == text } }
    static func withoutABuild(_ text: String) -> Line? { withoutABuild.first { $0.text == text } }
    static func elsewhere(_ text: String) -> Line? { elsewhere.first { $0.text == text } }
}

/// What the parser names a system it cannot place: the one it runs on.
private var thisPlatform: String {
    #if os(macOS)
    return "macOS"
    #elseif os(visionOS)
    return "visionOS"
    #else
    return "iOS"
    #endif
}

private struct NotJSON: Error {
    var key: String
}

private func parsed(_ text: String) -> UUID {
    UUID(uuidString: text)!
}

/// A frame as `scan` reads it.
private func frame(_ image: String, _ uuid: String, _ offset: UInt64) -> AirCrashReports.ScannedFrame {
    AirCrashReports.ScannedFrame(image: image, uuid: parsed(uuid), offset: offset)
}

/// A thread as `scan` reads it.
private func thread(_ crashed: Bool, _ frames: [AirCrashReports.ScannedFrame]) -> AirCrashReports.ScannedThread {
    AirCrashReports.ScannedThread(crashed: crashed, frames: frames)
}

/// A frame as a report carries it; nothing is resolved unless said so.
private func reportFrame(_ image: String, _ uuid: String, _ offset: UInt64, inApp: Bool = false,
                         symbol: String? = nil, symbolOffset: UInt64? = nil) -> AirCrashReports.Report.Frame {
    AirCrashReports.Report.Frame(image: image, uuid: parsed(uuid), offset: offset, inApp: inApp,
                                 symbol: symbol, symbolOffset: symbolOffset)
}

/// A crash as `didReceive` fills it from an `MXCrashDiagnostic`: the values are the fixture's.
private func crash(callStackTree: Data = Data(Payloads.exceptionTree.utf8), occurredAt: Date = CrashFixtures.endedAt,
                   appVersion: String = "1.0", appBuild: String = "3", deviceModel: String = "iPhone15,2",
                   osVersion: String = "iPhone OS 26.1 (23B85)", architecture: String = "arm64e",
                   exceptionType: Int? = 6, exceptionCode: Int? = 0, signal: Int? = 6,
                   exceptionName: String? = "NSInvalidArgumentException",
                   exceptionMessage: String? = "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                   terminationReason: String? = "Namespace SIGNAL, Code 6 Abort trap: 6") -> AirCrashReports.Crash {
    AirCrashReports.Crash(occurredAt: occurredAt, appVersion: appVersion, appBuild: appBuild, deviceModel: deviceModel,
                          osVersion: osVersion, architecture: architecture, exceptionType: exceptionType,
                          exceptionCode: exceptionCode, signal: signal, exceptionName: exceptionName,
                          exceptionMessage: exceptionMessage, terminationReason: terminationReason,
                          callStackTree: callStackTree)
}

/// A report with the given threads, their images, and fixed facts otherwise.
private func makeReport(_ threads: [AirCrashReports.Report.Thread]) -> AirCrashReports.Report {
    AirCrashReports.Report(
        id: "0c4e2f0a-9f6f-4f2e-9c7a-3a6c1a2b3c4d",
        occurredAt: "2026-11-01T00:00:00.000Z",
        installID: CrashFixtures.installID,
        app: .init(version: "1.0", build: "3", bundleID: "com.example.watchpost"),
        device: .init(model: "iPhone15,2", os: "iOS", osVersion: "26.1", osBuild: "23B85", arch: "arm64e", locale: "en_US"),
        exception: .init(type: 6, code: 0, signal: 6, name: nil, message: nil, terminationReason: nil),
        threads: threads,
        images: AirCrashReports.images(of: threads)
    )
}

/// Threads of `frames` frames each, in images with long names, so that a body grows past the limit fast.
private func heavyThreads(_ count: Int, frames: Int, nameLength: Int) -> [AirCrashReports.Report.Thread] {
    let padding = String(repeating: "x", count: nameLength)
    return (0 ..< count).map { index in
        AirCrashReports.Report.Thread(crashed: index == 0, frames: (0 ..< frames).map { number in
            reportFrame("Image\(index)\(padding)", Images.all[index % Images.all.count], UInt64(index * 1_000 + number))
        })
    }
}

/// `Payloads.delivery`, decoded from its JSON.
private func delivered() throws -> MetricKitPayload {
    try JSONDecoder().decode(MetricKitPayload.self, from: Data(Payloads.delivery.utf8))
}

/// A JSON object, or an error saying it is not one.
private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotJSON(key: "root") }
    return object
}

/// The object under `key` of a JSON object.
private func object(_ json: [String: Any], _ key: String) throws -> [String: Any] {
    guard let child = json[key] as? [String: Any] else { throw NotJSON(key: key) }
    return child
}

/// Every key of a JSON value, at any depth.
private func allKeys(_ json: Any) -> Set<String> {
    if let dictionary = json as? [String: Any] {
        return dictionary.reduce(into: Set<String>()) { keys, entry in
            keys.insert(entry.key)
            keys.formUnion(allKeys(entry.value))
        }
    }
    if let array = json as? [Any] {
        return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
    }
    return []
}

/// A time as `occurredAt` writes it: ISO 8601, to the millisecond, in UTC.
private func instant(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

/// The threads of a tree decoded by Foundation, each with its frames in the order they open.
private func flattened(_ tree: MetricKitPayload.Tree) -> [AirCrashReports.ScannedThread] {
    func walk(_ entries: [MetricKitPayload.Frame], into out: inout [AirCrashReports.ScannedFrame]) {
        for entry in entries {
            out.append(AirCrashReports.ScannedFrame(image: entry.binaryName ?? "",
                                                     uuid: UUID(uuidString: entry.binaryUUID ?? "") ?? UUID(),
                                                     offset: entry.offsetIntoBinaryTextSegment ?? 0))
            walk(entry.subFrames ?? [], into: &out)
        }
    }
    return tree.callStacks.map { stack in
        var frames: [AirCrashReports.ScannedFrame] = []
        walk(stack.callStackRootFrames, into: &frames)
        return AirCrashReports.ScannedThread(crashed: stack.threadAttributed == true, frames: frames)
    }
}

/// Each image once, in the order the frames first reach it; the app's own binary is marked so.
private func imageList(_ threads: [AirCrashReports.ScannedThread], app executable: String?) -> [WireReport.Image] {
    var images: [WireReport.Image] = []
    for scanned in threads.flatMap(\.frames) {
        let image = WireReport.Image(name: scanned.image.isEmpty ? "???" : scanned.image, uuid: scanned.uuid,
                                     inApp: scanned.image == executable)
        if !images.contains(image) { images.append(image) }
    }
    return images
}

/// A frame of a report as the wire spells it.
private func wire(_ frame: AirCrashReports.Report.Frame) -> WireReport.Frame {
    WireReport.Frame(image: frame.image, uuid: frame.uuid, offset: frame.offset, inApp: frame.inApp,
                     symbol: frame.symbol, symbolOffset: frame.symbolOffset)
}

private func wire(_ thread: AirCrashReports.Report.Thread) -> WireReport.Thread {
    .init(crashed: thread.crashed, frames: thread.frames.map { wire($0) })
}

private func wire(_ threads: [AirCrashReports.Report.Thread]) -> [WireReport.Thread] {
    threads.map { wire($0) }
}

private func wire(_ images: [AirCrashReports.Report.Image]) -> [WireReport.Image] {
    images.map { .init(name: $0.name, uuid: $0.uuid, inApp: $0.inApp) }
}

/// A report as the wire spells it.
private func wire(_ report: AirCrashReports.Report) -> WireReport {
    WireReport(
        id: report.id,
        occurredAt: report.occurredAt,
        installID: report.installID,
        app: .init(version: report.app.version, build: report.app.build, bundleID: report.app.bundleID),
        device: .init(model: report.device.model, os: report.device.os, osVersion: report.device.osVersion,
                      osBuild: report.device.osBuild, arch: report.device.arch, locale: report.device.locale),
        exception: .init(type: report.exception.type, code: report.exception.code, signal: report.exception.signal,
                         name: report.exception.name, message: report.exception.message,
                         terminationReason: report.exception.terminationReason),
        threads: wire(report.threads),
        images: wire(report.images)
    )
}

/// A chain of `depth` frames, each the caller of the one before it, under one attributed thread.
private func deepTree(depth: Int) -> Data {
    var parts = [#"{"callStacks":[{"threadAttributed":true,"callStackRootFrames":["#]
    for level in 0 ..< depth {
        parts.append(#"{"binaryName":"Frame\#(level % 7)","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":\#(level),"sampleCount":1,"subFrames":["#)
    }
    parts.append(String(repeating: "]}", count: depth))
    parts.append("]}]}")
    return Data(parts.joined().utf8)
}

/// A 64-bit mach header followed by its load commands, as little-endian bytes.
private func machHeader(_ commands: [[UInt8]], claiming count: Int? = nil) -> [UInt8] {
    var bytes: [UInt8] = []
    func put32(_ number: UInt32) { withUnsafeBytes(of: number) { bytes += $0 } }
    func put64(_ number: UInt64) { withUnsafeBytes(of: number) { bytes += $0 } }
    put32(MH_MAGIC_64)
    put32(0) // cputype
    put32(0) // cpusubtype
    put32(0) // filetype
    put32(UInt32(count ?? commands.count))
    put32(UInt32(commands.reduce(0) { $0 + $1.count }))
    put32(0) // flags
    put32(0) // reserved
    for command in commands { bytes += command }
    return bytes
}

/// An `LC_UUID` load command.
private func uuidCommand(_ uuid: UUID) -> [UInt8] {
    var command: [UInt8] = []
    withUnsafeBytes(of: UInt32(LC_UUID)) { command += $0 }
    withUnsafeBytes(of: UInt32(MemoryLayout<uuid_command>.size)) { command += $0 }
    withUnsafeBytes(of: uuid.uuid) { command += $0 }
    return command
}

/// An `LC_SEGMENT_64` load command for a `__TEXT` segment of `size` bytes.
private func textSegment(size: UInt64) -> [UInt8] {
    var command: [UInt8] = []
    withUnsafeBytes(of: UInt32(LC_SEGMENT_64)) { command += $0 }
    withUnsafeBytes(of: UInt32(MemoryLayout<segment_command_64>.size)) { command += $0 }
    command += Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10)
    withUnsafeBytes(of: UInt64(0)) { command += $0 } // vmaddr
    withUnsafeBytes(of: size) { command += $0 } // vmsize
    withUnsafeBytes(of: UInt64(0)) { command += $0 } // fileoff
    withUnsafeBytes(of: size) { command += $0 } // filesize
    command += [0, 0, 0, 0, 0, 0, 0, 0] // maxprot, initprot
    command += [0, 0, 0, 0, 0, 0, 0,  0] // nsects, flags
    return command
}

// MARK: - Reading the tree

/// `AirCrashReports.scan`: MetricKit's call stack tree as bytes.
@Suite
struct AirCrashTreeScanTests {
    /// A delivery's two crash trees, as MetricKit writes them: one thread per `callStacks` entry, each thread's
    /// frames in the order they open (the faulting frame first, then its callers, nested frames flattened), every
    /// image, UUID and offset kept exactly. Symbols, addresses, sample counts and queues are not kept: they are
    /// looked up again, here or on the server.
    @Test
    func readsBothCrashTreesOfADelivery() throws {
        let delivery = try delivered()

        let exception = try #require(AirCrashReports.scan(Data(Payloads.exceptionTree.utf8)))
        #expect(exception == Expected.exception)
        #expect(exception == flattened(delivery.crashDiagnostics[0].callStackTree))

        let badAccess = try #require(AirCrashReports.scan(Data(Payloads.badAccessTree.utf8)))
        #expect(badAccess == Expected.badAccess)
        #expect(badAccess == flattened(delivery.crashDiagnostics[1].callStackTree))

        #expect(exception.map(\.crashed) == [true, false, false])
        #expect(exception.map { $0.frames.count } == [8, 4, 3])
        #expect(badAccess.map(\.crashed) == [false, true, false])
        #expect(badAccess.map { $0.frames.count } == [7, 5, 2])

        // The exception's stack, innermost first: three frames of the app, then UIKit, Foundation, libobjc,
        // libc++abi and libc. Symbols with quotes, backslashes, unicode, colons, commas and slashes change nothing.
        #expect(exception[0].frames.map(\.image) == [
            "WatchpostApp", "WatchpostApp", "WatchpostApp", "UIKitCore", "Foundation", "libobjc.A.dylib",
            "libc++abi.dylib", "libsystem_c.dylib",
        ])
        #expect(exception[0].frames.map(\.offset) == [21_504, 18_392, 45_872, 29_280, 48_392, 8_176, 17_020, 397_388])
        #expect(exception[0].frames.map(\.uuid) == [Images.app, Images.app, Images.app, Images.uiKit, Images.foundation,
                                                    Images.objc, Images.libcxx, Images.libc].map(parsed))
        // The same image under two names is two images; each keeps its own UUID.
        #expect(badAccess[0].frames.map(\.image) == [
            "libsystem_pthread.dylib", "libdispatch.dylib", "WatchpostApp", "WatchpostApp", "libsystem_kernel.dylib",
            "libdispatch.dylib", "libc++.1.dylib",
        ])
    }

    /// A hang's tree has the same shape as a crash's and reads the same way. It is `didReceive`, which reads only
    /// `crashDiagnostics`, that keeps hangs (and CPU and disk-write exceptions) out of the crash reports.
    @Test
    func readsAHangsTreeTheSameWay() throws {
        let tree = try #require(AirCrashReports.scan(Data(Payloads.hangTree.utf8)))
        #expect(tree == [thread(true, [
            frame("libsystem_kernel.dylib", Images.kernel, 3_916),
            frame("WatchpostApp", Images.app, 88_432),
        ])])
    }

    /// The same trees, spelled differently (keys sorted or not, on one line or many, slashes escaped or not): the
    /// same threads and frames.
    @Test
    func readsTheTreesHoweverTheyAreSpelled() throws {
        let delivery = try delivered()
        let spellings: [JSONEncoder.OutputFormatting] = [
            [], .sortedKeys, .prettyPrinted, [.sortedKeys, .prettyPrinted], .withoutEscapingSlashes,
        ]
        for (diagnostic, literal) in zip(delivery.crashDiagnostics, [Payloads.exceptionTree, Payloads.badAccessTree]) {
            let expected = try #require(AirCrashReports.scan(Data(literal.utf8)))
            for spelling in spellings {
                let encoder = JSONEncoder()
                encoder.outputFormatting = spelling
                let spelled = try encoder.encode(diagnostic.callStackTree)
                #expect(spelled != Data(literal.utf8))
                #expect(AirCrashReports.scan(spelled) == expected, "\(spelling)")
            }
        }

        // Keys in the other order, on one line, with nothing but what a frame needs.
        let reversed = Data(
            #"{"callStacks":[{"callStackRootFrames":[{"subFrames":[],"offsetIntoBinaryTextSegment":7,"binaryUUID":"\#(Images.app)","binaryName":"WatchpostApp"}],"threadAttributed":true}]}"#.utf8
        )
        #expect(AirCrashReports.scan(reversed) == [thread(true, [frame("WatchpostApp", Images.app, 7)])])
    }

    /// Sibling frames: each branch is walked to its end before the next one starts.
    @Test
    func walksEachBranchToItsEndBeforeTheNext() throws {
        let json = Data(#"""
        {"callStacks":[{"threadAttributed":false,"callStackRootFrames":[
          {"binaryName":"A","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":1,"subFrames":[
            {"binaryName":"B","binaryUUID":"\#(Images.uiKit)","offsetIntoBinaryTextSegment":2,"subFrames":[
              {"binaryName":"C","binaryUUID":"\#(Images.foundation)","offsetIntoBinaryTextSegment":3,"subFrames":[]},
              {"binaryName":"D","binaryUUID":"\#(Images.objc)","offsetIntoBinaryTextSegment":4,"subFrames":[
                {"binaryName":"E","binaryUUID":"\#(Images.libc)","offsetIntoBinaryTextSegment":5,"subFrames":[]}]}]},
            {"binaryName":"F","binaryUUID":"\#(Images.xpc)","offsetIntoBinaryTextSegment":6,"subFrames":[]}]}]}]}
        """#.utf8)
        let scanned = try #require(AirCrashReports.scan(json))
        #expect(scanned == [thread(false, [
            frame("A", Images.app, 1),
            frame("B", Images.uiKit, 2),
            frame("C", Images.foundation, 3),
            frame("D", Images.objc, 4),
            frame("E", Images.libc, 5),
            frame("F", Images.xpc, 6),
        ])])
        // The same tree decoded by Foundation, flattened the same way.
        let decoded = try JSONDecoder().decode(MetricKitPayload.Tree.self, from: json)
        #expect(scanned == flattened(decoded))
    }

    /// Only objects inside `callStacks` give threads and frames. Entries of `callStacks` that are not objects are
    /// skipped, and a frame-like object that opens before any thread is ignored.
    @Test
    func onlyObjectsInsideCallStacksGiveThreadsAndFrames() throws {
        let json = Data(#"""
        {"callStackTree":{"binaryName":"before any thread","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":2},
         "callStacks":[1,"x",null,true,
          {"threadAttributed":true,"callStackRootFrames":[{"binaryName":"in","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":1,"subFrames":[]}]}]}
        """#.utf8)
        #expect(AirCrashReports.scan(json) == [thread(true, [frame("in", Images.app, 1)])])
    }
}

// MARK: - Robustness

/// `AirCrashReports.scan` on bytes that are not a healthy call stack tree.
@Suite
struct AirCrashTreeRobustnessTests {
    /// JSON without a tree, or with no stacks, gives no threads.
    @Test(arguments: [
        #"{}"#,
        #"{"callStacks":[ ]}"#,
        #"[]"#,
        #"null"#,
        #"{"callStacks":null}"#,
        #"{"callStacks":{}}"#,
        #"{"callStackRootFrames":[]}"#,
        #"{"callStacks":{"threadAttributed":true}}"#,
        #"{"appBuildVersion":"3","crashDiagnostics":[{"exceptionType":1}]}"#,
    ])
    func jsonWithoutStacksGivesNoThreads(_ json: String) {
        #expect(AirCrashReports.scan(Data(json.utf8)) == [])
    }

    /// No bytes at all: nothing to read, and so no threads.
    @Test
    func noBytesGiveNoThreads() {
        #expect(AirCrashReports.scan(Data()) == [])
    }

    /// A tree cut short anywhere is refused whole: nil, never part of a stack. Checked at every byte of the
    /// one-frame tree, and every 13th byte of a delivery's tree.
    @Test
    func truncatedJSONIsRefused() {
        let small = Data(Payloads.oneFrameTree.utf8)
        #expect(AirCrashReports.scan(small) == [thread(true, [frame("WatchpostApp", Images.app, 21_504)])])
        for cut in 1 ..< small.count {
            #expect(AirCrashReports.scan(small.prefix(cut)) == nil, "cut after \(cut) bytes")
        }
        let large = Data(Payloads.exceptionTree.utf8)
        #expect(AirCrashReports.scan(large) != nil)
        for cut in stride(from: 1, to: large.count, by: 13) {
            #expect(AirCrashReports.scan(large.prefix(cut)) == nil, "cut after \(cut) bytes")
        }
        #expect(AirCrashReports.scan(large.prefix(large.count - 1)) == nil)
    }

    /// A thread without frames is read, as a thread without frames; the report then drops it, and nothing is sent.
    @Test
    func aThreadWithoutFramesIsReadEmptyAndThenDropped() throws {
        let json = Data(#"{"callStacks":[{"threadAttributed":true,"queueName":"com.apple.main-thread","callStackRootFrames":[]}]}"#.utf8)
        let scanned = try #require(AirCrashReports.scan(json))
        #expect(scanned == [thread(true, [])])
        #expect(AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages()).isEmpty)
        #expect(AirCrashReports.bodies(of: [crash(callStackTree: json)], installID: CrashFixtures.installID).isEmpty)
        // No threads at all, or bytes that are not a tree: nothing is sent either.
        #expect(AirCrashReports.bodies(of: [crash(callStackTree: Data("not json".utf8))], installID: CrashFixtures.installID).isEmpty)
    }

    /// A stack nests one level per frame, and the reader is written to walk it without recursion and without a
    /// depth limit: 5,000 frames are read whole, where `JSONSerialization` gives up at a few hundred.
    @Test(arguments: [1, 2, 3, 255, 256, 1_000, 5_000])
    func deepStacksAreWalkedWithoutRecursion(depth: Int) throws {
        let scanned = try #require(AirCrashReports.scan(deepTree(depth: depth)))
        let frames = try #require(scanned.first?.frames)
        #expect(scanned.count == 1 && scanned.first?.crashed == true)
        #expect(frames.count == depth)
        #expect(frames.map(\.offset) == (0 ..< depth).map { UInt64($0) })
        #expect(frames.map(\.image) == (0 ..< depth).map { "Frame\($0 % 7)" })
        // The report keeps the crashed thread's first 256 frames.
        #expect(AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages()).first?.frames.count == min(depth, 256))
    }

    /// A key written twice keeps the last value.
    @Test
    func duplicatedKeysKeepTheLastValue() throws {
        let json = Data(#"""
        {"callStacks":[{"threadAttributed":false,"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"First","binaryName":"Second","binaryUUID":"\#(Images.uiKit)","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":6,"offsetIntoBinaryTextSegment":7,"subFrames":[]}]}]}
        """#.utf8)
        #expect(AirCrashReports.scan(json) == [thread(true, [frame("Second", Images.app, 7)])])
    }

    /// `threadAttributed` is a boolean; anything but `true` (a missing key, `false`, `null`, a number) leaves the
    /// thread unattributed.
    @Test(arguments: [#"true"#, #"false"#, #"null"#, #"1"#, #"0"#, #"True"#, #"YES"#])
    func onlyTrueAttributesAThread(_ value: String) throws {
        let json = Data(#"{"callStacks":[{"threadAttributed":\#(value),"callStackRootFrames":[{"binaryName":"WatchpostApp","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":1}]}]}"#.utf8)
        let expected = value == "true"
        #expect(AirCrashReports.scan(json)?.map(\.crashed) == [expected])
        // A missing key reads the same as `false`.
        let missing = Data(#"{"callStacks":[{"callStackRootFrames":[{"binaryName":"WatchpostApp","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":1}]}]}"#.utf8)
        #expect(AirCrashReports.scan(missing)?.map(\.crashed) == [false])
    }

    /// Offsets are unsigned 64-bit numbers, read exactly past `Int.max`; the numbers of other fields are skipped,
    /// however large.
    @Test
    func numbersAreReadAsUnsigned64Bit() throws {
        let json = Data(#"""
        {"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"Int.max","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":9223372036854775807,"address":18446744073709551615,"sampleCount":18446744073709551615},
          {"binaryName":"Int.max + 1","binaryUUID":"\#(Images.uiKit)","offsetIntoBinaryTextSegment":9223372036854775808,"symbolAddress":18446744073709551616},
          {"binaryName":"UInt64.max","binaryUUID":"\#(Images.foundation)","offsetIntoBinaryTextSegment":18446744073709551615},
          {"binaryName":"zero","binaryUUID":"\#(Images.objc)","offsetIntoBinaryTextSegment":0}]}]}
        """#.utf8)
        #expect(AirCrashReports.scan(json) == [thread(true, [
            frame("Int.max", Images.app, UInt64(Int.max)),
            frame("Int.max + 1", Images.uiKit, UInt64(Int.max) + 1),
            frame("UInt64.max", Images.foundation, UInt64.max),
            frame("zero", Images.objc, 0),
        ])])
    }

    /// Escapes (newlines, tabs, quotes, backslashes, unicode, surrogate pairs, slashes) in the fields that are
    /// skipped end where they should, so the frames around them are still read. A kept name is kept as written.
    @Test
    func escapedStringsEndWhereTheyShould() throws {
        let json = Data(#"""
        {"callStacks":[{"threadAttributed":true,"queueName":"com.apple.main-thread\n\t\"x\" \\ y \u00e9 \ud83d\ude00 \/z","callStackRootFrames":[
          {"binaryName":"UIKitCore","binaryUUID":"\#(Images.uiKit)","offsetIntoBinaryTextSegment":29280,"symbolName":"a\"b","symbolAddress":1,"sampleCount":1,"subFrames":[
            {"binaryName":"Foundation\\Core","binaryUUID":"\#(Images.foundation)","offsetIntoBinaryTextSegment":48392,"symbolName":"line 1\nline 2\ttab \u0041 \ud83d\ude00 end \" \\","sampleCount":1,"subFrames":[]}]}]}]}
        """#.utf8)
        let scanned = try #require(AirCrashReports.scan(json))
        #expect(scanned.count == 1 && scanned.first?.crashed == true)
        let frames = try #require(scanned.first?.frames)
        #expect(frames.count == 2)
        #expect(frames[0] == frame("UIKitCore", Images.uiKit, 29_280))
        #expect(frames[1].uuid == parsed(Images.foundation) && frames[1].offset == 48_392)
        // MetricKit's names are plain file names, which it never escapes; what is kept is the text between the quotes.
        #expect(frames[1].image == #"Foundation\\Core"#)
    }

    /// A frame without a UUID, or without an offset it can use, is left out; the frames around it stay. A UUID in
    /// lower case is the same UUID.
    @Test
    func framesWithoutAUsableUUIDOrOffsetAreLeftOut() throws {
        let json = Data(#"""
        {"callStacks":[{"threadAttributed":null,"callStackRootFrames":[
          {"binaryName":"kept","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":1},
          {"binaryName":"no offset","binaryUUID":"\#(Images.uiKit)"},
          {"binaryName":"no UUID","offsetIntoBinaryTextSegment":2},
          {"binaryName":"not a UUID","binaryUUID":"not-a-uuid","offsetIntoBinaryTextSegment":2},
          {"binaryName":"negative","binaryUUID":"\#(Images.foundation)","offsetIntoBinaryTextSegment":-2},
          {"binaryName":"fraction","binaryUUID":"\#(Images.foundation)","offsetIntoBinaryTextSegment":1.5},
          {"binaryName":"beyond UInt64","binaryUUID":"\#(Images.foundation)","offsetIntoBinaryTextSegment":18446744073709551616},
          {"binaryName":"lower case","binaryUUID":"\#(Images.libc.lowercased())","offsetIntoBinaryTextSegment":18446744073709551615},
          {"binaryName":"kept too","binaryUUID":"\#(Images.objc)","offsetIntoBinaryTextSegment":3,"subFrames":[]}]}]}
        """#.utf8)
        #expect(AirCrashReports.scan(json) == [thread(false, [
            frame("kept", Images.app, 1),
            frame("lower case", Images.libc, UInt64.max),
            frame("kept too", Images.objc, 3),
        ])])
    }

    /// Bytes that are not JSON at all give nil.
    @Test(arguments: [
        #"{"callStacks":[}"#, // an array closed with a brace
        #"{"callStacks":[{}"#, // never closed
        #"{"callStacks":]"#, // an array never opened, closed
        #"]"#, // nothing to close
        #"{"#, // never closed
        #"{"a":"b\"#, // a string that never ends
        #"{"callStacks":[1,2}"#, // numbers where frames should be, then the wrong bracket
        #"{"callStacks":[{}]}}"#, // one brace too many
        #"{"callStacks":"#, // cut after a colon
    ])
    func bytesThatAreNotJSONGiveNil(_ json: String) {
        #expect(AirCrashReports.scan(Data(json.utf8)) == nil)
    }

    /// A bare word, number or string is no tree either; nothing is read from it.
    @Test(arguments: [#"hello"#, #"true"#, #"42"#, #""callStacks""#, #"  \n\t "#])
    func loneTokensGiveNoThreads(_ json: String) {
        #expect((AirCrashReports.scan(Data(json.utf8)) ?? []).isEmpty)
    }
}

// MARK: - Threads and images

/// `AirCrashReports.threads` and `images(of:)`: the thread list of a report.
@Suite
struct AirCrashReportThreadTests {
    /// The executable of the bundle the tests run in: the one binary whose frames are the app's own.
    private var executable: String? { Bundle.main.executableURL?.lastPathComponent }

    /// The attributed thread comes first and is the crashed one; the others keep their order and are not crashed.
    /// Frames keep their order and their image, UUID and offset. Each image is listed once, in the order its first
    /// frame is reached.
    @Test
    func theAttributedThreadComesFirstAndTheOthersKeepTheirOrder() throws {
        let scanned = try #require(AirCrashReports.scan(Data(Payloads.badAccessTree.utf8)))
        let threads = AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages())
        #expect(threads.map(\.crashed) == [true, false, false])
        #expect(threads.map { $0.frames.map(\.offset) } == [
            [65_200, 498_764, 142_128, 397_388, 7_960],
            [12_440, 69_308, 30_712, 52_088, 13_960, 3_972, 11_944],
            [7_960, 110_432],
        ])
        #expect(wire(threads) == reportThreads(Expected.badAccessReport, crashedFirst: true, app: executable))
        #expect(wire(AirCrashReports.images(of: threads)) == imageList(Expected.badAccessReport, app: executable))
        #expect(AirCrashReports.images(of: threads).map(\.name) == [
            "WatchpostApp", "libswiftCore.dylib", "libsystem_c.dylib", "libsystem_kernel.dylib", "libsystem_pthread.dylib",
            "libdispatch.dylib", "libc++.1.dylib", "Foundation",
        ])

        // Already first: it stays first, and the order is the tree's.
        let alreadyFirst = try #require(AirCrashReports.scan(Data(Payloads.exceptionTree.utf8)))
        let kept = AirCrashReports.threads(alreadyFirst, loaded: AirCrashReports.LoadedImages())
        #expect(kept.map(\.crashed) == [true, false, false])
        #expect(wire(kept) == reportThreads(Expected.exception, crashedFirst: true, app: executable))
    }

    /// Without an attributed thread the order is the tree's and no thread is marked as the crashed one.
    @Test
    func withoutAnAttributedThreadNoThreadIsCrashed() throws {
        let text = Payloads.exceptionTree.replacingOccurrences(of: #""threadAttributed" : true"#, with: #""threadAttributed" : false"#)
        #expect(text != Payloads.exceptionTree)
        let scanned = try #require(AirCrashReports.scan(Data(text.utf8)))
        #expect(scanned.map(\.crashed) == [false, false, false])
        let threads = AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages())
        #expect(wire(threads) == reportThreads(scanned, crashedFirst: false, app: executable))
    }

    /// MetricKit attributes one thread. Should a tree name more, the first is the crashed one and the rest are
    /// left where they are, as ordinary threads.
    @Test
    func onlyTheFirstAttributedThreadIsMovedToTheFront() throws {
        let scanned = try #require(AirCrashReports.scan(wideTree(count: 5, frames: 2, attributed: [1, 3])))
        #expect(scanned.map(\.crashed) == [false, true, false, true, false])
        let threads = AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages())
        #expect(wire(threads) == reportThreads([scanned[1], scanned[0], scanned[2], scanned[3], scanned[4]], crashedFirst: true, app: executable))
    }

    /// The crashed thread keeps up to 256 frames, the others up to 64: the first ones read, the faulting frame and
    /// its nearest callers.
    @Test
    func framesAreCappedAt256ForTheCrashedThreadAnd64ForTheOthers() throws {
        let scanned = try #require(AirCrashReports.scan(wideTree(count: 3, frames: 300, attributed: [1])))
        let threads = AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages())
        #expect(threads.map(\.crashed) == [true, false, false])
        #expect(threads.map { $0.frames.count } == [256, 64, 64])
        #expect(wire(threads) == reportThreads([scanned[1], scanned[0], scanned[2]], crashedFirst: true, app: executable))
        #expect(threads[0].frames.last?.offset == 10_255 && threads[1].frames.last?.offset == 63 && threads[2].frames.last?.offset == 20_063)
    }

    /// At most 64 threads: the attributed one, then the tree's own threads from the first on.
    @Test
    func threadsAreCappedAt64() throws {
        let scanned = try #require(AirCrashReports.scan(wideTree(count: 100, frames: 2, attributed: [70])))
        #expect(scanned.count == 100)
        let threads = AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages())
        #expect(threads.count == 64)
        #expect(threads.map(\.crashed) == [true] + Array(repeating: false, count: 63))
        #expect(wire(threads) == reportThreads([scanned[70]] + Array(scanned[0 ..< 63]), crashedFirst: true, app: executable))

        // Without one: the first 64 of the tree, none crashed.
        let plain = try #require(AirCrashReports.scan(wideTree(count: 100, frames: 2)))
        let kept = AirCrashReports.threads(plain, loaded: AirCrashReports.LoadedImages())
        #expect(kept.count == 64 && kept.allSatisfy { !$0.crashed })
        #expect(wire(kept) == reportThreads(Array(plain.prefix(64)), crashedFirst: false, app: executable))
    }

    /// A frame without a binary name is reported with the image `???`, its UUID and offset intact; so is its image.
    @Test
    func aFrameWithoutANameIsReportedAsUnknown() throws {
        let json = Data(#"""
        {"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":5},
          {"binaryName":"UIKitCore","binaryUUID":"\#(Images.uiKit)","offsetIntoBinaryTextSegment":6,"subFrames":[
            {"binaryName":"","binaryUUID":"\#(Images.libc)","offsetIntoBinaryTextSegment":7,"subFrames":[]}]}]}]}
        """#.utf8)
        let scanned = try #require(AirCrashReports.scan(json))
        #expect(scanned.flatMap(\.frames).map(\.image) == ["", "UIKitCore", ""])
        let threads = AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages())
        #expect(wire(threads) == reportThreads(scanned, crashedFirst: true, app: executable))
        #expect(threads[0].frames.map(\.image) == ["???", "UIKitCore", "???"])
        #expect(threads[0].frames.map(\.offset) == [5, 6, 7])
        #expect(threads[0].frames.allSatisfy { !$0.inApp })
        #expect(wire(AirCrashReports.images(of: threads)) == [
            .init(name: "???", uuid: parsed(Images.app), inApp: false),
            .init(name: "UIKitCore", uuid: parsed(Images.uiKit), inApp: false),
            .init(name: "???", uuid: parsed(Images.libc), inApp: false),
        ])
    }

    /// Frames of the bundle's executable are the app's own, to be symbolicated on the server from the dSYMs; frames
    /// of system libraries are not. Every frame of an image agrees.
    @Test
    func framesOfTheAppAreMarkedAndSystemFramesAreNot() throws {
        let scanned = try #require(AirCrashReports.scan(Data(Payloads.exceptionTree.utf8)))
        let threads = AirCrashReports.threads(scanned, loaded: AirCrashReports.LoadedImages())
        let frames = threads.flatMap(\.frames)
        for frame in frames {
            #expect(frame.inApp == (frame.image == executable), "\(frame.image)")
        }
        #expect(frames.filter { $0.inApp }.map(\.image) == Array(repeating: executable ?? "", count: 3))
        for image in AirCrashReports.images(of: threads) {
            #expect(image.inApp == (image.name == executable), "\(image.name)")
        }
    }

    /// Images are told apart by name, UUID and mark: the same name with another UUID is another image, and an
    /// image reached again is not listed again.
    @Test
    func imagesAreToldApartByNameUUIDAndMark() {
        let threads = [
            AirCrashReports.Report.Thread(crashed: false, frames: [
                reportFrame("One", Images.app, 1),
                reportFrame("One", Images.uiKit, 1),
                reportFrame("Two", Images.foundation, 1, inApp: true),
            ]),
            AirCrashReports.Report.Thread(crashed: true, frames: [
                reportFrame("One", Images.app, 9),
                reportFrame("One", Images.foundation, 9, inApp: false),
                reportFrame("Two", Images.foundation, 9),
            ]),
        ]
        #expect(wire(AirCrashReports.images(of: threads)) == [
            .init(name: "One", uuid: parsed(Images.app), inApp: false),
            .init(name: "One", uuid: parsed(Images.uiKit), inApp: false),
            .init(name: "Two", uuid: parsed(Images.foundation), inApp: true),
            .init(name: "One", uuid: parsed(Images.foundation), inApp: false),
            .init(name: "Two", uuid: parsed(Images.foundation), inApp: false),
        ])
        #expect(AirCrashReports.images(of: []).isEmpty)
    }
}

/// `AirCrashReports.LoadedImages`: which images are loaded, and which of them are the app's own.
@Suite
struct AirCrashLoadedImagesTests {
    @Test
    func theImagesOfThisProcessAreReadWithUUIDAndTextSize() {
        let loaded = AirCrashReports.LoadedImages()
        #expect(!loaded.byUUID.isEmpty)
        #expect(loaded.byUUID.values.allSatisfy { $0.textSize > 0 && !$0.path.isEmpty })
    }

    /// The app's UUID is the app's, whatever it is called; an image loaded from elsewhere is not the app's, even
    /// when named like the app; an image not loaded now is the app's by name alone (a crash in an older build).
    @Test
    func loadedImagesTellTheAppFromTheSystem() throws {
        let loaded = AirCrashReports.LoadedImages()
        let executable = try #require(Bundle.main.executableURL?.lastPathComponent)
        let own = try #require(loaded.byUUID.first { ($0.value.path as NSString).lastPathComponent == executable })
        let system = try #require(loaded.byUUID.first {
            $0.value.path.hasPrefix("/System/") || $0.value.path.hasPrefix("/usr/lib/")
        })
        #expect(loaded.isInApp(image: executable, uuid: own.key))
        #expect(loaded.isInApp(image: "Not the " + executable, uuid: own.key))
        #expect(!loaded.isInApp(image: executable, uuid: system.key))
        #expect(loaded.isInApp(image: executable, uuid: UUID()))
        #expect(!loaded.isInApp(image: "Not the " + executable, uuid: UUID()))
    }
}

/// `AirCrashReports.SystemSymbols`: what is symbolicated on the device.
@Suite
struct AirCrashSystemSymbolTests {
    /// A frame whose image is not loaded now (another OS build, an image this run never loaded) is left as image
    /// and offset: nothing to look the name up in.
    @Test
    func framesOfImagesNotLoadedNowResolveToNothing() throws {
        let loaded = AirCrashReports.LoadedImages()
        let scanned = try #require(AirCrashReports.scan(Data(Payloads.exceptionTree.utf8)))
        let keys = Set(scanned.flatMap(\.frames).map { AirCrashReports.SystemSymbols.Key(uuid: $0.uuid, offset: $0.offset) })
        #expect(keys.count == 14)
        #expect(AirCrashReports.SystemSymbols.resolve(keys, in: loaded).isEmpty)
        #expect(AirCrashReports.SystemSymbols.resolve([], in: loaded).isEmpty)
    }

    /// An offset at or past the image's `__TEXT` end is outside the image's code: not resolved.
    @Test
    func anOffsetOutsideTheImagesTextResolvesToNothing() throws {
        let loaded = AirCrashReports.LoadedImages()
        let (uuid, image) = try #require(loaded.byUUID.first)
        let key = AirCrashReports.SystemSymbols.Key(uuid: uuid, offset: UInt64(image.textSize))
        #expect(AirCrashReports.SystemSymbols.resolve([key], in: loaded).isEmpty)
    }
}

// MARK: - Reports

/// `AirCrashReports.report` and `bodies`: the JSON body the ingest takes. (The install id itself comes from
/// `installID()`, which is private and keeps its value in `UserDefaults.standard`; what is checked here is that
/// `bodies` passes it through.)
@Suite
struct AirCrashReportBodyTests {
    private var executable: String? { Bundle.main.executableURL?.lastPathComponent }

    /// Two crashes of one delivery, as two bodies: every documented field, and no other. The hang and the CPU
    /// exception of the same delivery are in neither.
    @Test
    func bodiesCarryTheDocumentedFieldsAndNothingElse() throws {
        let delivery = try delivered()
        #expect(delivery.endedAt == CrashFixtures.endedAt)
        #expect(delivery.crashDiagnostics.count == 2 && delivery.hangDiagnostics.count == 1)
        #expect(delivery.cpuExceptionDiagnostics.count == 1 && delivery.diskWriteExceptionDiagnostics.isEmpty)

        // `didReceive` fills a `Crash` from each crash diagnostic and its payload's end.
        let first = delivery.crashDiagnostics[0]
        let second = delivery.crashDiagnostics[1]
        let crashes = [
            crash(callStackTree: Data(Payloads.exceptionTree.utf8), exceptionType: first.exceptionType,
                  exceptionCode: first.exceptionCode, signal: 6, exceptionName: first.exceptionReason?.exceptionName,
                  exceptionMessage: first.exceptionReason?.composedMessage, terminationReason: first.terminationReason),
            crash(callStackTree: Data(Payloads.badAccessTree.utf8), exceptionType: second.exceptionType,
                  exceptionCode: second.exceptionCode, signal: 11, exceptionName: nil, exceptionMessage: nil,
                  terminationReason: second.terminationReason),
        ]
        // ... with the values the JSON carries.
        #expect(crashes[0].exceptionType == 6 && crashes[0].exceptionCode == 0)
        #expect(crashes[0].exceptionName == "NSInvalidArgumentException")
        #expect(crashes[0].exceptionMessage == "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")
        #expect(crashes[0].terminationReason == "Namespace SIGNAL, Code 6 Abort trap: 6")
        #expect(crashes[1].exceptionType == 1 && crashes[1].exceptionCode == 1 && crashes[1].exceptionName == nil)
        #expect(crashes[1].terminationReason == "Namespace SIGNAL, Code 11 Segmentation fault: 11")

        let bodies = AirCrashReports.bodies(of: crashes, installID: CrashFixtures.installID)
        #expect(bodies.count == 2)
        #expect(Set(bodies.map(\.id)).count == 2)
        let decoder = JSONDecoder()
        let reports = try bodies.map { try decoder.decode(WireReport.self, from: $0.json) }

        let common = WireReport(
            id: "",
            occurredAt: "2026-11-01T00:00:00.000Z",
            installID: CrashFixtures.installID,
            app: .init(version: "1.0", build: "3", bundleID: Bundle.main.bundleIdentifier ?? ""),
            device: .init(model: "iPhone15,2", os: "iOS", osVersion: "26.1", osBuild: "23B85", arch: "arm64e",
                          locale: Locale.current.identifier),
            exception: .init(type: nil, code: nil, signal: nil, name: nil, message: nil, terminationReason: nil),
            threads: [],
            images: []
        )
        let exceptions = [
            WireReport.Exception(type: 6, code: 0, signal: 6, name: "NSInvalidArgumentException",
                                 message: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                                 terminationReason: "Namespace SIGNAL, Code 6 Abort trap: 6"),
            WireReport.Exception(type: 1, code: 1, signal: 11, name: nil, message: nil,
                                 terminationReason: "Namespace SIGNAL, Code 11 Segmentation fault: 11"),
        ]
        let trees = [Expected.exception, Expected.badAccessReport]
        for index in bodies.indices {
            var expected = common
            expected.id = bodies[index].id
            expected.exception = exceptions[index]
            expected.threads = reportThreads(trees[index], crashedFirst: true, app: executable)
            expected.images = imageList(trees[index], app: executable)
            #expect(reports[index] == expected)

            // A random id of its own: a UUID, in lower case.
            #expect(UUID(uuidString: bodies[index].id) != nil && bodies[index].id == bodies[index].id.lowercased())

            // The keys on the wire, and no others: no symbol, as no system frame could be resolved.
            let json = try jsonObject(bodies[index].json)
            #expect(json.keys.sorted() == ["app", "device", "exception", "id", "images", "installID", "occurredAt", "threads"])
            #expect(allKeys(json).sorted() == [
                "app", "arch", "build", "bundleID", "code", "crashed", "device", "exception", "frames", "id", "image",
                "images", "inApp", "installID", "locale", "message", "model", "name", "occurredAt", "offset", "os",
                "osBuild", "osVersion", "signal", "terminationReason", "threads", "type", "uuid", "version",
            ])
        }
        // Nothing of the hang (its app frame sits at offset 88,432) is in either body.
        let offsets = reports.flatMap { $0.threads.flatMap(\.frames) }.map(\.offset)
        #expect(offsets.contains(88_432) == false)
        #expect(reports.flatMap(\.threads).count == 6)
    }

    /// The body is plain JSON text, UTF-8, with UUIDs in upper case as MetricKit writes them and slashes as they
    /// are.
    @Test
    func bodiesAreUTF8TextWithUpperCaseUUIDsAndPlainSlashes() throws {
        let bodies = AirCrashReports.bodies(
            of: [crash(exceptionMessage: "cannot read /var/mobile/Containers/Data/Application/x")],
            installID: CrashFixtures.installID
        )
        let body = try #require(bodies.first)
        let text = try #require(String(data: body.json, encoding: .utf8))
        #expect(text.hasPrefix("{") && text.hasSuffix("}"))
        #expect(text.contains(Images.app))
        #expect(text.contains(#""message":"cannot read /var/mobile/Containers/Data/Application/x""#))
        #expect(text.contains(#"\/"#) == false)
    }

    /// The install id is passed through as given.
    @Test
    func theInstallIDIsPassedThrough() throws {
        let bodies = AirCrashReports.bodies(of: [crash()], installID: "6B1F4D0E-2C3A-4B5C-8D9E-0F1A2B3C4D5E")
        let body = try #require(bodies.first)
        let decoded = try JSONDecoder().decode(WireReport.self, from: body.json)
        #expect(decoded.installID == "6B1F4D0E-2C3A-4B5C-8D9E-0F1A2B3C4D5E")
    }

    /// Exception text is cut to its limit (a name to 256 characters, a message to 1,024, a reason to 512), and
    /// empty text is no text: an explicit `null`.
    @Test
    func exceptionTextIsCutAndEmptyTextIsNull() throws {
        let long = crash(exceptionName: String(repeating: "n", count: 1_000),
                         exceptionMessage: String(repeating: "m", count: 2_000),
                         terminationReason: String(repeating: "t", count: 1_000))
        var report = AirCrashReports.report(of: long, installID: CrashFixtures.installID, loaded: AirCrashReports.LoadedImages())
        #expect(report.exception.name?.count == 256)
        #expect(report.exception.message?.count == 1_024)
        #expect(report.exception.terminationReason?.count == 512)

        let empty = crash(exceptionName: "", exceptionMessage: "", terminationReason: "")
        report = AirCrashReports.report(of: empty, installID: CrashFixtures.installID, loaded: AirCrashReports.LoadedImages())
        #expect(report.exception.name == nil && report.exception.message == nil && report.exception.terminationReason == nil)
        let json = try #require(AirCrashReports.encoded(report))
        let root = try jsonObject(json)
        let exception = try object(root, "exception")
        #expect(exception.keys.sorted() == ["code", "message", "name", "signal", "terminationReason", "type"])
        #expect(exception["type"] as? Int == 6 && exception["code"] as? Int == 0 && exception["signal"] as? Int == 6)
        #expect(exception["name"] is NSNull && exception["message"] is NSNull && exception["terminationReason"] is NSNull)
    }

    /// An address the system wrote into the crash's text is not sent: the person's own server has one.
    @Test
    func addressesInExceptionTextAreTakenOut() {
        let report = AirCrashReports.report(
            of: crash(exceptionMessage: "Could not connect to http://192.168.1.50:8080/api/events (10.0.0.2, nas.local:8080, [fe80::1c31]:443): offline",
                      terminationReason: "Error Domain=NSURLErrorDomain Code=-1004 NSErrorFailingURLStringKey=https://home.example.org/live, next=ftp://192.168.1.5/clips"),
            installID: CrashFixtures.installID, loaded: AirCrashReports.LoadedImages()
        )
        #expect(report.exception.message == "Could not connect to <address> (<address>, <address>, <address>): offline")
        #expect(report.exception.terminationReason == "Error Domain=NSURLErrorDomain Code=-1004 NSErrorFailingURLStringKey=<address>, next=<address>")
    }

    /// An address that begins where the length limit cuts leaves nothing behind: not its beginning, and
    /// not the beginning of the mark that replaced it. One that fits just before the cut keeps its mark.
    @Test
    func anAddressCutByTheLengthLimitIsStillTakenOut() {
        let filler = String(repeating: "x", count: 1_020)
        let cut = AirCrashReports.report(of: crash(exceptionMessage: filler + " http://192.168.1.50:8080/api/events"),
                                         installID: CrashFixtures.installID, loaded: AirCrashReports.LoadedImages())
        #expect(cut.exception.message == filler)

        let shorter = String(filler.dropLast(20))
        let justFits = shorter + " http://192.168.1.50:8080/api/events"
        let kept = AirCrashReports.report(of: crash(exceptionMessage: justFits), installID: CrashFixtures.installID,
                                          loaded: AirCrashReports.LoadedImages())
        #expect(kept.exception.message == shorter + " <address>")
    }

    /// An address longer than the cut leaves nothing behind: addresses come out before the cut.
    @Test
    func anAddressLongerThanTheCutIsGoneWhole() {
        let long = "http://" + String(repeating: "a", count: 3_000) + "/x"
        let report = AirCrashReports.report(of: crash(exceptionMessage: long), installID: CrashFixtures.installID,
                                            loaded: AirCrashReports.LoadedImages())
        #expect(report.exception.message == "<address>")
    }

    /// The other ways an address gets written: `localhost`, a home server's name on its own, an IPv6
    /// number, a web address without its scheme. What the sentence puts around it stays.
    @Test(arguments: zip([
        "localhost:8080 refused",
        "at myserver.local",
        "jakes-macbook.local said no",
        "fe80::1c31%en0",
        "2001:db8::1 and ::1",
        "::ffff:192.168.1.1",
        "see www.example.com/live",
        "It could not reach home.example.org:8443 (timeout)",
        "see http://a.example/x, then y",
        "(http://a.example/x).",
        "192.168.1.1.",
        "tcp://jake:secret@10.0.0.5:22/x",
    ], [
        "<address> refused",
        "at <address>",
        "<address> said no",
        "<address>",
        "<address> and <address>",
        "<address>",
        "see <address>",
        "It could not reach <address> (timeout)",
        "see <address>, then y",
        "(<address>).",
        "<address>.",
        "<address>",
    ]))
    func otherWaysOfWritingAnAddressAreTakenOut(_ text: String, _ wanted: String) {
        #expect(AirCrashReports.redacted(text) == wanted)
    }

    /// A bare four-part number is taken for an address unless a version label sits before it:
    /// one version number lost in a crash's text is worth one address not sent.
    @Test
    func aBareFourPartNumberIsTakenForAnAddress() {
        #expect(AirCrashReports.redacted("needs 1.2.3.4 or newer") == "needs <address> or newer")
        #expect(AirCrashReports.redacted("needs version 1.2.3.4 or newer") == "needs version 1.2.3.4 or newer")
        #expect(AirCrashReports.redacted("CFNetwork version 2.0.0.0") == "CFNetwork version 2.0.0.0")
    }

    /// What the system says about a crash when no address is in it is sent as it is.
    @Test(arguments: [
        "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
        "Namespace SIGNAL, Code 6 Abort trap: 6",
        "Fatal error: Index out of range: file WatchpostApp/Data/Models.swift, line 42",
        "cannot read /var/mobile/Containers/Data/Application/x",
        "Error Domain=NSCocoaErrorDomain Code=3840 \"JSON text did not start with array or object.\" UserInfo={NSDebugDescription=JSON text did not start with array or object.}",
        "*** -[__NSArrayM objectAtIndex:]: Index 5 beyond bounds [0 .. 2]",
        "-[NSBundle objectForInfoDictionaryKey:]: unrecognized selector sent to instance 0x600003a0c1e0",
        "Swift runtime failure: Unexpectedly found nil while implicitly unwrapping an Optional value",
        "FoundationEssentials.framework",
        "Fatal error: Index out of range\n at WatchpostApp/Data/Models.swift:42",
        "Fatal error: file Models.swift:42",
        "launched at 08:00:00 and 08:00:00.123 and 10:30",
        "std::__1::vector<int>",
        "port:8080 and Code=-1001 and line: 42",
        "WatchpostApp.AppModel.connect()",
    ])
    func ordinaryExceptionTextIsLeftAlone(_ text: String) {
        #expect(AirCrashReports.redacted(text) == text, "changed")
        #expect(AirCrashReports.redacted(nil) == nil)
    }

    /// A crash with no exception values at all is still a report, with six explicit `null`s.
    @Test
    func aCrashWithoutExceptionValuesWritesSixNulls() throws {
        let bare = crash(exceptionType: nil, exceptionCode: nil, signal: nil, exceptionName: nil, exceptionMessage: nil,
                         terminationReason: nil)
        let body = try #require(AirCrashReports.bodies(of: [bare], installID: CrashFixtures.installID).first)
        let root = try jsonObject(body.json)
        let exception = try object(root, "exception")
        #expect(exception.keys.sorted() == ["code", "message", "name", "signal", "terminationReason", "type"])
        #expect(exception.values.allSatisfy { $0 is NSNull })
    }

    /// A crash is dated by its payload's end; one dated ahead of now (a clock that moved) is dated now.
    @Test
    func aCrashDatedInTheFutureIsDatedNow() throws {
        let before = Date()
        let report = AirCrashReports.report(of: crash(occurredAt: before.addingTimeInterval(3_600)),
                                            installID: CrashFixtures.installID, loaded: AirCrashReports.LoadedImages())
        let occurredAt = try #require(instant(report.occurredAt))
        #expect(occurredAt >= before.addingTimeInterval(-1) && occurredAt <= Date())
        // Dated in the past: kept.
        let past = AirCrashReports.report(of: crash(occurredAt: Date(timeIntervalSince1970: 0)), installID: CrashFixtures.installID,
                                          loaded: AirCrashReports.LoadedImages())
        #expect(past.occurredAt == "1970-01-01T00:00:00.000Z")
    }

    /// The facts of the app and the device come from the crash and from this process, and the system is named
    /// from MetricKit's string.
    @Test
    func appAndDeviceAreReportedAsGiven() throws {
        let report = AirCrashReports.report(
            of: crash(appVersion: "2.3", appBuild: "17", deviceModel: "iPad16,2", osVersion: "iPadOS 18.0 (22A3351)",
                      architecture: "arm64"),
            installID: CrashFixtures.installID, loaded: AirCrashReports.LoadedImages()
        )
        #expect(report.app.version == "2.3" && report.app.build == "17")
        #expect(report.app.bundleID == (Bundle.main.bundleIdentifier ?? ""))
        #expect(report.device.model == "iPad16,2" && report.device.arch == "arm64" && report.device.locale == Locale.current.identifier)
        #expect(report.device.os == "iPadOS" && report.device.osVersion == "18.0" && report.device.osBuild == "22A3351")
    }
}

// MARK: - Size limit

/// `AirCrashReports.encoded`: the body trimmed to the ingest's limit (500,000 bytes, under its 512 KiB).
@Suite
struct AirCrashReportSizeLimitTests {
    /// A body that fits is written whole, and the same bytes every time.
    @Test
    func aBodyThatFitsIsWrittenWholeAndTheSameWayTwice() throws {
        let report = AirCrashReports.report(of: crash(), installID: CrashFixtures.installID, loaded: AirCrashReports.LoadedImages())
        let json = try #require(AirCrashReports.encoded(report))
        #expect(json.count < AirCrashReports.maximumBody)
        let again = try #require(AirCrashReports.encoded(report))
        #expect(again == json)
        let decoded = try JSONDecoder().decode(WireReport.self, from: json)
        #expect(decoded == wire(report))
    }

    /// 64 threads of 64 frames in images with long names (about 600 KB): threads go from the end, a quarter of
    /// the rest at a time, until the body fits. Those kept are the tree's first, whole; the images list shrinks with
    /// them.
    @Test
    func threadsAreDroppedFromTheEndUntilTheBodyFits() throws {
        let report = makeReport(heavyThreads(64, frames: 64, nameLength: 60))
        let whole = try JSONEncoder().encode(report)
        #expect(whole.count > AirCrashReports.maximumBody)
        #expect(report.threads.count == 64 && report.images.count == 64)

        let json = try #require(AirCrashReports.encoded(report))
        #expect(json.count <= AirCrashReports.maximumBody)
        let trimmed = try JSONDecoder().decode(WireReport.self, from: json)
        let kept = trimmed.threads.count
        #expect(kept > 0 && kept < 64)
        #expect(trimmed.threads == Array(report.threads.prefix(kept).map { wire($0) }))
        #expect(trimmed.threads.map(\.crashed) == [true] + Array(repeating: false, count: kept - 1))
        #expect(trimmed.images == (0 ..< kept).map { index in
            .init(name: "Image\(index)" + String(repeating: "x", count: 60), uuid: parsed(Images.all[index % Images.all.count]), inApp: false)
        })

        // What is written is exactly the report with those threads: nothing else was touched.
        var reduced = report
        reduced.threads = Array(report.threads.prefix(kept))
        reduced.images = AirCrashReports.images(of: reduced.threads)
        #expect(trimmed == wire(reduced))
        // And the writer reaches that body from the whole report, not only from the reduced one.
        #expect(AirCrashReports.encoded(reduced) == json)
    }

    /// One thread of 4,500 frames (about 600 KB): with no other thread to drop, the crashed thread's deepest
    /// frames go, a quarter of them at a time, until the body fits. The faulting frame and its nearest callers stay.
    @Test
    func theDeepestFramesGoWhenTheCrashedThreadIsAlone() throws {
        let frames = (0 ..< 4_500).map { reportFrame("Image0" + String(repeating: "x", count: 40), Images.app, UInt64($0)) }
        let report = makeReport([AirCrashReports.Report.Thread(crashed: true, frames: frames)])
        let whole = try JSONEncoder().encode(report)
        #expect(whole.count > AirCrashReports.maximumBody)

        let json = try #require(AirCrashReports.encoded(report))
        #expect(json.count <= AirCrashReports.maximumBody)
        let trimmed = try JSONDecoder().decode(WireReport.self, from: json)
        let kept = try #require(trimmed.threads.first?.frames.count)
        #expect(trimmed.threads.count == 1 && trimmed.threads[0].crashed)
        #expect(kept > 0 && kept < frames.count)
        #expect(trimmed.threads[0].frames == frames.prefix(kept).map { wire($0) })
        #expect(trimmed.images.map(\.name) == ["Image0" + String(repeating: "x", count: 40)])
    }

    /// One frame cannot be cut: a body of a single frame that is too large is written as it is, for the ingest to
    /// refuse.
    @Test
    func aBodyOfOneFrameIsWrittenAsItIsHoweverLarge() throws {
        let name = String(repeating: "n", count: 600_000)
        let report = makeReport([AirCrashReports.Report.Thread(crashed: true, frames: [reportFrame(name, Images.app, 1)])])
        let json = try #require(AirCrashReports.encoded(report))
        #expect(json.count > AirCrashReports.maximumBody)
        let decoded = try JSONDecoder().decode(WireReport.self, from: json)
        #expect(decoded.threads.count == 1 && decoded.threads[0].frames.count == 1)
        #expect(decoded.threads[0].frames[0].image == name)
    }
}

// MARK: - Operating system

/// `AirCrashReports.operatingSystem`: MetricKit's `osVersion` string, read into name, version and build.
@Suite
struct AirCrashOperatingSystemTests {
    @Test(arguments: OSVersions.metricKit.map(\.text))
    func readsMetricKitsOwnStrings(_ text: String) throws {
        let line = try #require(OSVersions.metricKit(text))
        let os = AirCrashReports.operatingSystem(text, model: line.model)
        #expect(os.name == line.name && os.version == line.version && os.build == line.build)
    }

    @Test(arguments: OSVersions.withoutABuild.map(\.text))
    func readsStringsWithoutABuild(_ text: String) throws {
        let line = try #require(OSVersions.withoutABuild(text))
        let os = AirCrashReports.operatingSystem(text, model: line.model)
        #expect(os.name == line.name && os.version == line.version && os.build == line.build)
    }

    @Test(arguments: OSVersions.elsewhere.map(\.text))
    func fallsBackToThisPlatformOrKeepsTheName(_ text: String) throws {
        let line = try #require(OSVersions.elsewhere(text))
        let os = AirCrashReports.operatingSystem(text, model: line.model)
        #expect(os.name == line.name && os.version == line.version && os.build == line.build)
    }

    /// `iPhone OS` is `iPadOS` on an iPad and `iOS` elsewhere; `iPadOS` is `iPadOS` whatever the model.
    @Test
    func anIPadRunsIPadOS() {
        #expect(AirCrashReports.operatingSystem("iPhone OS 26.1 (23B85)", model: "iPad16,2").name == "iPadOS")
        #expect(AirCrashReports.operatingSystem("iPhone OS 26.1 (23B85)", model: "iPad").name == "iPadOS")
        #expect(AirCrashReports.operatingSystem("iPhone OS 26.1 (23B85)", model: "iPhone15,2").name == "iOS")
        #expect(AirCrashReports.operatingSystem("iPhone OS 26.1 (23B85)", model: "iPod touch").name == "iOS")
        #expect(AirCrashReports.operatingSystem("iPadOS 26.1 (23B85)", model: "iPhone15,2").name == "iPadOS")
        #expect(AirCrashReports.operatingSystem("iOS 17.1 (21B80)", model: "iPad16,2").name == "iPadOS")
        // Only the version words count: `iPhone` alone, or `OS`, is not a system name.
        #expect(AirCrashReports.operatingSystem("iPhone 26.1 (23B85)", model: "iPhone15,2").name == "iPhone")
    }
}

// MARK: - Image identity

/// `AirCrashReports.LoadedImages.identity`: the UUID and `__TEXT` size read from a mach header's load commands.
@Suite
struct AirCrashImageIdentityTests {
    private func identity(_ bytes: [UInt8]) -> (UUID, UInt)? {
        bytes.withUnsafeBytes { raw in
            AirCrashReports.LoadedImages.identity(of: raw.bindMemory(to: mach_header.self).baseAddress!)
        }
    }

    @Test
    func readsTheUUIDAndTextSize() {
        let id = parsed(Images.app)
        let read = identity(machHeader([uuidCommand(id), textSegment(size: 4_096)]))
        #expect(read?.0 == id && read?.1 == 4_096)
        let other = identity(machHeader([textSegment(size: 8_192), uuidCommand(id)]))
        #expect(other?.0 == id && other?.1 == 8_192)
    }

    /// A header is refused when its magic is not a 64-bit mach header's, when it has no UUID or no `__TEXT`, when a
    /// command claims a length the header does not hold, or when it claims too many commands.
    @Test
    func refusesHeadersItCannotRead() {
        let id = parsed(Images.app)
        var not64 = machHeader([uuidCommand(id), textSegment(size: 4_096)])
        not64[0] = 0xce // MH_MAGIC, a 32-bit header
        #expect(identity(not64) == nil)
        #expect(identity(machHeader([textSegment(size: 4_096)])) == nil)
        #expect(identity(machHeader([uuidCommand(id)])) == nil)
        #expect(identity(machHeader([])) == nil)

        var tooLong = uuidCommand(id)
        tooLong[4] = 0xff // cmdsize 255, where the header holds 24 bytes for it
        #expect(identity(machHeader([tooLong, textSegment(size: 4_096)])) == nil)
        var tooShort = textSegment(size: 4_096)
        tooShort[4] = 4 // cmdsize 4: no command is that short
        #expect(identity(machHeader([uuidCommand(id), tooShort])) == nil)

        #expect(identity(machHeader([uuidCommand(id), textSegment(size: 4_096)], claiming: 1)) == nil)
        #expect(identity(machHeader([uuidCommand(id), textSegment(size: 4_096)], claiming: 65_536)) == nil)
    }
}

// MARK: - Expected shapes

/// A frame as a report carries it when nothing is resolved: a nameless frame is `???`, the bundle's executable's
/// frames are the app's own, and no one else's.
private func wireFrame(_ frame: AirCrashReports.ScannedFrame, app executable: String?) -> WireReport.Frame {
    WireReport.Frame(image: frame.image.isEmpty ? "???" : frame.image, uuid: frame.uuid, offset: frame.offset,
                     inApp: frame.image == executable, symbol: nil, symbolOffset: nil)
}

/// Threads as `threads` makes them when they are in their final order: the first one the crashed thread, with up to
/// 256 frames, if `crashedFirst`; the others with up to 64.
private func reportThreads(_ scanned: [AirCrashReports.ScannedThread], crashedFirst: Bool,
                           app executable: String?) -> [WireReport.Thread] {
    scanned.prefix(64).enumerated().map { index, stack in
        let crashed = crashedFirst && index == 0
        return WireReport.Thread(crashed: crashed, frames: stack.frames.prefix(crashed ? 256 : 64).map { wireFrame($0, app: executable) })
    }
}

/// A tree of `count` threads with `frames` frames each, nested one under the next, the listed threads attributed.
/// A frame is named `T<thread>F<number>` and sits at offset `thread * 10,000 + number`.
private func wideTree(count: Int, frames: Int, attributed: Set<Int> = []) -> Data {
    let stacks = (0 ..< count).map { thread -> String in
        var parts = [#"{"threadAttributed":\#(attributed.contains(thread)),"callStackRootFrames":["#]
        for number in 0 ..< frames {
            parts.append(#"{"binaryName":"T\#(thread)F\#(number)","binaryUUID":"\#(Images.app)","offsetIntoBinaryTextSegment":\#(thread * 10_000 + number),"sampleCount":1,"subFrames":["#)
        }
        parts.append(String(repeating: "]}", count: frames))
        parts.append("]}")
        return parts.joined()
    }
    return Data(#"{"callStacks":[\#(stacks.joined(separator: ","))]}"#.utf8)
}
