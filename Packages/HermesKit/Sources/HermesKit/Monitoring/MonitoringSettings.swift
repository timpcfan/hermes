import Foundation

/// The app-wide monitoring connection (`PLAN.md`, "Settings → 监控服务 → 讯星链路"). It is
/// independent of every gateway and Bot profile: switching either never changes it.
public struct MonitoringSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var name: String
    /// The service's root address, as typed. Empty until someone sets it up: no localhost is
    /// assumed (on an iPhone it would point at the phone).
    public var baseURL: String
    public var auth: MonitoringAuthMode
    /// Live updates when the service speaks SSE. A saved polling-mode connection turns this off;
    /// an older settings file without the key means live.
    public var liveUpdates: Bool

    public static let initial = MonitoringSettings(
        enabled: false, name: "Xunxin monitor", baseURL: "", auth: .none
    )

    public init(
        enabled: Bool, name: String, baseURL: String, auth: MonitoringAuthMode, liveUpdates: Bool = true
    ) {
        self.enabled = enabled
        self.name = name
        self.baseURL = baseURL
        self.auth = auth
        self.liveUpdates = liveUpdates
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, name, baseURL, auth, liveUpdates
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        auth = try values.decode(MonitoringAuthMode.self, forKey: .auth)
        liveUpdates = try values.decodeIfPresent(Bool.self, forKey: .liveUpdates) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(name, forKey: .name)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(auth, forKey: .auth)
        try values.encode(liveUpdates, forKey: .liveUpdates)
    }

    /// A saved name never shows as blank.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Xunxin monitor" : trimmed
    }
}

public enum MonitoringAuthMode: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case none
    case bearer

    public var id: String { rawValue }
}

/// A validated service address. `token` only ever holds a Bearer token for a separately protected
/// deployment; the Hermes gateway's key is never sent here.
public struct MonitoringConnection: Sendable, Equatable {
    public let baseURL: URL
    public let token: String?

    public init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    public init(settings: MonitoringSettings, token: String?) throws {
        self = try MonitoringConnection(baseURLString: settings.baseURL,
                                        token: settings.auth == .bearer ? token : nil)
    }

    public init(baseURLString: String, token: String?) throws {
        baseURL = try MonitoringAddress.url(from: baseURLString)
        self.token = token?.isEmpty == true ? nil : token
    }

    /// `<base>/api/snapshot`, keeping any path prefix the service lives under.
    public func endpoint(_ path: String) -> URL {
        baseURL.appending(path: path)
    }
}

public enum MonitoringAddressError: Error, Equatable, Sendable, LocalizedError {
    case blank
    case unsupportedScheme(String)
    case credentialsInURL
    case queryInURL
    case fragmentInURL
    case missingHost
    case malformed

    public var errorDescription: String? {
        switch self {
        case .blank:
            "Enter the monitor service's address."
        case .unsupportedScheme(let scheme):
            "Use an http or https address, not “\(scheme)”."
        case .credentialsInURL:
            "Take the username and password out of the address. A Bearer token belongs in the token field."
        case .queryInURL:
            "Use the service's root address without a query. Secrets don't belong in a URL."
        case .fragmentInURL:
            "Use the service's root address without a #fragment."
        case .missingHost:
            "That address has no server name."
        case .malformed:
            "That isn't a valid address."
        }
    }
}

public enum MonitoringAddress {
    /// The address a person may save: http or https, a host, no embedded credentials, no query
    /// and no fragment. A path prefix is kept (a service behind `/monitor`), a trailing slash is
    /// dropped.
    public static func url(from text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MonitoringAddressError.blank }
        guard !trimmed.contains(where: \.isWhitespace), !trimmed.contains(where: \.isNewline) else {
            throw MonitoringAddressError.malformed
        }
        guard var components = URLComponents(string: trimmed) else { throw MonitoringAddressError.malformed }
        guard let scheme = components.scheme?.lowercased() else { throw MonitoringAddressError.malformed }
        guard scheme == "http" || scheme == "https" else {
            throw MonitoringAddressError.unsupportedScheme(scheme)
        }
        if components.user != nil || components.password != nil { throw MonitoringAddressError.credentialsInURL }
        if components.query != nil { throw MonitoringAddressError.queryInURL }
        if components.fragment != nil { throw MonitoringAddressError.fragmentInURL }
        guard let host = components.host, !host.isEmpty else { throw MonitoringAddressError.missingHost }
        components.scheme = scheme
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path == "/" ? "" : path
        guard let url = components.url else { throw MonitoringAddressError.malformed }
        return url
    }

    /// Whether the saved address is plain HTTP: true means data crosses the network unencrypted,
    /// which the settings screen says out loud. The app doesn't weaken ATS for it.
    public static func isPlainHTTP(_ text: String) -> Bool {
        (try? url(from: text))?.scheme?.lowercased() == "http"
    }
}

