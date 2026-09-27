import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screen capture, with two independent paths because **both of them are
/// flaky, in different ways, at different times.**
///
/// Measured on one machine on one day:
///
/// - In the morning, every `screencapture -R` region capture failed with
///   "could not create image from rect" — including a trivially on-screen rect
///   — while ScreenCaptureKit worked and full-screen `screencapture` worked.
///   It had worked the previous evening with no code change in between.
/// - In the afternoon, exactly the inverse: ScreenCaptureKit wedged and never
///   returned, while `screencapture` worked fine. It stayed wedged after the
///   Dock menu that triggered it was long closed.
///
/// So neither is trusted alone. SCK is tried first because it can filter to a
/// single window and does not light the purple recording indicator, and
/// `screencapture` is the fallback because it is a subprocess, which means it
/// can be given a deadline and actually killed. A blocked in-process C call
/// cannot be — Swift's cooperative cancellation has nothing to cancel.
///
/// `CGWindowListCreateImage` is not a third option: deprecated in macOS 14 and
/// obsoleted in the 15 SDK, where it no longer compiles.
public enum Capture {

    public enum CaptureError: Error, CustomStringConvertible {
        case screenRecordingDenied
        case noDisplay
        case windowNotShareable(CGWindowID)
        case captureFailed(String)
        case timedOut(TimeInterval)
        case encodeFailed

        public var description: String {
            switch self {
            case .screenRecordingDenied:
                return "Screen Recording permission is not granted"
            case .noDisplay:
                return "no display available to capture"
            case .windowNotShareable(let id):
                return "window \(id) is not shareable (it may have closed, or be on another Space)"
            case .captureFailed(let why):
                return "capture failed: \(why)"
            case .timedOut(let seconds):
                return "capture did not return within \(seconds)s (a context menu is open, or the capture stack has wedged)"
            case .encodeFailed:
                return "could not encode the captured image"
            }
        }
    }

    /// How the pixel-to-point scale was determined, carried in the result.
    ///
    /// Recorded rather than assumed because it is the number that turns a
    /// screenshot coordinate back into a click coordinate, and getting it from
    /// the wrong place is how a click ends up a fifth of the way across the
    /// screen. In a HiDPI "scaled" display mode the ratio is *not* the backing
    /// scale factor, so the measured ratio wins and says so.
    public enum ScaleSource: String, Sendable {
        case measured        // delivered pixels / requested points — always right
        case assumedOne      // nothing else available
    }

    /// Which path produced an image. Recorded because they fail independently.
    public enum Path: String, Sendable {
        case screenCaptureKit
        case screencaptureCLI
    }

    public struct Shot: Sendable {
        public let image: CGImage
        /// The rect in screen points this image covers.
        public let rect: CGRect
        public let scale: CGFloat
        public let scaleSource: ScaleSource
        public let path: Path

        public init(image: CGImage, rect: CGRect, scale: CGFloat, scaleSource: ScaleSource,
                    path: Path = .screenCaptureKit) {
            self.image = image
            self.rect = rect
            self.scale = scale
            self.scaleSource = scaleSource
            self.path = path
        }

        /// Map a pixel in this image back to a screen point.
        ///
        /// Divides by the *delivered* image size rather than by an assumed
        /// scale factor, so any downscale cancels out.
        public func screenPoint(fromPixel p: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + p.x / CGFloat(image.width) * rect.width,
                y: rect.minY + p.y / CGFloat(image.height) * rect.height
            )
        }

        /// Map a normalised (0..1, top-left origin) point back to a screen point.
        public func screenPoint(fromNormalized p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
    }

    /// How long any single capture may take before it is abandoned.
    ///
    /// ScreenCaptureKit can simply never return. Two ways to reach that, both
    /// seen on this machine: a Dock or context menu is open, which runs a nested
    /// event-tracking loop the capture waits behind forever; and the capture
    /// stack wedging on its own, staying wedged after the menu is long gone.
    ///
    /// A verification primitive that can hang is worse than one that fails,
    /// because the caller has no way to tell "still working" from "never coming
    /// back". Timing out turns it into an honest `unknown`.
    nonisolated(unsafe) public static var timeout: TimeInterval = 5

