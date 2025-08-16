import UIKit
import Flutter
import AVKit
import AVFoundation

// AVPlayer VC that reports position/rate on real dismissal & owns observers safely.
class ReportingAVPlayerViewController: AVPlayerViewController {
  // Bridge back to Flutter
  var channel: FlutterMethodChannel?

  // KVO for item.status
  var statusObserver: NSKeyValueObservation?

  // Periodic time observer token
  var timeObserverToken: Any?

  // NotificationCenter observer for end-of-playback
  var endObserver: NSObjectProtocol?

  deinit {
    // Remove periodic time observer to avoid leaks
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
    // Invalidate KVO if still active
    statusObserver?.invalidate()
    statusObserver = nil
    // Remove playback-end observer if set
    if let eo = endObserver {
      NotificationCenter.default.removeObserver(eo)
      endObserver = nil
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)

    // Do NOT tell Flutter we were dismissed if PiP is currently active.
    if #available(iOS 14.0, *), self.isPictureInPictureActive {
      return
    }

    // Only report dismissal if the controller is actually going away.
    // This avoids spurious callbacks during transitions.
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
    channel.setMethodCallHandler { [weak self] (call, result) in
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

      // Optional: auto fullscreen begin/end (fine for a modal VC)
      vc.entersFullScreenWhenPlaybackBegins = true
      vc.exitsFullScreenWhenPlaybackEnds = true

      // Periodic observer for auto-skip opening/ending.
      var didSkipOpening = false
      var didSkipEnding = false
      vc.timeObserverToken = player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
        queue: .main
      ) { time in
        let sec = CMTimeGetSeconds(time)
        if let s = openingStart, let e = openingEnd, !didSkipOpening, sec >= s && sec <= s + 5.0 {
          didSkipOpening = true
          player.seek(
            to: CMTime(seconds: e, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
          )
        }
        if let s = endingStart, let e = endingEnd, !didSkipEnding, sec >= s && sec <= s + 5.0 {
          didSkipEnding = true
          player.seek(
            to: CMTime(seconds: e, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
          )
        }
      }

      // Notify Flutter when playback completes.
      // If PiP is active, do not dismiss VC here — let the system handle the UI.
      vc.endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak vc] _ in
        if #available(iOS 14.0, *), vc?.isPictureInPictureActive == true {
          channel.invokeMethod("ios_player_completed", arguments: nil)
        } else {
          vc?.dismiss(animated: true, completion: {
            channel.invokeMethod("ios_player_completed", arguments: nil)
          })
        }
      }

      // Present native player
      controller.present(vc, animated: true) {
        // Helper: seek & play with the desired rate when ready
        let startPlayback = {
          if pos > 0 {
            player.seek(
              to: CMTime(seconds: pos, preferredTimescale: 600),
              toleranceBefore: .zero,
              toleranceAfter: .zero
            ) { _ in
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
              vc.statusObserver?.invalidate()
              vc.statusObserver = nil
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
    return true
  }

  /// Restore the player UI when PiP stops (so the user lands back in the player).
  func playerViewController(
    _ playerViewController: AVPlayerViewController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    // If the player VC isn't visible anymore, present it back on the root.
    if let root = self.window?.rootViewController,
       playerViewController.presentingViewController == nil {
      root.present(playerViewController, animated: true) {
        completionHandler(true)
      }
    } else {
      completionHandler(true)
    }
  }

  func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
    // Optional: logging/analytics
  }

  func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
    // Optional: logging/analytics
  }
}
