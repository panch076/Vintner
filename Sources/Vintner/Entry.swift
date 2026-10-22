import Foundation

@main
enum Main {
    static func main() {
        raiseFileDescriptorLimit()
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "--run" {
            runHeadless(bottlePath: args[2], file: args[3], arguments: Array(args.dropFirst(4)))
        }
        #if DEBUG
        if args.count >= 3, args[1] == "--snapshot" {
            MainActor.assumeIsolated { Snapshot.run(into: URL(fileURLWithPath: args[2])) }
        }
        #endif
        if args.count >= 2, args[1] == "--selftest" {
            MainActor.assumeIsolated { SelfTest.start() }
        }
        VintnerApp.main()
    }

    /// `Vintner --run <bottle folder> <file> [args…]` — used by generated launcher apps.
    /// Prepares the prefix and then exec()s Wine so no extra process stays around.
    private static func runHeadless(bottlePath: String, file: String, arguments: [String]) -> Never {
        let bottleURL = URL(fileURLWithPath: bottlePath, isDirectory: true)
        guard let meta = BottleMetadata.load(from: bottleURL) else {
            fputs("Vintner: no bottle at \(bottlePath)\n", stderr)
            exit(1)
        }
        guard FileManager.default.isExecutableFile(atPath: Paths.wineBin.path) else {
            fputs("Vintner: the Wine runtime is not installed. Open Vintner.app once to install it.\n", stderr)
            exit(1)
        }
        let fileURL = URL(fileURLWithPath: file)
        Wine.prepareForLaunch(bottleURL: bottleURL, settings: meta.settings)
        let env = Wine.environment(bottleURL: bottleURL, settings: meta.settings, logDirectory: Paths.logs)
        FileManager.default.changeCurrentDirectoryPath(fileURL.deletingLastPathComponent().path)

        let argv = [Paths.wineBin.path] + Wine.launchArguments(for: fileURL, arguments: arguments)
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(Paths.wineBin.path, &cArgs, &cEnv)
        perror("Vintner: execve")
        exit(127)
    }
}
