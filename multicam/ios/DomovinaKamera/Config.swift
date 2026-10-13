import Foundation
import Security
import UIKit

/// Where this phone connects and what it calls itself. Set once from the join URL
/// (`domovinacam://join?relay=…&room=…&key=…&name=…`, also the QR code) and kept.
struct RelayConfig: Equatable {
    var relay: URL
    var room: String
    var key: String
    var name: String

    /// Parses the join URL. Returns nil for anything that is not a complete join link.
    init?(joinURL url: URL, fallbackName: String) {
        guard url.scheme == "domovinacam", url.host == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let relayString = value("relay"), let relay = URL(string: relayString),
              let room = value("room"), let key = value("key") else { return nil }
        self.init(relay: relay, room: room, key: key, name: value("name") ?? fallbackName)
    }

    init(relay: URL, room: String, key: String, name: String) {
        self.relay = relay
        self.room = room
        self.key = key
        self.name = name
    }
}

enum ConfigStore {
    private static let defaults = UserDefaults.standard

    /// Generated once and never changed: the relay uses it to recognise a phone
    /// that reconnects, so it replaces its old socket instead of showing it twice.
    static var deviceID: String {
        if let id = defaults.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        return id
    }

    static var defaultName: String { DeviceInfo.modelIdentifier }

    static func load() -> RelayConfig? {
        guard let relay = defaults.url(forKey: "relay"),
              let room = defaults.string(forKey: "room"),
              let key = Keychain.read("relayKey") else { return nil }
        return RelayConfig(relay: relay, room: room, key: key,
                           name: defaults.string(forKey: "name") ?? defaultName)
    }

    static func save(_ config: RelayConfig) {
        defaults.set(config.relay, forKey: "relay")
        defaults.set(config.room, forKey: "room")
        defaults.set(config.name, forKey: "name")
        Keychain.write("relayKey", config.key)
    }
}

enum DeviceInfo {
    /// "iPhone13,1" rather than the marketing name, which iOS no longer exposes.
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var osVersion: String { UIDevice.current.systemVersion }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
    }

    static var freeBytes: Int64? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tv.domovina.multicam",
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Appends to Documents/app.log, which is reachable from the Files app and from
/// `devicectl device copy from`, so a run can be diagnosed without Xcode attached.
enum Log {
    private static let queue = DispatchQueue(label: "tv.domovina.multicam.log")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.log")
    private static let formatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("[multicam] %@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
