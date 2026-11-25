import Foundation

struct DemoConfig: Decodable {
    let nosmaiAPIKey: String
    let tencentSDKAppID: UInt32
    let roomID: String

    static func load() -> Result<DemoConfig, ConfigError> {
        guard let url = Bundle.main.url(forResource: "Local", withExtension: "plist", subdirectory: "Configuration") else {
            return .failure(.init(message: "Copy Configuration/Example.plist to Configuration/Local.plist and configure the app."))
        }
        let config: DemoConfig
        do {
            let data = try Data(contentsOf: url)
            config = try PropertyListDecoder().decode(DemoConfig.self, from: data)
        } catch {
            return .failure(.init(message: "Check the fields and types in Configuration/Local.plist."))
        }
        guard config.tencentSDKAppID > 0 else {
            return .failure(.init(message: "Set tencentSDKAppID in Configuration/Local.plist."))
        }
        guard !config.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.init(message: "Set roomID in Configuration/Local.plist."))
        }
        return .success(config)
    }

    struct ConfigError: Error {
        let message: String
    }
}
