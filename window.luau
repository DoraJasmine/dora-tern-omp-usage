-- Window half: draws the usage line above the focused omp composer's context bar (lib/line), keeps a
-- watchdog on the fetch service, shows today's tokens and cost in the status bar, and offers the settings.
-- The data comes from tern.kv, written by lib/fetch (host half, or this half if the daemon has none).
local parse = require("./lib/parse")
local labels = require("./lib/labels")
local settings_lib = require("./lib/settings")
local line = require("./lib/line")
local fetch = require("./lib/fetch")

local SHEET = "usage-plus"
local POLL_MS = 1000
local WATCHDOG_MS = 10000
local STALE_MS = 15 * 60 * 1000

-- Where this window half runs and whose kv it sees (answers the multi-host question empirically).
pcall(tern.kv.set, "probe_window", {
	context = tern.context,
	plugin_dir = tern.plugin.dir,
	data_dir = tern.plugin.data,
	os = tern.runtime.os,
	at = os.time(),
})

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

-- ── per-host data: sync blocks carry each host's kv to every window ─────────
-- The host half renders a `sync` block whose text is this machine's kv as JSON.
-- A window reads every sync block it can see (local and remote hosts'), maps each
-- pane to its host (cx.hosts:list supplies hosts with their pane ids), and shows
-- the data of the host the focused pane belongs to.

local SYNC_BLOCK = tern.plugin.id .. ".sync"
local host_data: { [string]: any } = {} -- host key ("local" or name) → {usage, today, models, at}
local pane_host_map: { [number]: string } = {}
local last_sync_read = 0
local last_ensure = 0

local function refresh_host_map(cx: any)
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	pane_host_map = {}
	if ok and type(hosts) == "table" then
		for _, host in hosts do
			if type(host) == "table" and type(host.panes) == "table" then
				local key = if host.kind == "local" then "local" else tostring(host.name or host.id)
				for _, pid in host.panes do
					pane_host_map[pid] = key
				end
			end
		end
	end
end

local function decode_payload(text: string): any
	local at = string.find(text or "", "{", 1, true)
	if not at then
		return nil
	end
	local ok, doc = pcall(tern.json.decode, string.sub(text, at))
	return if ok then doc else nil
end

local function refresh_sync_data(cx: any)
	local now = os.time()
	if now - last_sync_read < 3 then
		return
	end
	last_sync_read = now
	local ok, panes = pcall(function()
		return cx.session:panes()
	end)
	if not ok or type(panes) ~= "table" then
		return
	end
	for _, info in panes do
		if type(info) == "table" and info.block == SYNC_BLOCK then
			local ok_read, answer = pcall(function()
				return cx.session:read(info.pane, { max_chars = 8000 })
			end)
			if ok_read and type(answer) == "table" and answer.kind == "plugin" and type(answer.text) == "string" then
				local doc = decode_payload(answer.text :: string)
				if doc ~= nil then
					host_data[pane_host_map[info.pane] or "local"] = doc
				end
			end
		end
	end
end

-- Opens this host's sync block once, when the window's current host is remote (the
-- local machine's data needs no block: the window half reads the local kv directly).
local function ensure_sync_block(cx: any)
	local now = os.time()
	if now - last_ensure < 5 then
		return
	end
	last_ensure = now
	local ok, current = pcall(function()
		return cx.hosts:current()
	end)
	if not ok or type(current) ~= "table" or current.kind ~= "remote" then
		return
	end
	local name = tostring(current.name or current.id)
	-- Only offer the block kind once the current host's catalog is ready: calling
	-- cx:new_block earlier prints "no block type ... on this host" into the pane.
	local ok_types, types = pcall(function()
		return cx.session:block_types()
	end)
	local catalog_ready = false
	if ok_types and type(types) == "table" then
		for _, bt in types do
			if type(bt) == "table" and bt.kind == SYNC_BLOCK then
				catalog_ready = true
				break
			end
		end
	end
	if not catalog_ready then
		return -- retry on a later tick
	end
	local ok2, panes = pcall(function()
		return cx.session:panes()
	end)
	if not ok2 or type(panes) ~= "table" then
		return
	end
	for _, info in panes do
		if type(info) == "table" and info.block == SYNC_BLOCK then
			-- The sync block is infrastructure, not content: keep it out of the tab bar by
			-- parking it into its session's deck (its view keeps rendering there).
			if info.parked ~= true then
				pcall(function()
					cx.layout:park(info.pane)
				end)
			end
			if pane_host_map[info.pane] == name then
				return -- this host already has its sync block
			end
		end
	end
	local opened: any = nil
	local ok_open = pcall(function()
		opened = cx:new_block(SYNC_BLOCK, nil, "tab", { focus = false })
	end)
	if ok_open and type(opened) == "number" then
		pcall(function()
			cx.layout:park(opened :: number)
		end)
	end
end

-- The focused pane's host key ("local" or the host's name) and that host's data,
-- falling back to the local kv when the host has no sync block (yet).
local function data_for(settings: any, pane: number?): (string, any)
	local key = (pane and pane_host_map[pane]) or "local"
	local data = host_data[key]
	if key ~= "local" and type(data) == "table" and type(data.usage) == "table" then
		return key, data
	end
	return "local", {
		usage = fetch.kv_get("usage"),
		models = fetch.kv_get("models"),
		today = fetch.kv_get("today"),
		at = os.time() * 1000,
	}
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
local cached: any = { settings = nil, usage = nil, today = nil, sig = nil }

local function refresh_cache()
	local settings = settings_lib.load()
	cached.settings = settings
	cached.usage = fetch.kv_get("usage")
	cached.today = fetch.kv_get("today")
	local sig = table.concat({
		tostring(if type(cached.usage) == "table" then cached.usage.at else nil),
		tostring(if type(cached.today) == "table" then cached.today.at else nil),
		tostring(settings.show_tokens), tostring(settings.show_cost), tostring(settings.alerts), settings.language,
	}, "/")
	if sig ~= cached.sig then
		cached.sig = sig
		tern.chrome.refresh()
	end
end

local function providers_present(): { string }
	local present: { string } = {}
	local seen: { [string]: boolean } = {}
	local usage = fetch.kv_get("usage")
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
	return present
end

local function today_text(settings: any, host_key: string?, today: any): string?
	if type(today) ~= "table" or type(today.tokens) ~= "number" or type(today.cost) ~= "number" then
		return nil
	end
	local L = labels.get(settings.language)
	if host_key ~= nil and host_key ~= "local" then
		return string.format(L.today_line_host, host_key :: string, line.compact_number(today.tokens :: number), today.cost :: number)
	end
	return string.format(L.today_line, line.compact_number(today.tokens :: number), today.cost :: number)
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
	refresh_sync_data(cx)
	ensure_sync_block(cx)

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
	local host_key, data = data_for(settings, pane :: number)
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
	local host_sig = host_key .. "/" .. tostring(if type(data.today) == "table" then data.today.at else nil)
	if host_sig ~= cached.host_sig then
		cached.host_sig = host_sig
		tern.chrome.refresh()
	end
	install(line.sheet(settings, model, L, today_text(settings, host_key, data.today), data.today, now))
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
	local data = host_data[host_key]
	local shown_usage = if host_key ~= "local" and type(data) == "table" and type(data.usage) == "table"
		then data.usage
		else cached.usage
	local today = if host_key ~= "local" and type(data) == "table" and type(data.today) == "table"
		then data.today
		else cached.today
	local out: { any } = {}
	-- First, so a narrow window that clips the end of the status line still shows it.
	if type(shown_usage) == "table" and type(shown_usage.at) == "number" and os.time() * 1000 - shown_usage.at > STALE_MS then
		table.insert(out, { text = "⚠", tone = "error", command = PLUGIN .. "diagnostics" })
	end
	if type(today) == "table" and type(today.tokens) == "number" and settings.show_tokens then
		table.insert(out, { text = "🔥 " .. line.compact_number(today.tokens :: number) .. " " .. L.tokens, command = PLUGIN .. "dashboard" })
	end
	if type(today) == "table" and type(today.cost) == "number" and settings.show_cost then
		table.insert(out, { text = string.format("💸 $%.0f", today.cost :: number), command = PLUGIN .. "dashboard" })
	end
	if pane.kind == "agent" then
		table.insert(out, { text = L.usage, icon = "gauge", command = PLUGIN .. "panel" })
	end
	return if #out > 0 then out else nil
end)

