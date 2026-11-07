-- Builds the usage line's model from the plugin's data and renders it as CSS, using the technique
-- jmazzola/tern-plugin-omp-usage (MIT) proved out: the line is the focused composer meter's `::before`
-- content, one static `background-clip: text` gradient colors each part and fills each bar glyph by glyph.
-- Adapted here: windows come from structured omp reports (lib/parse), not from status-line text.
local parse = require("./parse")
local settings_lib = require("./settings")
local labels = require("./labels")

local M = {}

local GLYPH = 6 -- px: one glyph of the 10px mono line font
local BAR = "━"
local BAR_GLYPHS = 8
local COMPACT_BAR_GLYPHS = 6
local BAR_Y = 7.25
local TIP_W, TIP_H = 10, 6
local CARD_ROW = 18
local CARD_MIN = 28
local CARD_INDENT = "  "
local NBSP = "\u{00A0}"
local SEPARATOR = " · "

local METER = ".tn-pane.on .sf-meter[data-role='omp.composer.context']"
local HOST_BASE = "%s.sf-col[data-role^='omp.editor'] > .sf-row[data-role='omp.composer.chips']:is(.sf-hidden, .sf-void)"

local function host(region: string?): string
	return ".tn-pane.on " .. string.format(HOST_BASE, if region then region .. " " else "")
end

-- ── format helpers ──────────────────────────────────────────────────────────

local function css_string(s: string): string
	return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ") .. '"'
end

local function fill(template: string, vars: { [string]: string }): string
	return (string.gsub(template, "%$([%w_]+)", function(name: string): string
		return vars[name] or ""
	end))
end

local function num(x: number, places: number?): string
	local s = string.format("%." .. tostring(places or 2) .. "f", x)
	s = (string.gsub(s, "0+$", ""))
	s = (string.gsub(s, "%.$", ""))
	return if s == "-0" then "0" else s
end

-- Tern drops a gradient stop whose color is a bare `var()` holding `light-dark()`, but takes it inside a
-- relative color.
local function solid(color: string): string
	return "rgb(from " .. color .. " r g b)"
end

local function faded(color: string, percent: number): string
	return string.format("rgb(from %s r g b / %d%%)", color, percent)
end

local function em(glyph: number): string
	return num(glyph * 0.6, 3) .. "em"
end

local function glyph_count(s: string): number
	local _, n = string.gsub(s, "[^\128-\191]", "")
	return n
end

local function unbroken(s: string): string
	return (string.gsub(s, " ", NBSP))
end

