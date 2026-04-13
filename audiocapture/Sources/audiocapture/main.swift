import AppKit
import Foundation

func printUsage() {
    let usage = """
    Usage: audiocapture [--list] [--app <bundleID>] [--pid <pid>] [--sample-rate <hz>]

    Capture per-app audio via Core Audio taps. Outputs 16kHz mono float32 PCM to stdout.

    Options:
      --list                List running apps that produce audio
      --app <bundleID>      Bundle ID of the app to capture (e.g. org.mozilla.firefox)
      --pid <pid>           Process ID to capture audio from
      --sample-rate <hz>    Output sample rate in Hz (default: 16000)
      --help                Show this help message

    Examples:
      audiocapture --list
      audiocapture --app org.mozilla.firefox | whisper-term --mic
      audiocapture --pid 12345 | whisper-term --timestamps
    """
    FileHandle.standardError.write(usage.data(using: .utf8)!)
}

func parseArgs() -> (list: Bool, app: String?, pid: pid_t?, sampleRate: Int) {
    let args = CommandLine.arguments
    var list = false
    var app: String? = nil
    var pid: pid_t? = nil
    var sampleRate = 16000
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--list":
            list = true
        case "--app":
            i += 1
            guard i < args.count else {
                FileHandle.standardError.write("Error: --app requires a value\n".data(using: .utf8)!)
                exit(1)
            }
            app = args[i]
        case "--pid":
            i += 1
            guard i < args.count, let p = Int32(args[i]) else {
                FileHandle.standardError.write("Error: --pid requires an integer value\n".data(using: .utf8)!)
                exit(1)
            }
            pid = p
        case "--sample-rate":
            i += 1
            guard i < args.count, let rate = Int(args[i]) else {
                FileHandle.standardError.write("Error: --sample-rate requires an integer value\n".data(using: .utf8)!)
                exit(1)
            }
            sampleRate = rate
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write("Unknown option: \(args[i])\n".data(using: .utf8)!)
            printUsage()
            exit(1)
        }
        i += 1
    }
    return (list, app, pid, sampleRate)
}

// Find PID by bundle ID using NSWorkspace
func findPID(bundleID: String) -> pid_t? {
    let apps = NSWorkspace.shared.runningApplications
    return apps.first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier
}

func listApps() {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
        .filter { $0.bundleIdentifier != nil }
        .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }

    for app in apps {
        let name = app.localizedName ?? "Unknown"
        let bid = app.bundleIdentifier ?? "?"
        let pid = app.processIdentifier
        print("\(pid)\t\(bid)\t\(name)")
    }
}

let parsed = parseArgs()

if parsed.list {
    listApps()
    exit(0)
}

var targetPID: pid_t

if let pid = parsed.pid {
    targetPID = pid
} else if let bundleID = parsed.app {
    guard let pid = findPID(bundleID: bundleID) else {
        FileHandle.standardError.write("App not found: \(bundleID)\nRun 'audiocapture --list' to see running apps.\n".data(using: .utf8)!)
        exit(1)
    }
    targetPID = pid
    FileHandle.standardError.write("Found \(bundleID) at PID \(pid)\n".data(using: .utf8)!)
} else {
    FileHandle.standardError.write("Error: specify --app <bundleID> or --pid <pid>, or use --list.\n".data(using: .utf8)!)
    printUsage()
    exit(1)
}

let capture = AudioCapture(sampleRate: parsed.sampleRate)

signal(SIGINT) { _ in
    capture.stop()
    FileHandle.standardError.write("\nStopped.\n".data(using: .utf8)!)
    exit(0)
}

do {
    try capture.startCapture(pid: targetPID)
} catch {
    FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

// Keep alive
dispatchMain()
