import UIKit
import Flutter
import AVKit

// AVPlayer VC that reports position/rate on dismiss & owns observers.
class ReportingAVPlayerViewController: AVPlayerViewController {
  var channel: FlutterMethodChannel?
  var statusObserver: NSKeyValueObservation?
  var timeObserverToken: Any?

  deinit {
    // Clean up observers if anything survives to deinit.
    statusObserver?.invalidate()
    if let token = timeObserverToken {
      player?.removeTimeObserver(token)
      timeObserverToken = nil
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Send final position/rate back when user closes the controller.
    guard let player = self.player else { return }
    let pos = CMTimeGetSeconds(player.currentTime())
    let rate = Double(player.rate)
    let wasPlaying = player.rate > 0
    channel?.invokeMethod("ios_player_dismissed", arguments: [
      "position": pos,
      "rate": rate,
      "wasPlaying": wasPlaying
    ])
    // Remove periodic time observer to avoid leaks.
    if let token = timeObserverToken {
      player.removeTimeObserver(token)
      timeObserverToken = nil
    }
    // Invalidate KVO if still active.
    statusObserver?.invalidate()
    statusObserver = nil
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "native_ios_player", binaryMessenger: controller.binaryMessenger)

    // Handle "present" method to open native AVPlayer.
    channel.setMethodCallHandler { (call, result) in
      guard call.method == "present",
            let args = call.arguments as? [String: Any],
            let urlStr = args["url"] as? String,
            let url = URL(string: urlStr)
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing url", details: nil))
        return
      }

      let pos = (args["position"] as? Double) ?? 0.0
      let rate = (args["rate"] as? Double) ?? 1.0
      let title = (args["title"] as? String) ?? ""

      // Optional auto-skip ranges
      let openingStart = args["openingStart"] as? Double
      let openingEnd   = args["openingEnd"]   as? Double
      let endingStart  = args["endingStart"]  as? Double
      let endingEnd    = args["endingEnd"]    as? Double
      let wasPlaying   = (args["wasPlaying"] as? Bool) ?? true

      let item = AVPlayerItem(url: url)
      let player = AVPlayer(playerItem: item)
      player.automaticallyWaitsToMinimizeStalling = true

      let vc = ReportingAVPlayerViewController()
      vc.player = player
      vc.title = title
      vc.modalPresentationStyle = .fullScreen
      vc.channel = channel

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

      // Notify Flutter when playback completes AND auto-dismiss the native VC.
      NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak vc] _ in
        // Dismiss the native player automatically.
        vc?.dismiss(animated: true, completion: {
          // Tell Flutter that the item completed. Dart side will continue flow (next ep, etc.)
          channel.invokeMethod("ios_player_completed", arguments: nil)
        })
      }

      controller.present(vc, animated: true) {
        // Helper: seek & play with the desired rate.
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

        // Start after item becomes ready. Use KVO and retain it in the VC.
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
}