/// Why a draft can't be saved. Each case is the sentence the form shows under the field.
public enum MonitoringSettingsProblem: Error, Equatable, Sendable, LocalizedError {
    case address(MonitoringAddressError)
    case tokenMissing

    public var errorDescription: String? {
        switch self {
        case .address(let error): error.errorDescription
        case .tokenMissing: "Enter the access token, or choose No Authentication."
        }
    }
}

public enum MonitoringSettingsValidation {
    /// A disabled connection may be saved offline, with a blank address; a typed address still
    /// has to be valid, so nonsense never reaches the file. An enabled one needs an address, and
    /// a Bearer deployment needs a token (a newly typed one, or one already in the Keychain).
    public static func problem(
        _ settings: MonitoringSettings, typedToken: String?, hasStoredToken: Bool
    ) -> MonitoringSettingsProblem? {
        let url = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            return settings.enabled ? .address(.blank) : nil
        }
        do {
            _ = try MonitoringAddress.url(from: url)
        } catch let error as MonitoringAddressError {
            return .address(error)
        } catch {
            return .address(.malformed)
        }
        if settings.enabled, settings.auth == .bearer {
            let typed = typedToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if typed.isEmpty, !hasStoredToken { return .tokenMissing }
        }
        return nil
    }
}

/// Where the non-secret settings live: a JSON file in the app's own Application Support folder,
/// like the gateways' `bots.json`. The token lives beside it in the Keychain under its own
/// service, never in this file or in the gateway's key.
public struct MonitoringSettingsStore: Sendable {
    public let fileURL: URL
    public let keychain: KeychainStore
    public static let tokenAccount = "access-token"

    public init(fileURL: URL, keychain: KeychainStore) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    public static func standard() -> MonitoringSettingsStore {
        let bundle = Bundle.main.bundleIdentifier ?? HermesStorage.releaseBundleIdentifier
        return MonitoringSettingsStore(
            fileURL: HermesStorage.applicationSupport.appending(path: "monitoring.json"),
            keychain: KeychainStore(service: "\(bundle).monitoring")
        )
    }

    public func load() throws -> MonitoringSettings {
        try saved().settings
    }

    /// Saves the settings and, when `token` is given, the new token too. A failed save leaves the
    /// previous settings and token exactly as they were (`PLAN.md`: 保存失败保留输入与旧的有效配置).
    public func save(_ settings: MonitoringSettings, token: String?) throws {
        let previous = try saved()
        var account = previous.credentialAccount
        do {
            if let token, !token.isEmpty {
                // Never overwrite the effective item. A failed read must abort before staging.
                _ = try keychain.string(for: previous.credentialAccount ?? Self.tokenAccount)
                let staged = "monitoring-credential-\(UUID().uuidString)"
                account = staged
                try keychain.setString(token, for: staged)
            }
            try write(Saved(settings: settings, credentialAccount: account))
        } catch {
            if account != previous.credentialAccount, let account {
                do { try keychain.removeValue(for: account) }
                catch let cleanup {
                    throw MonitoringSettingsSaveFailure.cleanup(commit: error as NSError, cleanup: cleanup as NSError)
                }
            }
            throw error
        }
    }

    public func storedToken() throws -> String? {
        try keychain.string(for: saved().credentialAccount ?? Self.tokenAccount)
    }

    public func hasStoredToken() -> Bool {
        ((try? storedToken()) ?? nil)?.isEmpty == false
    }

    /// The file remains a flat settings object, with an additive, non-secret Keychain reference.
    /// Old files without the reference keep using access-token. Orphaned old items are retained:
    /// deleting them after commit would make an otherwise successful save partially fail.
    private struct Saved: Codable {
        var settings: MonitoringSettings
        var credentialAccount: String?

        enum CodingKeys: String, CodingKey { case credentialAccount }

        init(settings: MonitoringSettings, credentialAccount: String?) {
            self.settings = settings
            self.credentialAccount = credentialAccount
        }

        init(from decoder: any Decoder) throws {
            settings = try MonitoringSettings(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            credentialAccount = try values.decodeIfPresent(String.self, forKey: .credentialAccount)
            if let account = credentialAccount {
                let prefix = "monitoring-credential-"
                guard account.hasPrefix(prefix), UUID(uuidString: String(account.dropFirst(prefix.count))) != nil else {
                    throw DecodingError.dataCorruptedError(forKey: .credentialAccount, in: values, debugDescription: "Invalid monitoring credential reference")
                }
            }
        }

        func encode(to encoder: any Encoder) throws {
            try settings.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(credentialAccount, forKey: .credentialAccount)
        }
    }

    private func saved() throws -> Saved {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return Saved(settings: .initial, credentialAccount: nil)
        }
        return try JSONDecoder().decode(Saved.self, from: Data(contentsOf: fileURL))
    }

    private func write(_ settings: Saved) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(
            to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
