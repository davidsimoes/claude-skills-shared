#!/usr/bin/env python3
"""
write-manifest.py — atomic manifest writer for /restart-process.

Reads inventory JSON (from snapshot.sh --phase=1) on stdin, plus handoff/pane-state
files already written to the manifest dir, and builds:

  <manifest_dir>/manifest.json   — canonical schema, sha256-checksummed, atomic-written
  <manifest_dir>/launch-<S>-<W>-<P>.sh   — per-claude-pane launcher wrappers (already exist;
                                          this script just makes them executable + validates)

Atomicity: write to .tmp → fsync → rename. Manifest file is written LAST so its
existence is the commit marker for the whole capture.

Schema: see SCHEMA_VERSION + build_manifest() below.

Usage:
  cat inventory.json | write-manifest.py \\
    --manifest-dir <path> \\
    --orchestrator-pane <S:W.P> \\
    --orchestrator-cwd <abs_path> \\
    --captured-at <ISO-ts> \\
    --claude-binary-path <abs_path> \\
    --resume-orchestrator-cwd <abs_path>

Exit codes:
  0 = manifest written successfully
  1 = bad args / bad inventory
  2 = filesystem write failure
  3 = expected handoff file missing for a claude pane
"""

import argparse
import hashlib
import json
import os
import sys
from typing import Any, Dict

SCHEMA_VERSION = 1


def canonical_json(obj: Any) -> str:
    """Stable JSON for checksum — sorted keys, no whitespace variability."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def sha256_of(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def atomic_write(path: str, content: str) -> None:
    """Write to .tmp → fsync → rename. Raises on failure."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp, path)


def pane_key(session: str, window_index: int, pane_index: int) -> str:
    """Filename-safe key for a pane (used for handoff-X.md, launch-X.sh, etc)."""
    safe_session = session.replace("/", "-").replace(" ", "_")
    return f"{safe_session}-{window_index}-{pane_index}"


