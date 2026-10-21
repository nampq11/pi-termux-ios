import Foundation
import NodeMobile
import os

/// Starts the embedded Node.js engine for the HTTP/SSE/WS bridge.
///
/// iOS apps cannot exec external binaries, so there is no `node` child
/// process: `server.mjs` runs inside the app process on a dedicated thread.
/// nodejs-mobile allows exactly one engine instance per process and it can
/// never be restarted — a crashed engine needs an app relaunch.
enum NodeEngine {

    private static let log = Logger(subsystem: "org.pimobile.app", category: "engine")

    private static func redirectOutput() {
        var p = [Int32](repeating: 0, count: 2)
        guard pipe(&p) == 0 else { return }
        dup2(p[1], STDOUT_FILENO)
        dup2(p[1], STDERR_FILENO)
        close(p[1])
        let readFd = p[0]
        let t = Thread {
            let handle = FileHandle(fileDescriptor: readFd)
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                if let str = String(data: data, encoding: .utf8) {
                    for line in str.split(separator: "\n") {
                        log.info("[Node] \(String(line), privacy: .public)")
                    }
                }
            }
        }
        t.name = "pi-node-stdout"
        t.start()
    }

    /// Launches the engine on its own thread. `node_start` blocks that thread
    /// for the lifetime of the script's event loop (i.e. forever for the
    /// bridge server) and returns only if Node exits.
    ///
    /// - Parameters:
    ///   - script: absolute path to `server.mjs`.
    ///   - environment: environment variables applied via `setenv` before the
    ///     engine starts (HOME, PI_WORKDIR, …).
    static func launch(script: String, environment: [String: String]) {
        redirectOutput()
        log.info("engine: launching node for \(script, privacy: .public)")
        environment.forEach { setenv($0.key, $0.value, 1) }
        let thread = Thread {
            let arguments = ["node", script]
            // libuv requires argv as one contiguous, NUL-separated block.
            let capacity = arguments.reduce(0) { $0 + $1.utf8.count + 1 }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
            defer { buffer.deallocate() }
            var argv = [UnsafeMutablePointer<CChar>?]()
            argv.reserveCapacity(arguments.count + 1)
            var offset = 0
            for argument in arguments {
                strncpy(buffer.assumingMemoryBound(to: CChar.self) + offset, argument, argument.utf8.count + 1)
                argv.append(buffer.assumingMemoryBound(to: CChar.self) + offset)
                offset += argument.utf8.count + 1
            }
            argv.append(nil)
            // V8 needs far more than the default thread stack (docs: >= 2 MB).
            _ = node_start(Int32(arguments.count), &argv)
            log.error("engine: node_start returned (engine exited)")
        }
        thread.stackSize = 8 << 20
        thread.name = "pi-node-engine"
        thread.start()
    }
}
