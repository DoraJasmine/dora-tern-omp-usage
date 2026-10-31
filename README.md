# dora-tern-omp-usage

**Dora omp Usage** — your omp usage limits shown just above the omp composer's context bar in
[Tern](https://stencil.so/tern), for **every provider omp reports** (Kimi, Codex, Claude, Gemini, MiniMax, …),
plus today's tokens & API-price cost with a per-provider breakdown, a 7-day dashboard, and a settings panel.

**One-line install, no omp configuration.**

```sh
tern plugin install github.com/DoraJasmine/dora-tern-omp-usage
```

Or paste the same address into Tern's **Preferences › Plugins › Install…**

![The hover card over the usage line above the omp composer: Codex's 5h and 7d windows with meters, reset countdowns and today's totals for the pane's host](docs/images/hover-card.png)

> 简体中文说明见 [README.zh-CN.md](README.zh-CN.md)

## Requirements

- Tern 0.8+ (tested on 0.9.8, Windows and WSL)
- [omp](https://omp.sh) 18.9+ (tested on 18.14.1), signed in to at least one provider with usage limits
- No omp extension, no `config.yml` edits, no restart — install and it works

## What it shows

- **Usage line** above the focused omp pane's context hairline: per-window bars filled to the share left, with
  reset countdowns and saved resets, in each provider's colors (amber at 25% left, red at 10%).
- **Hover card** with per-window meters, reset times and clock times, saved-reset expiries, today's totals and
  settings shortcut. It stays open while you point at it.
- **Model follow**: switches to the focused agent's provider within ~2 s of a model switch (Alt+P), and shows a
  viewed subagent's model's provider.
- **Per-host data**: a pane on a remote host (WSL, a server) shows that host's accounts and stats; local panes
  show yours. Handled automatically — the plugin opens a small data block on each remote host and parks it out
  of your tab bar.
- **Status bar**: 🔥 today's tokens and 💸 today's API-price cost for the focused pane's host.
- **Dashboard**: 7 days of usage history plus today/week/month API-price cost (`r` refreshes).
- **Settings** (`Ctrl+Alt+U`, the status-bar `usage` segment, or the palette): show mode (current model /
  all providers / selected), provider order, per-provider colors, thresholds, refresh intervals, status-bar
  toggles, language (English / 简体中文).

## How the numbers are computed

- **Limits** come from `omp usage --json` — account-level, whatever providers omp is signed into. New providers
  appear with zero code changes.
- **Today** sums `omp stats --json` hourly buckets since local midnight. The per-provider breakdown aggregates
  `byModel` (input + output + cache tokens, the same semantics as the total).
- **Prices** come from omp's model catalog (`omp models --json`): the API list price per million tokens for
  input, output, cache reads and cache writes. The dollar amounts are therefore the **API-equivalent cost** of
  your usage — what it would have cost at API rates — not your subscription bill.

## Multi-host

Tern windows show panes from every connected host, and a plugin's window half runs on the window's machine.
This plugin bridges the gap the documented way: each host's host half renders a tiny `sync` block containing
that machine's data as text; the window reads every sync block it can see (`cx.session:read`) and maps panes to
hosts (`cx.hosts:list`). The sync block opens automatically when you work on a remote host and is parked out of
your tab bar immediately.

## Development

```sh
git clone https://github.com/DoraJasmine/dora-tern-omp-usage
tern plugin link ./dora-tern-omp-usage   # link your checkout
tern plugin reload dora-tern-omp-usage   # after edits
tern plugin types ./dora-tern-omp-usage  # regenerate tern.d.luau for luau-lsp
```

`docs/` carries the (Chinese) requirements and architecture documents, including the multi-host semantics and
the Tern APIs this plugin relies on.

## Credits

- [jmazzola/tern-plugin-omp-usage](https://github.com/jmazzola/tern-plugin-omp-usage) (MIT) — the CSS technique
  this plugin's line and card rendering is adapted from (the composer meter's `::before` content with one
  `background-clip: text` gradient).
- [joaodutra88/tern-omp-usage](https://github.com/joaodutra88/tern-omp-usage) (MIT) — the pure-Tern-plugin
  fetch architecture, status-line segments, dashboard block and per-day stats accumulation this build extends
  to every provider and host.

## License

[MIT](LICENSE) © 2026 DoraJasmine — third-party attributions and notices:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
