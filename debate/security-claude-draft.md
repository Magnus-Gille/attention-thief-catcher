# Security Assessment: attention-thief-catcher

**Assessor:** Claude Opus 4.6
**Date:** 2026-02-16
**Scope:** Full security review of the attention-thief-catcher macOS daemon

---

## 1. Executive Summary

attention-thief-catcher is a single-file Swift daemon that monitors macOS window focus changes, logs them as NDJSON, and flags anomalous behavior. It runs as a user-level LaunchAgent, executes `ps` to capture process snapshots, and stores detailed logs on disk. While the project has a modest attack surface (no network, no IPC, no root), it presents meaningful security considerations around **data at rest**, **privacy**, **process execution**, and **abuse potential**.

---

## 2. Data at Rest

### 2.1 What the logs contain

The NDJSON log files written to `~/Library/Logs/attention-thief-catcher/` contain:

- **Application names** and **bundle identifiers** for every app that gains/loses focus
- **Executable paths** (full filesystem paths to application binaries)
- **Process identifiers (PIDs)** for every activated application
- **Activation policies** (regular, accessory, prohibited)
- **Full `ps` output** every 5 minutes and on every anomaly, including:
  - PIDs and PPIDs of all running processes
  - CPU and memory usage percentages
  - Full command paths (`comm` column)
- **Timestamps** with millisecond precision for every event
- **System state transitions** (sleep, wake, screen lock, session events)

### 2.2 Risk assessment

**Severity: MEDIUM**

This data constitutes a comprehensive behavioral profile of the user. An attacker with read access to the log directory can determine:
- Exactly which applications the user runs and when
- Work patterns (active hours, break times, sleep/wake cycles)
- Whether specific sensitive applications are used (e.g., password managers, VPN clients, financial software)
- Process hierarchy and resource consumption patterns

### 2.3 File permissions

The log directory `~/Library/Logs/attention-thief-catcher/` is created with:

```swift
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
```

**Issue:** `FileManager.default.createDirectory` uses the process's default umask, which on macOS is typically `0022`, resulting in directory permissions `0755` (world-readable). Similarly, `FileManager.default.createFile` for log files uses the default umask, resulting in `0644` (world-readable).

This means any process running as any user on the system can read the log files. On a multi-user Mac or a system with compromised processes, this is an information disclosure vector.

**Recommendation:** Explicitly set directory permissions to `0700` and file permissions to `0600`.

---

## 3. Privacy Implications

### 3.1 Continuous monitoring

The daemon runs continuously from login via LaunchAgent with `KeepAlive` (restarts on crash) and `RunAtLoad`. It captures:
- Every single focus change (via notifications + 3-second polling fallback)
- Every app launch and termination
- Every sleep/wake/lock/unlock cycle

**Severity: MEDIUM**

This is inherently a surveillance tool, albeit self-directed. The README is transparent about what it does, but:
- There is **no consent mechanism** for multi-user systems where the user account might be shared
- There is **no data retention policy** -- logs accumulate indefinitely (limited only by 50MB file rotation, but old files are never deleted)
- There is **no encryption** of logs at rest
- The `ps` snapshots capture information about **all processes** on the system, not just the current user's, potentially exposing other users' activities

### 3.2 Process snapshot scope

The `ps -eo pid,ppid,%cpu,%mem,comm` command in `processSnapshot()` (line 79-94 of the Swift source) captures all processes visible to the user, including:
- System daemons
- Other users' processes (if visible -- macOS generally restricts this, but some processes are visible)
- Background agent paths that may reveal installed security tools, VPN clients, or monitoring software

---

## 4. Install Script Security (Scripts/install.sh)

### 4.1 Shell injection

The install script constructs paths using variable expansion:

```bash
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/.local/bin"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
```

**Assessment: LOW risk.** Variables are properly double-quoted throughout the script. The `REPO_DIR` computation uses `pwd` which resolves to an absolute path. `$HOME` is set by the shell. `BINARY_NAME` is a hardcoded string constant. No user-supplied input is interpolated unsafely.

The `sed` command on line 28:
```bash
sed "s|~/.local/bin|$INSTALL_DIR|g" "$PLIST_SRC" > "$PLIST_DST"
```
Uses `|` as delimiter, and `$INSTALL_DIR` is derived from `$HOME/.local/bin`. If `$HOME` contained `|` characters (essentially impossible on macOS), this could be exploited, but this is not a realistic concern.

