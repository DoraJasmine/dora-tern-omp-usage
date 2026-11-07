-- Run with the standalone Luau CLI: luau tests/identity.luau
local parse = require("../lib/parse")
local identity = require("../lib/identity")

local RAW = '{"version":1,"sessionId":"session-a","scope":"main","provider":"codex","id":"shared"}'
local MAIN = { version = 1, sessionId = "session-a", scope = "main", provider = "codex", id = "shared" }
local OTHER = { version = 1, sessionId = "session-b", scope = "main", provider = "proxy", id = "shared" }

-- Decode is an injected boundary: assert the actual joined payload, then provide the decoded value.
local function decode(raw)
	assert(raw == RAW, "identity spans must be joined without separators or trimming")
	return MAIN
end

local function text(id, role, value)
	return { id = id, p = { role = role, spans = { { t = value } } } }
end

local function chip(name)
	return { id = "composer/model", p = { role = "omp.composer.model" }, c = {
		text("composer/model/name", nil, name),
	} }
end

local function bridge()
	return text("identity", "dora.omp.model-identity", RAW)
end

local function tree(name, with_bridge, viewing)
	local nodes = {}
	if name ~= nil then table.insert(nodes, chip(name)) end
	if with_bridge then table.insert(nodes, bridge()) end
	if viewing then table.insert(nodes, text("focus", "omp.composer.focus", "Child")) end
	return { dock = { id = "dock", c = nodes } }
end

local function dock(name, with_bridge, viewing)
	return identity.read_dock(tree(name, with_bridge, viewing), decode)
end

local function expect(result, status, reason, provider, id)
	assert(result.status == status, "status: " .. tostring(result.status) .. ", expected " .. status)
	assert(result.reason == reason, "reason: " .. tostring(result.reason) .. ", expected " .. reason)
	assert(result.provider == provider, "provider mismatch")
	assert(result.id == id, "id mismatch")
	if status == "resolved" then
		assert(result.selector == provider .. "/" .. id, "canonical selector mismatch")
	end
	return result
end

