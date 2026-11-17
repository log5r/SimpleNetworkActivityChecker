import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// システムからネットワーク構成情報を読み取る。
nonisolated enum NetworkInfoProvider {
    struct HardwareInterface {
        var bsdName: String
        var displayName: String
        var kind: InterfaceKind
        var linkActive: Bool
    }

    struct LinkState {
        var snapshot: NetworkSnapshot
        /// 物理的に接続されたインターフェースが存在するか
        var hasActiveLink: Bool
        /// Wi‑Fi の電源状態（Wi‑Fi ハードウェアがない場合は nil）
        var wifiPowerOn: Bool?
        var hardwareInterfaces: [HardwareInterface]
    }

    static func currentState() -> LinkState {
        let store = SCDynamicStoreCreate(nil, "SimpleNetworkActivityChecker" as CFString, nil, nil)

        func value(_ key: String) -> [String: Any]? {
            guard let store else { return nil }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }

        let globalIPv4 = value("State:/Network/Global/IPv4")
        let globalIPv6 = value("State:/Network/Global/IPv6")
        let globalDNS = value("State:/Network/Global/DNS")

        let hardware = hardwareInterfaces { name in
            (value("State:/Network/Interface/\(name)/Link")?["Active"] as? Bool) ?? false
        }

        // 優先インターフェース。グローバル情報がない場合はリンクが有効なハードウェアから選ぶ。
        let primaryName = (globalIPv4?["PrimaryInterface"] as? String)
            ?? (globalIPv6?["PrimaryInterface"] as? String)
            ?? hardware.first(where: { $0.linkActive && $0.kind == .ethernet })?.bsdName
            ?? hardware.first(where: { $0.linkActive })?.bsdName

        var snapshot = NetworkSnapshot()
        snapshot.interfaceName = primaryName
        snapshot.router = (globalIPv4?["Router"] as? String) ?? (globalIPv6?["Router"] as? String)
        snapshot.dnsServers = (globalDNS?["ServerAddresses"] as? [String]) ?? []

        if let primaryName {
            if let hw = hardware.first(where: { $0.bsdName == primaryName }) {
                snapshot.interfaceDisplayName = hw.displayName
                snapshot.interfaceKind = hw.kind
            } else if primaryName.hasPrefix("utun") || primaryName.hasPrefix("ipsec") || primaryName.hasPrefix("ppp") {
                snapshot.interfaceDisplayName = "VPN"
            }
            let addresses = interfaceAddresses(for: primaryName)
            snapshot.ipv4Addresses = addresses.ipv4
            snapshot.ipv6Addresses = addresses.ipv6
            snapshot.subnetMasks = addresses.netmasks
        }

        // Wi‑Fi 情報（信号強度などは位置情報の許可なしで取得可能）
        var wifiPowerOn: Bool?
        let client = CWWiFiClient.shared()
        if let wifi = client.interface() {
            wifiPowerOn = wifi.powerOn()
            if snapshot.interfaceKind == .wifi || snapshot.interfaceName == nil {
                let rssi = wifi.rssiValue()
                if rssi != 0 { snapshot.wifiRSSI = rssi }
                let noise = wifi.noiseMeasurement()
                if noise != 0 { snapshot.wifiNoise = noise }
                let rate = wifi.transmitRate()
                if rate > 0 { snapshot.wifiTransmitRate = rate }
            }
        }

        let hasActiveLink: Bool = {
            guard let primaryName else { return false }
            if let hw = hardware.first(where: { $0.bsdName == primaryName }) {
                // リンク状態を読めない環境もあるため、アドレスがあれば接続済みとみなす
                return hw.linkActive || !snapshot.ipv4Addresses.isEmpty || !snapshot.globalIPv6Addresses.isEmpty
            }
            return true // VPN など物理インターフェース以外
        }()

        return LinkState(snapshot: snapshot, hasActiveLink: hasActiveLink, wifiPowerOn: wifiPowerOn, hardwareInterfaces: hardware)
    }

    private static func hardwareInterfaces(linkActive: (String) -> Bool) -> [HardwareInterface] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return all.compactMap { iface -> HardwareInterface? in
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { return nil }
            let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            let kind: InterfaceKind = switch type {
            case String(kSCNetworkInterfaceTypeIEEE80211): .wifi
            case String(kSCNetworkInterfaceTypeEthernet): .ethernet
            case String(kSCNetworkInterfaceTypeWWAN): .cellular
            default: .other
            }
            // ブリッジや Thunderbolt などは診断対象から外す
            guard kind != .other else { return nil }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? bsd
            return HardwareInterface(bsdName: bsd, displayName: name, kind: kind, linkActive: linkActive(bsd))
        }
    }

    private static func interfaceAddresses(for name: String) -> (ipv4: [String], ipv6: [String], netmasks: [String]) {
        var ipv4: [String] = []
        var ipv6: [String] = []
        var netmasks: [String] = []

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return ([], [], []) }
        defer { freeifaddrs(ifap) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard String(cString: ifa.ifa_name) == name,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  let addr = ifa.ifa_addr else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                if let host = numericHost(addr) { ipv4.append(host) }
                if let mask = ifa.ifa_netmask, let host = numericHost(mask) { netmasks.append(host) }
            case AF_INET6:
                if let host = numericHost(addr) {
                    ipv6.append(host.split(separator: "%").first.map(String.init) ?? host)
                }
            default:
                break
            }
        }
        return (ipv4, ipv6, netmasks)
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(addr.pointee.sa_len == 0 ? UInt8(MemoryLayout<sockaddr_in>.size) : addr.pointee.sa_len)
        guard getnameinfo(addr, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }
}
