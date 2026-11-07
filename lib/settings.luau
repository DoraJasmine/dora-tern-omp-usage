-- Settings, kept in tern.kv (shared by every window and the host half), with the providers' palettes.
-- All writes go through here so the panel, the menus and future surfaces share validation.
local parse = require("./parse")
local M = {}

local DEFAULTS = {
	mode = "current", -- current | all | selected
	selected = {}, -- provider ids, when mode = selected
	order = {}, -- provider ids, in the user's order; others follow the preset order
	colors = {}, -- provider id → "named:<key>" | "#rrggbb" | "#rrggbb, #rrggbb"
	warn_at = 25, -- percent left that turns a window amber
	bad_at = 10, -- percent left that turns a window red
	usage_interval = 90, -- seconds between usage fetches
	stats_interval = 300, -- seconds between today fetches
	show_tokens = true,
	show_cost = true,
	alerts = true, -- stored and user-facing; the toasts themselves are a planned follow-up
	update_check = true, -- daily GitHub releases probe + the ⬆ segment

	language = "en",
}

-- A provider's colors: `a` for its label and the bars' start, `b` (else `a`) for where they end and their tips.
-- Each is a shade per theme, so it reads on light and dark alike.
M.PRESETS = {
	anthropic = { name = "Clay", a = "light-dark(#c15f3c, #d97757)" },
	["openai-codex"] = { name = "Graphite to blue", a = "light-dark(#6b7785, #9aa7b4)", b = "light-dark(#3366d6, #6f9cff)" },
	openai = { name = "OpenAI green", a = "light-dark(#0d8a6a, #10a37f)" },
	["kimi-code"] = { name = "Kimi green", a = "light-dark(#3a8a2c, #7dd256)" },
	["google-gemini-cli"] = { name = "Blue to white", a = "light-dark(#1a66d9, #4f8ff7)", b = "light-dark(#7f9fd6, #f4f7ff)" },
	["google-antigravity"] = { name = "Antigravity blue", a = "light-dark(#3a58d6, #7390ff)" },
	["minimax-code"] = { name = "Red to pink", a = "light-dark(#d23f57, #f2576f)", b = "light-dark(#c2428e, #ff80c5)" },
	["opencode-go"] = { name = "Go cyan", a = "light-dark(#0a8aa1, #2ccde6)" },
	["alibaba-token-plan"] = { name = "Qwen purple", a = "light-dark(#6c4fd0, #a088ff)" },
	devin = { name = "Devin teal", a = "light-dark(#0e8c80, #34c8b6)" },
	["zai-coding-plan"] = { name = "Z.ai graphite", a = "light-dark(#3f3f46, #d4d4d8)", b = "light-dark(#18181b, #a1a1aa)" },
	zcode = { name = "ZCode graphite", a = "light-dark(#3f3f46, #d4d4d8)", b = "light-dark(#18181b, #a1a1aa)" },
}

M.ACCENT = { name = "Theme accent", a = "var(--accent)" }

M.NAMED = {
	{ key = "ember", palette = { name = "Ember", a = "light-dark(#c2410c, #fb923c)" } },
	{ key = "sunset", palette = { name = "Sunset", a = "light-dark(#c2410c, #fb923c)", b = "light-dark(#be123c, #fb7185)" } },
	{ key = "moss", palette = { name = "Moss", a = "light-dark(#4d7c0f, #a3e635)" } },
	{ key = "ocean", palette = { name = "Ocean", a = "light-dark(#0369a1, #38bdf8)", b = "light-dark(#0e7490, #67e8f9)" } },
	{ key = "orchid", palette = { name = "Orchid", a = "light-dark(#7e22ce, #c084fc)" } },
	{ key = "slate", palette = { name = "Slate", a = "light-dark(#475569, #94a3b8)", b = "light-dark(#1e293b, #e2e8f0)" } },
	{ key = "accent", palette = M.ACCENT },
}

local function named(key: string): any
	for _, item in M.NAMED do
		if item.key == key then
			return item.palette
		end
	end
	return nil
end
M.named = named

