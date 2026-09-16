#!/usr/bin/env python3
"""Seeds the staged world `make screenshots` photographs (ADR-159).

Three invented projects, each a real git repo, with Claude Code transcripts in an isolated
CLAUDE_CONFIG_DIR and Clinic state in an isolated CLINIC_APP_SUPPORT. Nothing here touches the
user's ~/.claude or Clinic's own Application Support.

Timestamps are relative to now, so the sidebar's ages and the running children's timers read as a
session caught mid-work rather than one from the day the fixtures were written.
"""
import json
import os
import re
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone

ROOT = sys.argv[1]
NOW = datetime.now(timezone.utc)
CLI_VERSION = "2.1.273"

APP = os.path.join(ROOT, "app")
CFG = os.path.join(ROOT, "cfg")
PROJECTS = ROOT

# The one placeholder key the fixtures pre-approve, so a resumed `claude` renders the conversation instead
# of asking how to log in. It is never valid, and ANTHROPIC_BASE_URL keeps it off the network (see `run`).
API_KEY = "sk-ant-api03-" + "0" * 80 + "screenshots-only-key"

WORKING = "5f0c2a1e-7d3b-4c8e-9a61-2b4d6e8f0a11"
WAITING = "8a3e5b7c-1d2f-4e6a-8b9c-0d1e2f3a4b22"
GRILL = "c4d5e6f7-a8b9-4c0d-9e1f-2a3b4c5d6e33"
QUIET = [
    ("storefront", "e1f2a3b4-c5d6-4e7f-8a9b-0c1d2e3f4a44", "Upgrade the storefront to Next 15", "next-15", timedelta(hours=26)),
    ("pantry", "f2a3b4c5-d6e7-4f8a-9b0c-1d2e3f4a5b55", "Sync the pantry list over CloudKit", "cloudkit-sync", timedelta(days=3)),
    ("ledger", "a3b4c5d6-e7f8-4a9b-8c0d-2e3f4a5b6c66", "Parse OFX bank statements", "ofx-import", timedelta(days=5)),
]


def iso(delta):
    return (NOW - delta).strftime("%Y-%m-%dT%H:%M:%S.") + f"{(NOW - delta).microsecond // 1000:03d}Z"


def git(repo, *args):
    subprocess.run(["git", "-C", repo, "-c", "user.email=screenshots@example.com", "-c", "user.name=Screenshots", *args],
                   check=True, capture_output=True)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


# MARK: Projects

def make_storefront():
    repo = os.path.join(PROJECTS, "storefront")
    write(os.path.join(repo, "package.json"), '{\n  "name": "storefront",\n  "private": true\n}\n')
    write(os.path.join(repo, "src/cart/total.ts"), """import type { CartLine } from "./types";

export function cartTotal(lines: CartLine[]): number {
  let total = 0;
  for (const line of lines) {
    const discounted = line.price * line.quantity * (1 - line.discount);
    total += Math.round(discounted * 100) / 100;
  }
  return total;
}
""")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "Cart totals")
    git(repo, "checkout", "-qb", "fix-checkout-rounding")
    return repo


def apply_edits(repo):
    """The turn in progress: round once, at the end, and a test that pins it. Written after the staged
    prompt, so the Diff pane's turn snapshot sees them as this turn's changes (ADR-080)."""
    write(os.path.join(repo, "src/cart/total.ts"), """import type { CartLine } from "./types";

/** Sums in cents and rounds once, so per-line rounding can't drift by a cent on large carts. */
export function cartTotal(lines: CartLine[]): number {
  const cents = lines.reduce(
    (sum, line) => sum + line.price * 100 * line.quantity * (1 - line.discount),
    0,
  );
  return Math.round(cents) / 100;
}
""")
    write(os.path.join(repo, "src/cart/total.test.ts"), """import { describe, expect, it } from "vitest";
import { cartTotal } from "./total";

describe("cartTotal", () => {
  it("rounds once across many discounted lines", () => {
    const lines = Array.from({ length: 4 }, () => ({ price: 9.99, quantity: 1, discount: 0.15 }));
    expect(cartTotal(lines)).toBe(33.97);
  });
});
""")


