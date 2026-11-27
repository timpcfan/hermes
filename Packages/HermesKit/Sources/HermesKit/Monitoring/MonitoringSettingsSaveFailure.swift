import Foundation

/// A failed settings commit with a failed cleanup of the unreferenced staged credential.
/// The previous settings and effective token remain selected; both failures stay observable.
public enum MonitoringSettingsSaveFailure: Error, LocalizedError {
    case cleanup(commit: NSError, cleanup: NSError)

    public var errorDescription: String? {
        switch self {
        case .cleanup(let commit, let cleanup):
            "The settings could not be saved (\(commit.domain) \(commit.code)); the unused credential could not be cleaned up (\(cleanup.domain) \(cleanup.code)). The previous configuration is still selected."
        }
    }
}
