-- Runs the omp CLIs and writes the plugin's kv entries. Used by both halves: the host polls on its loop,
-- the window only as a watchdog; the kv timestamps and a short lock keep concurrent calls from doubling.
local parse = require("./parse")
local settings_lib = require("./settings")

local M = {}

local LOCK_MS = 4000
local TIMEOUT_MS = 20000

local INTERVALS = {
	usage = nil, -- from settings
	models = 10 * 60 * 1000,
	stats = nil, -- from settings
}

function M.kv_get(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

function M.kv_set(key: string, value: any)
	pcall(tern.kv.set, key, value)
end

-- Tern's app and daemon may not inherit the shell PATH, so prefer the omp that Tern itself manages.
function M.omp_bin(): string
	local from_env = tern.getenv("OMP_USAGE_PLUS_BIN")
	if from_env and from_env ~= "" then
		return from_env
	end
	local paths: { string } = {}
	local local_app = tern.getenv("LOCALAPPDATA")
	if local_app then
		table.insert(paths, local_app .. "\\Tern\\omp\\bin\\omp.exe")
	end
	local home = tern.getenv("HOME") or tern.getenv("USERPROFILE")
	if home then
		table.insert(paths, home .. "/Library/Application Support/Tern/omp/bin/omp")
		table.insert(paths, (tern.getenv("XDG_DATA_HOME") or home .. "/.local/share") .. "/Tern/omp/bin/omp")
		table.insert(paths, home .. "/.local/bin/omp")
	end
	for _, path in paths do
		local ok, exists = pcall(tern.fs.exists, path)
		if ok and exists then
			return path
		end
	end
	return "omp"
end

-- omp sometimes prints progress lines before the JSON ("Syncing session files…"): decode from the first brace.
local function decode(stdout: string): any
	local at = string.find(stdout or "", "{", 1, true)
	if not at then
		return nil
	end
	local ok, doc = pcall(tern.json.decode, string.sub(stdout, at))
	return if ok then doc else nil
end

local now_ms = function(): number
	return os.time() * 1000
end

local busy: string? = nil
local pending: { string } = {}
local last_refresh: number = 0

-- The last 20 fetch events, for the diagnostics command and this file's debugging.
function M.trace(event: any)
	local trace = M.kv_get("trace")
	trace = if type(trace) == "table" then trace else {}
	table.insert(trace, event)
	while #trace > 20 do
		table.remove(trace, 1)
	end
	M.kv_set("trace", trace)
end

local function run(argv: { string }, kind: string, done: (any) -> ())
	local started, spawn_err = pcall(tern.process.run, argv, { timeout_ms = TIMEOUT_MS }, function(res: any)
		M.trace({
			at = now_ms(), kind = kind, stage = "callback",
			status = if res ~= nil then res.status else nil,
			out_len = if res ~= nil and type(res.stdout) == "string" then #res.stdout else nil,
			err = if res ~= nil and type(res.stderr) == "string" and #res.stderr > 0 then string.sub(res.stderr, 1, 200) else nil,
		})
		local doc = if res ~= nil and res.status == 0 and type(res.stdout) == "string" then decode(res.stdout) else nil
		done(doc)
	end)
	if started then
		M.trace({ at = now_ms(), kind = kind, stage = "spawned", omp = M.omp_bin() })
	else
		M.trace({ at = now_ms(), kind = kind, stage = "spawn_failed", err = string.sub(tostring(spawn_err), 1, 300) })
		done(nil)
	end
end

local function record_day(tokens: number, cost: number)
	local day = os.date("%Y-%m-%d") :: string
	local days = M.kv_get("days")
	days = if type(days) == "table" then days else {}
	local held = days[day]
	if type(held) == "table" and held.tokens == tokens and held.cost == cost then
		return
	end
	days[day] = { tokens = tokens, cost = cost }
	local oldest = os.date("%Y-%m-%d", os.time() - 62 * 86400) :: string
	for key in days do
		if key < oldest then
			days[key] = nil
		end
	end
	M.kv_set("days", days)
end

local HANDLERS: { [string]: (any) -> () } = {
	usage = function(doc: any)
		local parsed = parse.usage(doc, now_ms())
		-- A failed fetch keeps the last good reports; the next poll retries.
		if parsed then
			M.kv_set("usage", { at = now_ms(), reports = parsed.reports, capacity = parsed.capacity })
		end
	end,
	models = function(doc: any)
		local catalog = parse.catalog(doc)
		if catalog then
			M.kv_set("models", { at = now_ms(), by_name = catalog.by_name, by_selector = catalog.by_selector, by_provider = catalog.by_provider })
		end
	end,
	stats = function(doc: any)
		if type(doc) ~= "table" or type(doc.timeSeries) ~= "table" then
			return
		end
		local t = os.date("*t") :: any
		local midnight = os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }) * 1000
		local tokens, cost = parse.today(doc, midnight)
		local day = os.date("%Y-%m-%d") :: string
		-- Per-provider today: `byModel` is cumulative over the stats window. When the window
		-- starts inside today, its totals ARE today's; when it spans midnight, a per-day
		-- snapshot's deltas accumulate into today's buckets (a pruned DB resets to zero).
		local acc = M.kv_get("by_provider_today")
		if type(acc) ~= "table" or acc.day ~= day or type(acc.providers) ~= "table" then
			acc = { day = day, providers = {} }
		end
		local overall = type(doc.overall) == "table" and doc.overall or {}
		local first = overall.firstTimestamp
		local spans_midnight = type(first) == "number" and first < midnight
		local totals = parse.by_model_totals(doc)
		if not spans_midnight then
			acc.providers = totals
		else
			local snap = M.kv_get("by_model_snapshot")
			if type(snap) == "table" and snap.day == day and type(snap.providers) == "table" then
				for p, v in totals do
					local prev = snap.providers[p]
					local held = acc.providers[p] or { tokens = 0, cost = 0 }
					if type(prev) == "table" then
						local delta = v.tokens - (prev.tokens or 0)
						if delta > 0 then
							held.tokens += delta
						end
						delta = v.cost - (prev.cost or 0)
						if delta > 0 then
							held.cost += delta
						end
					end
					acc.providers[p] = held
				end
			end
			M.kv_set("by_model_snapshot", { day = day, providers = totals })
		end
		M.kv_set("by_provider_today", acc)
		M.kv_set("today", { at = now_ms(), tokens = tokens, cost = cost, day = day, by_provider = acc.providers })
		record_day(tokens, cost)
	end,
}