def make_repo(name, branch, files):
    repo = os.path.join(PROJECTS, name)
    for rel, text in files.items():
        write(os.path.join(repo, rel), text)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "Initial commit")
    git(repo, "checkout", "-qb", branch)
    return repo


# MARK: Transcripts

class Transcript:
    def __init__(self, sid, cwd, branch):
        self.sid, self.cwd, self.branch = sid, cwd, branch
        self.records = []
        self.parent = None

    def _base(self, kind, delta):
        u = str(uuid.uuid4())
        o = {"type": kind, "sessionId": self.sid, "cwd": self.cwd, "gitBranch": self.branch, "timestamp": iso(delta),
             "uuid": u, "parentUuid": self.parent, "isSidechain": False, "userType": "external", "version": CLI_VERSION}
        self.parent = u
        return o

    def prompt(self, text, delta):
        o = self._base("user", delta)
        o["message"] = {"role": "user", "content": text}
        o["origin"] = {"kind": "human"}
        self.records.append(o)

    def model(self, model_id, name, delta):
        self.records.append({"type": "attachment", "sessionId": self.sid, "timestamp": iso(delta), "isSidechain": False,
                             "attachment": {"type": "model", "identity": {"modelId": model_id, "marketingName": name}}})

    def say(self, text, delta, model="claude-opus-5", tokens=60000):
        o = self._base("assistant", delta)
        o["message"] = {"id": "msg_" + uuid.uuid4().hex[:20], "type": "message", "role": "assistant", "model": model,
                        "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                        "usage": {"input_tokens": 4, "cache_read_input_tokens": tokens, "cache_creation_input_tokens": 900, "output_tokens": 120}}
        self.records.append(o)

    def tool(self, name, tool_input, delta, model="claude-opus-5", tokens=60000):
        tid = "toolu_" + uuid.uuid4().hex[:24]
        o = self._base("assistant", delta)
        o["message"] = {"id": "msg_" + uuid.uuid4().hex[:20], "type": "message", "role": "assistant", "model": model,
                        "content": [{"type": "tool_use", "id": tid, "name": name, "input": tool_input}], "stop_reason": "tool_use",
                        "usage": {"input_tokens": 4, "cache_read_input_tokens": tokens, "cache_creation_input_tokens": 700, "output_tokens": 80}}
        self.records.append(o)
        return tid

    def result(self, tid, text, delta, tool_use_result=None):
        o = self._base("user", delta)
        o["message"] = {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": text}]}
        o["toolUseResult"] = tool_use_result if tool_use_result is not None else {}
        self.records.append(o)

    def notify(self, task_id, tid, status, summary, delta):
        body = (f"<task-notification>\n<task-id>{task_id}</task-id>\n<tool-use-id>{tid}</tool-use-id>\n"
                f"<status>{status}</status>\n<summary>{summary}</summary>\n</task-notification>")
        self.records.append({"type": "queue-operation", "operation": "enqueue", "timestamp": iso(delta), "sessionId": self.sid, "content": body})

    def title(self, text):
        self.records.append({"type": "ai-title", "aiTitle": text, "sessionId": self.sid})

    def recap(self, text, delta):
        o = self._base("system", delta)
        o["subtype"] = "away_summary"
        o["content"] = text + " (disable recaps in /config)"
        self.records.append(o)

    def save(self):
        encoded = re.sub(r"[^A-Za-z0-9]", "-", self.cwd)
        write(os.path.join(CFG, "projects", encoded, f"{self.sid}.jsonl"), "\n".join(json.dumps(r) for r in self.records) + "\n")


def seconds(n):
    return timedelta(seconds=n)


def working_session(repo):
    t = Transcript(WORKING, repo, "fix-checkout-rounding")
    t.prompt("A customer reported their order total didn't match the receipt. Can you look at the last few orders?", seconds(1800))
    t.title("Fix checkout total rounding")
    t.model("claude-opus-5", "Opus 5", seconds(1799))
    logs = t.tool("Bash", {"command": "pnpm orders:recent --limit 5", "description": "List the five most recent orders"}, seconds(1790))
    t.result(logs, "#10482  4 items  $33.96  receipt $33.97\n#10481  2 items  $18.40  receipt $18.40\n#10480  5 items  $51.03  receipt $51.05", seconds(1789))
    t.say("Two of the last five orders are a cent or two below their receipts, and both have four or more "
          "discounted items. The receipt service rounds the total once; the storefront rounds each line.", seconds(1780))
    t.prompt("Where is the cart total calculated?", seconds(900))
    grep = t.tool("Grep", {"pattern": "cartTotal", "path": repo}, seconds(890))
    t.result(grep, "src/cart/total.ts\nsrc/checkout/summary.tsx\nsrc/checkout/confirm.tsx", seconds(889))
    t.say("In `src/cart/total.ts`. `cartTotal` sums each line's price × quantity after its discount, and both the "
          "checkout summary and the confirmation page call it.", seconds(880))
    t.prompt("Totals are off by a cent when a cart has more than three discounted items. Fix the rounding and add a test.", seconds(300))
    t.say("Each line is rounded before it's summed, so the rounding errors add up across the cart. "
          "I'll sum in cents and round once at the end.", seconds(290))
    read = t.tool("Read", {"file_path": f"{repo}/src/cart/total.ts"}, seconds(285))
    t.result(read, "1\timport type { CartLine } from \"./types\";\n…", seconds(284))
    edit = t.tool("Edit", {"file_path": f"{repo}/src/cart/total.ts", "old_string": "total += Math.round", "new_string": "return Math.round"}, seconds(260))
    t.result(edit, f"The file {repo}/src/cart/total.ts has been updated.", seconds(259))
    t.say("That fixes the total. Before writing the test I'll check for the same per-line rounding elsewhere, "
          "confirm the tax rules, and get a review of the checkout flow.", seconds(250), tokens=72000)
    tax = t.tool("Agent", {"description": "Check tax rounding rules", "subagent_type": "Explore", "prompt": "…"}, seconds(240))
    t.result(tax, "Async agent launched successfully.", seconds(239), {"isAsync": True, "status": "async_launched", "agentId": "a1c2e3f4a5b6c7d80"})
    scan = t.tool("Agent", {"description": "Find other per-line rounding", "subagent_type": "Explore", "prompt": "…"}, seconds(150))
    t.result(scan, "Async agent launched successfully.", seconds(149), {"isAsync": True, "status": "async_launched", "agentId": "a2d3e4f5a6b7c8d91"})
    props = t.tool("Agent", {"description": "Write property tests for totals", "subagent_type": "general-purpose", "prompt": "…"}, seconds(95))
    t.result(props, "Async agent launched successfully.", seconds(94), {"isAsync": True, "status": "async_launched", "agentId": "a3e4f5a6b7c8d9e02"})
    review = t.tool("Agent", {"description": "Review the checkout flow", "subagent_type": "general-purpose", "prompt": "…"}, seconds(40))
    t.result(review, "Async agent launched successfully.", seconds(39), {"isAsync": True, "status": "async_launched", "agentId": "a4f5a6b7c8d9e0f13"})
    t.notify("a1c2e3f4a5b6c7d80", tax, "completed", 'Agent "Check tax rounding rules" finished', seconds(45))
    t.say("Tax is applied to the rounded subtotal, so the fix is safe. Adding the test now.", seconds(20), tokens=81000)
    t.tool("Edit", {"file_path": f"{repo}/src/cart/total.test.ts", "old_string": "", "new_string": "…"}, seconds(5), tokens=84000)
    t.save()


def waiting_session(repo):
    t = Transcript(WAITING, repo, "barcode-ipad")
    t.prompt("The barcode scanner crashes on iPad when the sheet opens in split view. Find out why and fix it.", seconds(900))
    t.title("Barcode scanner crashes on iPad")
    t.model("claude-sonnet-5", "Sonnet 5", seconds(899))
    t.say("The capture session is configured before the sheet has a size, so the preview layer's frame is zero "
          "on iPad in split view. I've moved setup into `viewDidLayoutSubviews`. Running the iPad tests to confirm.",
          seconds(200), model="claude-sonnet-5", tokens=118000)
    t.tool("Bash", {"command": "xcodebuild test -scheme Pantry -destination 'platform=iOS Simulator,name=iPad Pro 13-inch'",
                    "description": "Run the iPad UI tests"}, seconds(120), model="claude-sonnet-5", tokens=122000)
    t.save()


def grill_session(repo):
    t = Transcript(GRILL, repo, "csv-export")
    t.prompt("Add CSV export for accounts and transactions.", timedelta(minutes=48))
    t.title("Add CSV export")
    t.say("Export works for accounts and transactions. Before wiring it into the menu I've posted a few questions "
          "about date formats and which columns to include.", timedelta(minutes=12), tokens=54000)
    t.recap("CSV export works for accounts and transactions; waiting on your answers about date formats and "
            "columns before adding it to the menu.", timedelta(minutes=11))
    t.save()


def quiet_session(project_repo, sid, title, branch, age):
    t = Transcript(sid, project_repo, branch)
    t.prompt(title, age + timedelta(minutes=40))
    t.title(title)
    t.say("Done.", age)
    t.save()


# MARK: Clinic state

def grill_round():
    def q(qid, title, choices):
        return {"id": qid, "title": title, "body": "", "choices": [{"id": c.lower().replace(" ", "-"), "label": c, "recommended": i == 0}
                                                                  for i, c in enumerate(choices)], "allowsMultiple": False}
    return {"id": str(uuid.uuid4()), "index": 1, "topic": "CSV export", "postedAt": (NOW - timedelta(minutes=12)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "source": "tool", "answers": {},
            "questions": [q("Q1", "Date format", ["ISO 8601", "Locale"]),
                          q("Q2", "Include balances?", ["Yes", "No"]),
                          q("Q3", "One file or one per account?", ["One file", "One per account"])]}


def main():
    if len(sys.argv) > 2 and sys.argv[2] == "--apply-edits":
        apply_edits(os.path.join(PROJECTS, "storefront"))
        return
    storefront = make_storefront()
    pantry = make_repo("pantry", "barcode-ipad", {"Pantry/ScannerViewController.swift": "import AVFoundation\n"})
    ledger = make_repo("ledger", "csv-export", {"Sources/Ledger/Export.swift": "import Foundation\n"})
    repos = {"storefront": storefront, "pantry": pantry, "ledger": ledger}

    working_session(storefront)
    waiting_session(pantry)
    grill_session(ledger)
    for project, sid, title, branch, age in QUIET:
        quiet_session(repos[project], sid, title, branch, age)

    added = NOW - timedelta(days=30)
    owned = {sid: {"projectPath": path, "addedAt": added.strftime("%Y-%m-%dT%H:%M:%SZ"), "imported": False}
             for sid, path in [(WORKING, storefront), (WAITING, pantry), (GRILL, ledger)] + [(s, repos[p]) for p, s, *_ in QUIET]}
    state = {
        "version": 1,
        "ownedSessions": owned,
        # Registration order is sidebar order (ADR-077).
        "projectsAddedAt": {path: (added + timedelta(minutes=i)).strftime("%Y-%m-%dT%H:%M:%SZ")
                            for i, path in enumerate([storefront, pantry, ledger])},
        "grillRounds": {GRILL: [grill_round()]},
    }
    write(os.path.join(APP, "Clinic", "state.json"), json.dumps(state, indent=1))

    # Claude Code's own state: onboarding done, the placeholder key approved, every project trusted.
    claude_json = {
        "hasCompletedOnboarding": True, "lastOnboardingVersion": CLI_VERSION, "theme": "dark",
        "customApiKeyResponses": {"approved": [API_KEY[-20:]], "rejected": []},
        "projects": {path: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True} for path in repos.values()},
    }
    write(os.path.join(CFG, ".claude.json"), json.dumps(claude_json, indent=1))

    json.dump({"apiKey": API_KEY, "working": WORKING, "waiting": WAITING}, sys.stdout)


if __name__ == "__main__":
    main()
