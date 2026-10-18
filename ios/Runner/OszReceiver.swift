import Flutter
import UIKit

/// Receives `.osz` files opened with / shared to the app. Each one is copied
/// into Documents/Inbox — the folder the library screen lists as pending
/// imports — and Dart is told over the `osuedit/incoming` channel.
///
/// Registered as an in-app plugin for scene life-cycle events (see
/// AppDelegate), which is how Flutter forwards `scene(_:openURLContexts:)`
/// and the launch URLs of `scene(_:willConnectTo:options:)`.
class OszReceiver: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private let channel: FlutterMethodChannel

  // Files that arrive before Dart listens (launch URLs) are announced in the
  // reply to its "ready" call instead of being lost.
  private var dartReady = false
  private var unannounced = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "osuedit/incoming", binaryMessenger: registrar.messenger())
    let receiver = OszReceiver(channel: channel)
    registrar.addMethodCallDelegate(receiver, channel: channel)
    registrar.addSceneDelegate(receiver)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "ready" {
      dartReady = true
      result(unannounced)
      unannounced = false
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  private func announce() {
    if dartReady {
      channel.invokeMethod("changed", arguments: nil)
    } else {
      unannounced = true
    }
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts, !contexts.isEmpty else { return false }
    return receive(contexts)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return receive(URLContexts)
  }

  private func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {
    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
    let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
    var handled = false
    for context in contexts {
      let url = context.url
      let ext = url.pathExtension.lowercased()
      // Beatmap sets and skins (.osk); Dart tells them apart by extension.
      guard url.isFileURL, ext == "osz" || ext == "osk" else { continue }
      handled = true
      // iOS already copied it into our Inbox: nothing to do.
      if url.deletingLastPathComponent().standardizedFileURL == inbox.standardizedFileURL { continue }
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        var target = inbox.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
          target = inbox.appendingPathComponent("\(stem) (\(n)).\(ext)")
          n += 1
        }
        try fm.copyItem(at: url, to: target)
      } catch {
        NSLog("osuEdit: could not receive \(url): \(error)")
      }
    }
    if handled { announce() }
    return handled
  }
}
