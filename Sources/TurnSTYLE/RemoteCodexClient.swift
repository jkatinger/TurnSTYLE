import CryptoKit
import Foundation
import TurnStyleCore

/// Short, noninteractive SSH requests. No listener or stored credentials on either Mac.
actor RemoteCodexClient {
    private func validate(_ target: String) throws {
        guard target.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.@:\\[\\]-]*$", options: .regularExpression) != nil else {
            throw SetupError.invalid("Enter an SSH alias or user@hostname, without command options or spaces.")
        }
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func run(target: String, command: String, request: [String: Any]) throws -> Data {
        try validate(target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let controlPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurnSTYLE/mini-ssh.sock").path
        process.arguments = [
            "-T", "-S", controlPath, "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=5",
            "-oServerAliveInterval=3", "-oServerAliveCountMax=1", target, command,
        ]
        let input = Pipe()
        let output = Pipe()
        // A file prevents SSH diagnostics from filling a pipe while stdout is drained.
        let diagnosticURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "turnstyle-ssh-" + UUID().uuidString)
        guard
            FileManager.default.createFile(
                atPath: diagnosticURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw SetupError.invalid("Could not create a private SSH diagnostics file.")
        }
        let diagnostics = try FileHandle(forUpdating: diagnosticURL)
        defer {
            try? diagnostics.close()
            try? FileManager.default.removeItem(at: diagnosticURL)
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { deadline.cancel() }
        // Install packages exceed pipe capacity; send independently while draining stdout.
        let payload = try JSONSerialization.data(withJSONObject: request)
        DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: payload)
            try? input.fileHandleForWriting.close()
        }
        var bytes = Data()
        while let block = try output.fileHandleForReading.read(upToCount: 64 * 1024), !block.isEmpty {
            guard bytes.count + block.count <= 16 * 1024 * 1024 else {
                process.terminate()
                throw SetupError.invalid("The Mini returned an unexpectedly large snapshot.")
            }
            bytes.append(block)
        }
        process.waitUntilExit()
        try diagnostics.seek(toOffset: 0)
        let diagnostic = try diagnostics.read(upToCount: 1200) ?? Data()
        if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let error = object["error"] as? String
        {
            throw SetupError.invalid(error)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: diagnostic.prefix(1200), encoding: .utf8) ?? ""
            throw SetupError.invalid(
                "SSH could not connect. Verify Remote Login and the address, then authenticate the shared SSH connection in Terminal. "
                    + detail)
        }
        return bytes
    }
    func install(target: String, helper: URL, script: URL) throws -> String {
        let helperBytes = try Data(contentsOf: helper)
        let scriptBytes = try Data(contentsOf: script)
        let hash = SHA256.hash(data: helperBytes).map { String(format: "%02x", $0) }.joined()
        let data = try run(
            target: target, command: "/usr/bin/python3 -c " + quote(String(decoding: scriptBytes, as: UTF8.self)),
            request: [
                "action": "install", "helper": helperBytes.base64EncodedString(),
                "script": scriptBytes.base64EncodedString(), "helperSHA256": hash,
            ])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            result["installed"] as? Bool == true
        else {
            throw SetupError.invalid("The Mini did not confirm installation.")
        }
        guard let hostID = result["hostID"] as? String, UUID(uuidString: hostID) != nil else {
            throw SetupError.invalid("The Mini returned an invalid bridge identity.")
        }
        return hostID
    }
    func snapshot(target: String, ack: [String]) throws -> RemoteCodexSnapshot {
        let data = try run(
            target: target, command: "/usr/bin/python3 'Library/Application Support/TurnSTYLEBridge/bridge.py'",
            request: ["ack": ack])
        return try JSONDecoder().decode(RemoteCodexSnapshot.self, from: data)
    }
}
