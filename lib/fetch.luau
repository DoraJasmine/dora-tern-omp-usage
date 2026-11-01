-- Runs the omp CLIs and writes the plugin's kv entries, one data set per source.
-- Sources: "local" (the machine Tern runs on) and, on Windows, every WSL distro —
-- reached through wsl.exe, so a WSL host's data needs no plugin and no UI on that host.
-- Both halves call service() on their own cadence; per-source locks keep calls from doubling.
local parse = require("./parse")
local settings_lib = require("./settings")

local M = {}

local LOCK_MS = 4000
local TIMEOUT_MS = 20000

local MODELS_INTERVAL = 10 * 60 * 1000
local WSL_DETECT_INTERVAL = 10 * 60 * 1000

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

local function now_ms(): number
	return os.time() * 1000
end

-- ── sources ─────────────────────────────────────────────────────────────────
-- A source is "local" or "wsl:<distro>". Each source owns its kv keys
-- ("usage@<s>", "models@<s>", "today@<s>", "days@<s>") and its own serial queue.

local busy: { [string]: string? } = {}
local pending: { [string]: string? } = {}
local last_refresh: number = 0

function M.sources(): { string }
	local out: { string } = { "local" }
	local detected = M.kv_get("wsl_distros")
	if type(detected) == "table" and type(detected.list) == "table" then
		for _, distro in detected.list do
			if type(distro) == "string" and distro ~= "" then
				table.insert(out, "wsl:" .. distro)
			end
		end
	end
	local remotes = M.kv_get("remote_hosts")
	if type(remotes) == "table" and type(remotes.list) == "table" then
		for _, host in remotes.list do
			if type(host) == "string" and host ~= "" then
				table.insert(out, "ssh:" .. host)
			end
		end
	end
	return out
end

function M.is_wsl_source(source: string): boolean
	return string.sub(source, 1, 4) == "wsl:"
end

function M.source_label(source: string): string
	if source == "local" then
		return "local"
	end
	return string.sub(source, 5)
end

local function argv_for(source: string, kind: string): { string }
	local sub = if kind == "usage" then "usage" elseif kind == "models" then "models" else "stats"
	if M.is_wsl_source(source) then
		-- sh -lc: a login shell, so ~/.local/bin (where omp often lives) is on PATH
		local distro = string.sub(source, 5)
		return { "wsl.exe", "-d", distro, "--", "sh", "-lc", "omp " .. sub .. " --json" }
	end
	if string.sub(source, 1, 4) == "ssh:" then
		-- the remote command runs through the account's login shell; sh -lc puts
		-- ~/.local/bin on PATH the same way
		local host = string.sub(source, 5)
		return { "ssh", host, "sh -lc 'omp " .. sub .. " --json'" }
	end
	return { M.omp_bin(), sub, "--json" }
end

local function invalidate_argv(source: string): { string }
	if M.is_wsl_source(source) then
		local distro = string.sub(source, 5)
		return { "wsl.exe", "-d", distro, "--", "sh", "-lc", "omp usage invalidate" }
	end
	if string.sub(source, 1, 4) == "ssh:" then
		return { "ssh", string.sub(source, 5), "sh -lc 'omp usage invalidate'" }
	end
	return { M.omp_bin(), "usage", "invalidate" }
end

-- ── tracing ─────────────────────────────────────────────────────────────────

function M.trace(event: any)
	local trace = M.kv_get("trace")
	trace = if type(trace) == "table" then trace else {}
	table.insert(trace, event)
	while #trace > 20 do
		table.remove(trace, 1)
	end
	M.kv_set("trace", trace)
end

local function run(argv: { string }, tag: string, done: (any) -> ())
	local started, spawn_err = pcall(tern.process.run, argv, { timeout_ms = TIMEOUT_MS }, function(res: any)
		M.trace({
			at = now_ms(), kind = tag, stage = "callback",
			status = if res ~= nil then res.status else nil,
			out_len = if res ~= nil and type(res.stdout) == "string" then #res.stdout else nil,
			err = if res ~= nil and type(res.stderr) == "string" and #res.stderr > 0 then string.sub(res.stderr, 1, 200) else nil,
		})
		local doc = if res ~= nil and res.status == 0 and type(res.stdout) == "string" then decode(res.stdout) else nil
		done(doc)
	end)
	if started then
		M.trace({ at = now_ms(), kind = tag, stage = "spawned" })
	else
		M.trace({ at = now_ms(), kind = tag, stage = "spawn_failed", err = string.sub(tostring(spawn_err), 1, 300) })
		done(nil)
	end
end

-- ── handlers ────────────────────────────────────────────────────────────────

local function record_day(source: string, tokens: number, cost: number)
	local day = os.date("%Y-%m-%d") :: string
	local key = "days@" .. source
	local days = M.kv_get(key)
	days = if type(days) == "table" then days else {}
	local held = days[day]
	if type(held) == "table" and held.tokens == tokens and held.cost == cost then
		return
	end
	days[day] = { tokens = tokens, cost = cost }
	local oldest = os.date("%Y-%m-%d", os.time() - 62 * 86400) :: string
	for k in days do
		if k < oldest then
			days[k] = nil
		end
	end
	M.kv_set(key, days)
end