### 4.2 TOCTOU (Time-of-Check-Time-of-Use)

**Issue: LOW risk.**

The script does not perform check-then-act patterns with security implications. The `mkdir -p`, `swiftc`, and `sed > file` operations are atomic or idempotent at the filesystem level. The `launchctl print` check before `bootout` is a convenience check, not a security gate.

One minor TOCTOU: the script compiles the binary to `$BINARY_PATH` and then later the plist references it. If an attacker could replace the binary between compilation and LaunchAgent load (lines 16-32), they could execute arbitrary code. However, this requires write access to `~/.local/bin/`, which implies the user account is already compromised.

### 4.3 Path handling

All paths are properly quoted. The script uses `set -euo pipefail` which provides fail-fast behavior. No `eval`, backtick substitution with untrusted input, or glob expansion issues are present.

---

## 5. Process Execution Security

### 5.1 The `ps` command invocation

```swift
func processSnapshot() -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-eo", "pid,ppid,%cpu,%mem,comm"]
    // ...
}
```

**Assessment: GOOD.**

- The executable is specified by absolute path (`/bin/ps`), preventing PATH hijacking
- Arguments are passed as an array, not as a shell-interpreted string, preventing command injection
- No user-supplied input flows into the arguments
- `standardError` is captured separately (piped to a separate `Pipe()`), preventing stderr leakage

**No command injection vector exists here.** The `Process` API in Swift uses `posix_spawn`/`execve` semantics, passing arguments directly without shell interpretation.

### 5.2 Potential concern: ps output in JSON

The output of `ps` is stored as a string value in a JSON object. Since `JSONSerialization` handles escaping correctly, there is no injection risk in the log files themselves. However, the raw `ps` output could contain adversarial process names (e.g., processes with names containing special characters), which would be safely escaped by `JSONSerialization`.

---

## 6. LaunchAgent Persistence and Abuse Potential

### 6.1 Persistence mechanism

The plist at `~/Library/LaunchAgents/com.magnusgille.attention-thief-catcher.plist` configures:
- `RunAtLoad: true` -- starts on every login
- `KeepAlive.SuccessfulExit: false` -- restarts if it crashes
- `LimitLoadToSessionType: Aqua` -- only runs in GUI sessions

**Severity: MEDIUM**

If this tool is installed maliciously (e.g., as part of a supply chain attack), it becomes a persistent surveillance implant that:
- Survives reboots
- Restarts on crash
- Runs automatically on login
- Captures a comprehensive activity log

### 6.2 Abuse as spyware

An attacker who modifies the source before installation, or replaces the binary after installation, could:
- Exfiltrate the log files (add network code)
- Expand monitoring scope (capture keystrokes, screenshots)
- Use the existing `ps` capability to enumerate security tools and evade detection
- The logs already provide sufficient intelligence for targeted attacks (knowing when the user is active, which security tools are running)

### 6.3 Stdout/stderr to /tmp

The plist directs stdout and stderr to `/tmp/`:
```xml
<key>StandardOutPath</key>
<string>/tmp/attention-thief-catcher.stdout.log</string>
<key>StandardErrorPath</key>
<string>/tmp/attention-thief-catcher.stderr.log</string>
```

**Severity: LOW-MEDIUM.**

`/tmp` is world-readable on macOS. Any error messages, including potential stack traces or diagnostic output, would be readable by any user on the system. On macOS, `/tmp` is actually a symlink to `/private/tmp`, and while macOS applies sticky bit, files written there are still readable by default permissions.

**Recommendation:** Redirect stdout/stderr to `~/Library/Logs/attention-thief-catcher/` instead.

---

## 7. NDJSON Parsing Safety in analyze.py

### 7.1 JSON parsing

The analyzer uses `json.loads()` (line 84) which is safe against injection. Malformed JSON lines are silently skipped via `try/except json.JSONDecodeError`.

### 7.2 Path handling

```python
LOG_DIR = Path.home() / "Library" / "Logs" / "attention-thief-catcher"
log_files = sorted(LOG_DIR.glob("focus-*.ndjson"))
```

**Assessment: GOOD.** The log directory is hardcoded. The glob pattern `focus-*.ndjson` limits which files are read. There is no path traversal risk because the glob is relative to a fixed directory.

### 7.3 Potential issues

