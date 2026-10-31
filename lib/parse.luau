-- Pure parsing of omp CLI output into the plugin's model. No tern calls, so tests can run it directly.
--
-- Source of truth is `omp usage --json`: reports[] per account with limits[] (window, scope, amount),
-- resetCredits and capacity[provider] (account counts per window). Provider-agnostic: any provider with
-- limits shows; windows of any length map to 5h/1d/7d/mo or their span.
local M = {}

local HOUR = 3600000
local DAY = 86400000
-- "Unknown length" for window ordering, finite because kv is JSON and cannot hold Infinity.
local MAX_MS = 1e15

-- One-word labels; providers not listed take the first meaningful word of their id.
local PROVIDER_LABELS = {
	anthropic = "Claude",
	["openai-codex"] = "Codex",
	openai = "OpenAI",
	["kimi-code"] = "Kimi",
	["google-gemini-cli"] = "Gemini",
	["google-antigravity"] = "Antigravity",
	["minimax-code"] = "MiniMax",
	["opencode-go"] = "Go",
	["alibaba-token-plan"] = "Qwen",
	synthetic = "Synthetic",
	devin = "Devin",
	["zai-coding-plan"] = "Z.ai",
	zai = "Z.ai",
	zcode = "ZCode",
}

-- Words in provider ids that name the product or plan, not the provider.
local GENERIC = { api = true, cli = true, code = true, coding = true, plan = true, subscription = true, token = true }

-- Model-chip prefixes → provider, the fallback when the models catalog misses.
local PREFIX_HINTS = {
	anthropic = "anthropic", claude = "anthropic", opus = "anthropic", sonnet = "anthropic", haiku = "anthropic",
	gpt = "openai-codex", codex = "openai-codex", ["o3"] = "openai-codex", ["o4"] = "openai-codex",
	kimi = "kimi-code", ["k2"] = "kimi-code", ["k3"] = "kimi-code", moonshot = "kimi-code",
	gemini = "google-gemini-cli",
	minimax = "minimax-code", abab = "minimax-code",
	qwen = "alibaba-token-plan", glm = "alibaba-token-plan",
	zai = "zai-coding-plan", zcode = "zcode",
}

function M.provider_label(provider: any): string
	local id = string.lower(tostring(provider or ""))
	if id == "" then
		return ""
	end
	local known = PROVIDER_LABELS[id]
	if known then
		return known
	end
	for word in string.gmatch(id, "[^%-%s_]+") do
		if not GENERIC[string.lower(word)] then
			return string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2)
		end
	end
	return id
end

-- The provider a model chip's name suggests, via progressively shorter prefixes of its first
-- word ("Opus 5.5" → "opus" → anthropic; "K3.1 Pro" → "k3.1" → "k3" → kimi-code).
function M.provider_hint(chip: any): string?
	local text = string.lower(tostring(chip or ""))
	local word = string.match(text, "^[^%s]+") or ""
	for end_pos = #word, 1, -1 do
		local hit = PREFIX_HINTS[string.sub(word, 1, end_pos)]
		if hit then
			return hit
		end
	end
	return nil
end

-- A limit's window as { key, label, ms }, matched by omp's id or its length; unknown windows keep their id.
function M.window_of(limit: any): (string?, string?, number)
	local scope = type(limit) == "table" and limit.scope or nil
	local window = type(limit) == "table" and limit.window or nil
	local window_id = tostring((type(scope) == "table" and scope.windowId) or (type(window) == "table" and window.id) or "")
	local duration = type(window) == "table" and window.durationMs or nil
	local near = function(ms: number): boolean
		return type(duration) == "number" and math.abs(duration - ms) <= 60000
	end
	if window_id == "5h" or near(5 * HOUR) then
		return "5h", "5h", 5 * HOUR
	end
	if window_id == "daily" or window_id == "24h" or window_id == "1d" or near(DAY) then
		return "1d", "1d", DAY
	end
	if window_id == "7d" or near(7 * DAY) then
		return "7d", "7d", 7 * DAY
	end
	if window_id == "monthly" or window_id == "30d" or (type(duration) == "number" and duration >= 28 * DAY and duration <= 31 * DAY) then
		return "mo", "mo", 30 * DAY
	end
	if type(duration) == "number" and duration > 0 then
		local mins = math.round(duration / 60000)
		local label = if mins % 1440 == 0
			then tostring(mins / 1440) .. "d"
			elseif mins % 60 == 0 then tostring(mins / 60) .. "h"
			else tostring(mins) .. "m"
		return label, label, duration
	end
	if window_id ~= "" then
		return window_id, string.gsub(window_id, "%s+", "-"), MAX_MS
	end
	return nil, nil, MAX_MS