local function compact_number(n: number): string
	if n >= 1e9 then
		return string.format("%.1fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	elseif n >= 1e3 then
		return string.format("%.1fk", n / 1e3)
	end
	return tostring(math.floor(n))
end
M.compact_number = compact_number

local function countdown(reset_at: number?, now: number): string?
	if reset_at == nil or reset_at <= now then
		return if reset_at then "soon" else nil
	end
	local mins = math.max(1, math.floor((reset_at - now) / 60000))
	if mins < 60 then
		return tostring(mins) .. "m"
	end
	local hours = math.floor(mins / 60)
	if hours < 24 then
		return string.format("%dh%02dm", hours, mins % 60)
	end
	return string.format("%dd%dh", math.floor(hours / 24), hours % 24)
end

local function span_left(ms: number): string
	local mins = math.max(1, math.floor(ms / 60000))
	if mins >= 1440 then
		local days = math.floor(mins / 1440)
		return string.format("%dd %dh", days, math.floor((mins % 1440) / 60))
	elseif mins >= 60 then
		return string.format("%dh %dm", math.floor(mins / 60), mins % 60)
	end
	return tostring(mins) .. "m"
end

local function tone_of(pct: number, warn_at: number, bad_at: number): string
	if pct <= bad_at then
		return "bad"
	elseif pct <= warn_at then
		return "warn"
	end
	return "ok"
end

-- ── model ───────────────────────────────────────────────────────────────────

-- Whether a model's bare id belongs to a window's tier/model scope.
local function in_scope(bare: string, scope_model: string, scope_tier: string): boolean
	if bare == "" then
		return false
	end
	bare = string.lower(bare)
	if scope_model ~= "" and bare ~= scope_model and not string.find(bare, scope_model, 1, true) then
		return false
	end
	return scope_tier == "" or string.find(bare, scope_tier, 1, true) ~= nil
end

-- A window applies to the active model when it is plan-wide, or scoped to it, or when no known model of
-- the provider matches its scope (which then names a plan, not a model).
local function applies(window: any, bare: string, bares: { string }?): boolean
	if window.scope_shared or (window.scope_model == "" and window.scope_tier == "") then
		return true
	end
	if bares then
		local any_match = false
		for _, b in bares do
			if in_scope(b, window.scope_model, window.scope_tier) then
				any_match = true
				break
			end
		end
		if not any_match then
			return true
		end
	end
	return in_scope(bare, window.scope_model, window.scope_tier)
end

-- One provider's windows for the line: the worst of its reports per window key, or its capacity windows
-- when omp reports account counts. Returns plain rows the line and card can render.
local function provider_windows(data: any, provider: string, bare: string, plan_wide_only: boolean, now: number): ({ any }?, number)
	local capacity = data.usage.capacity[provider]
	local reports = {}
	for _, report in data.usage.reports do
		if report.provider == provider then
			table.insert(reports, report)
		end
	end
	if #reports == 0 and not capacity then
		return nil, 0
	end
	local bares = if data.models then data.models.by_provider[provider] else nil
	local windows: { any } = {}
	local credits = 0
	if capacity and #capacity > 0 then
		local by_key: { [string]: any } = {}
		for _, window in capacity do
			-- The rendered row, not the kv window, is the merge target: report reset times and saved
			-- credits must land on the copy the line and the card actually read.
			local row = {
				key = window.key, label = window.label, ms = window.ms,
				left = window.left, reset_at = window.reset_at, saved = window.saved or 0,
				expires_at = window.expires_at, accounts = window.accounts,
			}
			by_key[window.key] = row
			table.insert(windows, row)
		end
		for _, report in reports do
			credits += report.credits
			for _, window in report.windows do
				local target = by_key[window.key]
				if target then
					if window.reset_at and (target.reset_at == nil or window.reset_at < target.reset_at) then
						target.reset_at = window.reset_at
					end
					if window.saved > 0 and target.saved == 0 then
						target.saved = window.saved
						target.expires_at = window.expires_at
					end
				end
			end
		end
	else
		local worst: { [string]: any } = {}
		for _, report in reports do
			credits += report.credits
			for _, window in report.windows do
				if plan_wide_only and not applies(window, bare, bares) then
					continue
				end
				local held = worst[window.key]
				if held == nil or window.left < held.left then
					worst[window.key] = window
				elseif held and window.reset_at and (held.reset_at == nil or window.reset_at < held.reset_at) then
					held.reset_at = window.reset_at
				end
			end
		end
		for _, window in worst do
			table.insert(windows, window)
		end
	end
	table.sort(windows, function(a: any, b: any)
		if a.ms == b.ms then
			return a.key < b.key
		end
		return a.ms < b.ms
	end)
	local rows: { any } = {}
	for _, window in windows do
		if plan_wide_only and not (window.scope_shared or (window.scope_model == "" and window.scope_tier == "")) then
			continue
		end
		local pct = if window.key == "mo" then math.floor(window.left * 100) else math.round(window.left * 100)
		local saved = window.saved or 0
		table.insert(rows, {
			key = window.key,
			label = window.label,
			pct = math.clamp(pct, 0, 100),
			reset = countdown(window.reset_at, now),
			reset_at = window.reset_at,
			saved = saved,
			expires = if window.expires_at then span_left(window.expires_at - now) else nil,
			expires_at = window.expires_at,
			accounts = window.accounts,
		})
	end
	return rows, credits
end

-- Current mode never borrows another provider's data. Other modes remain plan-wide.
function M.build(settings: any, data: any, now: number): any
	local groups: { any } = {}
	local selection = data.selection
	local provider = if type(selection) == "table" and selection.status == "resolved" then selection.provider else nil
	local bare = if provider then selection.id else ""
	local notice = nil
	local fallback_candidates: { any } = {}

	local present: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, report in data.usage.reports do
		if not seen[report.provider] then
			seen[report.provider] = true
			table.insert(present, report.provider)
		end
	end
	for provider_id in data.usage.capacity do
		if not seen[provider_id] then
			seen[provider_id] = true
			table.insert(present, provider_id)
		end
	end
	-- A pay-as-you-go provider has no quota windows, so omp reports none for it and it never reaches the
	-- line. Today's per-provider ledger is the only trace it leaves, so a provider seen there gets a
	-- spend-only group instead of dropping out.
	local today_by = if type(data.today) == "table" and type(data.today.by_provider) == "table" then data.today.by_provider else nil
	local function spend_of(provider_id: string): any
		local entry = today_by and today_by[provider_id]
		if type(entry) ~= "table" then
			return nil
		end
		local tokens = if type(entry.tokens) == "number" then entry.tokens else 0
		local cost = if type(entry.cost) == "number" then entry.cost else 0
		if tokens <= 0 and cost <= 0 then
			return nil
		end
		return { tokens = tokens, cost = cost }
	end
	if today_by then
		for provider_id in today_by do
			if not seen[provider_id] and spend_of(provider_id) then
				seen[provider_id] = true
				table.insert(present, provider_id)
			end
		end
	end

	local function add_group(provider_id: string, plan_wide_only: boolean, forced_bare: string?)
		local rows, credits = provider_windows(data, provider_id, forced_bare or bare, plan_wide_only, now)
		if rows == nil or #rows == 0 then
			local spend = spend_of(provider_id)
			if spend == nil then
				return
			end
			table.insert(groups, {
				key = provider_id,
				id = provider_id,
				label = parse.provider_label(provider_id),
				windows = {},
				credits = 0,
				spend = spend,
			})
			return
		end
		table.insert(groups, {
			key = provider_id,
			id = provider_id,
			label = parse.provider_label(provider_id),
			windows = rows,
			credits = credits,
		})
	end

	if settings.mode ~= "current" then
		local chosen = settings_lib.ordered(settings, present)
		for _, provider_id in chosen do
			if settings.mode == "all" or table.find(settings.selected, provider_id) then
				add_group(provider_id, true)
			end
		end
	end
	if settings.mode == "current" then
		if provider then
			add_group(provider, false)
		elseif type(selection) == "table" and selection.status == "ambiguous"
			and selection.viewing ~= true and type(selection.candidates) == "table" then
			local seen_provider: { [string]: boolean } = {}
			for _, candidate in ipairs(selection.candidates) do
				if type(candidate) == "table" and type(candidate.provider) == "string" and candidate.provider ~= ""
					and type(candidate.id) == "string" and candidate.id ~= ""
					and not seen_provider[candidate.provider] then
					seen_provider[candidate.provider] = true
					table.insert(fallback_candidates, candidate)
				end
			end
			if #fallback_candidates > 1 then
				for _, candidate in fallback_candidates do
					add_group(candidate.provider, false, candidate.id)
				end
			else
				fallback_candidates = {}
			end
		end
		if #groups > 0 and #fallback_candidates > 1 then
			local L = labels.get(settings.language)
			local en = labels.get("en")
			local count = #fallback_candidates
			notice = {
				text = string.format(L.same_name_title, count),
				-- The line marker stays ASCII (see IMPLEMENTATION §4): CJK width would shift every bar's fill.
				line = string.format(en.same_name_line, count),
				detail = L.same_name_detail,
			}
		elseif #groups == 0 then
			local L = labels.get(settings.language)
			local en = labels.get("en")
			if provider then
				local label = parse.provider_label(provider)
				notice = { text = string.format(L.provider_no_data, label),
					line = string.format(en.provider_no_data, label), detail = L.provider_no_data_detail }
			else
				local reason = if type(selection) == "table" then selection.reason else ""
				local detail = if reason == "bridge_invalid" or reason == "bridge_unsupported" or reason == "bridge_chip_mismatch"
					then L.identity_invalid
					elseif type(selection) == "table" and selection.viewing then L.identity_viewing
					elseif reason == "catalog_ambiguous" then L.identity_need_extension
					else L.identity_unavailable
				notice = { text = L.identity_pending, line = en.identity_pending, detail = detail }
			end
		end
	elseif #groups == 0 then
		-- Preserve the non-current modes' empty-selection fallback.
		if provider then
			add_group(provider, false)
		end
		if #groups == 0 then
			for _, provider_id in settings_lib.ordered(settings, present) do
				add_group(provider_id, true)
			end
		end
	end

	local title = if notice then notice.text
		elseif #groups == 0 then ""
		elseif #groups == 1 then groups[1].label .. (if groups[1].spend then " today" else " usage")
		else "Usage"
	local parts: { string } = { tostring(#groups), settings.mode, provider or "",
		if type(selection) == "table" then selection.selector or selection.reason else "",
		if notice then notice.detail else "" }
	if type(selection) == "table" and type(selection.candidates) == "table" then
		for _, candidate in ipairs(selection.candidates) do
			if type(candidate) == "table" and type(candidate.selector) == "string" then
				table.insert(parts, candidate.selector)
			end
		end
	end
	for _, group in groups do
		table.insert(parts, group.key .. "#")
		for _, window in group.windows do
			table.insert(parts, string.format("%s:%s:%d:%s:%s", window.key, window.pct, window.saved or 0, window.reset or "", window.expires or ""))
		end
		if group.spend then
			table.insert(parts, string.format("$%.0f:%.2f", group.spend.tokens, group.spend.cost))
		end
	end
	return { groups = groups, title = title, notice = notice, signature = table.concat(parts, "|") }
end

-- ── the line ────────────────────────────────────────────────────────────────

type Paint = { from: number, to: number, color: string }
type Bar = { at: number, glyphs: number, fill: number, ends: number, key: string, a: string, b: string }

-- `Claude  5H ━━━━━━━━ 98% left  3h 57m · 7D ━━━━━━━━ 71% left  11h 37m  +1` — several providers go
-- compact (`Claude  5H ━━━━━━ 98%  7D ━━━━━━ 71% +1 · Codex  7D ━━━━━━ 79%`), countdowns left to the card.
local function line_of(settings: any, model: any): any
	local parts: { string } = {}
	local line = { text = "", glyphs = 0, paints = {}, bars = {} }
	local several = #model.groups > 1
	local bar_glyphs = if several then COMPACT_BAR_GLYPHS else BAR_GLYPHS

	local function add(s: string, color: string?)
		local n = glyph_count(s)
		if color then
			table.insert(line.paints, { from = line.glyphs, to = line.glyphs + n, color = color })
		end
		table.insert(parts, s)
		line.glyphs += n
	end
	local function next_part()
		if line.glyphs > 0 then
			add(" ")
			add(SEPARATOR .. NBSP, "var(--ou-sep)")
		end
	end
	if model.notice then
		add(unbroken(model.notice.line), "var(--ou-dim)")
	end

	for g, group in model.groups do
		local pa, pb = settings_lib.palette_for(settings, group.id)
		if group.spend then
			-- no quota to bar: the spend group stands on today's tokens and cost alone
			next_part()
			if group.label ~= "" then
				add(group.label, "var(--ou-g" .. g .. "-a)")
				add(NBSP .. NBSP)
			end
			add("TODAY", "var(--ou-lbl)")
			add(NBSP)
			add(compact_number(group.spend.tokens), "var(--ou-num-ok)")
			add(NBSP .. NBSP)
			add("$" .. string.format("%.2f", group.spend.cost), "var(--ou-soft)")
		end
		for w, window in group.windows do
			local tone = tone_of(window.pct, settings.warn_at, settings.bad_at)
			if w > 1 and several then
				add(" " .. NBSP)
			else
				next_part()
			end
			if w == 1 and group.label ~= "" then
				add(group.label, "var(--ou-g" .. g .. "-a)")
				add(NBSP .. NBSP)
			end
			add(string.upper(window.label), "var(--ou-lbl)")
			add(NBSP)
			local at = line.glyphs
			add(string.rep(BAR, bar_glyphs))
			add(NBSP)
			add(tostring(window.pct) .. "%", "var(--ou-num-" .. tone .. ")")
			if not several then
				add(NBSP .. "left", "var(--ou-dim)")
				if window.reset then
					add(NBSP .. NBSP .. unbroken(window.reset :: string), "var(--ou-soft)")
				end
			end
			if window.accounts and window.accounts > 1 then
				add(NBSP .. NBSP .. "×" .. tostring(window.accounts), "var(--ou-soft)")
			end
			if window.saved and window.saved > 0 then
				local saved = "+" .. tostring(window.saved)
				if window.expires then
					saved ..= if several then "!" else NBSP .. "exp" .. NBSP .. unbroken(window.expires :: string)
				end
				add(
					(if several then NBSP else NBSP .. NBSP) .. saved,
					if window.expires then "var(--ou-num-warn)" else "var(--ou-g" .. g .. "-a)"
				)
			end
			local ba, bb = pa, pb
			if tone ~= "ok" then
				local tone_color = if tone == "warn" then "var(--warn)" else "var(--bad)"
				ba, bb = tone_color, tone_color
			end
			table.insert(line.bars, {
				at = at,
				glyphs = bar_glyphs,
				fill = math.clamp(window.pct, 0, 100) / 100 * bar_glyphs,
				ends = line.glyphs,
				key = group.key .. "/" .. window.key,
				a = ba,
				b = bb,
			})
		end
	end
	line.text = table.concat(parts)
	return line
end

-- Each part's color over its glyphs; each bar from its first color, faint, to its second up to its share,
-- then the track. Hard stops sit between glyphs, so nothing bleeds.
local function line_paint(line: any): string
	local items: { any } = {}
	for _, paint in line.paints do
		table.insert(items, {
			at = paint.from,
			stops = string.format("%s %s %s", solid(paint.color), em(paint.from), em(paint.to)),
		})
	end
	for _, bar in line.bars do
		local tip = bar.at + bar.fill
		local stops: { string } = {}
		if bar.fill > 0 then
			table.insert(stops, string.format("%s %s", faded(bar.a, 40), em(bar.at)))
			table.insert(stops, string.format("%s %s", solid(bar.b), em(tip)))
		end
		if bar.fill < bar.glyphs then
			table.insert(stops, string.format("%s %s %s", solid("var(--ou-track)"), em(tip), em(bar.at + bar.glyphs)))
		end
		table.insert(items, { at = bar.at, stops = table.concat(stops, ", ") })
	end
	table.sort(items, function(a: any, b: any)
		return a.at < b.at
	end)
	local stops: { string } = {}
	for _, item in items do
		table.insert(stops, item.stops)
	end
	return "linear-gradient(90deg, " .. table.concat(stops, ", ") .. ")"
end

-- `size` while the bar's window fits on the line of the box drawing it, else 0, so a window that wrapped
-- away takes its tip along.
local function fits(bar: any, size: number): string
	return string.format("clamp(0px, calc((100%% - %spx) * 1000), %spx)", num(bar.ends * GLYPH - 3), num(size))
end

local function tip_image(color: string, strength: number): string
	return string.format(
		"radial-gradient(closest-side, color-mix(in srgb, %s 45%%, white), rgb(from %s r g b / %d%%) 45%%, rgb(from %s r g b / 0%%))",
		color, color, strength, color
	)
end

local function tips(line: any, strength: number): any
	local layers = { images = {}, positions = {}, sizes = {} }
	for _, bar in line.bars do
		local x = (bar.at + bar.fill) * GLYPH
		table.insert(layers.images, tip_image(bar.b, strength))
		table.insert(layers.positions, string.format("%spx %spx", num(x - TIP_W / 2), num(BAR_Y - TIP_H / 2)))
		table.insert(layers.sizes, string.format("%s %spx", fits(bar, TIP_W), num(TIP_H)))
	end
	return layers
end

-- The providers' colors as variables on the composer, which the line, its tips and the card all sit in.
local function palette_css(settings: any, model: any): string
	local lines: { string } = {}
	local lowest: number? = nil
	for g, group in model.groups do
		local a, b = settings_lib.palette_for(settings, group.id)
		table.insert(lines, string.format("\t--ou-g%d-a: %s;", g, a))
		table.insert(lines, string.format("\t--ou-g%d-b: %s;", g, b))
		for _, window in group.windows do
			lowest = if lowest == nil then window.pct else math.min(lowest :: number, window.pct)
		end
	end
	local low = if lowest then tone_of(lowest :: number, settings.warn_at, settings.bad_at) else "ok"
	local one = #model.groups == 1
	local ring: string
	if low == "warn" then
		ring = faded("var(--warn)", 45)
	elseif low == "bad" then
		ring = faded("var(--bad)", 50)
	elseif one then
		ring = faded("var(--ou-g1-a)", 40)
	else
		ring = "var(--l2)"
	end
	table.insert(lines, "\t--ou-ring: " .. ring .. ";")
	table.insert(lines, "\t--ou-glow: " .. (if one then "var(--ou-g1-a)" else "var(--accent)") .. ";")
	-- Tern's popover glass is translucent and counts on a backdrop blur, which doesn't take on the card,
	-- so text behind it would show through: the capsule and card take the glass's color opaque.
	table.insert(lines, "\t--ou-glass: light-dark(rgb(from var(--card) r g b / 1), rgb(from var(--pop-bg) r g b / 1));")
	return ".tn-pane.on .sf-col[data-role^='omp.editor'] {\n" .. table.concat(lines, "\n") .. "\n}"
end

local LINE_CSS = [==[
/* room above the hairline for the usage line, clear of the working row; every agent pane, so focus never shifts it */
.sf-dock .sf-col[data-role^='omp.editor'] {
	margin-top: 15px;
}
/* the providers' colors */
$PALETTE
/* the line: 10px mono in a 13px box whose second line (where a window that doesn't fit wraps) is cut off; one
   static gradient clipped to the text colors its parts and fills its bars */
$METER::before,
$HOST::before {
	content: $CONTENT;
	height: 13px;
	overflow: hidden;
	white-space: pre-wrap;
	text-overflow: ellipsis;
	font: 500 10px/15px var(--mono);
	font-variant-numeric: tabular-nums;
	color: transparent;
	background-image: $PAINT;
	background-repeat: no-repeat;
	background-clip: text;
	pointer-events: none;
	--ou-lbl: var(--t3);
	--ou-sep: var(--t4);
	--ou-num-ok: var(--t2);
	--ou-num-warn: var(--warn);
	--ou-num-bad: var(--bad);
	--ou-dim: var(--t4);
	--ou-soft: var(--t3);
	--ou-track: color-mix(in srgb, var(--t1) 13%, transparent);
}
/* the text is the focused agent's, so it shows on the focused pane only */
$METER::before {
	position: absolute;
	left: 0;
	right: 0;
	bottom: 100%;
	margin-bottom: 2px;
}
$TIPS_CSS
/* the hover target over the line: the meter's place in each chat style, widened by the capsule's 6px pad, as
   long as the line (or the meter, if that's shorter) */
$HOST {
	display: block !important;
	position: absolute;
	left: 12px;
	top: -28px;
	width: min($WIDTH, calc(100% - 24px));
	height: 15px;
	min-height: 0;
	margin: 0;
	padding: 0;
	overflow: visible;
	opacity: 1;
	z-index: 5;
	pointer-events: auto;
	border-radius: 8px;
	background-color: transparent;
	box-shadow: 0 0 0 1px transparent, 0 8px 20px -12px transparent, inset 0 1px 0 transparent;
	transition:
		background-color 0.2s var(--ease),
		box-shadow 0.2s var(--ease);
}
$HOST_READER {
	left: 16px;
	width: min($WIDTH, calc(100% - 32px));
}
$HOST_SPINE {
	left: -6px;
	width: min($WIDTH, calc(100% - 4px));
}
$HOST_CONSOLE {
	left: calc(max(0px, (100% - 1040px) / 2) + var(--cn-gut) - 12px);
	width: min($WIDTH, calc(min(100%, 1040px) - var(--cn-gut) + 12px));
}
/* hovered, the line lifts into a glass capsule, ringed in its provider's color (or the lowest window's tone) */
$HOST:hover {
	background-color: var(--ou-glass);
	box-shadow:
		0 0 0 1px var(--ou-ring),
		0 8px 20px -12px light-dark(rgba(0, 0, 0, 0.28), rgba(0, 0, 0, 0.8)),
		inset 0 1px 0 var(--glass-hi);
}
/* and comes up to full strength: the copy fades in over it, the capsule hiding the line beneath */
$HOST::before {
	position: absolute;
	left: 6px;
	right: 6px;
	top: 1px;
	background-image: $PAINT$HOVER_IMAGES;
	background-position: 0 0$HOVER_POSITIONS;
	background-size: auto$HOVER_SIZES;
	background-clip: text$HOVER_CLIPS;
	opacity: 0;
	transition: opacity 0.2s var(--ease);
	--ou-lbl: var(--t2);
	--ou-sep: var(--t3);
	--ou-num-ok: var(--t1);
	--ou-dim: var(--t3);
	--ou-soft: var(--t2);
	--ou-track: color-mix(in srgb, var(--t1) 20%, transparent);
}
$HOST:hover::before {
	opacity: 1;
}
]==]

local TIPS_CSS = [==[
/* each bar's lit tip, where its window stands */
$METER::after {
	content: "";
	position: absolute;
	left: 0;
	right: 0;
	bottom: 100%;
	margin-bottom: 2px;
	height: 13px;
	background-image: $IMAGES;
	background-position: $POSITIONS;
	background-size: $SIZES;
	background-repeat: no-repeat;
	pointer-events: none;
}]==]

local function line_css(settings: any, model: any): string
	local line = line_of(settings, model)
	local paint = line_paint(line)
	local rest = tips(line, 55)
	local lit = tips(line, 70)
	local function more(list: { string }): string
		return if #list > 0 then ", " .. table.concat(list, ", ") else ""
	end
	local clips: { string } = {}
	for _ in lit.images do
		table.insert(clips, "border-box")
	end
	local tips_css = ""
	if #rest.images > 0 then
		tips_css = fill(TIPS_CSS, {
			METER = METER,
			IMAGES = table.concat(rest.images, ", "),
			POSITIONS = table.concat(rest.positions, ", "),
			SIZES = table.concat(rest.sizes, ", "),
		})
	end
	return fill(LINE_CSS, {
		METER = METER,
		HOST = host(nil),
		HOST_READER = host(".sf-chat-reader"),
		HOST_SPINE = host(".sf-chat-spine"),
		HOST_CONSOLE = host(".sf-chat-console"),
		PALETTE = palette_css(settings, model),
		CONTENT = css_string(line.text),
		PAINT = paint,
		TIPS_CSS = tips_css,
		WIDTH = num(line.glyphs * GLYPH + 12) .. "px",
		HOVER_IMAGES = more(lit.images),
		HOVER_POSITIONS = more(lit.positions),
		HOVER_SIZES = more(lit.sizes),
		HOVER_CLIPS = more(clips),
	})
end

-- ── the card ────────────────────────────────────────────────────────────────

-- The card's rows: the title, then each provider's windows with their meters, reset times and saved
-- resets, then today's total and its per-provider breakdown, then the settings hint.
function M.card_rows(settings: any, model: any, L: any, today_text: string?, today: any, now: number): { any }
	local rows: { any } = { { text = model.title, color = "var(--oc-head)" } }
	if model.notice then
		table.insert(rows, { text = model.notice.detail, color = "var(--oc-mute)" })
	end
	local several = #model.groups > 1
	local spend_shown: { [string]: boolean } = {}
	for g, group in model.groups do
		local a = settings_lib.palette_for(settings, group.id)
		local accent = a
		if several then
			table.insert(rows, { text = group.label, color = accent })
		end
		if group.spend then
			spend_shown[group.id] = true
			table.insert(rows, {
				text = CARD_INDENT .. string.format(L.spend_today, compact_number(group.spend.tokens), group.spend.cost),
				color = accent,
			})
		end
		local carrier: number? = nil
		for w, window in group.windows do
			if window.saved and window.saved > 0 then
				carrier = w
				break
			end
		end
		for w, window in group.windows do
			local tone = tone_of(window.pct, settings.warn_at, settings.bad_at)
			local wa, wb = accent, accent
			if tone ~= "ok" then
				local tone_color = if tone == "warn" then "var(--warn)" else "var(--bad)"
				wa, wb = tone_color, tone_color
			end
			local reset_text = if window.reset == "soon" then L.resets_soon
				elseif window.reset then string.format(L.resets_in, window.reset :: string)
				else nil
			table.insert(rows, {
				-- the reset countdown sits between the window label and the remaining share
				text = string.format(L.window_word, window.label)
					.. (if reset_text then NBSP .. NBSP .. reset_text else ""),
				right = tostring(window.pct) .. "% " .. L.left,
				color = "var(--oc-win-" .. tone .. ")",
				share = math.clamp(window.pct, 0, 100) / 100,
				a = wa,
				b = wb,
			})
			if window.saved and window.saved > 0 and w == carrier then
				local saved_text = if window.saved == 1
					then string.format(L.saved_reset, window.saved)
					else string.format(L.saved_reset_plural, window.saved)
				if window.expires then
					saved_text ..= " · " .. string.format(L.expires_in, window.expires :: string)
				end
				table.insert(rows, {
					text = CARD_INDENT .. saved_text,
					color = if window.expires then "var(--oc-warn)" else accent,
				})
			end
			if window.accounts and window.accounts > 1 then
				table.insert(rows, { text = CARD_INDENT .. "×" .. tostring(window.accounts) .. " accounts", color = "var(--oc-mute)" })
			end
		end
	end
	if today_text then
		table.insert(rows, { text = today_text, color = "var(--oc-soft)" })
	end
	-- today's per-provider breakdown, heaviest first
	local by_provider = if type(today) == "table" and type(today.by_provider) == "table" then today.by_provider else nil
	if by_provider and next(by_provider) ~= nil then
		local list: { any } = {}
		for p, v in by_provider do
			if type(v) == "table" and ((v.tokens or 0) > 0 or (v.cost or 0) > 0) then
				table.insert(list, { provider = p, tokens = v.tokens or 0, cost = v.cost or 0 })
			end
		end
		table.sort(list, function(a: any, b: any)
			return a.tokens > b.tokens
		end)
		for i, item in list do
			if not spend_shown[item.provider] then
				if i > 6 then
					break
				end
				table.insert(rows, {
					text = CARD_INDENT
						.. (parse.provider_label(item.provider) ~= "" and parse.provider_label(item.provider) or item.provider)
						.. "  "
						.. compact_number(item.tokens)
						.. " · $"
						.. string.format("%.2f", item.cost),
					color = "var(--oc-mute)",
				})
			end
		end
	end
	table.insert(rows, { text = L.settings_hint, color = "var(--oc-hint)", rule = true })
	return rows
end

local CARD_CSS = [==[
/* the card: the line's facts spelled out over it, a row each, in a glass panel with a title bar; one gradient,
   row by row, colors the text, and each window's row sits on a meter with a lit tip. It hides on a 0.5s grace
   after the pointer leaves, so crossing the gap to the card keeps it open (the card is hoverable itself). */
$HOST::after {
	content: "$CONTENT";
	position: absolute;
	left: 0;
	bottom: calc(100% + 8px);
	padding: 5px 12px 9px;
	border-radius: 12px;
	white-space: pre;
	font: 500 11px/18px var(--mono);
	font-variant-numeric: tabular-nums;
	color: transparent;
	background-color: var(--ou-glass);
	background-image: $IMAGES;
	background-position: $POSITIONS;
	background-size: $SIZES;
	background-repeat: no-repeat;
	background-origin: $ORIGINS;
	background-clip: $CLIPS;
	box-shadow:
		0 0 0 1px var(--l2),
		0 22px 44px -18px light-dark(rgba(0, 0, 0, 0.3), rgba(0, 0, 0, 0.85)),
		0 6px 14px -8px light-dark(rgba(0, 0, 0, 0.12), rgba(0, 0, 0, 0.55)),
		inset 0 1px 0 var(--glass-hi);
	pointer-events: auto;
	opacity: 0;
	visibility: hidden;
	transform-origin: 16px 100%;
	transition: opacity 0.18s var(--ease), visibility 0s linear 0.5s;
	--oc-head: var(--t1);
	--oc-win-ok: var(--t1);
	--oc-win-warn: var(--warn);
	--oc-win-bad: var(--bad);
	--oc-mute: var(--t3);
	--oc-soft: var(--t2);
	--oc-warn: var(--warn);
	--oc-track: color-mix(in srgb, var(--t1) 10%, transparent);
	--oc-hint: light-dark(var(--t3), color-mix(in srgb, var(--t3) 60%, var(--t4)));
}
$HOST:hover::after {
	opacity: 1;
	visibility: visible;
	transition: opacity 0.18s var(--ease), visibility 0s;
	animation: usage-plus-card 0.28s var(--out) 0.35s both;
}
@keyframes usage-plus-card {
	from { opacity: 0; transform: translateY(5px) scale(0.97); }
	to { opacity: 1; transform: none; }
}
@media (prefers-reduced-motion: reduce) {
	$HOST,
	$HOST::before {
		transition: none;
	}
	$HOST::after {
		transition: opacity 0s, visibility 0s linear 0.5s;
	}
	$HOST:hover::after {
		animation: none;
	}
}
]==]

local function card_css(rows: { any }): string
	local width = CARD_MIN
	for _, row in rows do
		local n = glyph_count(row.text)
		if row.right then
			n += 4 + glyph_count(row.right :: string)
		end
		width = math.max(width, n)
	end
	local lines: { string } = {}
	local paint: { string } = {}
	local images: { string } = { "" }
	local positions: { string } = { "0 0" }
	local sizes: { string } = { "100% 100%" }
	local origins: { string } = { "content-box" }
	local clips: { string } = { "text" }
	local function layer(image: string, position: string, size: string, origin: string)
		table.insert(images, image)
		table.insert(positions, position)
		table.insert(sizes, size)
		table.insert(origins, origin)
		table.insert(clips, "padding-box")
	end
	for i, row in rows do
		local y = (i - 1) * CARD_ROW
		local text = row.text
		if row.right then
			local right = row.right :: string
			text ..= string.rep(" ", math.max(1, width - glyph_count(row.text) - glyph_count(right))) .. right
			local a = row.a or "var(--accent)"
			local b = row.b or a
			local share = row.share or 0
			local meter = y + CARD_ROW - 1
			layer(
				tip_image(b, 70),
				string.format("calc(%s%% + %spx) %spx", num(share * 100), num(share * TIP_W - TIP_W / 2), num(meter - 2)),
				string.format("%spx %spx", num(TIP_W), num(TIP_H)),
				"content-box"
			)
			layer(
				string.format("linear-gradient(90deg, %s, %s)", faded(a, 40), solid(b)),
				string.format("0 %spx", num(meter)),
				string.format("calc(100%% * %s) 2px", num(share, 4)),
				"content-box"
			)
			layer(
				string.format("linear-gradient(90deg, %s, %s)", solid("var(--oc-track)"), solid("var(--oc-track)")),
				string.format("0 %spx", num(meter)),
				"100% 2px",
				"content-box"
			)
		end
		if row.rule then
			layer(
				string.format("linear-gradient(90deg, %s, %s)", solid("var(--l2)"), faded("var(--l2)", 0)),
				string.format("0 %spx", num(y + 1)),
				"100% 1px",
				"content-box"
			)
		end
		table.insert(lines, string.sub(css_string(text), 2, -2))
		table.insert(paint, string.format("%s %spx %spx", solid(row.color), num(y), num(y + CARD_ROW)))
	end
	images[1] = "linear-gradient(180deg, " .. table.concat(paint, ", ") .. ")"
	-- the title bar: a lighter band down to a hairline under the title, and a glow of the provider's color
	local band = string.format("%spx", num(5 + CARD_ROW - 1))
	layer(
		string.format("linear-gradient(90deg, %s, %s)", solid("var(--l3)"), solid("var(--l1)")),
		"0 " .. band,
		"100% 1px",
		"padding-box"
	)
	layer(
		string.format("linear-gradient(90deg, %s, %s)", solid("var(--l1)"), solid("var(--l1)")),
		"0 0",
		"100% " .. band,
		"padding-box"
	)
	layer(
		string.format("radial-gradient(130%% 150%% at 0%% 0%%, %s, transparent 60%%)", faded("var(--ou-glow)", 14)),
		"0 0",
		"100% 100%",
		"padding-box"
	)
	return fill(CARD_CSS, {
		HOST = host(nil),
		CONTENT = table.concat(lines, "\\A "),
		IMAGES = table.concat(images, ", "),
		POSITIONS = table.concat(positions, ", "),
		SIZES = table.concat(sizes, ", "),
		ORIGINS = table.concat(origins, ", "),
		CLIPS = table.concat(clips, ", "),
	})
end

-- The whole sheet for a model, or "" when there is nothing to show.
function M.sheet(settings: any, model: any, L: any, today_text: string?, today: any, now: number): string
	if model == nil or (#model.groups == 0 and model.notice == nil) then
		return ""
	end
	return line_css(settings, model) .. card_css(M.card_rows(settings, model, L, today_text, today, now))
end

return M
