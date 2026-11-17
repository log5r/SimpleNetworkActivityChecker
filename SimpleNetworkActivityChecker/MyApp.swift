import AppKit
import OSLog
import SwiftData
import SwiftUI

enum MainWindow {
    static let id = "main"
}

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor: NetworkMonitor
    private let container: ModelContainer

    /// 単体テストのホストとして起動されたか。その場合は実際の記録に触れないよう、メモリ上のストアを使い監視も始めない。
    private static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        AppSettings.registerDefaults()
        let (container, error) = Self.makeContainer(inMemory: Self.isHostingUnitTests)
        self.container = container
        let monitor = NetworkMonitor(container: container)
        if let error {
            monitor.persistenceError = "記録用のデータベースを開けなかったため、今回の記録は保存されません。\n\(error.localizedDescription)"
        }
        _monitor = State(initialValue: monitor)
        // ウインドウの有無にかかわらず起動直後から監視を始める
        if !Self.isHostingUnitTests {
            Task { @MainActor in monitor.start() }
        }
    }

    var body: some Scene {
        Window("Simple Network Activity Checker", id: MainWindow.id) {
            ContentView()
                .environment(monitor)
        }
        .modelContainer(container)
        .commands {
            CommandMenu("ネットワーク") {
                Button("今すぐチェック") { monitor.checkNow() }
                    .keyboardShortcut("r")
                    .disabled(monitor.isChecking)
            }
        }

        Settings {
            SettingsView()
                .environment(monitor)
        }

        // メニューバーに常駐して接続状態を表示する
        MenuBarExtra {
            MenuBarContentView()
                .environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }

    private static func makeContainer(inMemory: Bool) -> (ModelContainer, Error?) {
        let schema = Schema([CheckRecord.self, ErrorLogEntry.self])
        do {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
            return (try ModelContainer(for: schema, configurations: configuration), nil)
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Storage")
                .error("Failed to open store: \(error.localizedDescription, privacy: .public)")
            // 保存できなくても監視自体は続けられるようにメモリ上のストアで起動する
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try! ModelContainer(for: schema, configurations: memory), error)
        }
    }
}

/// メニューバー常駐アプリとしての振る舞い（ウインドウを閉じても終了しない、Dock アイコンの表示切り替え）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                // ウインドウが実際に閉じられた後で判定する
                DispatchQueue.main.async { self?.updateActivationPolicy(excluding: closing) }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let window, self?.isRegularWindow(window) == true, NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
            }
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func isRegularWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
    }

    private func updateActivationPolicy(excluding closing: NSWindow?) {
        guard !AppSettings.showDockIconWhenClosed else { return }
        // Dock にしまわれた（最小化された）ウインドウは isVisible が false になるが、Dock アイコンが必要なので数える
        let hasOpenWindow = NSApp.windows.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized) && isRegularWindow($0)
        }
        if !hasOpenWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
