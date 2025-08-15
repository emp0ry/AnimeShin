import UIKit
import Flutter
import AVKit

// Subclass to report dismissal back to Flutter with current position & rate.
class ReportingAVPlayerViewController: AVPlayerViewController {
  var channel: FlutterMethodChannel?
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard let player = self.player else { return }
    let pos = CMTimeGetSeconds(player.currentTime())
    let rate = Double(player.rate)
    let wasPlaying = player.rate > 0
    channel?.invokeMethod("ios_player_dismissed", arguments: [
      "position": pos,
      "rate": rate,
      "wasPlaying": wasPlaying
    ])
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

      // Auto-skip helper
      var didSkipOpening = false
      var didSkipEnding = false
      let timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
        let sec = CMTimeGetSeconds(time)
        if let s = openingStart, let e = openingEnd, !didSkipOpening, sec >= s && sec <= s + 5.0 {
          didSkipOpening = true
          player.seek(to: CMTime(seconds: e, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if let s = endingStart, let e = endingEnd, !didSkipEnding, sec >= s && sec <= s + 5.0 {
          didSkipEnding = true
          player.seek(to: CMTime(seconds: e, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
      }

      // Completion -> notify Flutter and let the controller close when user taps Done.
      NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
        channel.invokeMethod("ios_player_completed", arguments: nil)
      }

      controller.present(vc, animated: true) {
        // Seek after ready to avoid starting from zero.
        if item.status == .readyToPlay {
          if pos > 0 {
            player.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
              if wasPlaying { player.playImmediately(atRate: Float(rate)) }
            }
          } else {
            if wasPlaying { player.playImmediately(atRate: Float(rate)) }
          }
        } else {
          item.addObserver(forKeyPath: "status", options: .new, context: nil)
          // Simple KVO via closure:
          item.observe(\.status, options: .new) { item, _ in
            if item.status == .readyToPlay {
              if pos > 0 {
                player.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                  if wasPlaying { player.playImmediately(atRate: Float(rate)) }
                }
              } else {
                if wasPlaying { player.playImmediately(atRate: Float(rate)) }
              }
            }
          }
        }
      }

      result(nil)

      // Cleanup when dismissed (ReportingAVPlayerViewController handles callback).
      // Here we only ensure the timeObserver is removed to prevent leaks.
      vc.presentationController?.delegate = DismissHandler {
        player.removeTimeObserver(timeObserver)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// Helper to run a closure on dismissal.
class DismissHandler: NSObject, UIAdaptivePresentationControllerDelegate {
  let onDismiss: () -> Void
  init(_ onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    onDismiss()
  }
}
