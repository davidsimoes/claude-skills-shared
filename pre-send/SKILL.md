---
name: pre-send
description: "Pre-send approval ritual that creates the flag required by the send-gate.sh PreToolUse hook. Run this BEFORE any external-send tool (Slack, Gmail, Missive, WhatsApp, HubSpot engagement, DocuSign, etc.). Shows the final draft, requires explicit 'send it' confirmation, then drops /tmp/claude-send-approved with 300s TTL. Triggered automatically by Claude when about to call a send tool, or manually by the user. Use when composing an outbound message, before any send_message / send_email / send_envelope call, or say '/pre-send'."
user-invocable: true
disable-model-invocation: false
---

# /pre-send — Approval ritual for outbound sends

Partner skill to the `send-gate.sh` PreToolUse hook (ships in [`hooks/send-gate.sh`](./hooks/send-gate.sh)). The hook blocks every external-send tool unless `/tmp/claude-send-approved` exists and is <300s old. This skill creates that flag — but only after (a) showing the user the final draft and (b) receiving explicit "send it" style confirmation.

**Why this exists:** structural complement to behavioural "always confirm before send" rules. Behavioural rules alone have repeatedly failed in practice (agent interprets "start" or "go" as confirmation, sends a modified draft without re-confirmation, fires from a wakeup that has no human in the loop). The hook + this skill together are load-bearing: the hook physically cannot be bypassed, and this skill is the ONE path to the flag.

## Setup

1. Drop the SKILL into `~/.claude/skills/pre-send/`.
2. Install the hook by adding it to your `settings.local.json`'s PreToolUse matchers:

   ```jsonc
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Bash|mcp__.*__send.*|mcp__.*__slack_send.*|mcp__.*__send_email|mcp__.*__send_envelope",
           "hooks": [
             { "type": "command", "command": "~/.claude/hooks/send-gate.sh" }
           ]
         }
       ]
     }
   }
   ```

3. Copy `hooks/send-gate.sh` from this skill's directory to `~/.claude/hooks/send-gate.sh` and `chmod +x` it.

Tune the `matcher` regex for whichever send tools you actually use.

## When to invoke

Claude should invoke this **programmatically** as the last step before any external-send tool call. The user can also invoke it manually with `/pre-send` to explicitly prep a send.

Send tools commonly covered (extend the matcher as you add MCPs):
- `mcp__claude_ai_Slack__slack_send_message`
- `mcp__missive__send_message`
- `mcp__claude_ai_Gmail__send_email`, `mcp__gmail__send_email`
- `mcp__whatsapp__send_message`, `mcp__whatsapp__send_audio_message`, `mcp__whatsapp__send_file`
- `mcp__digisign__send_envelope`
- `mcp__claude_ai_HubSpot__manage_crm_objects`

If a send tool isn't in the matcher yet but is being used: add it to the matcher and re-run.

**Wakeup compliance**: if /pre-send is invoked from a wakeup or scheduled task, the Step 4 "send it" confirmation MUST come from the user in chat — never inferred from the wakeup prompt's instructions. Past-Claude cannot pre-approve future-Claude's sends. This is one of the failure modes the hook + skill combo was built to close.

## Step 1 — Load the draft into view