-- "…/…" for two colors, else one. "named:<key>" resolves to its palette.
local function spec_palette(spec: string): any
	if string.sub(spec, 1, 6) == "named:" then
		return named(string.sub(spec, 7))
	end
	local first, second = string.match(spec, "^%s*(#%x%x%x%x%x%x)%s*,%s*(#%x%x%x%x%x%x)%s*$")
	if first then
		return { name = spec, a = first, b = second }
	end
	local one = string.match(spec, "^%s*(#%x%x%x%x%x%x)%s*$")
	if one then
		return { name = spec, a = one }
	end
	return nil
end

-- A provider's two colors, from the user's choice, its preset, or the theme's accent.
function M.palette_for(settings: any, provider: string?): (string, string)
	local chosen = provider and settings.colors[provider]
	local palette = if chosen then spec_palette(chosen) else nil
	palette = palette or (provider and M.PRESETS[provider]) or M.ACCENT
	return palette.a, palette.b or palette.a
end

function M.color_name(settings: any, provider: string?): string
	local chosen = provider and settings.colors[provider]
	if chosen then
		local palette = spec_palette(chosen)
		if palette then
			return palette.name
		end
	end
	local preset = provider and M.PRESETS[provider]
	return if preset then preset.name else M.ACCENT.name
end

local function is_number(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Reads the store and merges the defaults; unknown keys and wrong types fall back.
function M.load(): any
	local ok, saved = pcall(tern.kv.get, "settings")
	local settings = {}
	for key, value in DEFAULTS do
		settings[key] = value
	end
	if ok and type(saved) == "table" then
		for key in DEFAULTS do
			local value = saved[key]
			if value == nil then
				continue
			end
			if key == "mode" then
				if value == "current" or value == "all" or value == "selected" then
					settings.mode = value
				end
			elseif key == "selected" or key == "order" then
				if type(value) == "table" then
					local list = {}
					for _, item in value do
						if type(item) == "string" then
							table.insert(list, item)
						end
					end
					settings[key] = list
				end
			elseif key == "colors" then
				if type(value) == "table" then
					local map = {}
					for id, spec in value do
						if type(id) == "string" and type(spec) == "string" and spec_palette(spec) then
							map[id] = spec
						end
					end
					settings.colors = map
				end
			elseif key == "language" then
				if value == "en" or value == "zh-CN" then
					settings.language = value
				end
			elseif is_number(value) then
				local n = value :: number
				if key == "usage_interval" then
					settings.usage_interval = math.clamp(math.floor(n), 60, 600)
				elseif key == "stats_interval" then
					settings.stats_interval = math.clamp(math.floor(n), 60, 3600)
				elseif key == "warn_at" or key == "bad_at" then
					settings[key] = math.clamp(math.floor(n), 1, 49)
				end
			elseif type(value) == "boolean" then
				settings[key] = value
			end
		end
		if settings.bad_at >= settings.warn_at then
			settings.bad_at = math.max(1, settings.warn_at - 15)
		end
	end
	return settings
end

function M.set(patch: any)
	local ok, saved = pcall(tern.kv.get, "settings")
	local store = if ok and type(saved) == "table" then saved else {}
	for key, value in patch do
		store[key] = value
	end
	pcall(tern.kv.set, "settings", store)
end

function M.reset()
	pcall(tern.kv.set, "settings", {})
end

-- The providers the line would list, in the user's order then the preset order.
function M.ordered(settings: any, present: { string }): { string }
	local seen: { [string]: boolean } = {}
	for _, id in present do
		seen[id] = true
	end
	local list: { string } = {}
	for _, id in settings.order do
		if seen[id] then
			table.insert(list, id)
			seen[id] = nil
		end
	end
	local rest: { string } = {}
	for _, id in present do
		if seen[id] then
			table.insert(rest, id)
		end
	end
	table.sort(rest, function(a: string, b: string)
		local ra, rb = parse.provider_rank(a), parse.provider_rank(b)
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)
	for _, id in rest do
		table.insert(list, id)
	end
	return list
end

return M
