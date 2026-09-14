import Foundation

extension Fault {
    static func connection(_ error: any Error, provider: String) -> Fault {
        let reason: String
        // Error descriptions and userInfo can contain request URLs or credentials.
        switch (error as? URLError)?.code {
        case .notConnectedToInternet: reason = "This Mac is offline. Check its network connection."
        case .networkConnectionLost: reason = "The network connection was lost."
        case .timedOut: reason = "The request timed out."
        case .cannotFindHost, .dnsLookupFailed: reason = "The server address could not be resolved (DNS)."
        case .cannotConnectToHost: reason = "A connection to the server could not be established."
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            reason = "The secure connection failed. Check this Mac's clock and network settings."
        case .cancelled: reason = "The request was cancelled."
        default: reason = "The network request failed."
        }
        return Fault("provider_unavailable", "\(provider) could not be reached. \(reason)")
    }
}
