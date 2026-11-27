import Foundation
import HermesKit

extension MonitoringConnectionCheck {
    var statsSummary: String {
        switch mode {
        case .live:
            statsString("Ready. The app updates live and falls back to a snapshot every 10 seconds if the stream drops.")
        case .polling:
            statsString("Snapshot and requests work. Live updates don't, so the app will read a snapshot every 10 seconds.")
        case .unusable:
            !snapshot.isOK
                ? statsString("The snapshot check failed. Fix that before saving.")
                : statsString("The requests check failed. Fix that before saving.")
        }
    }
}

extension MonitoringCheckStep {
    var statsDetail: String? {
        guard state != .ok else { return nil }
        if state == .timedOut { return statsError(MonitoringClientFailure.timedOut) }
        return statsErrorText(detail ?? "")
    }
}

/// Translate feature-owned errors at the App boundary; core wire/error semantics stay unchanged.
func statsError(_ error: any Error) -> String {
    if let error = error as? MonitoringAddressError {
        switch error {
        case .blank: return statsString("Enter the monitor service's address.")
        case .unsupportedScheme(let scheme): return statsString("Use an http or https address, not “\(scheme)”.")
        case .credentialsInURL: return statsString("Remove credentials from the address. Put a Bearer token in the token field.")
        case .queryInURL: return statsString("Use the service's root address without a query. Secrets don't belong in a URL.")
        case .fragmentInURL: return statsString("Use the service's root address without a #fragment.")
        case .missingHost: return statsString("That address has no server name.")
        case .malformed: return statsString("That isn't a valid address.")
        }
    }
    if let error = error as? MonitoringSettingsProblem {
        switch error {
        case .address(let address): return statsError(address)
        case .tokenMissing: return statsString("Enter the access token, or choose No Authentication.")
        }
    }
    if let error = error as? MonitoringClientFailure {
        switch error {
        case .unauthorized(let status):
            return status == 403
                ? statsString("The monitor service refused this device (403). Check the token and the service's access rules, or choose No Authentication.")
                : statsString("The monitor service didn't accept the access token (401). Check the token, or choose No Authentication.")
        case .refused: return statsString("The monitor service refused the request.")
        case .missingEndpoint: return statsString("The monitor service has no monitoring API at that address. Check that it's the service's root address.")
        case .redirected: return statsString("The monitor service redirected to another address. Enter that address directly; the app never sends a token to a redirect's target.")
        case .server(let status, _): return statsString("The monitor service answered \(status). Try again in a moment.")
        case .notMonitoringService: return statsString("That address isn't a monitor service. Check the address.")
        case .incompatible(let contract): return statsError(contract)
        case .timedOut: return statsString("The monitor service didn't answer in time. A timeout doesn't prove the token is wrong: check the address and the network.")
        case .secureConnection: return statsString("The secure connection failed. Check the service's certificate and the address.")
        case .unreachable: return statsString("Can't reach the monitor service. Check the address and the network.")
        case .transport(let domain, let code): return statsString("The connection to the monitor service failed (\(domain) \(code)).")
        case .connectionFailed: return statsString("The connection to the monitor service failed.")
        case .streamEnded: return statsString("The live update stream ended.")
        }
    }
    if let error = error as? MonitoringContractError {
        switch error {
        case .notJSON: return statsString("That address answered, but not with monitoring data.")
        case .legacyPayload: return statsString("This monitor service doesn't support Xunxin-only statistics. Update the monitor service.")
        case .unsupportedSchema(let version): return statsString("This monitor service speaks contract \(version), which this app doesn't know. Update Hermes or the monitor service.")
        case .wrongScope(let scope): return statsString("That service answered for “\(scope)”, not the Xunxin scope. The app won't show global statistics as Xunxin's.")
        case .malformed(let detail): return statsString("The monitor service answered in a way this app doesn't understand (\(detail)).")
        }
    }
    let problem = error as NSError
    return statsString("The operation failed (\(problem.domain) \(problem.code)). Check the connection and try again.")
}

/// Session/check APIs expose descriptions. Match known feature errors without translating
/// arbitrary service output, and give a scoped instruction for an unrecognized description.
func statsErrorText(_ text: String) -> String {
    let failures: [MonitoringClientFailure] = [
        .unauthorized(401), .unauthorized(403), .refused(nil), .missingEndpoint(nil),
        .redirected(302), .notMonitoringService, .timedOut, .secureConnection,
        .unreachable, .connectionFailed, .streamEnded,
        .incompatible(.notJSON), .incompatible(.legacyPayload)
    ]
    if let failure = failures.first(where: { $0.errorDescription == text }) { return statsError(failure) }
    if text == "The check was cancelled." { return statsString("The check was cancelled.") }
    if text == "Live updates are off for this connection." { return statsString("Live updates are off for this connection.") }
    return statsString("The check failed. Verify the service address, access token and monitoring contract, then try again.")
}
