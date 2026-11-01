-- Window half: draws the usage line above the focused omp composer's context bar (lib/line), keeps a
-- watchdog on the fetch service, shows today's tokens and cost in the status bar, and offers the settings.
-- The data comes from tern.kv, written by lib/fetch (host half, or this half if the daemon has none).
local parse = require("./lib/parse")
local labels = require("./lib/labels")
local settings_lib = require("./lib/settings")
local line = require("./lib/line")
local fetch = require("./lib/fetch")

local SHEET = "usage-plus"
-- Module state, declared early so every function below shares one scope.
local cached: any = { settings = nil, by_source = nil, sources_list = nil,
	wsl_list = nil, remote_list = nil, sig = nil, host_sig = nil }
local POLL_MS = 1000
local WATCHDOG_MS = 10000
local STALE_MS = 15 * 60 * 1000

local FOCUS_ROLE = "omp.composer.focus"
local MODEL_ROLE = "omp.composer.model"
local NAME_SUFFIX = "/name"

-- ── the omp pane's surface tree ─────────────────────────────────────────────

-- The first node, depth first, that `test` accepts. Nodes carry `id`, `p` {role, spans[{t}]} and `c`
-- (children), as jmazzola/tern-plugin-omp-usage reads them.
local function find_node(node: any, test: (any) -> boolean): any
	if type(node) ~= "table" then
		return nil
	end
	if test(node) then
		return node
	end
	if type(node.c) == "table" then
		for _, child in ipairs(node.c) do
			local found = find_node(child, test)
			if found then
				return found
			end
		end
	end
	return nil
end

local function role_is(role: string): (any) -> boolean
	return function(node: any): boolean
		return type(node.p) == "table" and node.p.role == role
	end
end

local function id_ends(suffix: string): (any) -> boolean
	return function(node: any): boolean
		return type(node.id) == "string" and string.sub(node.id, -#suffix) == suffix
	end
end

-- From a dock tree: the model chip's name (what the cache and the provider mapping key on) and whether a
-- subagent's transcript is being viewed.
local function dock_chip(tree: any): (string?, boolean)
	if type(tree) ~= "table" then
		return nil, false
	end
	local function find(test: (any) -> boolean): any
		return find_node(tree.main, test) or find_node(tree.dock, test)
	end
	local chip = find(role_is(MODEL_ROLE))
	local name = if chip then find_node(chip, id_ends(NAME_SUFFIX)) else nil
	local spans = if name and type(name.p) == "table" then name.p.spans else nil
	local first = if type(spans) == "table" then spans[1] else nil
	local text: string? = nil
	if type(first) == "table" and type(first.t) == "string" then
		local trimmed = string.match(first.t :: string, "^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then
			text = trimmed
		end
	end
	return text, find(role_is(FOCUS_ROLE)) ~= nil
end

local function read_dock(cx: any, pane: number): (string?, boolean)
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { root = "dock" })
	end)
	return dock_chip(if ok then tree else nil)
end

-- ── per-host data: one fetch source per host ────────────────────────────
-- Sources are "local" and one per detected WSL distro ("wsl:<distro>"), fetched by
-- lib/fetch (on Windows through wsl.exe) and keyed in kv as "usage@<s>" / "models@<s>" /
-- "today@<s>" / "days@<s>". The focused pane's host maps to its source: local panes to
-- "local", panes on a WSL remote host (Tern names them "<user>@wsl") to that distro.

local pane_host_map: { [number]: string } = {}
local local_host_name: string = ""
local last_chip: string? = nil

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
	if type(wsl_list) == "table" and #wsl_list > 0 then
		return "wsl:" .. wsl_list[1]
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
		-- a remote host with no fetchable source: limits fall back to the local accounts,
		-- but the today row reads "data unavailable" instead of claiming local numbers
		return host_key, {
			usage = fetch.kv_get("usage@local"),
			models = fetch.kv_get("models@local"),
			today = nil,
		}, label
	end
	return source, {
		usage = fetch.kv_get("usage@" .. source),
		models = fetch.kv_get("models@" .. source),
		today = fetch.kv_get("today@" .. source),
	}, label
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
		cached.by_source[source] = { usage = usage, today = today }
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
	end
	collect(fetch.kv_get("usage")) -- legacy flat key
	return present
end

local function today_text(settings: any, label: string, today: any): string?
	local L = labels.get(settings.language)
	if type(today) ~= "table" or type(today.tokens) ~= "number" or type(today.cost) ~= "number" then
		return string.format(L.today_unavailable, label)
	end
	return string.format(L.today_line, label, line.compact_number(today.tokens :: number), today.cost :: number)
end

