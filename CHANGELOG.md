# Changelog

## 1.0.0 — 2026-11-01

First stable release.

- **Usage line** above the omp composer's context bar, for **every provider omp reports**
  (Kimi, Codex, Claude, Gemini, MiniMax, Qwen, Z.ai, …): per-window bars, share left, reset
  countdowns, saved resets; provider colors (amber ≤25% left, red ≤10%); compact layout in
  narrow panes; change comets without motion for Reduce-Motion users.
- **Hover card**: per-window meters, reset times and clock times, saved-reset expiries, today's
  totals with a **per-provider breakdown**, settings shortcut; stays open while you point at it.
- **Model follow**: switches with the focused agent's provider in ~2 s (Alt+P); follows a viewed
  subagent's model.
- **Per-host data**: panes on remote hosts (WSL, servers) show that host's accounts and stats.
  Handled with a tiny sync block the plugin opens and parks on each remote host automatically —
  no tabs, no omp configuration.
- **Today's tokens & API-price cost** in the status bar, per the focused pane's host.
- **Dashboard block**: 7 days of usage history, today/week/month API-price costs (`r` refreshes).
- **Settings** (Ctrl+Alt+U, status-bar `usage`, palette): show mode (current / all / selected),
  provider order, per-provider colors, thresholds, refresh intervals, status-bar toggles,
  language (English / 简体中文).
- **One-line install**, zero omp configuration: `tern plugin install github.com/DoraJasmine/dora-tern-omp-usage`

Requirements: Tern 0.8+ (tested on 0.9.8, Windows & WSL), omp 18.9+ (tested on 18.14.1).

Credits and third-party notices: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