end

-- Providers, in the order the line lists them.
M.ORDER = {
	"anthropic", "openai-codex", "openai", "kimi-code", "google-gemini-cli",
	"google-antigravity", "minimax-code", "opencode-go", "alibaba-token-plan", "synthetic", "devin",
}

function M.provider_rank(id: string): number
	for i, p in M.ORDER do
		if p == id then
			return i
		end
	end
	return #M.ORDER + 1
end

-- Saved resets that clear `limit_id`: count and the soonest expiry within `warn_ms` (nil for none).
function M.credits_for(report: any, limit_id: string, warn_ms: number?, now_ms: number): (number, number?)
	local rc = type(report) == "table" and report.resetCredits or nil
	local credits = type(rc) == "table" and rc.credits or nil
	if type(credits) ~= "table" then
		local n = type(rc) == "table" and rc.availableCount or nil
		return if type(n) == "number" then n else 0, nil
	end
	local count, soonest = 0, nil
	for _, credit in credits do
		if type(credit) ~= "table" or credit.status ~= "available" or credit.usable == false then
			continue
		end
		if type(credit.clears) == "table" and not table.find(credit.clears, limit_id) then
			continue
		end
		local remaining = if type(credit.remainingCount) == "number" then credit.remainingCount else 1
		count += remaining
		local expires = credit.expiresAt
		if warn_ms and type(expires) == "number" and expires > now_ms and expires - now_ms <= warn_ms then
			if soonest == nil or expires < soonest then
				soonest = expires
			end
		end
	end
	return count, soonest
end

-- One report → { provider, label, windows[], credits }, windows deduped, kimi-style `limit_*` duplicates
-- dropped, scope kept for model filtering at build time.
function M.report(report: any, now: number): (string, { any }, number)
	if type(report) ~= "table" then
		return "", {}, 0
	end
	local provider = string.lower(tostring(report.provider or ""))
	local windows: { any } = {}
	local seen: { [string]: any } = {}
	for _, limit in type(report.limits) == "table" and report.limits or {} do
		if type(limit) ~= "table" then
			continue
		end
		local key, label, ms = M.window_of(limit)
		if key == nil then
			continue
		end
		local amount = limit.amount
		local left: number? = nil
		if type(amount) == "table" then
			if type(amount.remainingFraction) == "number" then
				left = amount.remainingFraction
			elseif type(amount.usedFraction) == "number" then
				left = 1 - amount.usedFraction
			end
		end
		if left == nil then
			continue
		end
		-- kimi reports `limit_7d` alongside the real 7d window with near-identical figures (their API
		-- rounds differently): drop a `limit_*` window when a real one matches its reset time closely
		-- and its share within a point.
		local duplicate = false
		if string.match(key, "^limit_") then
			for _, other in seen do
				local other_reset = other.reset_at or 0
				local this_reset = if type(limit.window) == "table" and type(limit.window.resetsAt) == "number" then limit.window.resetsAt else 0
				if math.abs(other_reset - this_reset) < 120000 and math.abs(other.left - left) < 0.05 then
					duplicate = true
					break
				end
			end
		end
		if duplicate then
			continue
		end
		local scope = limit.scope
		local window = {
			key = key,
			label = label,
			ms = ms,
			left = left,
			reset_at = if type(limit.window) == "table" and type(limit.window.resetsAt) == "number" then limit.window.resetsAt else nil,
			scope_shared = if type(scope) == "table" then scope.shared == true else false,
			scope_model = if type(scope) == "table" then string.lower(tostring(scope.modelId or "")) else "",
			scope_tier = if type(scope) == "table" then string.lower(tostring(scope.tier or "")) else "",
			limit_id = tostring(limit.id or ""),
			saved = 0,
			expires_at = nil,
		}
		if key == "7d" then
			local count, soonest = M.credits_for(report, window.limit_id, 5 * DAY, now)
			window.saved = count
			window.expires_at = soonest
		end
		if seen[key] == nil then
			table.insert(windows, window)
			seen[key] = window
		end
	end
	table.sort(windows, function(a: any, b: any)
		if a.ms == b.ms then
			return a.key < b.key
		end
		return a.ms < b.ms
	end)
	local credits = 0
	local rc = report.resetCredits
	if type(rc) == "table" then
		if type(rc.availableCount) == "number" then
			credits = rc.availableCount
		elseif type(rc.credits) == "table" then
			for _, credit in rc.credits do
				if type(credit) == "table" and credit.status == "available" and credit.usable ~= false then
					credits += if type(credit.remainingCount) == "number" then credit.remainingCount else 1
				end
			end
		end
	end
	return provider, windows, credits
