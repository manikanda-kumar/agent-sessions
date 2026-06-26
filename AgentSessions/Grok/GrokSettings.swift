import Foundation
import SwiftUI

@MainActor
final class GrokSettings: ObservableObject {
    static let shared = GrokSettings()

    enum Keys {
        static let binaryPath = "GrokBinaryPath"
        static let resolvedBinaryPath = "GrokResolvedBinaryPath"
        static let resolvedSupportsResume = "GrokResolvedSupportsResume"
        static let preferITerm = "GrokPreferITerm"
        static let defaultWorkingDirectory = "GrokDefaultWorkingDirectory"
    }

    @Published var binaryPath: String
    @Published var resolvedBinaryPath: String
    @Published var resolvedSupportsResume: Bool
    @Published var preferITerm: Bool
    @Published var defaultWorkingDirectory: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard, warmResolvedBinaryCache: Bool = true) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        resolvedBinaryPath = defaults.string(forKey: Keys.resolvedBinaryPath) ?? ""
        resolvedSupportsResume = defaults.bool(forKey: Keys.resolvedSupportsResume)
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
        if warmResolvedBinaryCache {
            warmResolvedBinaryPathIfNeeded()
        }
    }

    func setBinaryPath(_ path: String) {
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setResolvedBinaryPath(nil)
            warmResolvedBinaryPathIfNeeded()
        }
    }

    func setResolvedBinaryPath(_ path: String?) {
        let value = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedBinaryPath = value
        resolvedSupportsResume = !value.isEmpty
        defaults.set(value, forKey: Keys.resolvedBinaryPath)
        defaults.set(resolvedSupportsResume, forKey: Keys.resolvedSupportsResume)
    }

    func setPreferITerm(_ value: Bool) {
        preferITerm = value
        defaults.set(value, forKey: Keys.preferITerm)
    }

    func setDefaultWorkingDirectory(_ path: String) {
        defaultWorkingDirectory = path
        defaults.set(path, forKey: Keys.defaultWorkingDirectory)
    }

    func effectiveWorkingDirectory(for session: Session) -> URL? {
        if let sessionCwd = session.cwd, !sessionCwd.isEmpty {
            return URL(fileURLWithPath: sessionCwd)
        }
        if !defaultWorkingDirectory.isEmpty {
            return URL(fileURLWithPath: defaultWorkingDirectory)
        }
        return nil
    }

    private func warmResolvedBinaryPathIfNeeded() {
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let env = GrokCLIEnvironment()
            let result = env.probe(customPath: nil)
            if case let .success(resolved) = result {
                DispatchQueue.main.async { [weak self] in
                    self?.setResolvedBinaryPath(resolved.binaryURL.path)
                    self?.resolvedSupportsResume = resolved.supportsResume
                    self?.defaults.set(resolved.supportsResume, forKey: Keys.resolvedSupportsResume)
                }
            }
        }
    }
}

extension GrokSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "GrokTests") ?? .standard) -> GrokSettings {
        GrokSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}