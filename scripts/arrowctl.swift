// Debug remote control for a running Debug build of Arrow.
// Usage: swift scripts/arrowctl.swift <action> [argument]
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard let action = arguments.first else {
    print("usage: arrowctl <action> [argument]")
    exit(64)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.euskadi31.arrow.debug"), object: nil,
    userInfo: ["action": action, "argument": arguments.dropFirst().joined(separator: " ")],
    deliverImmediately: true)
