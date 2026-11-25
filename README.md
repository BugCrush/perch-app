# Perch

**Your Claude Code sessions, from your phone.**

Perch lets you watch and steer the Claude Code sessions running on your computers from an Android phone: see what every session is doing, answer Claude's questions and permission requests, send messages, start new sessions, and get a notification when Claude needs you or is done. It works with sessions you started in a terminal, not only ones Perch started.

- **Every session on every machine** — live state (working, waiting for you, done), the conversation, Stop.
- **Answer from anywhere** — permission requests, plans and Claude's questions arrive as cards: Allow, Deny, Approve, or pick answers and Submit.
- **Notifications** — when a session needs an answer or finishes, and nothing while you are at the machine.
- **Start sessions** — in any folder, with the model you want; the terminal opens on the machine.
- **Task board** — projects and tasks on your phone; run a task on a machine and get Claude's report back for review. `/perch` shows the same board inside Claude Code.
- **Usage limits** — when your plan's limit hits, choose to continue when it resets, wait, or switch account.
- **Private by design** — the phone and the machine talk end-to-end encrypted. The relay that connects them away from home only passes sealed messages it cannot read.

> **Beta.** Perch is being tested by a small group. Expect rough edges and tell us what breaks.

## What you need

- **Claude Code** on the machine (Perch is a Claude Code plugin plus a small background program, the *host*).
- **Windows 10 or 11 (x64)** or **macOS on Apple Silicon**.
- **An Android phone**, Android 7.0 or newer. (No iPhone app yet.)
- On the same Wi-Fi Perch works on its own. **Away from home** it goes through a relay: during the beta you need an **invite code** for it.

## Install

### 1. On each computer: the Claude Code plugin

In Claude Code, run:

```
/plugin marketplace add BugCrush/perch-app
/plugin install perch@perch
```

Then start a new Claude Code session. In the background the plugin downloads the Perch host for your system from this repository's Releases, checks its SHA-256 checksum, sets it to start when you log in, and starts it. It takes about a minute the first time and prints nothing; its log is `%APPDATA%\perch\setup.log` (Windows) or `~/.perch/setup.log` (Mac).

Turn on automatic updates once: `/plugin` → **Marketplaces** → **perch** → **Enable auto-update**.

**On a Mac** Perch needs two permissions a plugin cannot give itself:

- **System Settings → Privacy & Security → Accessibility**: turn on **Terminal** (and **Warp** if you use it), so Perch can type your answers into terminal sessions.
- When macOS asks whether **"sh" may control "Terminal"**, choose **Allow** (that is how the host starts at login).

### 2. On your phone: the app

Download `perch-<version>.apk` from the [latest release](https://github.com/BugCrush/perch-app/releases/latest) on your phone and open it. Android asks you to allow installing apps from your browser once.

On Samsung phones: if notifications arrive late while the screen is off, set **Settings → Apps → Perch → Battery** to **Unrestricted**.

### 3. Pair them

1. In Claude Code on the computer, type `/perch` and choose **Pair your phone**. A QR code appears.
2. In the app, tap **Add machine** and scan it.
3. On the computer, Perch asks whether to let the phone in: choose **Allow** (or **Watch only** for a phone that may look but not act).

### 4. The invite code (to reach your machine away from home)

If `/perch` says **"this relay needs an invite code"**, choose **Enter invite code**, type the code you were sent (`perch-xxxx-xxxx-xxxx`) and **Save**. On the same Wi-Fi everything works without it.

## Using Perch

- **Sessions** — open a machine to see its sessions. Tap one for its conversation; type to send it a message; **Stop** interrupts it.
- **Cards** — when Claude asks something, a card appears in the conversation (and as a notification). Questions come as a deck: one page per question, then your answers and **Submit**.
- **New session** — on a machine, **New session**, pick the folder and model; a terminal opens there.
- **Board** — projects and tasks. **Run on…** sends a task to a machine (a new session, or one that is idle); when Claude is done the task moves to **Review** with its report. In Claude Code, `/perch` lists the same board and can start a task in the current session.
- **Search** — every conversation on every machine.
- **Usage limit** — when the limit hits, the card offers **Continue when available**, **Wait** or **Switch account**.
- **Devices** — on the phone, the machine's menu lists the paired devices; remove one to lock it out.

## Updates

- **Computer**: with auto-update on, Claude Code updates the plugin, and the plugin moves the host to the new version when it is idle.
- **Phone**: the app says **Update available** when a newer release is out; tap **Download**.

## Privacy and security

- Messages between the phone and the machine are end-to-end encrypted with keys made at pairing; each phone has its own key.
- The relay (a Cloudflare Worker) only forwards sealed messages and stores short-lived counters and push tokens. Notifications are sealed too: Google's push service carries text it cannot read.
- A new phone must be allowed at the machine before it sees anything. Your Claude login and tokens stay on your machine.

## Troubleshooting

- **The phone does not find the machine**: run `/perch` on the computer; if it says the host is not running, start a new Claude Code session (the plugin starts it) and look at `setup.log`.
- **Works at home but not away**: the relay needs your invite code (`/perch`), or the shared daily allowance is used up (it resets at 00:00 UTC).
- **Answers are not typed into a terminal on a Mac**: check the Accessibility permission above.

Please report problems in [Issues](https://github.com/BugCrush/perch-app/issues).

## Build it yourself

The source is all here: `packages/perch_host` (the host, Dart), `packages/perch_protocol` (the wire protocol), `apps/perch_app` (the app, Flutter), `relay/` (the Cloudflare Worker), and the plugin in `packages/perch_host/claude_plugin/perch`.

- Flutter 3.50 / Dart 3.14: run `flutter pub get` at the root, then `dart test` in `packages/*` and `flutter test` in `apps/perch_app`.
- Host: `dart run bin/perch_host.dart serve` in `packages/perch_host`.
- Your own relay: `npm ci` and `npx wrangler deploy` in `relay/` (a free Cloudflare account is enough), then `perch_host relay set <url>`. Push notifications need your own Firebase project (`google-services.json` for the app, the service-account key as the Worker secret `FCM_SERVICE_ACCOUNT`).

## Licence

Perch is free software under the [GNU Affero General Public License v3.0](LICENSE). If you run a modified Perch as a service for others, you must offer them its source.