local function tick(cx: any?)
	if cx == nil then
		return
	end
	refresh_cache()
	local settings = cached.settings
	local L = labels.get(settings.language)
	local now = os.time() * 1000

	refresh_host_map(cx)

	local pane = cx.session:focused()
	local focused_agent = false
	if pane then
		local ok, info = pcall(function()
			return cx.session:pane(pane)
		end)
		focused_agent = ok and type(info) == "table" and info.kind == "agent"
	end
	if not focused_agent then
		install("")
		return
	end

	local chip, _viewing = read_dock(cx, pane :: number)
	local host_key, data, host_label = data_for(pane :: number)
	-- A model switch redraws at once from the cached reports, then fetches fresh ones
	-- for the focused source (jmazzola's "redraw, then fetch" pattern).
	if chip ~= nil and chip ~= last_chip then
		last_chip = chip
		local src = source_for_host(host_key, cached.wsl_list, cached.remote_list)
		if src ~= "?" then
			fetch.maybe_fetch(src, "usage", true)
		end
	end
	local usage = data.usage
	local models = data.models
	local model = line.build(settings, {
		usage = if type(usage) == "table" and type(usage.reports) == "table"
			then usage
			else { reports = {}, capacity = {} },
		models = if type(models) == "table" and type(models.by_name) == "table" then models else nil,
		chip = chip,
	}, now)
	if #model.groups == 0 then
		install("")
		return
	end
	-- redraw the status bar when the shown host's data changed
	local host_sig = host_key .. "/" .. tostring(if type(data.today) == "table" then data.today.at else nil) .. "/" .. tostring(data.sync_error or "")
	if host_sig ~= cached.host_sig then
		cached.host_sig = host_sig
		tern.chrome.refresh()
	end
	install(line.sheet(settings, model, L, today_text(settings, host_label, data.today), data.today, now))
end

local function poll_loop(cx: any?)
	tern.timer(POLL_MS, poll_loop)
	tick(cx)
end

tern.timer(POLL_MS, poll_loop)

tern.on("focus", function(_ev: any, cx: any)
	tick(cx)
end)

-- Official startup hook: fires once per window after the session has settled (saved tabs
-- restored), so the first draw sees the real panes instead of racing the restore.
tern.on("window_start", function(cx: any)
	tick(cx)
end)

-- A paused hook stops this plugin's timers; log it and redraw the moment it resumes.
tern.on("budget", function(ev: any, cx: any)
	pcall(function()
		tern.log.info("usage-plus budget", ev.hook, ev.state, ev.ms or ev.paused_ms or "")
	end)
	if ev.state == "resumed" then
		tick(cx)
	end
end)

-- The watchdog: if the daemon half is not running its loop (no daemon, or the plugin half off), this window
-- still keeps the data fresh; the kv locks keep the two halves from doubling a fetch.
local function watchdog_loop()
	fetch.service()
	tern.timer(WATCHDOG_MS, watchdog_loop)
end

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
		tick(cx)
		tern.chrome.refresh()
	end
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
		{ label = if settings.language == "en" then L.menu_language else L.menu_language_en, pick = "language" },
		{ label = (if settings.show_tokens then "✓ " else "") .. "🔥 " .. L.tokens, group = "Status bar", pick = "tokens" },
		{ label = (if settings.show_cost then "✓ " else "") .. "💰", group = "Status bar", pick = "cost" },
		{ label = (if settings.alerts then "✓ " else "") .. "alerts", group = "Status bar", pick = "alerts" },
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
		local chip = nil
		if pane then
			chip = (read_dock(cx, pane))
		end
		local host_key = (pane and pane_host_map[pane]) or "local"
		local source = source_for_host(host_key, cached.wsl_list, cached.remote_list)
		local models = fetch.kv_get("models@" .. source)
		local provider = nil
		if chip and type(models) == "table" and type(models.by_name) == "table" then
			local entry = models.by_name[chip :: string]
			provider = if entry then entry.provider else parse.provider_hint(chip)
		end
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
		table.insert(parts, "chip " .. (chip or "-") .. " · provider " .. (provider or "?"))
		local mem_ok, mem_kb = pcall(collectgarbage, "count")
		local kv_ok, kv_text = pcall(tern.fs.read, tern.plugin.data .. "/kv.json", 1048576)
		table.insert(parts, string.format("lua heap %s · kv.json %s",
			if mem_ok and type(mem_kb) == "number" then string.format("%.0f KB", mem_kb) else "n/a",
			if kv_ok and type(kv_text) == "string" then string.format("%.1f KB", #kv_text / 1024) else "n/a"))
		local detail = table.concat(parts, " · ")
		local usage = fetch.kv_get("usage@" .. source)
		local stale = type(usage) == "table" and type(usage.at) == "number" and now - usage.at > STALE_MS
			local stale = type(usage) == "table" and type(usage.at) == "number" and now - usage.at > STALE_MS
		cx:toast(if stale then "error" else "info", L.menu_title, detail .. (if stale then " · " .. L.toast_stale else ""))
	end,
})