-- ── settings, as menus (the canvas panel is a later milestone) ──────────────

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
			fetch.maybe_fetch("usage", true)
			where:toast("success", L.toast_refresh_ok)
		elseif item.pick == "dashboard" then
			open_dashboard(where)
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

-- One dashboard per window: focus the open one, else open it beside the focused pane.
function open_dashboard(cx: any)
	for _, pane in cx.session:panes() do
		if pane.title == "Dora omp Usage" then
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
		fetch.maybe_fetch("usage", true)
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
		local usage, models, today = fetch.kv_get("usage"), fetch.kv_get("models"), fetch.kv_get("today")
		local pane = cx.session:focused()
		local chip = nil
		if pane then
			chip = (read_dock(cx, pane))
		end
		local provider = nil
		if chip and type(models) == "table" and type(models.by_name) == "table" then
			local entry = models.by_name[chip :: string]
			provider = if entry then entry.provider else parse.provider_hint(chip)
		end
		local function age(at: any): string
			return if type(at) == "number" then line.compact_number(math.floor((now - at) / 1000)) .. "s ago" else "never"
		end
		local host_key = (pane and pane_host_map[pane]) or "local"
		local sync_hosts: { string } = {}
		for key in host_data do
			table.insert(sync_hosts, key)
		end
		table.sort(sync_hosts)
		local detail = string.format(
			"host %s · sync blocks [%s] · usage %s · models %s · today %s · chip %s · provider %s",
			host_key,
			table.concat(sync_hosts, ", "),
			age(if type(usage) == "table" then usage.at else nil),
			age(if type(models) == "table" then models.at else nil),
			age(if type(today) == "table" then today.at else nil),
			chip or "-",
			provider or "?"
		)
		local stale = type(usage) == "table" and type(usage.at) == "number" and now - usage.at > STALE_MS
		cx:toast(if stale then "error" else "info", L.menu_title, detail .. (if stale then " · " .. L.toast_stale else ""))
	end,
})
