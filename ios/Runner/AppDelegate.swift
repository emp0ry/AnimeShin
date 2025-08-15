import UIKit
import Flutter
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var timeObserver: Any?
  private weak var presentedAVVC: AVPlayerViewController?
  private var openingStart: Double?
  private var openingEnd: Double?
  private var endingStart: Double?
  private var endingEnd: Double?
  private var didSkipOpening = false
  private var didSkipEnding = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "native_ios_player", binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self, weak controller] (call, result) in
      guard let self = self, let controller = controller else {
        result(FlutterError(code: "NO_CONTROLLER", message: "Root controller missing", details: nil))
        return
      }
      guard call.method == "present",
            let args = call.arguments as? [String: Any],
            let urlStr = args["url"] as? String,
            let url = URL(string: urlStr)
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing url", details: nil))
        return
      }

      // Read arguments
      let initialPos = (args["position"] as? Double) ?? 0.0
      let rate = (args["rate"] as? Double) ?? 1.0
      let title = (args["title"] as? String) ?? ""
      let wasPlaying = (args["wasPlaying"] as? Bool) ?? true

      // Opening/Ending ranges
      self.openingStart = args["openingStart"] as? Double
      self.openingEnd   = args["openingEnd"]   as? Double
      self.endingStart  = args["endingStart"]  as? Double
      self.endingEnd    = args["endingEnd"]    as? Double
      self.didSkipOpening = false
      self.didSkipEnding = false

      // Build player & controller
      let item = AVPlayerItem(url: url)
      let player = AVPlayer(playerItem: item)
      player.automaticallyWaitsToMinimizeStalling = true

      let vc = AVPlayerViewController()
      vc.player = player
      vc.title = title
      vc.modalPresentationStyle = .fullScreen
      self.presentedAVVC = vc

      // Observe completion -> tell Flutter to open next if needed.
      NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
        // Report completion back to Flutter.
        channel.invokeMethod("ios_player_completed", arguments: nil)
      }

      // Periodic time observer for local auto-skip & (optionally) metrics.
      self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
        guard let self = self else { return }
        let sec = CMTimeGetSeconds(time)

        // Auto-skip Opening (only once).
        if let s = self.openingStart, let e = self.openingEnd, !self.didSkipOpening {
          if sec >= s && sec <= s + 5.0 {
            self.didSkipOpening = true
            let to = CMTime(seconds: e, preferredTimescale: 600)
            player.seek(to: to, toleranceBefore: .zero, toleranceAfter: .zero)
          }
        }

        // Auto-skip Ending (only once).
        if let s = self.endingStart, let e = self.endingEnd, !self.didSkipEnding {
          if sec >= s && sec <= s + 5.0 {
            self.didSkipEnding = true
            let to = CMTime(seconds: e, preferredTimescale: 600)
            player.seek(to: to, toleranceBefore: .zero, toleranceAfter: .zero)
          }
        }
      }

      // Present controller, then seek AFTER item is ready to avoid restarting from 0.
      controller.present(vc, animated: true) {
        // Wait until the player item becomes ready.
        if item.status == .readyToPlay {
          if initialPos > 0 {
            let cm = CMTime(seconds: initialPos, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
              if wasPlaying { player.playImmediately(atRate: Float(rate)) }
            }
          } else {
            if wasPlaying { player.playImmediately(atRate: Float(rate)) }
          }
        } else {
          // KVO for readiness if not ready yet.
          item.addObserver(self, forKeyPath: "status", options: .new, context: nil)
          // Store a closure to run once ready
          objc_setAssociatedObject(item, &Self.readyKey, {
            if initialPos > 0 {
              let cm = CMTime(seconds: initialPos, preferredTimescale: 600)
              player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                if wasPlaying { player.playImmediately(atRate: Float(rate)) }
              }
            } else {
              if wasPlaying { player.playImmediately(atRate: Float(rate)) }
            }
          } as (() -> Void), .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
      }

      result(nil)
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // KVO support for item readiness.
  private static var readyKey = 0

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard keyPath == "status",
          let item = object as? AVPlayerItem
    else { return }

    if item.status == .readyToPlay {
      if let block = objc_getAssociatedObject(item, &Self.readyKey) as? (() -> Void) {
        block()
        objc_setAssociatedObject(item, &Self.readyKey, nil, .OBJC_ASSOCIATION_ASSIGN)
      }
      item.removeObserver(self, forKeyPath: "status")
    }
  }

  // When fullscreen controller is dismissed, report final position back to Flutter so it can sync.
  override func applicationWillResignActive(_ application: UIApplication) {
    reportDismissalIfNeeded()
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    reportDismissalIfNeeded()
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    reportDismissalIfNeeded()
  }

  private func reportDismissalIfNeeded() {
    guard let vc = presentedAVVC, let player = vc.player,
          let controller = window?.rootViewController as? FlutterViewController
    else { return }

    let channel = FlutterMethodChannel(name: "native_ios_player", binaryMessenger: controller.binaryMessenger)
    let pos = CMTimeGetSeconds(player.currentTime())
    let rate = Double(player.rate)
    let wasPlaying = player.rate > 0
    channel.invokeMethod("ios_player_dismissed", arguments: [
      "position": pos,
      "rate": rate,
      "wasPlaying": wasPlaying
    ])

    // Clean up observers
    if let obs = timeObserver {
      player.removeTimeObserver(obs)
      timeObserver = nil
    }
    presentedAVVC?.dismiss(animated: true, completion: nil)
    presentedAVVC = nil
  }
}