end

-- `omp usage --json` → { reports = { {provider, label, windows, credits} }, capacity = { [provider] = windows } }.
-- nil when the document has no reports array (a failed or reshaped answer).
function M.usage(doc: any, now: number): any
	if type(doc) ~= "table" or type(doc.reports) ~= "table" then
		return nil
	end
	local reports: { any } = {}
	for _, report in doc.reports do
		local provider, windows, credits = M.report(report, now)
		if provider ~= "" and #windows > 0 then
			table.insert(reports, { provider = provider, label = M.provider_label(provider), windows = windows, credits = credits })
		end
	end
	local capacity: { [string]: any } = {}
	for provider, entries in type(doc.capacity) == "table" and doc.capacity or {} do
		if type(entries) ~= "table" then
			continue
		end
		local id = string.lower(tostring(provider))
		local windows: { any } = {}
		local seen_c: { [string]: boolean } = {}
		for _, entry in entries do
			if type(entry) ~= "table" then
				continue
			end
			local accounts = entry.accounts
			local used = entry.usedAccounts
			if type(accounts) ~= "number" or accounts <= 0 or type(used) ~= "number" then
				continue
			end
			-- omp's capacity windows are ids for some providers ("5h", "7d") and labels for others
			-- ("7 Day"), and mirror the report's odd windows too ("limit_7d"): accept only known ones.
			local raw = string.lower(string.gsub(tostring(entry.window or ""), "%s+", " "))
			local key, label, ms = nil, nil, nil
			if raw == "5h" then
				key, label, ms = "5h", "5h", 5 * HOUR
			elseif raw == "daily" or raw == "24h" or raw == "1d" then
				key, label, ms = "1d", "1d", DAY
			elseif raw == "7d" or raw == "7 day" or raw == "weekly" then
				key, label, ms = "7d", "7d", 7 * DAY
			elseif raw == "monthly" or raw == "30d" then
				key, label, ms = "mo", "mo", 30 * DAY
			elseif type(entry.durationMs) == "number" and entry.durationMs > 0 then
				ms = entry.durationMs
				local mins = math.round(ms / 60000)
				label = if mins % 1440 == 0
					then tostring(mins / 1440) .. "d"
					elseif mins % 60 == 0 then tostring(mins / 60) .. "h"
					else tostring(mins) .. "m"
				key = label
			end
			if key == nil or seen_c[key] then
				continue
			end
			seen_c[key] = true
			table.insert(windows, {
				key = key, label = label, ms = ms, left = 1 - used / accounts, reset_at = nil,
				scope_shared = true, scope_model = "", scope_tier = "", limit_id = "",
				saved = 0, expires_at = nil, accounts = accounts,
			})
		end
		if #windows > 0 then
			table.sort(windows, function(a: any, b: any)
				return a.ms < b.ms
			end)
			capacity[id] = windows
		end
	end
	return { reports = reports, capacity = capacity }
end

