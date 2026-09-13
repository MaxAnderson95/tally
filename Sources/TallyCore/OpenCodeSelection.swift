import Foundation

struct OpenCodeSelection: Sendable {
    var environment = ProcessInfo.processInfo.environment
    var home = FileManager.default.homeDirectoryForCurrentUser.path
    var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
        let session = URLSession(configuration: .ephemeral, delegate: SelectionRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Fault("opencode_unavailable", "OpenCode returned an invalid response.") }
        return (data, response)
    }

    func activate(_ credential: StoredCredential, databasePath: String) async throws {
        struct Registration: Decodable { var url: URL; var password: String }
        struct Configuration: Decodable { var env: [String: String]? }
        let state = environment["XDG_STATE_HOME"] ?? home + "/.local/state"
        let config = environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        let registration: Registration
        do {
            registration = try JSONDecoder().decode(Registration.self, from: Data(contentsOf: URL(fileURLWithPath: state + "/opencode/service.json")))
        } catch { throw Fault("opencode_unavailable", "Start the local OpenCode service before switching Accounts.") }
        var serviceEnvironment = environment
        let configURL = URL(fileURLWithPath: config + "/opencode/service.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
                serviceEnvironment.merge(configuration.env ?? [:]) { _, new in new }
            } catch { throw Fault("opencode_unavailable", "OpenCode's service configuration could not be read.") }
        }
        let expected = OpenCodeInventory.defaultPath(environment: serviceEnvironment, home: home)
        guard try OpenCodeInventory(path: expected).databaseIdentity() == OpenCodeInventory(path: databasePath).databaseIdentity() else {
            throw Fault("account_changed", "Tally must read the local OpenCode service's database to switch Accounts. Check the database path in Settings.")
        }
        guard registration.url.scheme == "http", let host = registration.url.host,
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host),
              registration.url.user == nil, registration.url.password == nil,
              registration.url.query == nil, registration.url.fragment == nil else {
            throw Fault("opencode_unavailable", "Account switching requires a local OpenCode service.")
        }
        func request(_ path: String, method: String = "GET") -> URLRequest {
            var request = URLRequest(url: registration.url.appendingPathComponent(path), timeoutInterval: 10)
            request.httpMethod = method
            request.setValue("Basic " + Data("opencode:\(registration.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            return request
        }
        // Verify the service knows this stored row before sending the explicit selection command.
        struct Integration: Decodable {
            var connections: [Connection]
            struct Connection: Decodable { var id: String }
        }
        struct IntegrationResponse: Decodable { var data: Integration }
        do {
            let (data, response) = try await send(request("api/integration/" + credential.provider))
            guard response.statusCode == 200,
                  try JSONDecoder().decode(IntegrationResponse.self, from: data).data.connections.contains(where: { $0.id == credential.storedID }) else {
                throw Fault("account_changed", "The Account is not available in the local OpenCode service. Refresh Accounts.")
            }
        } catch let fault as Fault { throw fault }
        catch { throw Fault("opencode_unavailable", "Cannot read Accounts from OpenCode. Check that its local service is running.") }
        do {
            let (_, response) = try await send(request("api/credential/" + credential.storedID + "/activate", method: "POST"))
            guard response.statusCode == 204 else {
                throw Fault("account_switch_unconfirmed", "OpenCode did not confirm the switch. Refresh Accounts before trying again.")
            }
        } catch let fault as Fault { throw fault }
        catch { throw Fault("account_switch_unconfirmed", "The switch response was lost. Refresh Accounts to check the selection before trying again.") }
    }
}

private final class SelectionRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
