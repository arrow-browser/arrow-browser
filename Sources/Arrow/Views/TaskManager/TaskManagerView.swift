import AppKit
import Darwin
import SwiftUI

/// Help ▸ Troubleshooting ▸ Open Task Manager: Arrow's processes (browser,
/// GPU, network, renderers…) with their memory and CPU use.
@MainActor
@Observable
final class TaskManagerModel {
    struct Row: Identifiable, Hashable {
        let id: pid_t
        let task: String
        let memory: UInt64
        let cpu: Double
    }

    private(set) var rows: [Row] = []
    @ObservationIgnored private var cpuTimes: [pid_t: (time: UInt64, at: UInt64)] = [:]
    @ObservationIgnored private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Ends a helper process; a renderer's tabs then show their crash page.
    func end(_ id: pid_t) {
        guard id != getpid() else { return }
        kill(id, SIGTERM)
        refresh()
    }

    private func refresh() {
        let browser = getpid()
        let now = mach_absolute_time()
        var seen: [pid_t: (time: UInt64, at: UInt64)] = [:]
        rows = ([browser] + Self.children(of: browser)).compactMap { pid in
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { return nil }
            let time = usage.ri_user_time + usage.ri_system_time
            seen[pid] = (time, now)
            var cpu = 0.0
            if let previous = cpuTimes[pid], now > previous.at {
                cpu = Double(time - min(time, previous.time)) / Double(now - previous.at) * 100
            }
            return Row(id: pid, task: pid == browser ? "Browser" : Self.task(of: pid), memory: usage.ri_phys_footprint, cpu: cpu)
        }
        .sorted { ($0.id == browser ? 1 : 0, $0.memory) > ($1.id == browser ? 1 : 0, $1.memory) }
        cpuTimes = seen
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        let count = proc_listchildpids(parent, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 8)
        let filled = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    /// Chromium's name for a helper, from its `--type` and `--utility-sub-type` switches.
    private static func task(of pid: pid_t) -> String {
        let arguments = Self.arguments(of: pid)
        func value(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        switch value("type") {
        case "renderer":
            return arguments.contains("--extension-process") ? "Extension" : "Renderer"
        case "gpu-process": return "GPU Process"
        case "utility":
            switch value("utility-sub-type") {
            case "network.mojom.NetworkService": return "Network Service"
            case "storage.mojom.StorageService": return "Storage Service"
            case "audio.mojom.AudioService": return "Audio Service"
            case let service?: return "Utility: \(service.split(separator: ".").last.map(String.init) ?? service)"
            case nil: return "Utility"
            }
        case let type?: return type.capitalized
        case nil: return "Helper"
        }
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        // argc, then the executable path and the arguments, NUL-separated.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return Array(strings.dropFirst().prefix(Int(argc)))
    }
}

struct TaskManagerView: View {
    @State private var model = TaskManagerModel()
    @State private var selection: pid_t?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Table(model.rows, selection: $selection) {
                TableColumn("Task", value: \.task)
                TableColumn("Memory footprint") { row in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(row.memory), countStyle: .memory)).monospacedDigit()
                }
                TableColumn("CPU") { row in
                    Text(row.cpu, format: .number.precision(.fractionLength(1))).monospacedDigit()
                }
                .width(60)
                TableColumn("Process ID") { row in
                    Text(String(row.id)).monospacedDigit()
                }
                .width(80)
            }
            Button("End Process") {
                if let selection { model.end(selection) }
            }
            .disabled(selection == nil || selection == getpid())
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 320)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