-- One fetch of `kind`; `force` skips the freshness check but keeps the lock. Answers true when it started.
function M.maybe_fetch(kind: string, force: boolean?): boolean
	if HANDLERS[kind] == nil then
		return false
	end
	local now = now_ms()
	local held = M.kv_get(kind)
	local interval = if kind == "usage"
		then settings_lib.load().usage_interval * 1000
		elseif kind == "stats" then settings_lib.load().stats_interval * 1000
		else INTERVALS.models :: number
	local due = force or held == nil or type(held.at) ~= "number" or now - held.at >= interval
	if not due then
		return false
	end
	local lock = M.kv_get("fetch_lock")
	if type(lock) == "table" and lock.kind == kind and now - (lock.at or 0) < LOCK_MS then
		return false
	end
	M.kv_set("fetch_lock", { kind = kind, at = now })
	if busy ~= nil then
		if not table.find(pending, kind) then
			table.insert(pending, kind)
		end
		return true
	end
	busy = kind
	-- A manual refresh asks omp to drop its cache first; regular polls take the cache as it is.
	local function go()
		run({ M.omp_bin(), if kind == "usage" then "usage" elseif kind == "models" then "models" else "stats", "--json" }, kind, function(doc: any)
			busy = nil
			local ok, handler_err = pcall(HANDLERS[kind], doc)
			if not ok then
				M.trace({ at = now_ms(), kind = kind, stage = "handler_error", err = string.sub(tostring(handler_err), 1, 400) })
			end
			local next_kind = table.remove(pending, 1)
			if next_kind then
				M.maybe_fetch(next_kind :: string, true)
			end
		end)
	end
	if kind == "usage" and force then
		run({ M.omp_bin(), "usage", "invalidate" }, kind .. "-invalidate", go)
	else
		go()
	end
	return true
end

-- The service both halves call on their own cadence: manual refreshes first, then whatever is due.
function M.service()
	local request = M.kv_get("refresh_request")
	if type(request) == "number" and request > last_refresh then
		last_refresh = request
		M.maybe_fetch("usage", true)
	end
	M.maybe_fetch("usage", false)
	M.maybe_fetch("models", false)
	M.maybe_fetch("stats", false)
end

return M
