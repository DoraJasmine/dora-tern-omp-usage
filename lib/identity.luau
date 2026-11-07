-- Pure surface-tree identity extraction and exact catalog resolution. No runtime or quota evidence.
local M = {}

local MODEL_ROLE = "omp.composer.model"
local FOCUS_ROLE = "omp.composer.focus"
local IDENTITY_ROLE = "dora.omp.model-identity"
local NAME_SUFFIX = "/name"

local function nonempty(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function identity_status(value: any): string
	if type(value) ~= "table" or type(value.version) ~= "number" or type(value.scope) ~= "string" then
		return "invalid"
	end
	if value.version ~= 1 or value.scope ~= "main" then
		return "unsupported"
	end
	if not nonempty(value.sessionId) or not nonempty(value.provider) or not nonempty(value.id) then
		return "invalid"
	end
	return "ready"
end

-- Only matching text nodes allocate a join buffer, and the common single-span case needs none.
local function text_of(props: any): string?
	local spans = if type(props) == "table" then props.spans else nil
	if type(spans) ~= "table" or #spans == 0 then
		return nil
	end
	if #spans == 1 then
		local span = spans[1]
		return if type(span) == "table" and type(span.t) == "string" then span.t else nil
	end
	local parts = {}
	for _, span in ipairs(spans) do
		if type(span) ~= "table" or type(span.t) ~= "string" then
			return nil
		end
		table.insert(parts, span.t)
	end
	return table.concat(parts)
end

local function clipped(value: any): boolean
	return value ~= nil and value ~= 0
end

function M.read_dock(tree: any, decode: (string) -> any): any
	local result: any = { viewing = false, bridge_status = "missing" }
	if type(tree) ~= "table" then
		return result
	end
	local truncated = clipped(tree.more)
	local identity_count, name_count = 0, 0
	local raw: string? = nil
	local function walk(node: any, in_model: boolean)
		if type(node) ~= "table" then
			return
		end
		if clipped(node.more) then
			truncated = true
		end
		local props = node.p
		local role = if type(props) == "table" then props.role else nil
		local model = in_model or role == MODEL_ROLE
		if role == FOCUS_ROLE then
			result.viewing = true
		elseif role == IDENTITY_ROLE then
			identity_count += 1
			if identity_count == 1 then
				raw = text_of(props)
			end
		end
		if model and type(node.id) == "string" and string.sub(node.id, -#NAME_SUFFIX) == NAME_SUFFIX then
			name_count += 1
			if name_count == 1 then
				local name = text_of(props)
				result.chip = if name ~= "" then name else nil
			end
		end
		if type(node.c) == "table" then
			for _, child in ipairs(node.c) do
				walk(child, model)
			end
		end
	end
	walk(tree.main, false)
	walk(tree.dock, false)
	if name_count > 1 then
		result.chip = nil
	end
	-- Omitted nodes might conceal a second identity or a subagent focus marker. Never trust a prefix.
	if truncated or identity_count > 1 or name_count > 1 then
		result.bridge_status = "invalid"
	elseif identity_count == 1 then
		if raw == nil then
			result.bridge_status = "invalid"
		else
			local ok, identity = pcall(decode, raw)
			result.bridge_status = if ok then identity_status(identity) else "invalid"
			if result.bridge_status == "ready" then
				result.identity = identity
			end
		end
	end
	return result
end

local function catalog_ready(catalog: any): boolean
	return type(catalog) == "table" and catalog.version == 2
		and type(catalog.by_name) == "table" and type(catalog.by_selector) == "table"
		and type(catalog.by_provider) == "table"
end

local function entry_valid(entry: any): boolean
	return type(entry) == "table" and nonempty(entry.provider) and nonempty(entry.id)
		and type(entry.name) == "string" and entry.selector == entry.provider .. "/" .. entry.id
end

local function displayed_name(entry: any): string
	local name = if entry.name ~= "" then entry.name else entry.id
	return (string.gsub(name, "^Claude ", "", 1))
end

local function unavailable(reason: string): any
	return { status = "unavailable", reason = reason }
end

function M.resolve(dock: any, catalog: any): any
	if type(dock) ~= "table" then
		return unavailable("chip_missing")
	end
	local bridge = dock.bridge_status
	if bridge == "invalid" then
		return unavailable("bridge_invalid")
	elseif bridge == "unsupported" then
		return unavailable("bridge_unsupported")
	elseif bridge ~= "missing" and bridge ~= "ready" then
		return unavailable("bridge_invalid")
	end
	if bridge == "ready" then
		local identity = dock.identity
		local validity = identity_status(identity)
		if validity ~= "ready" then
			return unavailable(if validity == "unsupported" then "bridge_unsupported" else "bridge_invalid")
		end
		if dock.viewing ~= true then
			local selector = identity.provider .. "/" .. identity.id
			if catalog_ready(catalog) and nonempty(dock.chip) then
				local selected = catalog.by_selector[selector]
				if selected ~= nil then
					if not entry_valid(selected) or selected.selector ~= selector then
						return unavailable("catalog_invalid")
					end
					if displayed_name(selected) ~= dock.chip then
						return unavailable("bridge_chip_mismatch")
					end
				end
			end
			return { status = "resolved", reason = "identity", source = "identity", provider = identity.provider,
				id = identity.id, selector = selector, sessionId = identity.sessionId }
		end
	end
	-- A main-session bridge is irrelevant while viewing a child. Only its exact chip can resolve it.
	if not nonempty(dock.chip) then
		return unavailable("chip_missing")
	end
	if catalog == nil then
		return unavailable("catalog_missing")
	elseif type(catalog) ~= "table" or catalog.version ~= 2 then
		return unavailable("catalog_unsupported")
	elseif not catalog_ready(catalog) then
		return unavailable("catalog_invalid")
	end
	local candidates = catalog.by_name[dock.chip]
	if candidates == nil then
		return unavailable("catalog_no_match")
	elseif type(candidates) ~= "table" then
		return unavailable("catalog_invalid")
	end
	if candidates[1] == nil and next(candidates) ~= nil then
		return unavailable("catalog_invalid")
	end
	local selected: any = nil
	local candidates_out: { any } = {}
	local seen_candidates: { [string]: boolean } = {}
	for _, candidate in ipairs(candidates) do
		if not entry_valid(candidate) or displayed_name(candidate) ~= dock.chip then
			return unavailable("catalog_invalid")
		end
		if not seen_candidates[candidate.selector] then
			seen_candidates[candidate.selector] = true
			table.insert(candidates_out, candidate)
		end
		selected = selected or candidate
	end
	if selected == nil then
		return unavailable("catalog_no_match")
	end
	if #candidates_out > 1 then
		return { status = "ambiguous", reason = "catalog_ambiguous", source = "catalog", candidates = candidates_out }
	end
	return { status = "resolved", reason = "catalog_unique", source = "catalog", provider = selected.provider,
		id = selected.id, selector = selected.selector }
end

return M
