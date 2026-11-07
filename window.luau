-- Window half: draws the usage line above the focused omp composer's context bar (lib/line), keeps a
-- watchdog on the fetch service, shows today's tokens and cost in the status bar, and offers the settings.
-- The data comes from tern.kv, written by lib/fetch (host half, or this half if the daemon has none).
local parse = require("./lib/parse")
local labels = require("./lib/labels")
local settings_lib = require("./lib/settings")
local line = require("./lib/line")
local fetch = require("./lib/fetch")
local update = require("./lib/update")
local identity = require("./lib/identity")

local SHEET = "usage-plus"
-- Module state, declared early so every function below shares one scope.
local cached: any = { settings = nil, by_source = nil, sources_list = nil,
	wsl_list = nil, remote_list = nil, sig = nil, host_sig = nil }
local POLL_MS = 100
local CACHE_MS = 1000
local next_cache_at = 0
local WATCHDOG_MS = 10000
local STALE_MS = 15 * 60 * 1000

-- Read the chip, bridge and subagent focus from the same pane snapshot.
local function read_dock(cx: any, pane: number): any
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { root = "dock", nodes = 1000 })
	end)
	return identity.read_dock(if ok then tree else nil, tern.json.decode)
end

-- ── per-host data: one fetch source per host ────────────────────────────
-- Sources are "local" and one per detected WSL distro ("wsl:<distro>"), fetched by
-- lib/fetch (on Windows through wsl.exe) and keyed in kv as "usage@<s>" / "models@<s>" /
-- "today@<s>" / "days@<s>". The focused pane's host maps to its source: local panes to
-- "local", panes on a WSL remote host (Tern names them "<user>@wsl") to that distro.

local pane_host_map: { [number]: string } = {}
local local_host_name: string = ""
local last_selection: string? = nil
local update_toasted_run = false

