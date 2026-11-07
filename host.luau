-- Host half: the fetch service (per-source usage / models / today, kept fresh in tern.kv
-- even with no window open) and the dashboard block (7 days of history and API-price costs).
local parse = require("./lib/parse")
local labels = require("./lib/labels")
local settings_lib = require("./lib/settings")
local fetch = require("./lib/fetch")

local ui = tern.ui

-- ── the fetch service ───────────────────────────────────────────────────────
-- One process at a time per source is started from a timer: a callback over the budget makes
-- Tern turn off every timer of the plugin until a reload, and on Windows starting a process
-- takes a good part of that. Each source's queue is serial (lib/fetch).
local function every(ms: number, fn: () -> ())
	local function loop()
		fn()
		tern.timer(ms, loop)
	end
	loop()
end

every(250, fetch.service)

-- ── costs, aggregated over every source the fetch service records ───────────

local function costs(now: number): any
	local month = os.date("%Y-%m", now) :: string
	local r = { today = 0, week = 0, month = 0, last7 = {} }
	local per_day: { [string]: number } = {}
	for _, source in fetch.sources() do
		local days = fetch.kv_get("days@" .. source)
		if type(days) == "table" then
			for key, d in days do
				if type(d) == "table" and type(d.cost) == "number" then
					if string.sub(key, 1, 7) == month then
						r.month += d.cost
					end
					per_day[key] = (per_day[key] or 0) + d.cost
				end
			end
		end
	end
	-- legacy flat days, recorded before per-source keys
	local legacy = fetch.kv_get("days")
	if type(legacy) == "table" then
		for key, d in legacy do
			if type(d) == "table" and type(d.cost) == "number" then
				if string.sub(key, 1, 7) == month then
					r.month += d.cost
				end
				per_day[key] = (per_day[key] or 0) + d.cost
			end
		end
	end
	for i = 6, 0, -1 do
		local t = now - i * 86400
		local key = os.date("%Y-%m-%d", t) :: string
		local cost = per_day[key] or 0
		r.week += cost
		table.insert(r.last7, { os.date("%m-%d", t), cost })
		if i == 0 then
			r.today = cost
		end
	end
	return r
end

-- ── the dashboard block ─────────────────────────────────────────────────────

type State = {
	cx: any,
	series: { [string]: { { number } } }?,
	failed: boolean,
	loading: boolean,
	fetched: number?,
}

-- A pane id survives Restart, so the state object identifies this run of the block.
local running: { [number]: State } = {}

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	running[state.cx.pane] = nil
	return false
end

local function load(state: State)
	if state.loading then
		return
	end
	state.loading = true
	state.cx:render()
	local started = pcall(tern.process.run, { fetch.omp_bin(), "usage", "--history", "--json", "--days", "7" }, { timeout_ms = 60000 }, function(res: any)
		if not alive(state) then
			return
		end
		state.loading = false
		local doc = if res ~= nil and res.status == 0 and type(res.stdout) == "string" then res.stdout else nil
		local at = doc and string.find(doc, "{", 1, true)
		local decoded = nil
		if at then
			local ok, parsed = pcall(tern.json.decode, string.sub(doc :: string, at))
			decoded = if ok then parsed else nil
		end
		state.failed = not (decoded ~= nil and type(decoded.entries) == "table")
		if not state.failed then
			state.series = parse.history(decoded.entries)
			state.fetched = os.time()
		end
		state.cx:render()
	end)
	if not started then
		state.loading = false
		state.failed = true
		state.cx:render()
	end
end

local function history_cards(series: { [string]: { { number } } }): { any }
	local ids: { string } = {}
	for id in series do
		table.insert(ids, id)
	end
	table.sort(ids, function(a: string, b: string)
		local ap = string.match(a, "^([^:]+):")
		local bp = string.match(b, "^([^:]+):")
		local ra = parse.provider_rank(ap or a)
		local rb = parse.provider_rank(bp or b)
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	local cards: { any } = {}
	for _, id in ids do
		local points = series[id]
		if points and #points > 0 then
			local now = points[#points][2]
			local spark: { any } = {}
			for _, p in points do
				table.insert(spark, { os.date("%m-%d %Hh", p[1]), math.floor(p[2] * 100 + 0.5) })
			end
			table.insert(cards, ui.card(parse.history_label(id), {
				ui.meter(math.clamp(now, 0, 1), string.format("%d%% used", math.floor(now * 100 + 0.5))),
				ui.spark(spark),
			}))
		end
	end
	return cards
end

local function money(n: number): string
	return string.format("$%.2f", n)
end

tern.block.define("dashboard", {
	init = function(cx: any, _args: { string }, _saved: any): State
		local state: State = { cx = cx, series = nil, failed = false, loading = false, fetched = nil }
		running[cx.pane] = state
		load(state)
		return state
	end,

	title = function(_state: State): string?
		return "Dora omp Usage"
	end,

	view = function(state: State, _cx: any): any
		local settings = settings_lib.load()
		local L = labels.get(settings.language)
		local parts: { any } = {}
		if state.series then
			local cards = history_cards(state.series)
			if #cards == 0 then
				table.insert(parts, ui.text(ui.span(L.dash_no_history, "muted")))
			else
				for _, card in cards do
					table.insert(parts, card)
				end
			end
		elseif state.failed then
			table.insert(parts, ui.text(ui.span(L.dash_failed, "warning")))
		else
			table.insert(parts, ui.progress(nil, L.dash_loading))
		end
		local c = costs(os.time())
		if c.week > 0 or c.month > 0 or c.today > 0 then
			table.insert(parts, ui.card(L.dash_cost, {
				ui.kv({
					{ L.dash_today, money(c.today) },
					{ L.dash_week, money(c.week) },
					{ L.dash_month, money(c.month) },
				}),
				ui.bars(c.last7),
			}))
		end
		local status: { any } = {}
		if state.fetched then
			table.insert(status, ui.span(string.format(L.dash_updated, os.date("%H:%M", state.fetched)), "muted"))
		end
		return { main = ui.col(parts), dock = ui.col({ ui.text(status) }) }
	end,

	key = function(state: State, key: any, _cx: any): boolean?
		if key.ctrl or key.alt or key.meta or (key.text or key.name) ~= "r" then
			return false
		end
		load(state)
		return true
	end,
})
