import Foundation
import Testing
@testable import DMXCore

struct DockerProxyResponseTests {
    @Test func refusalFinishesHTTP10ResponseWithoutDockerdOrTeardown() async throws {
        var client: [Int32] = [0, 0], server: [Int32] = [0, 0]
        let first = socketpair(AF_UNIX, SOCK_STREAM, 0, &client)
        try #require(first == 0)
        let second = socketpair(AF_UNIX, SOCK_STREAM, 0, &server)
        guard second == 0 else { client.forEach { Darwin.close($0) }; throw DMXError("test_socket", "socketpair failed") }
        let localClient = client[0], localServer = server[0], remoteClient = client[1], remoteServer = server[1]
        defer { Darwin.close(localClient); Darwin.close(localServer); Darwin.close(remoteServer) }
        let proxy = DockerProxy(client: localClient, server: localServer) { _ in .refuse("port already in use") }
        let forwarding = Task { await proxy.run() }
        let stream = DockerStream(fd: remoteClient, timeoutSeconds: 1) { Darwin.close(remoteClient) }
        defer { stream.close() }
        let api = DockerAPI { stream }
        let started = ContinuousClock.now
        let (code, body) = try await api.call("POST", "/containers/probe/start")
        #expect(code == 500)
        #expect(String(decoding: body, as: UTF8.self).contains("port already in use"))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(fcntl(remoteServer, F_GETFD) >= 0)
        await forwarding.value
    }
}