local catalog = parse.catalog({ models = {
	{ provider = "proxy", id = "shared", name = "Shared", selector = "wrong/selector" },
	{ provider = "codex", id = "shared", name = "Shared" },
	{ provider = "codex", id = "shared", name = "Repeated selector must not be indexed" },
	{ provider = "codex", id = "second", name = "Same provider" },
	{ provider = "codex", id = "third", name = "Same provider" },
	{ provider = "anthropic", id = "opus", name = "Claude Opus" },
	{ provider = "other", id = "opus", name = "Opus" },
	{ provider = "child", id = "child-model", name = "Unique child" },
	{ provider = "CaseProvider", id = "CaseID", name = "" },
	{ provider = "fallback", id = "Claude Fallback" },
	{ provider = "invalid", name = "No id" },
	{ provider = 42, id = "invalid-provider" },
} })
assert(catalog.version == 2)
assert(#catalog.by_name.Shared == 2, "same bare id on two providers must remain distinct")
assert(#catalog.by_name["Same provider"] == 2, "same provider is not sufficient identity")
assert(catalog.by_name["Repeated selector must not be indexed"] == nil)
assert(catalog.by_selector["wrong/selector"] == nil)
assert(catalog.by_selector["proxy/shared"].selector == "proxy/shared")
assert(#catalog.by_provider.codex == 3, "duplicate selectors must not duplicate bare ids")
assert(catalog.by_provider.proxy[1] == "shared" and catalog.by_provider.codex[1] == "shared")
assert(catalog.by_name.Opus[1].name == "Claude Opus" and #catalog.by_name.Opus == 2)
assert(catalog.by_name.CaseID[1].selector == "CaseProvider/CaseID", "ids are case-sensitive")
assert(catalog.by_name.Fallback[1].id == "Claude Fallback", "name || id and prefix normalization")
assert(catalog.by_name["No id"] == nil)
assert(parse.catalog({}) == nil)
assert(parse.catalog({ by_name = { Shared = {} } }) == nil, "cached indexes are not CLI model lists")
assert(parse.catalog({ models = {} }).version == 2)
assert(parse.catalog({ { provider = "p", id = "m", name = "Model" } }).by_selector["p/m"] ~= nil)

expect(identity.resolve(dock("Shared", false), catalog), "ambiguous", "catalog_ambiguous")
expect(identity.resolve(dock("Same provider", false), catalog), "ambiguous", "catalog_ambiguous")
expect(identity.resolve(dock("Opus", false), catalog), "ambiguous", "catalog_ambiguous")
expect(identity.resolve(dock("CaseID", false), catalog), "resolved", "catalog_unique", "CaseProvider", "CaseID")
expect(identity.resolve(dock("Fallback", false), catalog), "resolved", "catalog_unique", "fallback", "Claude Fallback")
for _, name in { "shared", "SHARED", "sha", "codex/shared", "GPT-6.1", "Claude Opus", " Shared " } do
	expect(identity.resolve(dock(name, false), catalog), "unavailable", "catalog_no_match")
end
expect(identity.resolve(dock("Unique child", false), nil), "unavailable", "catalog_missing")
expect(identity.resolve(dock("Unique child", false), { by_name = { ["Unique child"] = { provider = "child", id = "child-model" } } }),
	"unavailable", "catalog_unsupported")
expect(identity.resolve(dock("Unique child", false), { version = 2, by_name = {} }), "unavailable", "catalog_invalid")
expect(identity.resolve(dock(nil, false), catalog), "unavailable", "chip_missing")
expect(identity.resolve(nil, catalog), "unavailable", "chip_missing")

local resolved = expect(identity.resolve(dock("Shared", true), catalog), "resolved", "identity", "codex", "shared")
assert(resolved.source == "identity" and resolved.sessionId == "session-a")
expect(identity.resolve(dock("Shared", true), nil), "resolved", "identity", "codex", "shared")
expect(identity.resolve(dock(nil, true), nil), "resolved", "identity", "codex", "shared")
expect(identity.resolve(dock("Shared", true), { by_name = {} }), "resolved", "identity", "codex", "shared")
expect(identity.resolve(dock("Unique child", true), catalog), "unavailable", "bridge_chip_mismatch")
local custom = { version = 1, sessionId = "custom-session", scope = "main", provider = "custom", id = "uncached" }
local custom_dock = identity.read_dock(tree("Custom", true), function() return custom end)
expect(identity.resolve(custom_dock, catalog), "resolved", "identity", "custom", "uncached")

-- The main identity must not select a child, even when it could resolve the main chip's ambiguity.
local child = expect(identity.resolve(dock("Unique child", true, true), catalog), "resolved", "catalog_unique", "child", "child-model")
assert(child.source == "catalog" and child.sessionId == nil)
expect(identity.resolve(dock("Shared", true, true), catalog), "ambiguous", "catalog_ambiguous")
expect(identity.resolve(dock("Unique child", true, true), nil), "unavailable", "catalog_missing")
expect(identity.resolve(dock("Unknown child", true, true), catalog), "unavailable", "catalog_no_match")

-- No module-level cache: provider/id, session and unavailable transitions are read afresh.
local switched = identity.read_dock(tree("Shared", true), function() return OTHER end)
local next_result = expect(identity.resolve(switched, catalog), "resolved", "identity", "proxy", "shared")
assert(next_result.sessionId == "session-b")
for _, id in { "second", "third" } do
	local same_provider = identity.read_dock(tree("Same provider", true), function()
		return { version = 1, scope = "main", sessionId = "session-a", provider = "codex", id = id }
	end)
	expect(identity.resolve(same_provider, catalog), "resolved", "identity", "codex", id)
end
expect(identity.resolve(dock("Shared", false), catalog), "ambiguous", "catalog_ambiguous")
expect(identity.resolve(identity.read_dock(nil, decode), catalog), "unavailable", "chip_missing")
local no_model = identity.read_dock(tree("Shared", true), function() return nil end)
assert(no_model.identity == nil)
expect(identity.resolve(no_model, catalog), "unavailable", "bridge_invalid")

local split = tree("Unique child", true)
split.dock.c[1].c[1].p.spans = { { t = "Unique " }, { t = "child" } }
split.dock.c[2].p.spans = { { t = string.sub(RAW, 1, 40) }, { t = string.sub(RAW, 41) } }
local split_dock = identity.read_dock(split, decode)
assert(split_dock.chip == "Unique child" and split_dock.identity == MAIN)
local separate = { main = bridge(), dock = { c = { chip("Shared") } } }
expect(identity.resolve(identity.read_dock(separate, decode), catalog), "resolved", "identity", "codex", "shared")
assert(identity.read_dock({ main = text("not-model/name", nil, "Shared") }, decode).chip == nil)

for _, bad in { false, 17, "string", {}, { version = 1, scope = "main" },
	{ version = 1, scope = "main", sessionId = "s" },
	{ version = "1", scope = "main", sessionId = "s", provider = "p", id = "i" },
	{ version = 1, scope = "main", sessionId = "", provider = "p", id = "i" },
	{ version = 1, scope = "main", sessionId = "s", provider = {}, id = "i" },
	{ version = 1, scope = "main", sessionId = "s", provider = "p", id = "" },
	{ version = 1, scope = false, sessionId = "s", provider = "p", id = "i" },
} do
	local invalid = identity.read_dock(tree("Unique child", true), function() return bad end)
	assert(invalid.bridge_status == "invalid" and invalid.identity == nil)
	expect(identity.resolve(invalid, catalog), "unavailable", "bridge_invalid")
	invalid.viewing = true
	expect(identity.resolve(invalid, catalog), "unavailable", "bridge_invalid")
end
for _, unsupported in {
	{ version = 2, scope = "main", sessionId = "s", provider = "p", id = "i" },
	{ version = 1, scope = "child", sessionId = "s", provider = "p", id = "i" },
} do
	local invalid = identity.read_dock(tree("Unique child", true), function() return unsupported end)
	assert(invalid.bridge_status == "unsupported" and invalid.identity == nil)
	expect(identity.resolve(invalid, catalog), "unavailable", "bridge_unsupported")
end
local broken_json = identity.read_dock(tree("Unique child", true), function() error("invalid JSON") end)
expect(identity.resolve(broken_json, catalog), "unavailable", "bridge_invalid")
for _, spans in { {}, { { t = false } }, { { t = RAW }, { t = {} } } } do
	local malformed = tree("Unique child", true)
	malformed.dock.c[2].p.spans = spans
	expect(identity.resolve(identity.read_dock(malformed, decode), catalog), "unavailable", "bridge_invalid")
end

-- Any clipping can conceal a duplicate bridge or child-focus marker, not only clipping at the bridge.
for _, with_bridge in { false, true } do
	local clipped_tree = tree("Unique child", with_bridge)
	clipped_tree.more = 1
	expect(identity.resolve(identity.read_dock(clipped_tree, decode), catalog), "unavailable", "bridge_invalid")
	clipped_tree.more = nil
	table.insert(clipped_tree.dock.c, { id = "unrelated", more = 1 })
	expect(identity.resolve(identity.read_dock(clipped_tree, decode), catalog), "unavailable", "bridge_invalid")
end
local complete = tree("Shared", true)
complete.more, complete.dock.more = 0, 0
expect(identity.resolve(identity.read_dock(complete, decode), catalog), "resolved", "identity", "codex", "shared")
local duplicate = tree("Unique child", true)
table.insert(duplicate.dock.c, bridge())
expect(identity.resolve(identity.read_dock(duplicate, decode), catalog), "unavailable", "bridge_invalid")
local duplicate_name = tree("Unique child", true)
table.insert(duplicate_name.dock.c, chip("Shared"))
local duplicate_dock = identity.read_dock(duplicate_name, decode)
assert(duplicate_dock.chip == nil)
expect(identity.resolve(duplicate_dock, catalog), "unavailable", "bridge_invalid")

-- Defensively reject malformed v2 entries rather than interpreting a first-hit legacy index as a list.
local malformed_catalog = { version = 2, by_provider = {}, by_selector = {}, by_name = {
	["Unique child"] = { provider = "child", id = "child-model" },
} }
expect(identity.resolve(dock("Unique child", false), malformed_catalog), "unavailable", "catalog_invalid")
malformed_catalog.by_name["Unique child"] = { { provider = "child", id = "child-model", name = "Unique child", selector = "wrong" } }
expect(identity.resolve(dock("Unique child", false), malformed_catalog), "unavailable", "catalog_invalid")
malformed_catalog.by_selector["codex/shared"] = { provider = "proxy", id = "shared", name = "Shared", selector = "proxy/shared" }
expect(identity.resolve(dock("Shared", true), malformed_catalog), "unavailable", "catalog_invalid")

print("identity regressions passed")