    /// A value the compiler cannot prove Sendable, carried across a task
    /// boundary anyway. ScreenCaptureKit's content, filter and configuration
    /// objects are created here, handed to one detached task, and never touched
    /// again from anywhere else, which is the property Sendable is checking for.
    private final class Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Resumes a continuation exactly once, whoever gets there first.
    ///
    /// Needed because two independent tasks race to answer, and resuming a
    /// continuation twice is undefined behaviour, not a caught error.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func settle(_ result: Result<T, Error>, _ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { continuation.resume(with: result) }
        }
    }

    /// Run a capture with a deadline that is actually enforced.
    ///
    /// The obvious implementation — a throwing task group with a sleeping
    /// sibling — does not work, and quietly. A task group does not return until
    /// **every** child has finished, and ScreenCaptureKit does not honour
    /// cancellation, so when SCK wedges the deadline fires, the error is
    /// produced, `cancelAll()` is called, and then the group sits waiting for a
    /// child that is never coming back. The timeout appears to exist and does
    /// nothing.
    ///
    /// That is not theoretical. Two `macctl` processes were found alive after
    /// three and a half hours, both blocked exactly here, both with a five
    /// second deadline configured.
    ///
    /// So the work runs detached and is deliberately **not** awaited. A wedged
    /// SCK task leaks its thread for the life of the process, which is the
    /// honest trade: the process is a short-lived CLI that will exit in
    /// milliseconds, and leaking a thread we cannot reclaim is strictly better
    /// than blocking a caller forever on it.
    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do { gate.settle(.success(try await body()), continuation) }
                catch { gate.settle(.failure(error), continuation) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                gate.settle(.failure(CaptureError.timedOut(seconds)), continuation)
            }
        }
    }

    public static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Pixels per point on the display that shows `rect`.
    ///
    /// Read from the display mode rather than assumed to be two: a HiDPI
    /// "scaled" resolution, an external 1x monitor and a Sidecar iPad all give
    /// different answers, and the answer decides how many pixels Vision gets to
    /// read. `CGDisplayPixelsWide` is not the same number — on a Retina display
    /// it reports points.
    static func displayScale(covering rect: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        var id = CGMainDisplayID()
        if CGGetDisplaysWithRect(rect, UInt32(ids.count), &ids, &count) == .success, count > 0 {
            id = ids[0]
        }
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await withTimeout(timeout) {
            Unchecked(try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
        }.value
    }

    private static func screenshot(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async throws -> CGImage {
        let request = Unchecked((filter: filter, config: config))
        return try await withTimeout(timeout) {
            try await SCScreenshotManager.captureImage(contentFilter: request.value.filter,
                                                       configuration: request.value.config)
        }
    }

    /// Capture one window by id, cropped to `region` if given (screen points).
    public static func window(_ windowID: CGWindowID, region: CGRect? = nil) async throws -> Shot {
        guard isScreenRecordingGranted else { throw CaptureError.screenRecordingDenied }

        let content = try await shareableContent()
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotShareable(windowID)
        }

        let frame = scWindow.frame
        let scale = displayScale(covering: frame)
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await screenshot(SCContentFilter(desktopIndependentWindow: scWindow), config)
        let full = Shot(
            image: image,
            rect: frame,
            scale: CGFloat(image.width) / max(frame.width, 1),
            scaleSource: .measured
        )
        guard let region else { return full }
        return try crop(full, to: region)
    }

    /// Capture one window, trying ScreenCaptureKit and falling back to the CLI.
    ///
    /// A missing permission is reported as such and never worked around:
    /// `screencapture` without Screen Recording access produces the wallpaper
    /// with no windows on it, which OCR reads as "nothing on screen".
    ///
    /// A region that cannot be cut from the fallback shot is a failure, not a
    /// whole-window shot. Widening the search silently would let a
    /// `--region` check match text outside the region and report satisfied.
    public static func windowResilient(_ windowID: CGWindowID, rect: CGRect, region: CGRect? = nil) async -> Result<Shot, Error> {
        guard isScreenRecordingGranted else { return .failure(CaptureError.screenRecordingDenied) }
        do {
            return .success(try await window(windowID, region: region))
        } catch {
            do {
                let shot = try await viaCLI(windowID: windowID, rect: rect, deadline: timeout)
                guard let region else { return .success(shot) }
                return .success(try crop(shot, to: region))
            } catch let fallbackError {
                return .failure(fallbackError)
            }
        }
    }

    /// Capture the whole main display, cropped to `region` if given.
    ///
    /// Anything that is not inside the target app's window — a system dialog, a
    /// Screen Time shield, the Dock — has to be found this way. Mapping such a
    /// thing through the app's window rect is how an unclickable dialog looks
    /// like a modal-blocking-input problem when it is really a coordinate bug.
    ///
    /// "The screen" is the main display, the one with the menu bar, on every
    /// path: here, in the `screencapture` fallback, and in the Dock code. A
    /// second display must not change what the word means.
    public static func screen(region: CGRect? = nil) async throws -> Shot {
        guard isScreenRecordingGranted else { throw CaptureError.screenRecordingDenied }

        let content = try await shareableContent()
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
        else { throw CaptureError.noDisplay }

        let rect = CGDisplayBounds(display.displayID)
        let scale = displayScale(covering: rect)
        let config = SCStreamConfiguration()
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await screenshot(SCContentFilter(display: display, excludingWindows: []), config)
        let full = Shot(
            image: image,
            rect: rect,
            scale: CGFloat(image.width) / max(rect.width, 1),
            scaleSource: .measured
        )
        guard let region else { return full }
        return try crop(full, to: region)
    }

    /// Capture through the `screencapture` CLI, with a deadline we can enforce.
    ///
    /// This exists because it is a *subprocess*: when it wedges we can kill it.
    /// That is the whole reason it is here rather than a second in-process API.
    /// With no window id it captures the main display only (`-m`), so that a
    /// second display cannot change what "the screen" means.
    public static func viaCLI(windowID: CGWindowID?, rect: CGRect, deadline: TimeInterval) async throws -> Shot {
        guard isScreenRecordingGranted else { throw CaptureError.screenRecordingDenied }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macctl-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        var arguments = ["-x", "-t", "png"]
        if let windowID {
            // -l captures one window by id, and -o drops its shadow.
            arguments += ["-l\(windowID)", "-o"]
        } else {
            arguments.append("-m")
        }
        arguments.append(path.path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()

        let expiry = Date().addingTimeInterval(deadline)
        while process.isRunning, Date() < expiry {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 200_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw CaptureError.timedOut(deadline)
        }
        guard process.terminationStatus == 0,
              let source = CGImageSourceCreateWithURL(path as CFURL, nil)
        else { throw CaptureError.captureFailed("screencapture produced no image") }

        // Decode NOW, into memory. `CGImageSourceCreateImageAtIndex` hands back
        // an image that is lazily backed by the file, and the `defer` above
        // deletes that file the moment this function returns. Without
        // ShouldCacheImmediately the image silently becomes empty: the capture
        // "succeeds", OCR finds nothing, and the caller concludes the thing it
        // was looking for is not on screen. That cost an hour of chasing a Dock
        // menu that was open and readable the whole time.
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { throw CaptureError.captureFailed("screencapture produced an unreadable image") }

        return Shot(image: image, rect: rect,
                    scale: CGFloat(image.width) / max(rect.width, 1),
                    scaleSource: .measured, path: .screencaptureCLI)
    }

    /// Crop a shot to a screen-point rect, in pixel space.
    ///
    /// The region is first clipped to what was actually captured, and the rect
    /// of the result is derived from the pixels actually cut. `CGImage.cropping`
    /// silently intersects with the image bounds, so a region hanging off the
    /// edge of the window would otherwise come back as a smaller image labelled
    /// with the full requested rect, and every point read from it would be
    /// scaled wrong.
    public static func crop(_ shot: Shot, to region: CGRect) throws -> Shot {
        let visible = region.intersection(shot.rect)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            throw CaptureError.captureFailed("region \(region) lies outside the captured area \(shot.rect)")
        }
        let sx = CGFloat(shot.image.width) / shot.rect.width
        let sy = CGFloat(shot.image.height) / shot.rect.height
        let pixels = CGRect(
            x: (visible.minX - shot.rect.minX) * sx,
            y: (visible.minY - shot.rect.minY) * sy,
            width: visible.width * sx,
            height: visible.height * sy
        ).integral
        guard let cropped = shot.image.cropping(to: pixels) else {
            throw CaptureError.captureFailed("region \(region) is outside the captured area")
        }
        let covered = CGRect(
            x: shot.rect.minX + pixels.minX / sx,
            y: shot.rect.minY + pixels.minY / sy,
            width: CGFloat(cropped.width) / sx,
            height: CGFloat(cropped.height) / sy
        )
        return Shot(image: cropped, rect: covered, scale: sx, scaleSource: .measured, path: shot.path)
    }

    /// Write a shot to a PNG.
    public static func writePNG(_ shot: Shot, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw CaptureError.encodeFailed }
        CGImageDestinationAddImage(dest, shot.image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.encodeFailed }
    }
}
