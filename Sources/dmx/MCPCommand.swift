import ArgumentParser
import DMXCore
import Foundation

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the Model Context Protocol on stdin and stdout, for AI clients.",
        discussion: """
            An MCP client starts this; it is not meant for a terminal. Tools: dmx_exec, dmx_status, \
            dmx_start, dmx_stop, dmx_config_get, dmx_config_set, the dmx_sandbox_* tools (create, \
            exec, list, rm, checkpoint, rollback, fork) and dmx_logs. The daemon and VM start on the \
            first call that needs them. Logs go to stderr. Register it with, for example, \
            `claude mcp add dmx -- dmx mcp`. See docs/mcp.md.
            """
    )

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
        await MCPServer(paths: Paths(), version: version).run()
    }
}
