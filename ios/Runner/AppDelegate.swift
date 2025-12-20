import UIKit
import Flutter
import AVKit
import AVFoundation

// AVPlayer VC that reports position/rate on real dismissal & owns observers safely.
class ReportingAVPlayerViewController: AVPlayerViewController {
  // Bridge back to Flutter
  var channel: FlutterMethodChannel?

  // Track PiP state without relying on unavailable APIs on older SDKs
  var pipActive: Bool = false

  // Playback intent & seek bookkeeping
  var desiredRate: Float = 1.0                 // last non-zero rate we should keep
  var programmaticSeekInFlight: Bool = false   // true while our skip/seek is running
  var wasPlayingRecentlyAt: Date?              // for user scrubs auto-resume heuristic

  // Mark that the item reached end (used to decide PiP restore behavior)
  var didReachEnd: Bool = false

  // KVO & notifications
  var statusObserver: NSKeyValueObservation?
  var rateObserver: NSKeyValueObservation?
  var timeObserverToken: Any?
  var endObserver: NSObjectProtocol?
  var timeJumpObserver: NSObjectProtocol?
  var stalledObserver: NSObjectProtocol?

  deinit {
    // Remove periodic time observer to avoid leaks
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
    // Invalidate KVO if still active
    statusObserver?.invalidate(); statusObserver = nil
    rateObserver?.invalidate();   rateObserver   = nil
    // Remove playback-end/timejump/stalled observers if set
    if let eo = endObserver { NotificationCenter.default.removeObserver(eo); endObserver = nil }
    if let tj = timeJumpObserver { NotificationCenter.default.removeObserver(tj); timeJumpObserver = nil }
    if let st = stalledObserver { NotificationCenter.default.removeObserver(st); stalledObserver = nil }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)

    // If PiP is active, this is not a real dismissal of playback UI.
    if pipActive { return }

    // Only report dismissal if the controller is actually going away.
    let actuallyDismissing = self.isBeingDismissed || self.view.window == nil
    guard actuallyDismissing, let player = self.player else { return }

    let pos = CMTimeGetSeconds(player.currentTime())
    let rate = Double(player.rate)
    let wasPlaying = player.rate > 0
    channel?.invokeMethod("ios_player_dismissed", arguments: [
      "position": pos,
      "rate": rate,
      "wasPlaying": wasPlaying
    ])
  }

  // Prefer landscape; allow portrait too (prevents orientation glitches)
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    return [.landscapeLeft, .landscapeRight, .portrait]
  }

  // Hide home indicator while playing
  override var prefersHomeIndicatorAutoHidden: Bool { true }
}

