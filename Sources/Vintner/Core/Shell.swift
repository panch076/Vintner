import Foundation

enum ShellError: LocalizedError {
    case failed(String, Int32)
    var errorDescription: String? {
        switch self {
        case let .failed(what, code): return "\(what) failed (exit code \(code))."
        }
    }
}

enum Shell {
    /// Runs a process to completion without blocking a thread. Output goes to `output` (a file
    /// handle) or is discarded. We deliberately never use pipes for Wine: wineserver inherits
    /// stdout/stderr and keeps them open long after the child exits, so reading a pipe to EOF
    /// would hang.
    @discardableResult
    static func run(_ executable: URL,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil,
                    output: FileHandle? = nil) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a short-lived tool and returns its combined output (only for tools that don't spawn daemons).
    static func capture(_ executable: URL, _ arguments: [String]) async throws -> (Int32, String) {
        let tmp = Paths.cache.appendingPathComponent("capture-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let handle = try FileHandle(forWritingTo: tmp)
        let status = try await run(executable, arguments, output: handle)
        try? handle.close()
        let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        return (status, text)
    }
}
