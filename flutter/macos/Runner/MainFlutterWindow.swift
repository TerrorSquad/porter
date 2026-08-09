import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  /// Set by Dart whenever a transfer starts or finishes, so the close button
  /// can ask for confirmation without a round trip while the window is
  /// closing (windowShouldClose must answer synchronously).
  private var transferInProgress = false

  /// True while the confirmation sheet is up, so a second close attempt
  /// doesn't stack another sheet.
  private var askingToClose = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerSecureBookmarksChannel(flutterViewController)
    registerTransferStateChannel(flutterViewController)

    self.delegate = self

    super.awakeFromNib()
  }

  /// Confirms before closing mid-transfer. A large transfer is hours of
  /// scanning; recovered blocks are on disk, but the un-peeled symbol pool
  /// is lost, so quitting by accident is expensive.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard transferInProgress, !askingToClose else { return true }

    askingToClose = true
    let alert = NSAlert()
    alert.messageText = "A transfer is still in progress"
    alert.informativeText =
      "Blocks already decoded are saved and will resume next time, but symbols "
      + "collected in memory will be lost. Quit anyway?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Keep Scanning")

    alert.beginSheetModal(for: self) { response in
      self.askingToClose = false
      if response == .alertFirstButtonReturn {
        self.transferInProgress = false
        self.close()
      }
    }
    return false
  }

  /// Dart reports whether a transfer is active; see `windowShouldClose`.
  private func registerTransferStateChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "porter/window",
      binaryMessenger: controller.engine.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setTransferInProgress":
        let args = call.arguments as? [String: Any]
        self?.transferInProgress = (args?["inProgress"] as? Bool) ?? false
        result(nil)
      default:
        result(FlutterError(code: "unimplemented", message: nil, details: nil))
      }
    }
  }

  /// Lets the user-selected output directory survive across app launches.
  ///
  /// A plain path picked via `file_picker` only stays writable for the rest
  /// of this process; on the next launch the sandbox no longer grants
  /// access to it. Security-scoped bookmarks let us persist that grant: the
  /// Dart side creates a bookmark right after the user picks a directory
  /// (while the picker's grant is still active), then resolves it and
  /// starts accessing it again on every app start.
  private func registerSecureBookmarksChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "porter/secure_bookmarks",
      binaryMessenger: controller.engine.binaryMessenger)

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "createBookmark":
        guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
        else {
          result(FlutterError(code: "bad_args", message: "Missing path", details: nil))
          return
        }

        do {
          let data = try URL(fileURLWithPath: path).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
          result(data.base64EncodedString())
        } catch {
          result(
            FlutterError(
              code: "bookmark_failed", message: error.localizedDescription, details: nil))
        }

      case "resolveBookmark":
        guard let args = call.arguments as? [String: Any],
          let bookmark = args["bookmark"] as? String,
          let data = Data(base64Encoded: bookmark)
        else {
          result(FlutterError(code: "bad_args", message: "Missing bookmark", details: nil))
          return
        }

        do {
          var isStale = false
          let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)

          _ = url.startAccessingSecurityScopedResource()

          var refreshedBookmark: String? = nil
          if isStale {
            refreshedBookmark = try? url.bookmarkData(
              options: .withSecurityScope,
              includingResourceValuesForKeys: nil,
              relativeTo: nil
            ).base64EncodedString()
          }

          result([
            "path": url.path,
            "refreshedBookmark": refreshedBookmark as Any,
          ])
        } catch {
          result(
            FlutterError(
              code: "resolve_failed", message: error.localizedDescription, details: nil))
        }

      default:
        result(FlutterError(code: "unimplemented", message: nil, details: nil))
      }
    }
  }
}