@main
@objc class AppDelegate: FlutterAppDelegate, AVPlayerViewControllerDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Configure audio session for video playback (enables background/PiP audio)
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("AVAudioSession error: \(error)")
    }

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    let channel = FlutterMethodChannel(
      name: "native_ios_player",
      binaryMessenger: controller.binaryMessenger
    )

    // Handle "present" method to open native AVPlayer.
    channel.setMethodCallHandler { (call, result) in
      guard call.method == "present",
            let args = call.arguments as? [String: Any],
            let urlStr = args["url"] as? String,
            let url = URL(string: urlStr) else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing url", details: nil))
        return
      }

      // Initial state coming from Flutter
      let pos = (args["position"] as? Double) ?? 0.0
      let rate = (args["rate"] as? Double) ?? 1.0
      let title = (args["title"] as? String) ?? ""
      let openingStart = args["openingStart"] as? Double
      let openingEnd   = args["openingEnd"]   as? Double
      let endingStart  = args["endingStart"]  as? Double
      let endingEnd    = args["endingEnd"]    as? Double
      let wasPlaying   = (args["wasPlaying"] as? Bool) ?? true

      // Build player & item
      let item = AVPlayerItem(url: url)
      let player = AVPlayer(playerItem: item)

      // Prefer brief stalls over "catch-up" jumps that look like random skips
      player.automaticallyWaitsToMinimizeStalling = false

      // Configure view controller
      let vc = ReportingAVPlayerViewController()
      vc.player = player
      vc.title = title
      vc.modalPresentationStyle = .fullScreen
      vc.channel = channel
      vc.delegate = self

      // Enable PiP
      vc.allowsPictureInPicturePlayback = true
      if #available(iOS 14.0, *) {
        vc.canStartPictureInPictureAutomaticallyFromInline = true
      }

      // Auto fullscreen begin/end (fine for a modal VC)
      vc.entersFullScreenWhenPlaybackBegins = true
      vc.exitsFullScreenWhenPlaybackEnds = true

      // Track last non-zero rate to preserve playback intent
      vc.desiredRate = Float(rate)
      vc.rateObserver = player.observe(\.rate, options: [.new, .initial]) { [weak vc] p, _ in
        guard let vc = vc else { return }
        if p.rate > 0 {
          vc.desiredRate = p.rate
          vc.wasPlayingRecentlyAt = Date()
        }
      }

      // Auto-skip opening/ending via periodic time observer (with resume)
      var didSkipOpening = false
      var didSkipEnding = false
      vc.timeObserverToken = player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
        queue: .main
      ) { [weak vc] time in
        guard let vc = vc else { return }
        let sec = CMTimeGetSeconds(time)

        func seekAndResume(to seconds: Double) {
          vc.programmaticSeekInFlight = true
          let target = CMTime(seconds: seconds, preferredTimescale: 600)
          let rateToUse = (vc.player?.rate ?? 0) > 0 ? (vc.player?.rate ?? vc.desiredRate) : vc.desiredRate
          vc.player?.seek(
            to: target,
            toleranceBefore: .zero,
            toleranceAfter: .zero
          ) { _ in
            vc.programmaticSeekInFlight = false
            if rateToUse > 0 {
              vc.player?.playImmediately(atRate: rateToUse)
            }
          }
        }

        if let s = openingStart, let e = openingEnd, !didSkipOpening, sec >= s && sec <= s + 5.0 {
          didSkipOpening = true
          seekAndResume(to: e)
        }
        if let s = endingStart, let e = endingEnd, !didSkipEnding, sec >= s && sec <= s + 5.0 {
          didSkipEnding = true
          seekAndResume(to: e)
        }
      }

      // User scrubbing auto-resume (ignore our own seeks).
      vc.timeJumpObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemTimeJumped,
        object: item,
        queue: .main
      ) { [weak vc] _ in
        guard let vc = vc else { return }
        if vc.programmaticSeekInFlight { return }
        if let last = vc.wasPlayingRecentlyAt, Date().timeIntervalSince(last) < 1.0 {
          if vc.desiredRate > 0 {
            vc.player?.playImmediately(atRate: vc.desiredRate)
          }
        }
      }

      // Resume after stalls if user intended to play
      vc.stalledObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemPlaybackStalled,
        object: item,
        queue: .main
      ) { [weak vc] _ in
        guard let vc = vc else { return }
        if vc.desiredRate > 0 {
          vc.player?.playImmediately(atRate: vc.desiredRate)
        }
      }

      // Notify Flutter when playback completes (including PiP case).
      vc.endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak vc] _ in
        guard let vc = vc else { return }

        vc.didReachEnd = true

        // Send final position & duration back to Flutter
        let pos = CMTimeGetSeconds(vc.player?.currentTime() ?? .zero)
        let dur = CMTimeGetSeconds(vc.player?.currentItem?.duration ?? .zero)
        vc.channel?.invokeMethod("ios_player_completed", arguments: [
          "position": pos,
          "duration": dur
        ])

        // If VC is still presented (not auto-dismissed by PiP), dismiss it.
        if vc.presentingViewController != nil {
          vc.dismiss(animated: true, completion: nil)
        }
      }

      // Present native player
      controller.present(vc, animated: true) {
        // Seek & play with the desired rate when ready
        let startPlayback = {
          if pos > 0 {
            vc.programmaticSeekInFlight = true
            player.seek(
              to: CMTime(seconds: pos, preferredTimescale: 600),
              toleranceBefore: .zero,
              toleranceAfter: .zero
            ) { _ in
              vc.programmaticSeekInFlight = false
              if wasPlaying { player.playImmediately(atRate: Float(rate)) }
            }
          } else {
            if wasPlaying { player.playImmediately(atRate: Float(rate)) }
          }
        }

        // Start after item becomes ready (guard against early seeking)
        if item.status == .readyToPlay {
          startPlayback()
        } else {
          vc.statusObserver = item.observe(\.status, options: [.new, .initial]) { observedItem, _ in
            if observedItem.status == .readyToPlay {
              startPlayback()
              vc.statusObserver?.invalidate(); vc.statusObserver = nil
            }
          }
        }
      }

      result(nil)
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - AVPlayerViewControllerDelegate (PiP behavior)

  /// Let the system automatically dismiss the full-screen player when PiP starts.
  func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
    if let vc = playerViewController as? ReportingAVPlayerViewController {
      vc.pipActive = true
    }
    return true
  }

  func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    (playerViewController as? ReportingAVPlayerViewController)?.pipActive = true
  }

  func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    (playerViewController as? ReportingAVPlayerViewController)?.pipActive = true
  }

  func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    (playerViewController as? ReportingAVPlayerViewController)?.pipActive = false
  }

  func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    (playerViewController as? ReportingAVPlayerViewController)?.pipActive = false
  }

  /// When the user exits PiP, restore the native player UI unless the item has already completed.
  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    // If we already completed while in PiP, do NOT re-present the native player.
    if let rvc = playerViewController as? ReportingAVPlayerViewController, rvc.didReachEnd {
      completionHandler(true)
      return
    }

    // If already presented, nothing to do.
    if playerViewController.presentingViewController != nil {
      completionHandler(true)
      return
    }

    // Present the same native player VC back on top of Flutter.
    guard let root = self.window?.rootViewController else {
      completionHandler(false); return
    }

    root.present(playerViewController, animated: true) {
      // Send a lightweight "PiP restored" signal so Flutter can persist progress.
      if let rvc = playerViewController as? ReportingAVPlayerViewController {
        let pos = CMTimeGetSeconds(rvc.player?.currentTime() ?? .zero)
        let dur = CMTimeGetSeconds(rvc.player?.currentItem?.duration ?? .zero)
        let rate = Double(rvc.player?.rate ?? 0)
        rvc.channel?.invokeMethod("ios_pip_restored", arguments: [
          "position": pos,
          "duration": dur,
          "rate": rate
        ])
      }
      completionHandler(true)
    }
  }
}
