// clinic-hook: reads a Claude Code hook payload from stdin and forwards it to Clinic's Unix socket (ADR-015).
// Milestone 1 step 4 fills this in; for now it drains stdin and exits 0 so it never blocks the CLI.
import Foundation

_ = FileHandle.standardInput.readDataToEndOfFile()
exit(0)
