import Darwin
import Foundation

private func argument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

private func unixAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        raw.copyBytes(from: bytes)
    }
    return address
}

guard let input = try? FileHandle.standardInput.readToEnd(), !input.isEmpty,
      var object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }

let toolName = ((object["tool_name"] as? String) ?? (object["toolName"] as? String) ?? "").lowercased()
let toolInput = (object["tool_input"] as? [String: Any]) ?? (object["toolInput"] as? [String: Any])
let hasQuestions = (toolInput?["questions"] as? [Any])?.isEmpty == false
guard toolName.contains("askuserquestion") || toolName.contains("request_user_input") || hasQuestions else { exit(0) }

object["source"] = argument(after: "--source") ?? "codex"
guard var payload = try? JSONSerialization.data(withJSONObject: object) else { exit(0) }
payload.append(0x0A)

let socketPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agentpip/run/agentpip.sock").path
guard var address = unixAddress(socketPath) else { exit(0) }
let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard descriptor >= 0 else { exit(0) }
defer { close(descriptor) }

let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { exit(0) }

let sent = payload.withUnsafeBytes { write(descriptor, $0.baseAddress, payload.count) }
guard sent == payload.count else { exit(0) }

var response = Data()
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let count = read(descriptor, &buffer, buffer.count)
    if count <= 0 { break }
    response.append(buffer, count: count)
    if response.contains(0x0A) { break }
}
if !response.isEmpty { try? FileHandle.standardOutput.write(contentsOf: response) }