-- Builds the pane -> host map from the window's host list, reports the connected
-- remote hosts to kv (the host-side fetch service cannot see Tern's host list),
-- and records the local machine's display name.
local function refresh_host_map(cx: any)
	pane_host_map = {}
	local remote_names: { string } = {}
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	if ok and type(hosts) == "table" then
		for _, host in hosts do
			if type(host) == "table" then
				if host.kind == "local" then
					local_host_name = tostring(host.name or "")
				elseif host.kind == "remote" and host.state == "connected" then
					table.insert(remote_names, tostring(host.name or host.id))
				end
				if type(host.panes) == "table" then
					local key = if host.kind == "local" then "local" else tostring(host.name or host.id)
					for _, pid in host.panes do
						pane_host_map[pid] = key
					end
				end
			end
		end
	end
	fetch.kv_set("remote_hosts", { at = os.time() * 1000, list = remote_names })
	cached.remote_list = remote_names
end

local function source_for_host(host_key: string, wsl_list: { string }?, remote_list: { string }?): string
	if host_key == "local" then
		return "local"
	end
	if host_key == "wsl" or string.sub(host_key, -4) == "@wsl" then
		-- The advertised host name doesn't identify a distro when several are installed.
		return if type(wsl_list) == "table" and #wsl_list == 1 then "wsl:" .. wsl_list[1] else "?"
	end
	if type(remote_list) == "table" and table.find(remote_list, host_key) then
		return "ssh:" .. host_key
	end
	return "?"
end

local function data_for(pane: number?): (string, any, string)
	local host_key = (pane and pane_host_map[pane]) or "local"
	local label = if host_key == "local"
		then (if local_host_name ~= "" then local_host_name else "本机")
		else host_key
	local source = source_for_host(host_key, cached.wsl_list, cached.remote_list)
	if source == "?" then
		-- Never attribute another host's accounts or model catalog to this pane.
		return source, {}, label
	end
	return source, (cached.by_source and cached.by_source[source]) or {}, label
end

-- ── rendering ───────────────────────────────────────────────────────────────

local last_css: string? = nil

local function install(css: string)
	if css ~= last_css then
		last_css = css
		tern.css(SHEET, css)
	end
end

-- The status formatter must not read kv (Tern's budget for it is tight), so the tick caches what it needs
-- and asks for a status redraw only when something it shows changed.

local function refresh_cache()
	local settings = settings_lib.load()
	cached.settings = settings
	cached.by_source = {}
	local sources = fetch.sources()
	local sig_parts: { string } = { tostring(settings.show_tokens), tostring(settings.show_cost), tostring(settings.alerts), settings.language }
	for _, source in sources do
		local usage = fetch.kv_get("usage@" .. source)
		local today = fetch.kv_get("today@" .. source)
		cached.by_source[source] = { usage = usage, today = today, models = fetch.kv_get("models@" .. source) }
		table.insert(sig_parts, tostring(if type(usage) == "table" then usage.at else nil))
		table.insert(sig_parts, tostring(if type(today) == "table" then today.at else nil))
	end
	cached.sources_list = sources
	cached.wsl_list = nil
	local detected = fetch.kv_get("wsl_distros")
	if type(detected) == "table" and type(detected.list) == "table" then
		cached.wsl_list = detected.list
	end
	local sig = table.concat(sig_parts, "/")
	if sig ~= cached.sig then
		cached.sig = sig
		tern.chrome.refresh()
	end
end

local function providers_present(): { string }
	local present: { string } = {}
	local seen: { [string]: boolean } = {}
	local function collect(usage: any)
		if type(usage) == "table" and type(usage.reports) == "table" then
			for _, report in usage.reports do
				if type(report.provider) == "string" and not seen[report.provider] then
					seen[report.provider] = true
					table.insert(present, report.provider)
				end
			end
		end
		if type(usage) == "table" and type(usage.capacity) == "table" then
			for provider in usage.capacity do
				if not seen[provider] then
					seen[provider] = true
					table.insert(present, provider)
				end
			end
		end
	end
	for _, source in fetch.sources() do
		collect(fetch.kv_get("usage@" .. source))
		-- a pay-as-you-go provider reports no quota windows, so today's ledger is all it shows up in
		local today = fetch.kv_get("today@" .. source)
		if type(today) == "table" and type(today.by_provider) == "table" then
			for provider, entry in today.by_provider do
				local tokens = if type(entry) == "table" and type(entry.tokens) == "number" then entry.tokens else 0
				local cost = if type(entry) == "table" and type(entry.cost) == "number" then entry.cost else 0
				if not seen[provider] and (tokens > 0 or cost > 0) then
					seen[provider] = true
					table.insert(present, provider)
				end
			end
		end
	end
	return present
end

local function today_text(settings: any, label: string, today: any): string?
	local L = labels.get(settings.language)
	if type(today) ~= "table" or type(today.tokens) ~= "number" or type(today.cost) ~= "number" then
		return string.format(L.today_unavailable, label)
	end
	return string.format(L.today_line, label, line.compact_number(today.tokens :: number), today.cost :: number)
end

local function tick(cx: any?, force: boolean?)
	if cx == nil then
		return
	end
	local clock = tern.now()
	local refreshed = force == true or cached.settings == nil or clock >= next_cache_at
	if refreshed then
		refresh_host_map(cx)
		refresh_cache()
		next_cache_at = clock + CACHE_MS
	end
	local settings = cached.settings

	local pane = cx.session:focused()
	local focused_agent = false
	if pane then
		local ok, info = pcall(function()
			return cx.session:pane(pane)
		end)
		focused_agent = ok and type(info) == "table" and info.kind == "agent"
	end
	if not focused_agent then
		last_selection = nil
		install("")
		return
	end

	local dock = read_dock(cx, pane :: number)
	local source, data, host_label = data_for(pane :: number)
	local selection = identity.resolve(dock, data.models)
	selection.viewing = dock.viewing
	local selection_key = table.concat({
		tostring(pane), source, selection.sessionId or "", selection.selector or "",
		selection.status, selection.reason, dock.chip or "", tostring(dock.viewing),
	}, "\0")
	local changed = selection_key ~= last_selection
	if not changed and not refreshed then
		return
	end
	last_selection = selection_key
	local L = labels.get(settings.language)
	local now = os.time() * 1000
	local usage = data.usage
	local model = line.build(settings, {
		usage = if type(usage) == "table" and type(usage.reports) == "table"
			then usage
			else { reports = {}, capacity = {} },
		selection = selection,
		models = if type(data.models) == "table" and data.models.version == 2 then data.models else nil,
		today = if type(data.today) == "table" then data.today else nil,
	}, now)
	if #model.groups == 0 and model.notice == nil then
		install("")
	else
		install(line.sheet(settings, model, L, today_text(settings, host_label, data.today), data.today, now))
	end
	-- redraw the status bar when the shown host's data changed
	local host_sig = source .. "/" .. tostring(if type(data.today) == "table" then data.today.at else nil) .. "/" .. tostring(data.sync_error or "")
	if host_sig ~= cached.host_sig then
		cached.host_sig = host_sig
		tern.chrome.refresh()
	end
	if changed and selection.status == "resolved" and source ~= "?" then
		-- The host service coalesces requests. No process spawn on the fast UI path.
		fetch.kv_set("refresh_usage@" .. source, true)
	end
end

local function poll_loop(cx: any?)
	tern.timer(POLL_MS, poll_loop)
	tick(cx)
end

tern.timer(POLL_MS, poll_loop)

tern.on("focus", function(_ev: any, cx: any)
	tick(cx, true)
end)

-- A paused hook stops this plugin's timers; log it and redraw the moment it resumes.
tern.on("budget", function(ev: any, cx: any)
	pcall(function()
		tern.log.info("usage-plus budget", ev.hook, ev.state, ev.ms or ev.paused_ms or "")
	end)
	if ev.state == "resumed" then
		tick(cx, true)
	end
end)

-- Update check: once a day (first pass a minute after load). A newer release toasts once
-- per version and shows the ↗ segment until the plugin is updated.
local function check_updates(cx: any?)
	if settings_lib.load().update_check == false then
		return
	end
	update.check(function(newver: string?, ucx: any?)
		if newver == nil then
			return
		end
		-- The reminder repeats once per Tern start while outdated (the ↗ segment is the
		-- persistent form; info toasts are transient, so repetition is the point).
		if update_toasted_run then
			tern.chrome.refresh()
			return
		end
		update_toasted_run = true
		local target = if ucx then ucx else cx
		if target then
			local settings = settings_lib.load()
			local L = labels.get(settings.language)
			target:toast("info", string.format(L.update_available, newver))
		end
		tern.chrome.refresh()
	end, cx)
end

local function update_loop(cx: any?)
	tern.timer(86400000, update_loop)
	check_updates(cx)
end

-- The watchdog: if the daemon half is not running its loop (no daemon, or the plugin half off), this window
-- still keeps the data fresh; the kv locks keep the two halves from doubling a fetch.
local function watchdog_loop()
	fetch.service()
	tern.timer(WATCHDOG_MS, watchdog_loop)
end

-- Official startup hook: fires once per window after the session has settled (saved tabs
-- restored), so the first draw sees the real panes instead of racing the restore.
tern.on("window_start", function(cx: any)
	tick(cx, true)
	check_updates(cx)
end)

tern.timer(60000, update_loop)
tern.timer(WATCHDOG_MS, watchdog_loop)

-- ── status bar: today's tokens and cost, and the settings shortcut ──────────

local PLUGIN = "plugin." .. tern.plugin.id .. "."

tern.chrome.status(function(pane: any): { any }?
	local settings = if cached.settings then cached.settings else settings_lib.load()
	local L = labels.get(settings.language)
	local host_key = pane_host_map[pane.pane] or "local"
	local source = source_for_host(host_key, cached.wsl_list, cached.remote_list)
	local by = if cached.by_source then cached.by_source[source] else nil
	local shown_usage = if type(by) == "table" and type(by.usage) == "table" then by.usage else nil
	local today = if type(by) == "table" and type(by.today) == "table" then by.today else nil
	local out: { any } = {}
	local up = update.get_latest()
	if type(up) == "table" then
		table.insert(out, 1, { text = "↗ Update v" .. tostring(up.version or ""), tone = "accent", command = PLUGIN .. "update" })
	end
	-- First, so a narrow window that clips the end of the status line still shows it.
	if type(shown_usage) == "table" and type(shown_usage.at) == "number" and os.time() * 1000 - shown_usage.at > STALE_MS then
		table.insert(out, { text = "⚠", tone = "error", command = PLUGIN .. "diagnostics" })
	end
	if type(today) == "table" and type(today.tokens) == "number" and settings.show_tokens then
		table.insert(out, { text = "🔥 " .. line.compact_number(today.tokens :: number) .. " " .. L.tokens, command = PLUGIN .. "dashboard" })
	end
	if type(today) == "table" and type(today.cost) == "number" and settings.show_cost then
		table.insert(out, { text = string.format("💸 $%.2f", today.cost :: number), command = PLUGIN .. "dashboard" })
	end
	if pane.kind == "agent" then
		table.insert(out, { text = L.usage, icon = "gauge", command = PLUGIN .. "panel" })
	end
	return if #out > 0 then out else nil
end)

-- ── settings, as menus (the canvas panel is a later milestone) ──────────────

local open_dashboard: ((cx: any) -> ())? -- defined with the commands below
local function open_dashboard_or_nil(cx: any)
	if open_dashboard then
		open_dashboard(cx)
	end
end

local function after_change(cx: any)
	if cx then
		tick(cx, true)
		tern.chrome.refresh()
	end
end

-- Prompt for a seconds interval (a settings number key), clamped by `lo`–`hi` like settings.load does.
local function open_interval(cx: any, key: string, lo: number, hi: number)
	local settings = settings_lib.load()
	local L = labels.get(settings.language)
	cx:prompt({
		value = tostring(settings[key]),
		placeholder = if key == "usage_interval" then L.prompt_interval else L.prompt_stats_interval,
		icon = "gauge",
	}):next(function(text: string?, _err: string?, next_cx: any?)
		if text == nil or not string.find(text :: string, "%S") then
			return
		end
		local n = tonumber(text :: string)
		if n == nil or math.floor(n) ~= n or n < lo or n > hi then
			(next_cx or cx):toast("error", if key == "usage_interval" then L.toast_interval_bad else L.toast_stats_interval_bad)
			return
		end
		settings_lib.set({ [key] = math.floor(n) })
		local target = next_cx or cx
		target:toast("success", L.toast_saved)
		after_change(target)
	end)
end

local function open_chooser(cx: any)
	local settings = settings_lib.load()
	local L = labels.get(settings.language)
	local present = providers_present()
	local ordered = settings_lib.ordered(settings, present)
	local items: { any } = {}
	for _, id in ordered do
		table.insert(items, {
			label = parse.provider_label(id),
			detail = id,
			current = table.find(settings.selected, id) ~= nil,
			pick = "toggle",
			id = id,
		})
	end
	cx:pick({ items = items, placeholder = L.chooser_title, icon = "gauge" }):next(function(item: any?, _err: string?, next_cx: any?)
		if item == nil then
			return
		end
		local list = table.clone(settings.selected)
		local at = table.find(list, item.id :: string)
		if at then
			table.remove(list, at :: number)
		else
			table.insert(list, item.id :: string)
		end
		settings_lib.set({ selected = list, mode = "selected" })
		after_change(next_cx or cx)
		open_chooser(next_cx or cx) -- the list stays open so several can be checked; Esc closes
	end)
end

local function open_reorder(cx: any)
	local settings = settings_lib.load()
	local L = labels.get(settings.language)
	local ordered = settings_lib.ordered(settings, providers_present())
	local items: { any } = {}
	for i, id in ordered do
		table.insert(items, { label = parse.provider_label(id), detail = string.format("%d / %d", i, #ordered), pick = "provider", id = id })
	end
	cx:pick({ items = items, placeholder = L.reorder_title, icon = "gauge" }):next(function(item: any?, _err: string?, next_cx: any?)
		if item == nil then
			return
		end
		local moves: { any } = {
			{ label = L.move_up, how = "up" },
			{ label = L.move_down, how = "down" },
			{ label = L.move_top, how = "top" },
			{ label = L.move_bottom, how = "bottom" },
		}
		local move_items: { any } = {}
		for _, move in moves do
			table.insert(move_items, { label = move.label, pick = "move", how = move.how, id = item.id })
		end
		(next_cx or cx):pick({ items = move_items, placeholder = parse.provider_label(item.id :: string), icon = "gauge" }):next(function(choice: any?, _err2: string?, final_cx: any?)
			if choice ~= nil then
				local list = {}
				for _, id in ordered do
					table.insert(list, id)
				end
				local i = table.find(list, choice.id :: string) or #list
				table.remove(list, i)
				local j = i
				if choice.how == "up" then
					j = math.max(1, i - 1)
				elseif choice.how == "down" then
					j = math.min(#list + 1, i + 1)
				elseif choice.how == "top" then
					j = 1
				else
					j = #list + 1
				end
				table.insert(list, j, choice.id :: string)
				settings_lib.set({ order = list })
				after_change(final_cx or cx)
			end
		end)
	end)
end

local function open_colors(cx: any)
	local settings = settings_lib.load()
	local L = labels.get(settings.language)
	local present = providers_present()
	local ordered = settings_lib.ordered(settings, present)
	local items: { any } = {}
	for _, id in ordered do
		table.insert(items, { label = parse.provider_label(id), detail = settings_lib.color_name(settings, id), pick = "provider", id = id })
	end
	cx:pick({ items = items, placeholder = L.colors_title, icon = "palette" }):next(function(item: any?, _err: string?, next_cx: any?)
		if item == nil then
			return
		end
		local where = next_cx or cx
		local palette_items: { any } = {}
		local preset = settings_lib.PRESETS[item.id :: string]
		if preset then
			table.insert(palette_items, { label = preset.name, detail = "preset", pick = "save", spec = "" })
		end
		for _, named in settings_lib.NAMED do
			table.insert(palette_items, { label = named.palette.name, detail = if named.key == "accent" then nil else "alternative", pick = "save", spec = "named:" .. named.key })
		end
		table.insert(palette_items, { label = L.color_custom, detail = "#d97757 or #9aa7b4, #5b8def", pick = "custom" })
		table.insert(palette_items, { label = L.color_reset, pick = "save", spec = "" })
		where:pick({ items = palette_items, placeholder = parse.provider_label(item.id :: string), icon = "palette" }):next(function(choice: any?, _err2: string?, final_cx: any?)
			if choice == nil then
				return
			end
			local dest = final_cx or where
			if choice.pick == "custom" then
				local spec = settings.colors[item.id :: string]
				dest:prompt({
					value = if spec and string.sub(spec :: string, 1, 1) == "#" then spec else "",
					placeholder = L.prompt_custom,
					icon = "palette",
				}):next(function(text: string?, _err3: string?, last_cx: any?)
					if text == nil or not string.find(text :: string, "%S") then
						return
					end
					local colors = table.clone(settings.colors)
					colors[item.id :: string] = text :: string
					settings_lib.set({ colors = colors })
					local target = last_cx or dest
					target:toast("success", L.toast_saved)
					after_change(target)
				end)
				return
			end
			local colors = table.clone(settings.colors)
			if choice.spec == "" then
				colors[item.id :: string] = nil
			else
				colors[item.id :: string] = choice.spec :: string
			end
			settings_lib.set({ colors = colors })
			after_change(dest)
		end)
	end)
end

local function open_menu(cx: any)
	local settings = settings_lib.load()
	local L = labels.get(settings.language)
	local details = {
		current = if providers_present() then parse.provider_label((settings_lib.ordered(settings, providers_present()))[1] or "") else "",
		all = tostring(#providers_present()) .. " providers",
		selected = tostring(#settings.selected) .. " selected",
	}
	local items: { any } = {
		{ label = L.menu_mode_current, detail = details.current, group = "Show", current = settings.mode == "current", pick = "mode", mode = "current" },
		{ label = L.menu_mode_all, detail = details.all, group = "Show", current = settings.mode == "all", pick = "mode", mode = "all" },
		{ label = L.menu_mode_selected, detail = details.selected, group = "Show", current = settings.mode == "selected", pick = "mode", mode = "selected" },
		{ label = L.menu_choose, group = "Providers", pick = "choose" },
		{ label = L.menu_reorder, group = "Providers", pick = "reorder" },
		{ label = L.menu_colors, group = "Providers", pick = "colors" },
		{ label = L.menu_refresh, pick = "refresh" },
		{ label = L.menu_dashboard, pick = "dashboard" },
		{ label = L.menu_usage_interval, detail = settings.usage_interval .. "s", pick = "usage_interval" },
		{ label = L.menu_stats_interval, detail = settings.stats_interval .. "s", pick = "stats_interval" },
		{ label = if settings.language == "en" then L.menu_language else L.menu_language_en, pick = "language" },
		{ label = (if settings.show_tokens then "✓ " else "") .. "🔥 " .. L.tokens, group = "Status bar", pick = "tokens" },
		{ label = (if settings.show_cost then "✓ " else "") .. "💰", group = "Status bar", pick = "cost" },
		{ label = (if settings.alerts then "✓ " else "") .. "alerts", group = "Status bar", pick = "alerts" },
		{ label = (if settings.update_check then "✓ " else "") .. L.menu_update_check, pick = "update_check" },
		{ label = L.menu_reset, pick = "reset" },
	}
	cx:pick({ items = items, placeholder = L.menu_title, icon = "gauge" }):next(function(item: any?, _err: string?, next_cx: any?)
		if item == nil then
			return
		end
		local where = next_cx or cx
		if item.pick == "mode" then
			settings_lib.set({ mode = item.mode :: string })
			after_change(where)
		elseif item.pick == "choose" then
			open_chooser(where)
		elseif item.pick == "reorder" then
			open_reorder(where)
		elseif item.pick == "colors" then
			open_colors(where)
		elseif item.pick == "refresh" then
			fetch.kv_set("refresh_request", os.time() * 1000)
			for _, src in fetch.sources() do
				fetch.maybe_fetch(src, "usage", true)
			end
			where:toast("success", L.toast_refresh_ok)
		elseif item.pick == "dashboard" then
			open_dashboard_or_nil(where)
		elseif item.pick == "usage_interval" then
			open_interval(where, "usage_interval", 60, 600)
		elseif item.pick == "stats_interval" then
			open_interval(where, "stats_interval", 60, 3600)
		elseif item.pick == "language" then
			settings_lib.set({ language = if settings.language == "en" then "zh-CN" else "en" })
			after_change(where)
		elseif item.pick == "tokens" then
			settings_lib.set({ show_tokens = not settings.show_tokens })
			after_change(where)
		elseif item.pick == "cost" then
			settings_lib.set({ show_cost = not settings.show_cost })
			after_change(where)
		elseif item.pick == "alerts" then
			settings_lib.set({ alerts = not settings.alerts })
			after_change(where)
		elseif item.pick == "update_check" then
			settings_lib.set({ update_check = not settings.update_check })
			after_change(where)
		elseif item.pick == "reset" then
			settings_lib.reset()
			after_change(where)
			where:toast("success", L.toast_reset)
		end
	end)
end

-- ── commands ────────────────────────────────────────────────────────────────

-- The focused pane's dashboard block, if any. Matched by block kind, not title: the parked
-- sync block carries the same title.
local function info_is_dashboard(info: any): boolean
	return type(info) == "table" and info.block == tern.plugin.id .. ".dashboard"
end

function open_dashboard(cx: any)
	for _, pane in cx.session:panes() do
		if info_is_dashboard(pane) then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(tern.plugin.id .. ".dashboard", nil, "beside") == nil then
		local L = labels.get(settings_lib.load().language)
		cx:toast("error", L.dash_failed)
	end
end

tern.command({
	id = "panel",
	title = "Dora omp Usage: Settings",
	icon = "gauge",
	keys = { "ctrl+alt+u" },
	run = open_menu,
})

tern.command({
	id = "settings",
	title = "Dora omp Usage: Settings menu",
	icon = "gauge",
	run = open_menu,
})

tern.command({
	id = "refresh",
	title = "Dora omp Usage: Refresh usage",
	icon = "gauge",
	run = function(cx)
		fetch.kv_set("refresh_request", os.time() * 1000)
		for _, src in fetch.sources() do
			fetch.maybe_fetch(src, "usage", true)
		end
		local L = labels.get(settings_lib.load().language)
		cx:toast("success", L.toast_refresh_ok)
	end,
})

tern.command({
	id = "update",
	title = "Dora omp Usage: Update to the latest release",
	icon = "download",
	run = function(cx)
		update.install(function(ok: boolean, msg: string)
			local up = update.get_latest()
			local L = labels.get(settings_lib.load().language)
			cx:toast(if ok then "success" else "error",
				if ok then string.format(L.update_ok, (type(up) == "table" and up.version) or "?") else string.format(L.update_fail, msg))
			if ok then
				tern.chrome.refresh()
			end
		end)
	end,
})

tern.command({
	id = "dashboard",
	title = "Dora omp Usage: dashboard",
	icon = "gauge",
	run = open_dashboard,
})

-- What the plugin sees, for the times the line doesn't show: data ages, the chip, the provider it maps to.
tern.command({
	id = "diagnostics",
	title = "Dora omp Usage: Diagnostics",
	icon = "gauge",
	run = function(cx)
		local now = os.time() * 1000
		local settings = settings_lib.load()
		local L = labels.get(settings.language)
		local pane = cx.session:focused()
		refresh_cache()
		refresh_host_map(cx)
		local dock = if pane then read_dock(cx, pane) else identity.read_dock(nil, tern.json.decode)
		local host_key = (pane and pane_host_map[pane]) or "local"
		local source = "local"
		local data: any = nil
		if pane then
			source, data = data_for(pane)
		end
		local selection = identity.resolve(dock, if data then data.models else fetch.kv_get("models@" .. source))
		local function age(at: any): string
			return if type(at) == "number" then line.compact_number(math.floor((now - at) / 1000)) .. "s ago" else "never"
		end
		local parts: { string } = { "host " .. host_key }
		table.insert(parts, "source " .. source)
		for _, src in fetch.sources() do
			local u = fetch.kv_get("usage@" .. src)
			local t = fetch.kv_get("today@" .. src)
			table.insert(parts, string.format("%s: usage %s · today %s", src,
				age(if type(u) == "table" then u.at else nil),
				age(if type(t) == "table" then t.at else nil)))
		end
		table.insert(parts, "chip " .. (dock.chip or "-") .. " · selector " .. (selection.selector or "?"))
		table.insert(parts, "identity " .. selection.status .. "/" .. selection.reason
			.. " · bridge " .. dock.bridge_status .. " · source " .. (selection.source or "-")
			.. " · session " .. (selection.sessionId or "-") .. " · child " .. tostring(dock.viewing))
		local mem_ok, mem_kb = pcall(collectgarbage, "count")
		local kv_ok, kv_text = pcall(tern.fs.read, tern.plugin.data .. "/kv.json", 1048576)
		table.insert(parts, string.format("lua heap %s · kv.json %s",
			if mem_ok and type(mem_kb) == "number" then string.format("%.0f KB", mem_kb) else "n/a",
			if kv_ok and type(kv_text) == "string" then string.format("%.1f KB", #kv_text / 1024) else "n/a"))
		local detail = table.concat(parts, " · ")
		local usage = fetch.kv_get("usage@" .. source)
		local stale = type(usage) == "table" and type(usage.at) == "number" and now - usage.at > STALE_MS
		cx:toast(if stale then "error" else "info", L.menu_title, detail .. (if stale then " · " .. L.toast_stale else ""))
	end,
})
