// Cast — one-time M1 development-token migration into Keychain.
import Foundation

public enum GatewayConfigLoader {
    /// Resolution order: CAST_GATEWAY_TOKEN env → $HOME/.openclaw/openclaw.json.
    /// Simulator development should use CAST_GATEWAY_TOKEN because its $HOME is
    /// the app container, not the host Mac's home directory.
    public static func discoverLocalToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CAST_GATEWAY_TOKEN"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".openclaw/openclaw.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let gateway = json["gateway"] as? [String: Any],
                  let auth = gateway["auth"] as? [String: Any],
                  let token = auth["token"] as? String,
                  !token.isEmpty
            else { continue }
            return token
        }
        return nil
    }
}
