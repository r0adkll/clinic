import Darwin
import Foundation

/// Locates the process libghostty spawned for a surface and inspects its TTY.
///
/// libghostty exposes neither the child PID nor the pty, so this is reconstructed
/// from the kernel process table (`sysctl KERN_PROC`):
///
/// - The spawned process is a direct child of this process. On macOS libghostty wraps
///   the command in `/usr/bin/login -flp` (a setuid binary that then forks the shell),
///   so the child's exec arguments/environment are *not* readable by us (`EPERM`),
///   nor are those of its descendants. Matching a child to a surface by an injected
///   environment marker is therefore impossible; instead children are matched to
///   surfaces by creation order (see ``GhosttySurfaceView/childPID``).
/// - `kinfo_proc.kp_eproc.e_tdev` gives the child's controlling terminal without any
///   permission constraint (``ttyPath(of:)``), and `e_tpgid` the tty's foreground
///   process group (``foregroundProcessGroup(of:)``). `tcgetpgrp` cannot be used here:
///   XNU only allows `TIOCGPGRP` on the caller's own controlling terminal.
enum GhosttyProcessProbe {
    struct ChildInfo {
        let pid: pid_t
        let startTime: Date
        let ttyDevice: dev_t    // 0 / NODEV (-1) when none
        let ttyForegroundPGID: pid_t
    }

    private static func processTable(_ mib: [Int32]) -> [kinfo_proc] {
        var mib = mib
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / stride))
    }

    private static func info(_ p: kinfo_proc) -> ChildInfo {
        let tv = p.kp_proc.p_starttime
        return ChildInfo(
            pid: p.kp_proc.p_pid,
            startTime: Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000),
            ttyDevice: p.kp_eproc.e_tdev,
            ttyForegroundPGID: p.kp_eproc.e_tpgid)
    }

    /// Direct children of `parent`, oldest first.
    static func children(of parent: pid_t) -> [ChildInfo] {
        processTable([CTL_KERN, KERN_PROC, KERN_PROC_ALL])
            .filter { $0.kp_eproc.e_ppid == parent && $0.kp_proc.p_pid > 0 }
            .map(info)
            .sorted { $0.startTime < $1.startTime }
    }

    /// Kernel info for a single process, if it exists.
    static func process(_ pid: pid_t) -> ChildInfo? {
        processTable([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]).first.map(info)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Path of the controlling terminal of `pid` (e.g. `/dev/ttys003`), if any.
    static func ttyPath(of pid: pid_t) -> String? {
        guard let p = process(pid) else { return nil }
        return ttyPath(device: p.ttyDevice)
    }

    static func ttyPath(device: dev_t) -> String? {
        guard device != 0, device != -1 else { return nil }
        guard let name = devname(device, mode_t(S_IFCHR)) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// The foreground process group of the controlling terminal of `pid`.
    static func foregroundProcessGroup(of pid: pid_t) -> pid_t? {
        guard let p = process(pid), p.ttyDevice != 0, p.ttyDevice != -1 else { return nil }
        return p.ttyForegroundPGID > 0 ? p.ttyForegroundPGID : nil
    }
}