- **No file size limits:** The analyzer reads all matching files into memory (line 65-100). A maliciously crafted log file could be very large, causing memory exhaustion. However, since log files are capped at 50MB by the daemon, this is bounded.
- **No validation of JSON structure:** The analyzer accesses dictionary keys with `.get()` (safe, returns None), but never validates that events conform to an expected schema. A tampered log file could cause misleading analysis output but not code execution.
- **Regex in parse_duration:** The regex `r"^(\d+)([smhd])$"` on line 49 is anchored and safe against ReDoS.

---

## 8. Information Disclosure Through Log Files

### 8.1 What an attacker learns from logs

An attacker with read access to logs gains:

| Information | Source | Intelligence Value |
|---|---|---|
| Application usage patterns | APP_ACTIVATED events | Work habits, tools used |
| Active hours | Timestamps on all events | When user is present |
| Security tools installed | ps snapshots, app events | Evasion planning |
| Sleep/wake patterns | System events | Physical presence |
| Development tools | App paths, bundle IDs | Technology stack |
| Communication patterns | Email/chat app activations | When user is distracted |

### 8.2 Log rotation does not equal deletion

The 50MB rotation creates new files but never deletes old ones. Over time, logs accumulate without bound:
- At typical usage rates, a few MB per day of log data
- Process snapshots (captured every 5 minutes and on anomalies) are the largest entries
- No automatic cleanup mechanism exists

---

## 9. Supply Chain Risks

### 9.1 Build-from-source model

The project compiles from source via `swiftc`, which is positive for auditability. Users can inspect the single Swift file before building. However:

- The install script downloads nothing, which is good
- There are no dependency integrity checks (no Package.swift with pinned dependencies, no checksums)
- The single-file approach actually minimizes supply chain risk since there are no third-party dependencies
- The Swift source uses only `AppKit` and `Foundation` (system frameworks)

### 9.2 Repository trust

As with any open-source tool, users must trust the repository. A compromised repository could:
- Add exfiltration code to the Swift source
- Modify install.sh to install additional malware
- The `swiftc` compilation step provides no protection against malicious source code

---

## 10. Privilege Escalation Vectors

### 10.1 Current privilege level

The daemon runs as a user-level LaunchAgent (not a system daemon). It has no elevated privileges beyond what the user already has.

### 10.2 Escalation potential

**Severity: LOW.**

- The binary at `~/.local/bin/attention-thief-catcher` runs with the user's permissions. Replacing it gives code execution as the user (but the attacker already needs user-level write access)
- The daemon does not interact with privileged services
- The `ps` command runs with user privileges (no setuid)
- No IPC, no network listeners, no file watchers on sensitive paths

### 10.3 Binary replacement

If `~/.local/bin/` has weak permissions, an attacker could replace the binary. Since KeepAlive restarts the process, a replaced binary would execute on next crash or reboot. However, this requires pre-existing write access to the user's home directory.

---

## 11. Recommendations Summary

| Priority | Issue | Recommendation |
|---|---|---|
| HIGH | Log file permissions world-readable | Set directory to 0700, files to 0600 |
| MEDIUM | stdout/stderr to /tmp | Redirect to ~/Library/Logs/ |
| MEDIUM | No log retention policy | Add automatic cleanup of logs older than N days |
| MEDIUM | ps captures all visible processes | Consider filtering to user's processes only (`ps -U $USER`) |
| LOW | No data encryption at rest | Consider encrypting sensitive fields or log files |
| LOW | No integrity verification | Add optional log signing/checksums |
| LOW | Binary in writable location | Document permission hardening for ~/.local/bin/ |

---

## 12. Conclusion

The attention-thief-catcher daemon has a **relatively small attack surface** for its category. It has no network exposure, no IPC, no root privileges, and no third-party dependencies. The code quality is solid: the `ps` invocation is safe against injection, the shell scripts handle quoting correctly, and the Python analyzer parses JSON safely.

The primary security concerns are:
1. **Information disclosure** through world-readable log files containing detailed behavioral data
2. **Privacy** implications of continuous monitoring and unbounded log retention
3. **Abuse potential** as a persistent surveillance mechanism if installed maliciously
4. **stdout/stderr leaking** to world-readable `/tmp`

None of these represent critical vulnerabilities in the traditional sense, but the information disclosure through default file permissions (issue #1) should be addressed before recommending this tool for general use.