local function store(source: string, kind: string, value: any)
	M.kv_set(kind .. "@" .. source, value)
end

local function handle(source: string, kind: string, doc: any)
	if kind == "usage" then
		local parsed = parse.usage(doc, now_ms())
		-- A failed fetch keeps the last good data; the next poll retries.
		if parsed then
			store(source, "usage", { at = now_ms(), reports = parsed.reports, capacity = parsed.capacity })
		end
	elseif kind == "models" then
		local catalog = parse.catalog(doc)
		if catalog then
			store(source, "models", { at = now_ms(), by_name = catalog.by_name, by_selector = catalog.by_selector, by_provider = catalog.by_provider })
		end
	elseif kind == "stats" then
		if type(doc) ~= "table" or type(doc.timeSeries) ~= "table" then
			return
		end
		local t = os.date("*t") :: any
		local midnight = os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }) * 1000
		local tokens, cost = parse.today(doc, midnight)
		local day = os.date("%Y-%m-%d") :: string
		-- Per-provider today: byModel is cumulative over the stats window. When the window
		-- starts inside today, its totals ARE today's; when it spans midnight, per-day
		-- snapshot deltas accumulate (a pruned DB resets to zero).
		local snap_key = "by_model_snapshot@" .. source
		local acc_key = "by_provider_today@" .. source
		local acc = M.kv_get(acc_key)
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
			local snap = M.kv_get(snap_key)
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
			M.kv_set(snap_key, { day = day, providers = totals })
		end
		M.kv_set(acc_key, acc)
		store(source, "today", { at = now_ms(), tokens = tokens, cost = cost, day = day, by_provider = acc.providers })
		record_day(source, tokens, cost)
	end
end

-- ── the fetch queue, per source ─────────────────────────────────────────────

local function interval_for(kind: string): number
	local settings = settings_lib.load()
	if kind == "usage" then
		return settings.usage_interval * 1000
	elseif kind == "stats" then
		return settings.stats_interval * 1000
	end
	return MODELS_INTERVAL
end

local function maybe_fetch(source: string, kind: string, force: boolean): boolean
	local now = now_ms()
	local key = kind .. "@" .. source
	local held = M.kv_get(key)
	local due = force or held == nil or type(held.at) ~= "number" or now - held.at >= interval_for(kind)
	if not due then
		return false
	end
	local lock_key = "fetch_lock@" .. source
	local lock = M.kv_get(lock_key)
	if type(lock) == "table" and lock.kind == kind and now - (lock.at or 0) < LOCK_MS then
		return false
	end
	M.kv_set(lock_key, { kind = kind, at = now })
	if busy[source] ~= nil then
		if pending[source] ~= kind then
			pending[source] = kind
		end
		return true
	end
	busy[source] = kind
	local function go()
		run(argv_for(source, kind), kind .. "@" .. source, function(doc: any)
			busy[source] = nil
			local ok, handler_err = pcall(handle, source, kind, doc)
			if not ok then
				M.trace({ at = now_ms(), kind = kind, stage = "handler_error", source = source, err = string.sub(tostring(handler_err), 1, 400) })
			end
			local next_kind = pending[source]
			pending[source] = nil
			if next_kind then
				maybe_fetch(source, next_kind :: string, true)
			end
		end)
	end
	if kind == "usage" and force then
		-- A manual refresh asks omp to drop its cache first; regular polls take the cache as it is.
		run(invalidate_argv(source), "invalidate@" .. source, go)
	else
		go()
	end
	return true
end

-- ── WSL distro detection (Windows only) ─────────────────────────────────────

local function handle_wsl_detect(doc_text: string?)
	-- wsl.exe -l -q prints UTF-16LE: drop the interleaved zero bytes, then split lines.
	local list: { string } = {}
	if type(doc_text) == "string" then
		local clean = string.gsub(doc_text, "\0", "")
		for line in string.gmatch(clean, "[^\r\n]+") do
			local name = string.match(line, "^%s*(.-)%s*$")
			if name and name ~= "" then
				table.insert(list, name)
			end
		end
	end
	M.kv_set("wsl_distros", { at = now_ms(), list = list })
end

local function detect_wsl(): boolean
	if tern.runtime.os ~= "windows" then
		return false
	end
	local now = now_ms()
	local held = M.kv_get("wsl_distros")
	if type(held) == "table" and type(held.at) == "number" and now - held.at < WSL_DETECT_INTERVAL then
		return false
	end
	local started = pcall(tern.process.run, { "wsl.exe", "-l", "-q" }, { timeout_ms = 15000 }, function(res: any)
		local text = if res ~= nil and type(res.stdout) == "string" then res.stdout else nil
		handle_wsl_detect(text)
	end)
	return started
end

-- ── the service ─────────────────────────────────────────────────────────────

-- Manual refreshes first, then whatever is due, on every source.
function M.service()
	local request = M.kv_get("refresh_request")
	if type(request) == "number" and request > last_refresh then
		last_refresh = request
		for _, source in M.sources() do
			maybe_fetch(source, "usage", true)
		end
		return
	end
	detect_wsl()
	for _, source in M.sources() do
		maybe_fetch(source, "usage", false)
		maybe_fetch(source, "models", false)
		maybe_fetch(source, "stats", false)
	end
end

return M
