-- Run with the standalone Luau CLI: luau tests/line.luau
local parse = require("../lib/parse")
local identity = require("../lib/identity")
local line = require("../lib/line")

local settings = {
	mode = "current", language = "en", selected = {}, order = { "openai-codex", "leimugpt" },
	colors = {}, warn_at = 25, bad_at = 10,
}
local catalog = parse.catalog({ models = {
	{ provider = "leimugpt", id = "gpt-6.1-sol", name = "GPT-6.1 Sol" },
	{ provider = "openai-codex", id = "gpt-6.1-sol", name = "GPT-6.1 Sol" },
} })
local data = {
	models = catalog,
	usage = { reports = { {
		provider = "openai-codex", credits = 0,
		windows = { {
			key = "5h", label = "5h", ms = 18000000, left = 0.73,
			scope_shared = true, scope_model = "", scope_tier = "", saved = 0,
		} },
	} }, capacity = {} },
	today = { by_provider = {
		leimugpt = { tokens = 3, cost = 0 },
		["openai-codex"] = { tokens = 11, cost = 1 },
	} },
}
local function choose(provider)
	data.selection = identity.resolve({
		chip = "GPT-6.1 Sol", viewing = false, bridge_status = "ready",
		identity = { version = 1, scope = "main", sessionId = "main", provider = provider, id = "gpt-6.1-sol" },
	}, catalog)
	return line.build(settings, data, 0)
end

-- Historical spend is not evidence of the user's current selection.
local codex = choose("openai-codex")
assert(#codex.groups == 1 and codex.groups[1].id == "openai-codex")
assert(codex.groups[1].spend == nil and codex.groups[1].windows[1].pct == 73)
local proxy = choose("leimugpt")
assert(#proxy.groups == 1 and proxy.groups[1].id == "leimugpt")
assert(#proxy.groups[1].windows == 0 and proxy.groups[1].spend.tokens == 3 and proxy.groups[1].spend.cost == 0)
assert(proxy.signature ~= codex.signature, "same-name provider switches must redraw")

-- A chosen provider with no data must not borrow another provider's quota.
data.today.by_provider.leimugpt = { tokens = 0, cost = 0 }
local empty_proxy = choose("leimugpt")
assert(#empty_proxy.groups == 0 and empty_proxy.notice ~= nil)
assert(empty_proxy.signature ~= proxy.signature, "withdraw old spend after it disappears")
local codex_again = choose("openai-codex")
assert(#codex_again.groups == 1 and codex_again.groups[1].id == "openai-codex")
assert(codex_again.notice == nil)

-- Removing the bridge or losing its validity must withdraw the old provider.
for _, dock in {
	{ chip = "GPT-6.1 Sol", bridge_status = "missing" },
	{ chip = "GPT-6.1 Sol", bridge_status = "invalid" },
	{ chip = "GPT-6.1 Sol", bridge_status = "unsupported" },
	{ chip = "GPT-6.1 Sol", viewing = true, bridge_status = "ready", identity = {
		version = 1, scope = "main", sessionId = "main", provider = "openai-codex", id = "gpt-6.1-sol",
	} },
} do
	data.selection = identity.resolve(dock, catalog)
	local pending = line.build(settings, data, 0)
	assert(#pending.groups == 0 and pending.notice ~= nil, "unresolved selection must not expose an arbitrary provider")
	assert(pending.signature ~= codex_again.signature)
end

-- Explicit aggregate modes are independent of an ambiguous composer selection.
data.today.by_provider.leimugpt = { tokens = 3, cost = 0 }
settings.mode = "all"
local all = line.build(settings, data, 0)
assert(all.notice == nil and #all.groups == 2)
assert(all.groups[1].id == "openai-codex" and all.groups[2].id == "leimugpt")
assert(all.groups[1].windows[1].pct == 73 and all.groups[2].spend.tokens == 3)
settings.mode = "selected"
settings.selected = { "leimugpt" }
local selected = line.build(settings, data, 0)
assert(selected.notice == nil and #selected.groups == 1 and selected.groups[1].id == "leimugpt")
assert(selected.groups[1].spend.tokens == 3)

-- Canonical provider keys must survive every parser, including case variants.
local case_catalog = parse.catalog({ models = {
	{ provider = "CaseProvider", id = "CaseID", name = "Case model" },
	{ provider = "caseprovider", id = "CaseID", name = "Case model" },
} })
local case_usage = parse.usage({ reports = {}, capacity = {
	CaseProvider = { { window = "5h", accounts = 4, usedAccounts = 1 } },
	caseprovider = { { window = "5h", accounts = 4, usedAccounts = 3 } },
} }, 0)
local case_totals = parse.by_model_totals({ byModel = {
	{ provider = "CaseProvider", totalInputTokens = 11, totalCost = 1 },
	{ provider = "caseprovider", totalOutputTokens = 23, totalCost = 2 },
} })
assert(case_totals.CaseProvider.tokens == 11 and case_totals.caseprovider.tokens == 23)
local raw_provider = parse.report({ provider = "CaseProvider" }, 0)
assert(raw_provider == "CaseProvider", "report provider identity must not be case-folded")
settings.mode = "current"
for provider, pct in { CaseProvider = 75, caseprovider = 25 } do
	local case_selection = identity.resolve({
		chip = "Case model", bridge_status = "ready",
		identity = { version = 1, scope = "main", sessionId = "s", provider = provider, id = "CaseID" },
	}, case_catalog)
	local case_model = line.build(settings, {
		selection = case_selection, models = case_catalog, usage = case_usage,
		today = { by_provider = case_totals },
	}, 0)
	assert(#case_model.groups == 1 and case_model.groups[1].id == provider)
	assert(case_model.groups[1].windows[1].pct == pct, "case variants must not share quota data")
end

print("provider isolation regressions passed")
