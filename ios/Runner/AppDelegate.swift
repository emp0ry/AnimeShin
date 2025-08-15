import UIKit
import Flutter
import AVKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "native_ios_player", binaryMessenger: controller.binaryMessenger)

    // Канал для открытия нативного AVPlayer
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

      let player = AVPlayer(url: url)
      if pos > 0 {
        let cm = CMTime(seconds: pos, preferredTimescale: 600)
        player.seek(to: cm)
      }
      player.rate = Float(rate)

      let vc = AVPlayerViewController()
      vc.player = player
      vc.modalPresentationStyle = .fullScreen

      controller.present(vc, animated: true) {
        player.play()
      }
      result(nil)
    }

    // Workmanager
    UIApplication.shared.setMinimumBackgroundFetchInterval(TimeInterval(60*15))

    // Flutter Local Notifications
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
