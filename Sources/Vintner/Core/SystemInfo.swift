import Foundation
import Metal

struct GPUInfo: Identifiable, Hashable {
    let name: String
    let lowPower: Bool
    let removable: Bool
    let headless: Bool
    let memoryMB: Int
    let supportsMoltenVK: Bool
    var id: String { name + (removable ? "-egpu" : "") }

    var kind: String {
        if removable { return "eGPU" }
        if lowPower { return "Integrated" }
        return "Discrete"
    }
}

struct SystemInfo {
    let osVersion: String
    let model: String
    let cpu: String
    let cores: Int
    let memoryGB: Int
    let isTranslated: Bool
    let hasAVX: Bool
    let hasAVX2: Bool
    let gpus: [GPUInfo]

    var canUseDXVK: Bool { gpus.contains { $0.supportsMoltenVK } }
    var supportsMetalHUD: Bool { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)) }

    static let current = SystemInfo.gather()

    static func gather() -> SystemInfo {
        let gpus = MTLCopyAllDevices().map { device in
            GPUInfo(name: device.name,
                    lowPower: device.isLowPower,
                    removable: device.isRemovable,
                    headless: device.isHeadless,
                    memoryMB: Int(device.recommendedMaxWorkingSetSize / 1_048_576),
                    supportsMoltenVK: device.supportsFamily(.mac2))
        }
        return SystemInfo(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            model: sysctlString("hw.model") ?? "Unknown",
            cpu: sysctlString("machdep.cpu.brand_string") ?? "Unknown",
            cores: ProcessInfo.processInfo.activeProcessorCount,
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            isTranslated: sysctlInt("sysctl.proc_translated") == 1,
            hasAVX: sysctlInt("hw.optional.avx1_0") == 1,
            hasAVX2: sysctlInt("hw.optional.avx2_0") == 1,
            gpus: gpus)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// Wine opens many files/sockets (one fd per mapped DLL, plus esync-like handles in some games).
/// macOS defaults the soft limit to 256; raise it to the kernel max so child processes inherit it.
func raiseFileDescriptorLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
    let target = min(limit.rlim_max, rlim_t(10_240)) // OPEN_MAX; setrlimit rejects RLIM_INFINITY here
    if limit.rlim_cur < target {
        limit.rlim_cur = target
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}
