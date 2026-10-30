import Foundation

public enum PSNCallback {
    public enum Failure: Error { case invalid, missingState, stateMismatch, missingCode, provider(String) }
    public static let scheme = "com.scee.psxandroid.scecompcall"
    public static let redirect = scheme + "://redirect"

    public static func code(from url: URL, expectedState: String) throws -> String {
        guard !expectedState.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == "redirect",
              parts.user == nil, parts.password == nil, parts.port == nil,
              (parts.path.isEmpty || parts.path == "/"), parts.fragment == nil,
              let query = parts.queryItems else { throw Failure.invalid }
        if let error = query.first(where: { $0.name == "error" })?.value {
            let known = ["login_required", "access_denied", "invalid_request", "invalid_scope", "invalid_client", "unsupported_response_type"]
            throw Failure.provider(known.contains(error) ? error : "unknown")
        }
        let states = query.filter { $0.name == "state" }
        let codes = query.filter { $0.name == "code" }
        guard states.count == 1 else { throw Failure.missingState }
        guard states[0].value == expectedState else { throw Failure.stateMismatch }
        guard codes.count == 1, let code = codes[0].value,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.missingCode }
        return code
    }

    public static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}
