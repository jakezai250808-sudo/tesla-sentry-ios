import Foundation
@testable import WatchpostApp

/// What the box answers, spelled as `sentry-viewer.py` 2.8.45 spells it.
enum ServerFixtures {
    // MARK: Session

    /// `GET /api/ver`
    static let version = #"{"v": "2.8.45"}"#

    /// `GET /api/auth/info`: on a server that needs a password, and on one that does not.
    static let authInfoOn = #"{"user": "admin", "on": true}"#
    static let authInfoOff = #"{"user": "admin", "on": false}"#

    /// `POST /login`'s answer to a wrong password (401) and to too many of them (429): the login
    /// page with its message, here shortened to the message.
    static let wrongPasswordMessage = "用户名或密码不对"
    static let lockedOutMessage = "尝试次数过多，请 5 分钟后再试"

    static func loginPage(status: Int, message: String) -> String {
        "<!DOCTYPE html><html lang=\"zh\"><head><meta charset=\"utf-8\"></head><body>\(message)</body></html>"
    }

    // MARK: Live and storage

    /// `GET /api/live` as `live_status`, `disk_usage` and `sys_status` give it together.
    static let live = """
        {"running": true, "pending": 2, "ago": 384, "last": "已同步 2026-11-08 20:01",
         "disk": {"img_nominal": 64424509440, "img_real": 64423829504, "img_used": 41204699136,
                  "arc_used": 412000000000, "disk_total": 1000204888064, "disk_used": 618457903104,
                  "disk_free": 381746987968, "arc_free": 1588000000000, "arc_limit": 2000000000000,
                  "src": "loop", "used": 41204699136, "total": 64424509440},
         "sys": {"cpu_temp": 52.3, "cpu_pct": 18, "mem_total": 2071445504, "mem_used": 612345678, "ffmpeg": true}}
        """

    /// A box with no USB image and no sync log.
    static let liveUnknown = #"{"running": false, "pending": 0, "ago": null, "last": "", "disk": null, "sys": {"cpu_temp": null, "cpu_pct": 0, "mem_total": 2071445504, "mem_used": 612345678, "ffmpeg": false}}"#

    // MARK: Telemetry

    /// `GET /api/telemetry` of a clip recorded while driving: 14 numbers a row.
    static let telemetry = """
        {"ok": true, "fps": 29.97, "count": 3, "duration": 12.0, "max_speed": 31.6, "avg_speed": 23.9, "brake_ratio": 12.0,
         "frames": [[0.0, "D", 30.0, 17, 0.3, 0, 0, 0, 31.2304, 121.4737, 12.0, -0.01, 0.40, 9.80],
                    [6.5, "D", 27.8, 0, -0.8, 1, 0, 0, 31.2305, 121.4738, 11.7, 0.03, -1.95, 9.80],
                    [9.5, "D", 13.9, 18, -149.7, 0, 2, 3, 31.2306, 121.4739, 16.4, 1.14, -0.07, 9.80]]}
        """

    /// A parked clip carries no SEI: the normal answer, not a failure.
    static let telemetryNoSEI = #"{"ok": false, "reason": "no-sei"}"#
    /// Answered with 404.
    static let telemetryBadPath = #"{"ok": false, "reason": "bad-path"}"#

    // MARK: Timeline

    /// Answered with 400.
    static let timelineInvalid = #"{"error": "invalid category or event"}"#
    /// Answered with 202 while another gap scan runs.
    static let timelinePending = #"{"pending": true}"#

    // MARK: Font

    /// `GET /api/font`
    static let fontPresent = #"{"ok": true, "path": "/opt/tesla-sentry/fonts/NotoSansSC.ttf", "name": "NotoSansSC.ttf", "size": 10181588, "dir": "/opt/tesla-sentry/fonts", "install_dir": "/opt/tesla-sentry/fonts"}"#
    static let fontMissing = #"{"ok": false, "path": "", "name": "", "size": 0, "dir": "/opt/tesla-sentry/fonts", "install_dir": "/opt/tesla-sentry/fonts"}"#

    // MARK: Playback

    static let playbackReady = #"{"state": "ready"}"#
    static let playbackPending = #"{"state": "pending"}"#
    static let playbackCooling = #"{"state": "cooling"}"#
    static let playbackFailed = #"{"state": "failed"}"#
    static let playbackMissing = #"{"state": "missing"}"#
    /// Only sent to a caller that asked for `parts=1`; the app never does.
    static let playbackParts = #"{"state": "parts", "seconds": 1}"#

    /// `POST /api/kick` and `POST /api/live/demand`.
    static let kickAnswer = #"{"ok": true, "started": 1, "skipped": 0}"#
    static let demandAnswer = #"{"files": {"/media/RecentClips/2026-11-08_20-01-00/2026-11-08_20-01-00-back.mp4": "/media/RecentClips/2026-11-08_20-01-00/2026-11-08_20-01-00-back.mp4?livefile=480p"}}"#

    // MARK: Export

    /// `POST /api/export/burn`
    static let exportStarted = #"{"ok": true, "id": "2026-11-08_19-43-36-ex482913"}"#
    static let burnFontRefusal = #"{"ok": false, "error": "设备缺少中文字体, 水印烧不进去: 请先点「安装字体」(约 17MB) 再导出, 或取消勾选水印直接导出视频"}"#
    static let burnFFmpegRefusal = #"{"ok": false, "error": "设备上没有 ffmpeg, 无法生成 mp4"}"#
    static let burnEventMissing = #"{"ok": false, "error": "事件不存在"}"#
    static let burnNothingToExport = #"{"ok": false, "error": "没有可导出的片段"}"#
    static let burnBusy = #"{"ok": false, "error": "已有导出/合成任务在进行, 请等它完成"}"#
    static let burnLowMemory = #"{"ok": false, "error": "设备可用内存不足(38MB), 稍后再试"}"#
    static let burnTooBig = #"{"ok": false, "error": "请求体过大 (上限 1MB)"}"#

    /// `GET /api/stitch/status?id=…`
    static let stitchDone = #"{"state": "done", "pct": 100, "err": "", "size": 1048576}"#
    static let stitchFailed = #"{"state": "error", "pct": 0, "err": "转码超时", "size": 0}"#
    /// Answered with 404 once the job expired or was downloaded.
    static let stitchGone = #"{"state": "error", "err": "任务不存在或已过期"}"#

    static func stitchRunning(percent: Int) -> String {
        #"{"state": "running", "pct": \#(percent), "err": "", "size": 0}"#
    }

    /// `GET /api/export/burn/dl` when the transcode did not work: 503, plain text.
    static let qualityUnavailable = "所选画质暂不可用"
}
