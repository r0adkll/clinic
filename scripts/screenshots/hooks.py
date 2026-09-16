#!/usr/bin/env python3
"""Puts the staged sessions into the states the hero shows (ADR-159).

The resumed `claude` processes sit idle at their prompts, so the states a real turn would report are sent
to Clinic's hook socket the way `clinic-hook` sends them: working, waiting for permission, and a status
line each for the context gauge.

usage: hooks.py <hook.sock> <working-session-id> <waiting-session-id>
"""
import json
import socket
import sys

sock, working, waiting = sys.argv[1:4]


def send(event):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock)
    s.sendall(json.dumps(event).encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    s.close()


send({"hook_event_name": "UserPromptSubmit", "session_id": working, "prompt": "Fix checkout total rounding"})
send({"hook_event_name": "StatusLine", "session_id": working,
      "model": {"id": "claude-opus-5", "display_name": "Opus 5"}, "effort": {"level": "high"},
      "context_window": {"used_percentage": 42, "context_window_size": 200000, "total_input_tokens": 84000}})
send({"hook_event_name": "PermissionRequest", "session_id": waiting, "tool_name": "Bash"})
send({"hook_event_name": "StatusLine", "session_id": waiting,
      "model": {"id": "claude-sonnet-5", "display_name": "Sonnet 5"},
      "context_window": {"used_percentage": 61, "context_window_size": 200000, "total_input_tokens": 122000}})
