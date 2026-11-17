import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case status
    case statistics
    case log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "状態"
        case .statistics: "統計"
        case .log: "エラーログ"
        }
    }

    var symbolName: String {
        switch self {
        case .status: "network"
        case .statistics: "chart.bar.xaxis"
        case .log: "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @Environment(NetworkMonitor.self) private var monitor
    @State private var selection: SidebarItem? = .status

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("モニタ") {
                    ForEach(SidebarItem.allCases) { item in
                        NavigationLink(value: item) {
                            HStack {
                                Label(item.title, systemImage: item.symbolName)
                                if item == .status, let status = monitor.status {
                                    Spacer()
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(status.color)
                                        .accessibilityLabel(status.label)
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            switch selection ?? .status {
            case .status: StatusView()
            case .statistics: StatisticsView()
            case .log: LogView()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .alert("エラー", isPresented: Binding(get: { monitor.persistenceError != nil },
                                            set: { if !$0 { monitor.persistenceError = nil } })) {
            Button("OK") { monitor.persistenceError = nil }
        } message: {
            Text(monitor.persistenceError ?? "")
        }
    }
}