def build_manifest(
    inventory: Dict[str, Any],
    orchestrator_pane: str,
    orchestrator_cwd: str,
    captured_at: str,
    claude_binary_path: str,
    resume_orchestrator_cwd: str,
    manifest_dir: str,
) -> Dict[str, Any]:
    """
    Build the canonical manifest dict from inventory.

    Manifest structure:
      {
        schema_version: 1,
        captured_at: ISO timestamp,
        orchestrator_pane: "session:window.pane" (this session — will respawn last),
        resume_orchestrator_cwd: where /restart-resume should be invoked,
        claude_binary_path: absolute path captured at capture time,
        target_dir: from inventory (CLAUDE_CONFIG_DIR or default),
        target_version: from inventory,
        windows: [{ tmux_target, session, window_index, window_name,
                    window_layout, panes: [...] }, ...],
        checksum: sha256(canonical_json(records))     ← added last
      }

    Per-pane records keep all snapshot.sh fields plus:
      - is_claude (bool)
      - is_orchestrator (bool) — true iff this pane == orchestrator_pane
      - handoff_path (relative to manifest_dir) — claude panes only
      - launcher_path (relative) — claude panes only
      - pane_state_path (relative) — non-claude panes only
    """
    windows_out = []
    for w in inventory.get("windows", []):
        panes_out = []
        for p in w["panes"]:
            session = w["session"]
            wi = w["window_index"]
            pi = p["pane_index"]
            tmux_target_pane = f"{session}:{wi}.{pi}"
            key = pane_key(session, wi, pi)

            rec = dict(p)  # copy raw snapshot fields
            rec["tmux_target_pane"] = tmux_target_pane
            rec["is_claude"] = p.get("claude_pid") is not None
            rec["is_orchestrator"] = tmux_target_pane == orchestrator_pane

            if rec["is_claude"]:
                handoff = f"handoff-{key}.md"
                launcher = f"launch-{key}.sh"
                rec["handoff_path"] = handoff
                # launcher_path retained for backward compat; restore.sh sends
                # `claude "$(cat <handoff>)"` directly via tmux send-keys to the
                # pane's interactive shell so any user-defined `claude` shell
                # function (credential binding, plugin sync, etc.) still runs.
                # A non-interactive bash launcher would bypass it and may hit
                # OAuth onboarding.
                rec["launcher_path"] = launcher
                # Verify handoff file exists (it should have been written by extract-handoff)
                handoff_full = os.path.join(manifest_dir, handoff)
                if not os.path.exists(handoff_full):
                    raise FileNotFoundError(
                        f"missing handoff file for claude pane {tmux_target_pane}: {handoff_full}"
                    )
            else:
                pane_state = f"pane-state-{key}.json"
                rec["pane_state_path"] = pane_state
                pane_state_full = os.path.join(manifest_dir, pane_state)
                # Write pane-state for non-claude panes here (small file, single source)
                state_data = {
                    "tmux_target_pane": tmux_target_pane,
                    "cwd": p.get("pane_path", ""),
                    "argv": p.get("cmd", ""),  # may be empty
                    "command": p.get("cmd", ""),
                }
                atomic_write(pane_state_full, canonical_json(state_data))

            panes_out.append(rec)

        windows_out.append({
            "tmux_target": w["tmux_target"],
            "session": w["session"],
            "window_index": w["window_index"],
            "window_name": w["window_name"],
            "window_layout": w["window_layout"],
            "panes": panes_out,
        })

    records = {
        "schema_version": SCHEMA_VERSION,
        "captured_at": captured_at,
        "orchestrator_pane": orchestrator_pane,
        "resume_orchestrator_cwd": resume_orchestrator_cwd,
        "claude_binary_path": claude_binary_path,
        "target_dir": inventory.get("target_dir", ""),
        "target_version": inventory.get("target_version", ""),
        "windows": windows_out,
    }

    manifest = dict(records)
    manifest["checksum"] = sha256_of(canonical_json(records))
    return manifest


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest-dir", required=True)
    ap.add_argument("--orchestrator-pane", required=True)
    ap.add_argument("--orchestrator-cwd", required=True)
    ap.add_argument("--captured-at", required=True)
    ap.add_argument("--claude-binary-path", required=True)
    ap.add_argument("--resume-orchestrator-cwd", required=True)
    args = ap.parse_args()

    if not os.path.isdir(args.manifest_dir):
        print(f"ERROR: manifest dir does not exist: {args.manifest_dir}", file=sys.stderr)
        return 1

    try:
        inventory = json.load(sys.stdin)
    except Exception as e:
        print(f"ERROR: failed to parse inventory JSON from stdin: {e}", file=sys.stderr)
        return 1

    try:
        manifest = build_manifest(
            inventory=inventory,
            orchestrator_pane=args.orchestrator_pane,
            orchestrator_cwd=args.orchestrator_cwd,
            captured_at=args.captured_at,
            claude_binary_path=args.claude_binary_path,
            resume_orchestrator_cwd=args.resume_orchestrator_cwd,
            manifest_dir=args.manifest_dir,
        )
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 3
    except Exception as e:
        print(f"ERROR: build_manifest failed: {e}", file=sys.stderr)
        return 1

    manifest_path = os.path.join(args.manifest_dir, "manifest.json")
    try:
        atomic_write(manifest_path, json.dumps(manifest, indent=2))
    except OSError as e:
        print(f"ERROR: atomic_write failed: {e}", file=sys.stderr)
        return 2

    # Print summary on stdout for the orchestrator
    n_claude = sum(1 for w in manifest["windows"] for p in w["panes"] if p["is_claude"])
    n_non_claude = sum(1 for w in manifest["windows"] for p in w["panes"] if not p["is_claude"])
    print(json.dumps({
        "manifest_path": manifest_path,
        "checksum": manifest["checksum"],
        "schema_version": manifest["schema_version"],
        "n_claude_panes": n_claude,
        "n_non_claude_panes": n_non_claude,
        "n_windows": len(manifest["windows"]),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