-- `omp models --json` (an object with a `models` list) → lookup tables from the chip name to a model:
-- byName (the chip shows the name), bySelector, and per provider the bare ids (for scope filtering).
-- nil when the answer carries no model list.
function M.catalog(doc: any): any
	local list = nil
	if type(doc) == "table" then
		if type(doc.models) == "table" then
			list = doc.models
		elseif doc[1] ~= nil then
			list = doc
		end
	end
	if list == nil then
		return nil
	end
	local by_name: { [string]: any } = {}
	local by_selector: { [string]: any } = {}
	local by_provider: { [string]: { string } } = {}
	for _, model in list do
		if type(model) ~= "table" then
			continue
		end
		local provider = string.lower(tostring(model.provider or ""))
		local id = string.lower(tostring(model.id or ""))
		local name = tostring(model.name or "")
		local selector = string.lower(tostring(model.selector or ""))
		if provider == "" or (id == "" and name == "") then
			continue
		end
		local entry = { provider = provider, id = id, name = name }
		if name ~= "" and by_name[name] == nil then
			by_name[name] = entry
		end
		if selector ~= "" then
			by_selector[selector] = entry
		end
		if id ~= "" then
			local list = by_provider[provider] or {}
			table.insert(list, id)
			by_provider[provider] = list
		end
	end
	return { by_name = by_name, by_selector = by_selector, by_provider = by_provider }
end

-- `omp stats --json` → tokens and cost since `day_start_ms` (local midnight), all providers.
function M.today(doc: any, day_start_ms: number): (number, number)
	if type(doc) ~= "table" or type(doc.timeSeries) ~= "table" then
		return 0, 0
	end
	local tokens, cost = 0, 0
	for _, bucket in doc.timeSeries do
		if type(bucket) ~= "table" then
			continue
		end
		if type(bucket.timestamp) == "number" and bucket.timestamp >= day_start_ms then
			tokens += if type(bucket.tokens) == "number" then bucket.tokens else 0
			cost += if type(bucket.cost) == "number" then bucket.cost else 0
		end
	end
	return tokens, cost
end

-- `omp stats --json` → per-provider totals over the whole stats window:
-- { ["kimi-code"] = { tokens, cost } }. Tokens count cache reads and writes, the
-- same semantics as the timeSeries totals.
function M.by_model_totals(doc: any): { [string]: any }
	local out: { [string]: any } = {}
	local entries = if type(doc) == "table" and type(doc.byModel) == "table" then doc.byModel else {}
	for _, entry in entries do
		if type(entry) ~= "table" or type(entry.provider) ~= "string" or entry.provider == "" then
			continue
		end
		local p = string.lower(entry.provider)
		local slot = out[p] or { tokens = 0, cost = 0 }
		out[p] = slot
		if type(entry.totalInputTokens) == "number" then
			slot.tokens += entry.totalInputTokens
		end
		if type(entry.totalOutputTokens) == "number" then
			slot.tokens += entry.totalOutputTokens
		end
		if type(entry.totalCacheReadTokens) == "number" then
			slot.tokens += entry.totalCacheReadTokens
		end
		if type(entry.totalCacheWriteTokens) == "number" then
			slot.tokens += entry.totalCacheWriteTokens
		end
		if type(entry.totalCost) == "number" then
			slot.cost += entry.totalCost
		end
	end
	return out
end

-- `omp usage --history --json` entries → per limit id, { { hourStartSec, usedFraction } } oldest first.
function M.history(entries: any): { [string]: { { number } } }
	local sums: { [string]: { [number]: { number } } } = {}
	for _, entry in type(entries) == "table" and entries or {} do
		if type(entry) ~= "table" then
			continue
		end
		local fraction, at = entry.usedFraction, entry.recordedAt
		if type(entry.limitId) == "string" and type(fraction) == "number" and type(at) == "number" then
			local hour = at // 3600000
			local by_hour = sums[entry.limitId] or {}
			sums[entry.limitId] = by_hour
			local slot = by_hour[hour] or { 0, 0 }
			by_hour[hour] = slot
			slot[1] += fraction
			slot[2] += 1
		end
	end
	local out: { [string]: { { number } } } = {}
	for id, by_hour in sums do
		local hours: { number } = {}
		for h in by_hour do
			table.insert(hours, h)
		end
		table.sort(hours)
		local points: { { number } } = {}
		for _, h in hours do
			table.insert(points, { h * 3600, by_hour[h][1] / by_hour[h][2] })
		end
		out[id] = points
	end
	return out
end

-- A history limit's display label: provider label plus a window word for known suffixes.
function M.history_label(limit_id: string): string
	local provider, suffix = string.match(limit_id, "^([^:]+):(.+)$")
	if provider == nil then
		return limit_id
	end
	local window = ({ ["5h"] = "5h", primary = "5h", ["7d"] = "7d", secondary = "7d", weekly = "7d", monthly = "mo" })[suffix] or suffix
	return M.provider_label(provider) .. " " .. window
end

return M