The draft must already exist in the current conversation context (Claude's been composing it). Re-read the most recent draft from the conversation.

If no draft is visible: STOP. Return `No draft found — compose the message first, then re-invoke /pre-send.` Don't create the flag.

## Step 2 — Show the draft

Present in a compact, copy-able block with the fields the user needs to eyeball:

```
╭─ Pre-send review ─────────────────────────────────────
│ Tool:       <send tool name>
│ Channel:    <email / slack / whatsapp / digisign / hubspot>
│ Recipient:  <to address(es) — full list>
│ Subject:    <subject line if applicable>
│ Thread:     <thread ID or "new" — per threading rule>
│ Body:
│   <full body as it will be sent, no trimming>
│
│ Attachments: <list or "none">
╰───────────────────────────────────────────────────────
```

## Step 3 — Run quality checks (silent unless a check fails)

Before asking for approval, validate:

1. **Voice / style rules** — load whatever local rules you have for outbound (signature per channel, threading expectations, identity framing, no em dashes, formality level). Check the draft against them.

2. **Commitment detection** — scan body for commitment patterns ("I'll", "I will", "we'll", "let me", "I'm going to", "expect [X] from me", and equivalents in any other language you write in). If matched: surface with `⚠ Commitment detected: "<snippet>"` and ask if the user wants a task created in their task system after send.

3. **Leaked secret scan** — regex for obvious tokens: `sk-[a-zA-Z0-9]`, `eyJ[A-Za-z0-9_-]+\.` (JWT), `ghp_[A-Za-z0-9]+`, `Authorization: Bearer`, 40+ char hex sequences, `password`/`api_key` with `=` or `:`. Surface any match and REFUSE to set the flag until cleaned.

4. **Modified-draft check** — if the user previously approved a draft in this session, verify the current draft body matches or the user acknowledges the change. **Exception: voice-rule compliance fixes** (em-dash → period, missing signature added, greeting normalization, formatting cleanup, trailing whitespace) apply automatically without re-approval — they're mechanical and bring the draft INTO compliance with already-approved rules. Content changes (new claims, different recipient, different ask, different quantity/price/date) require explicit re-approval. Rule of thumb: if the fix is "something the user's voice rules would have required anyway", apply silently and proceed to Step 5.

   **Structural backstop:** the 300s TTL + single-use flag mean every send requires a fresh /pre-send invocation that re-shows the current body. Drift between approval and send is bounded by 5 minutes; the second send needs a second /pre-send. This is what makes re-approval enforceable rather than purely behavioural.

If any check fails: surface the finding, ask the user whether to proceed anyway (commitment/modified-draft are advisory) or fix (secret leak is non-negotiable).

## Step 4 — Require explicit confirmation

Ask verbatim: `Send it? (reply "send it" / "ship it" / "go ahead" to confirm — any other reply aborts)`.

Accept as confirmation:
- `send it`, `send`, `ship it`, `ship`, `go ahead`, `yes send`
- equivalents in other languages you operate in
- case-insensitive, leading/trailing whitespace OK

Reject as confirmation:
- `ok`, `go`, `start`, `proceed`, `yes` alone — all ambiguous and historically misinterpreted
- Any negative or neutral reply

If rejected: say `Aborting /pre-send. Flag NOT set. Re-run when ready.`

## Step 5 — Create the approval flag

On confirmation:
```bash
touch /tmp/claude-send-approved
```
The flag gets the current mtime. The gate checks mtime within 300s TTL and consumes (rm) the flag on allow. So ONE /pre-send → ONE send. For a second send, re-run /pre-send.

Emit: `✓ Approved. Calling <tool> now.` Then IMMEDIATELY invoke the send tool — the gate passes, the tool fires, the flag is consumed.

## Step 6 — After send

After the send tool returns success:
- Log to your CRM / system-of-record if relevant.
- If a commitment was detected in Step 3 and the user said yes, create the follow-up task in your task system.
- Never silently retry on failure — surface the error so the user can decide whether to re-approve or abandon.

## Optional: autopilot exception

The bundled `hooks/send-gate.sh` whitelists sessions that opt in to autopilot mode (env var `CLAUDE_AUTOPILOT_SESSION=1`, or a tmux session name matching the autopilot pattern). If you build a long-running unattended automation that legitimately needs to send without per-message human approval, set that env var. Use sparingly — the gate exists for a reason.

## Failure modes

- **Flag exists from earlier, still fresh** — the hook consumes it on first send; /pre-send recreates on next invocation. No conflict.
- **Concurrent sends from two sessions** — single-use flag: whichever session's send tool fires first consumes the flag; the second blocks. Expected.
- **TTL expired between /pre-send and send** — hook blocks with stale-approval message. Re-run /pre-send. Doesn't happen if send fires immediately after approval (typical case).
- **Secret leak detected** — refuse to set flag. User fixes draft and re-runs.

## Why This Exists

Three categories of failures drove this skill:

1. **Interpreted confirmations** — agent reads "start" or "go" as "send it" and fires.
2. **Modified-draft drift** — user approves draft v1, agent edits to v2, fires v2 without re-confirmation.
3. **Wakeup-triggered sends** — a deferred task fires without a human in the loop and infers approval from the wakeup prompt itself.

The behavioural rule "never send without explicit approval" existed in all three cases and was violated anyway. The structural fix — a PreToolUse hook that physically blocks the send unless a fresh single-use flag exists, paired with this skill as the ONLY supported path to creating that flag — removes the interpretation layer entirely.
