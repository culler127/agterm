import Foundation
import Testing

/// Resolves `node` for OpenCodeStatusHookTests. Kept outside the suite type so `@Suite(.enabled(if:))`
/// can reference it without a circular macro resolution on the suite itself.
private enum OpenCodeStatusHookSupport {
    /// First `node` on PATH, or nil. Suite-gated via `.enabled(if:)` so machines without Node skip
    /// visibly rather than failing (README lists Node only as a test dependency).
    static var node: String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "node"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}

// Exercises the OpenCode plugin shipped by the Help-menu installer. Event-to-status mapping and
// wrapper spawning belong to this installed plugin, not to agterm's runtime status engine.
// Drives the plugin through Node (same host OpenCode uses) with AGTERM_STATUS_WRAPPER recording argv.
// Skipped when node is absent — the app does not require Node at runtime; only these tests do.
@Suite(.enabled(if: OpenCodeStatusHookSupport.node != nil,
                "node is required to exercise the OpenCode status plugin; install Node.js to run these tests"))
struct OpenCodeStatusHookTests {
    private static var plugin: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/opencode/agterm-status.js")
            .path
    }

    /// Run a node process; on non-zero exit, surface stderr so the failure names the cause.
    private func runNode(arguments: [String], environment: [String: String]) throws -> Int32 {
        let node = try #require(OpenCodeStatusHookSupport.node)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = arguments
        proc.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Issue.record(
                """
                node exited \(proc.terminationStatus)
                args: \(arguments)
                stderr:
                \(err)
                stdout:
                \(out)
                """
            )
        }
        return proc.terminationStatus
    }

    /// Run the plugin's `event` hook for each OpenCode bus payload; returns recorded wrapper argv lines.
    private func runEvents(_ events: [[String: Any]],
                           setStatusWrapper: Bool = true,
                           sessionID: String? = "sid") throws -> [String] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-opencode-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let statuses = dir.appendingPathComponent("statuses")
        let home = dir.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let recordScript = """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(statuses.path)'
        """

        let statusWrapper = dir.appendingPathComponent("status-wrapper")
        try recordScript.write(to: statusWrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusWrapper.path)

        if !setStatusWrapper {
            let defaultWrapperDir = home.appendingPathComponent(".config/agterm/agent-status", isDirectory: true)
            try fm.createDirectory(at: defaultWrapperDir, withIntermediateDirectories: true)
            let defaultWrapper = defaultWrapperDir.appendingPathComponent("agterm-agent-status.sh")
            try recordScript.write(to: defaultWrapper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: defaultWrapper.path)
        }

        let eventsFile = dir.appendingPathComponent("events.json")
        try String(data: JSONSerialization.data(withJSONObject: events), encoding: .utf8)!
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        // Harness stays out of Resources (would ship to users). The harness is .mjs; Node loads the
        // plugin's .js as ESM via dynamic import / module-syntax detection — no --experimental-* flag.
        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import { readFileSync } from "node:fs";
        import { pathToFileURL } from "node:url";
        const { AgtermStatusPlugin } = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const events = JSON.parse(readFileSync(process.env.AGTERM_OPENCODE_EVENTS, "utf8"));
        const hooks = await AgtermStatusPlugin();
        if (typeof hooks.event !== "function") process.exit(0);
        for (const event of events) {
          await hooks.event({ event });
        }
        """.write(to: harness, atomically: true, encoding: .utf8)

        var environment: [String: String] = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "AGTERM_OPENCODE_PLUGIN": Self.plugin,
            "AGTERM_OPENCODE_EVENTS": eventsFile.path,
        ]
        if let sessionID {
            environment["AGTERM_SESSION_ID"] = sessionID
        }
        if setStatusWrapper {
            environment["AGTERM_STATUS_WRAPPER"] = statusWrapper.path
        }
        #expect(try runNode(arguments: [harness.path], environment: environment) == 0)

        return ((try? String(contentsOf: statuses, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func event(_ type: String, properties: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "properties": properties]
    }

    private func status(_ kind: String, sessionID: String = "ses_root") -> [String: Any] {
        event("session.status", properties: ["sessionID": sessionID, "status": ["type": kind]])
    }

    @Test func pluginExportsOnlyPluginFunctions() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-opencode-exports-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // .mjs harness — avoid node -e (needs --input-type=module) and the removed
        // --experimental-default-type=module flag.
        let harness = dir.appendingPathComponent("exports.mjs")
        try """
        import { pathToFileURL } from "node:url";
        const mod = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const keys = Object.keys(mod);
        if (keys.length !== 1 || keys[0] !== "AgtermStatusPlugin") process.exit(2);
        if (typeof mod.AgtermStatusPlugin !== "function") process.exit(3);
        for (const [name, value] of Object.entries(mod)) {
          if (typeof value !== "function") process.exit(4);
        }
        """.write(to: harness, atomically: true, encoding: .utf8)
        #expect(try runNode(
            arguments: [harness.path],
            environment: [
                "PATH": "/usr/bin:/bin",
                "AGTERM_OPENCODE_PLUGIN": Self.plugin,
            ]
        ) == 0)
    }

    @Test func lifecycleEventsDriveOnlyTheGenericStatusWrapper() throws {
        let calls = try runEvents([
            status("busy"),
            status("retry"),
            status("idle"),
            event("permission.asked"),
            event("question.asked"),
            event("permission.replied"),
            event("question.replied"),
            event("question.rejected"),
        ])
        #expect(calls == [
            "active --blink",
            "active --blink",
            "completed --auto-reset",
            "blocked",
            "blocked",
            "active --blink",
            "active --blink",
            "active --blink",
        ])
    }

    @Test func sessionErrorStaysBlockedThroughFollowingIdle() throws {
        // SessionProcessor.halt publishes session.error then status(idle) on the next line; without an
        // errored latch the serial queue would overwrite blocked with completed --auto-reset.
        let calls = try runEvents([
            status("busy"),
            event("session.error", properties: ["sessionID": "ses_root"]),
            status("idle"),
        ])
        #expect(calls == ["active --blink", "blocked"])
    }

    @Test func idleWithoutPrecedingBusyIsIgnored() throws {
        let calls = try runEvents([
            status("idle"),
            status("idle", sessionID: "ses_never_busy"),
        ])
        #expect(calls.isEmpty)
    }

    @Test func subagentIdleDoesNotCompleteWhileParentIsActive() throws {
        // needsAttention would otherwise pull the still-working parent into attention nav / auto-follow.
        let calls = try runEvents([
            status("busy", sessionID: "ses_parent"),
            status("idle", sessionID: "ses_child"),
            status("idle", sessionID: "ses_parent"),
        ])
        #expect(calls == [
            "active --blink",
            "completed --auto-reset",
        ])
    }

    @Test func ignoresDeprecatedSessionIdleAndNonStatusNoise() throws {
        let calls = try runEvents([
            event("session.idle", properties: ["sessionID": "s1"]),
            event("tool.execute.before"),
            event("tool.execute.after"),
            event("session.compacted"),
            event("chat.message"),
            event("session.created", properties: ["info": ["id": "child", "parentID": "root"]]),
        ])
        #expect(calls.isEmpty)
    }

    @Test func pluginIsSilentNoOpOutsideAgterm() throws {
        let calls = try runEvents(
            [status("busy")],
            sessionID: nil
        )
        #expect(calls.isEmpty)
    }

    @Test func defaultWrapperPathIsUsedWhenStatusWrapperUnset() throws {
        let calls = try runEvents(
            [event("permission.asked")],
            setStatusWrapper: false
        )
        #expect(calls == ["blocked"])
    }

    @Test func reportsRunStrictlyInOrder() throws {
        // Gate protocol: blocked holds until `release` exists; the next report must not start until then.
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agterm-opencode-order-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let statuses = dir.appendingPathComponent("statuses")
        let started = dir.appendingPathComponent("started")
        let release = dir.appendingPathComponent("release")
        let wrapper = dir.appendingPathComponent("status-wrapper")
        try """
        #!/bin/bash
        printf '%s\\n' "start $*" >> '\(started.path)'
        if [ "$1" = "blocked" ]; then
          while [ ! -f '\(release.path)' ]; do sleep 0.01; done
        fi
        printf '%s\\n' "$*" >> '\(statuses.path)'
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        // permission.asked / replied always report (no active-set gate), so the queue order is isolated.
        let events: [[String: Any]] = [
            event("permission.asked"),
            event("permission.replied"),
        ]
        let eventsFile = dir.appendingPathComponent("events.json")
        try String(data: JSONSerialization.data(withJSONObject: events), encoding: .utf8)!
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let harness = dir.appendingPathComponent("harness.mjs")
        try """
        import { readFileSync, writeFileSync, existsSync } from "node:fs";
        import { pathToFileURL } from "node:url";
        import { setTimeout as sleep } from "node:timers/promises";
        const { AgtermStatusPlugin } = await import(pathToFileURL(process.env.AGTERM_OPENCODE_PLUGIN).href);
        const events = JSON.parse(readFileSync(process.env.AGTERM_OPENCODE_EVENTS, "utf8"));
        const hooks = await AgtermStatusPlugin();
        const pending = Promise.all(events.map((event) => hooks.event({ event })));
        const startedPath = process.env.AGTERM_OPENCODE_STARTED;
        const releasePath = process.env.AGTERM_OPENCODE_RELEASE;
        const statusesPath = process.env.AGTERM_OPENCODE_STATUSES;
        for (let i = 0; i < 500 && !existsSync(startedPath); i++) await sleep(10);
        // While blocked is held, the follow-up active report must not have started (queue serializes).
        const started = existsSync(startedPath) ? readFileSync(startedPath, "utf8") : "";
        if (started.includes("active")) {
          writeFileSync(releasePath, "1");
          await pending;
          process.exit(2);
        }
        if (existsSync(statusesPath) && readFileSync(statusesPath, "utf8").trim()) {
          writeFileSync(releasePath, "1");
          await pending;
          process.exit(3);
        }
        writeFileSync(releasePath, "1");
        await pending;
        """.write(to: harness, atomically: true, encoding: .utf8)

        #expect(try runNode(
            arguments: [harness.path],
            environment: [
                "HOME": dir.path,
                "PATH": "/usr/bin:/bin",
                "AGTERM_SESSION_ID": "sid",
                "AGTERM_STATUS_WRAPPER": wrapper.path,
                "AGTERM_OPENCODE_PLUGIN": Self.plugin,
                "AGTERM_OPENCODE_EVENTS": eventsFile.path,
                "AGTERM_OPENCODE_STARTED": started.path,
                "AGTERM_OPENCODE_RELEASE": release.path,
                "AGTERM_OPENCODE_STATUSES": statuses.path,
            ]
        ) == 0)

        let calls = ((try? String(contentsOf: statuses, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        #expect(calls == ["blocked", "active --blink"])
    }
}
