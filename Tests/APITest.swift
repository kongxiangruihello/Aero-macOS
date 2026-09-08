import Foundation

@main
struct APITest {
    static func main() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let secretURL = home.appendingPathComponent("Library/Application Support/Aero/controller.secret")
        let secret = try String(contentsOf: secretURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var patch = URLRequest(url: URL(string: "http://127.0.0.1:19097/configs")!)
        patch.httpMethod = "PATCH"
        patch.httpBody = try JSONSerialization.data(withJSONObject: ["mixed-port": 17890])
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        patch.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: patch)
        print("PATCH", (response as? HTTPURLResponse)?.statusCode ?? -1)

        var get = URLRequest(url: URL(string: "http://127.0.0.1:19097/configs")!)
        get.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: get)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        print("mixed-port", json["mixed-port"] ?? "missing")
    }
}
