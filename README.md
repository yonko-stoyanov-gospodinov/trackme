# trackme

A macOS menu bar app and desktop widget that shows what your Claude Code sessions cost, for pay-per-token API use.

- **Desktop widget:** today, 7-day and 30-day spend, active sessions, sitting on the desktop under your windows, with tabs to switch between customers. Drag it anywhere; it remembers the spot. Right-click it to refresh, keep it on top of other windows, or hide it.
- **Menu bar:** a cat icon with a menu of the settings (prices, keep awake, launch at login, show the widget again, quit).
- **Keep awake:** holds off system sleep while a Claude Code session is working, and for a few minutes after, so a long task is not cut off when you walk away. The screen still locks.

Everything is computed on your Mac from files Claude Code already writes. The app makes no network requests.

## Build and run

Needs macOS 12 or later and the Xcode command line tools (`xcode-select --install`).

```sh
sh build.sh            # build and launch from ./build
sh build.sh install    # build, copy to /Applications, launch from there
sh build.sh test       # run the engine tests
```

Use `install` before turning on **Launch at login** in the menu bar menu, so the login item points at a stable location.

## Where the numbers come from

Claude Code writes one transcript per session to `~/.claude/projects/<project>/<session>.jsonl` (also checked: `~/.config/claude`, and `CLAUDE_CONFIG_DIR` if the app inherits it). Each assistant line records the model and the token counts the API reported. The app:

1. Reads those lines, including subagent transcripts stored under `<session>/subagents/`.
2. Counts each API response once. Streaming writes a response more than once and resumed sessions can replay history, so duplicates are matched on message ID plus request ID.
3. Multiplies tokens by the prices in the price table.

Days are your local calendar days. A session's active time ignores gaps longer than five minutes.

## Customers

To see spend per customer, give each customer's sessions a name. The simplest way is one start script per customer:

```sh
#!/bin/sh
# claude-acme
exec claude --name "Acme" "$@"
```

Two such scripts, `Scripts/vm-claude.sh` and `Scripts/ps-claude.sh`, are in the project; copy them somewhere on your `PATH` or run them by path.

The name is written into the session's transcript, and trackme groups sessions by the part of the name before the first colon. So `--name "Acme"` and `--name "Acme: billing"` both count as Acme, and renaming a session with `/rename` keeps it with its customer as long as the prefix stays. Sessions with no name are grouped as "Other".

The widget has a tab per customer. **vm** and **ps** are listed from the start; change that list with **Customers…** in the menu bar menu. Any other name found in the transcripts gets a tab of its own, and sessions with no name are grouped under **Other**. Click a tab to see that customer's today, 7-day and 30-day spend; **All** shows everything together.

## Spend since a day

Choose **Since…** in the menu bar menu to pick a day. The big figure then shows the spend from the start of that day until now (for the selected customer), in place of today's figure. **Reset since date** goes back to the normal view. The date is kept until it is reset.

## Keeping the Mac awake

A long Claude Code task dies when the Mac goes to sleep and loses its network. trackme can hold a power assertion of the kind `caffeinate -i` uses while any session is working: the display still dims, sleeps and locks on your usual schedule, but the Mac and its network stay up. The widget shows a small bolt while the assertion is held, and `pmset -g assertions` lists it as "trackme: Claude Code is working".

Knowing when a session is working takes a Claude Code hook. Choose **Keep awake ▸ Install hook** in the menu bar menu. That adds trackme to the `hooks` section of `~/.claude/settings.json` (or the first folder in `CLAUDE_CONFIG_DIR`) for every event that marks the start or end of work, leaving any hooks already there in place. The file as it was before the first change is kept as `settings.json.before-trackme`; the keys in the rewritten file come out sorted. Sessions already running pick the hook up when they are restarted. **Remove hook** takes trackme out again.

The hook is the app itself, run as `trackme --hook`. It reads the event from stdin, writes one small file per session in `~/Library/Application Support/trackme/sessions/`, and exits in a few milliseconds. The states:

- **working** after a prompt is submitted, before and after each tool call, through compaction, and while subagents run;
- **waiting** when Claude Code is blocked on a permission prompt or a question;
- **idle** when a turn ends or the session starts, and the file is removed when the session ends.

The app re-reads these files every 15 seconds. The Mac is kept awake while any session is working, and for a grace period after the last one stops (**Linger for**: 2, 5, 15 or 30 minutes; 5 by default). Two more switches: **Approving**, off by default because nothing happens until you answer; and **On battery**, off by default so a MacBook does not drain itself.

Two guards keep a crashed session from holding the Mac awake forever: the hook records the Claude Code process ID, and a session whose process is gone is dropped; and a "working" state that has not been refreshed for 30 minutes is treated as abandoned. Claude Code reports at least once per tool call, so a live session never goes that long in silence. A MacBook with its lid closed sleeps regardless of any assertion unless it is on power with an external display; leave the lid open.

## Prices

Built-in prices are Anthropic's API list prices as read on 2026-10-03 from
<https://platform.claude.com/docs/en/about-claude/pricing>. To change them, choose **Prices…** in the menu bar menu. That creates `~/Library/Application Support/trackme/prices.json`; the app picks up edits within 15 seconds. **Reset to built-in prices** deletes the file.

Each entry's `match` is looked for inside the model ID, and the longest match wins. A model with no entry is counted in tokens but not in dollars, and the footer names it.

## Limits

- **It is an estimate, not your bill.** It uses list prices. It does not apply the 1.1x US-only inference multiplier, the legacy long-context surcharge on Sonnet 4 and 4.5, or any discount on your account. The Claude Console is the authority on what you were charged.
- **History is as long as the transcripts.** Claude Code deletes transcripts after 30 days by default (`cleanupPeriodDays` in its settings). The app keeps no history of its own.
- **The transcript format is internal to Claude Code** and can change between versions. The parser ignores anything it does not recognise, so a format change shows up as missing usage, not a crash.
- A session that runs past midnight is listed with its whole cost, while the day totals split it by day.
- Keep awake only knows about sessions started after the hook was installed, and cannot help if the network is switched off by something other than the Mac sleeping.

## Layout

```
Sources/Core   engine: parsing, prices, totals, hook states, settings merge (no UI; builds on any platform)
Sources/App    menu bar item, desktop widget, views, sleep assertion, hook command
Tests          engine tests with hand-computed expected totals
Scripts        start scripts that name a session after a customer
build.sh       compiles and packages the .app
```
