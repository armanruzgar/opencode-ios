# Changelog

Notable changes to the app, the push plugin and the relay. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## 1.0.0 - Unreleased

The first release.

### App

- **Pairing and connections.** Pair with the QR code or link from `opencode pair`, or with a URL and password. Credentials are kept in the Keychain. Each server can have several addresses (LAN, Tailscale, HTTPS, OpenTunnel); the app tries encrypted ones first, races them, watches the event stream, backs off, and resyncs over REST after every reconnect. opencode 1.x servers and V2 servers older than 2.0.25 get an upgrade screen.
- **Try a demo.** Recorded sessions to explore from the first screen, with no server, no network and nothing kept afterwards.
- **Home.** Sessions from every server and project, grouped by day, with *Needs you* and *Running* on top, search, unread markers, pins and a project picker. Sessions archived in opencode (2.1 and later, including `opencode run --archived`) stay out, and leave as soon as they are archived elsewhere.
- **Transcript.** Streaming Markdown with highlighted code, tables, Mermaid diagrams and TeX; reasoning; grouped tool calls; diff cards; images with full-screen zoom; live shell output; subagent drill-in; and paging for long sessions.
- **Approvals and questions.** The full command, path or diff before you answer. Allow once, Allow always (behind device authentication) or Reject with a note, with risk tiers. Question forms cover every field type.
- **Prompt dock.** `@` mentions for files, agents, skills and references; `/` commands, including `/btw` side questions; `!` shell mode; image, PDF and file attachments; model, variant and agent pickers; steer, queue and stop; prompt history; and on-device dictation with a hands-free mode. Drafts and an outbox survive a relaunch, and no prompt is sent twice.
- **Review and files.** Per-turn, uncommitted and branch changes as unified or split diffs with word-level highlights; reviewed marks; line comments that go into the next prompt; commit-and-push and pull request prompts; and a file browser with highlighting, find and previews.
- **Terminal.** Terminals on the server with a key bar, hardware keyboard support, full-screen programs and resume after the app was in the background or closed. Run a command outside any session and watch or stop it.
- **Session actions.** Rename, fork, compact, undo, redo, move to another worktree, and export as Markdown or JSON, redacted by default.
- **Settings.** Providers with API keys and sign-in, MCP servers, saved permissions, agents, commands, skills and plugins, projects, configuration, worktrees, server administration and usage statistics.
- **Push notifications.** End-to-end sealed alerts for approvals, questions, finished and failed runs, delivered through the relay or straight to Apple with your server's own APNs key, chosen per server; lock-screen actions with risk tiers, where every action that sends needs an unlocked device; a Live Activity for runs started from the phone; per-kind settings, per-session mute and quiet hours that never silence approvals; App Attest on relay registration.
- **iPad workspace.** Project tabs, a collapsible Home sidebar, a review panel with Changes, Files, Terminal and Context, a menu bar with keyboard shortcuts, a ⌘K switcher, a window per session and drag and drop into the composer.
- **System integration.** Shortcuts and Siri, Spotlight, Home and Lock Screen widgets, and Control Center controls.
- **Accessibility.** XCUITest accessibility audits of every main screen on iPhone and iPad, in light and dark mode; VoiceOver rows with custom actions and announcements for permissions and questions; Dynamic Type up to the largest accessibility sizes; and Reduce Motion.
- **Localization groundwork.** Every user-facing string is in a String Catalog with comments for translators and English plurals, and layouts are checked with double-length strings and right to left. English is the only language so far.
- **Privacy and licences.** Privacy manifests for the app and both extensions, and an Acknowledgements screen under Settings → About with every component's licence.

### Push plugin

- An opencode V2 server plugin that seals a notification for each registered device with HPKE and sends it through the relay: approvals and questions after a short grace period, finished and failed runs, replacements when a request is answered elsewhere, and Live Activity updates.
- Presence: no alerts while the app is open on that device.
- Direct mode: with your own APNs key, the plugin sends to Apple itself over HTTP/2, with no relay.

### Relay

- A Cloudflare Worker (with a Node entry point) that turns sealed envelopes into APNs requests. It stores token hashes and APNs tokens, never notification content, and enforces per-device rate limits.
- App Attest verification of device registrations, against Apple's pinned root, behind `APP_ATTEST` (off by default).

