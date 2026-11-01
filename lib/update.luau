-- Update check: a daily look at the GitHub Releases API, a ⬆ status segment when a newer
-- release exists, and a one-click reinstall (tern plugin install --force, after which the
-- daemon and windows hot-reload the new code). Pattern after joaodutra88/tern-omp-usage.
local M = {}

M.VERSION = "1.2.1"
local REPO_INSTALL = "github.com/DoraJasmine/dora-tern-omp-usage"
local API = "https://api.github.com/repos/DoraJasmine/dora-tern-omp-usage/releases/latest"

local latest: any = nil -- {version, url} when the API reports a newer release

local function parts(v: string): { number }
	local out: { number } = {}
	for n in string.gmatch(v, "%d+") do
		table.insert(out, tonumber(n) :: number)
	end
	return out
end

function M.newer(a: string, b: string): boolean
	local x, y = parts(a), parts(b)
	for i = 1, math.max(#x, #y) do
		local p, q = x[i] or 0, y[i] or 0
		if p ~= q then
			return p > q
		end
	end
	return false
end

-- check(callback): queries the latest release once; callback(new_version_or_nil, cx)
-- fires when the answer arrives (new_version set only when it is newer than M.VERSION).
function M.check(callback: (string?, any?) -> ())
	local ok = pcall(function()
		tern.fetch(API, nil, function(res: any, cx: any)
			local newver: string? = nil
			if res ~= nil and res.status == 200 and type(res.body) == "string" then
				local ok2, doc = pcall(tern.json.decode, res.body :: string)
				if ok2 and type(doc) == "table" then
					local tag = tostring(doc.tag_name or "")
					tag = string.match(tag, "^v?(.+)$") or tag
					local url = tostring(doc.html_url or "")
					if tag ~= "" and M.newer(tag, M.VERSION) then
						latest = { version = tag, url = url }
						newver = tag
					end
				end
			end
			callback(newver, cx)
		end)
	end)
	if not ok then
		callback(nil, nil)
	end
end

function M.get_latest(): any
	return latest
end

-- install(callback): one-click reinstall from GitHub; the CLI reloads the plugin
-- on both the daemon and the windows, so the new code takes over immediately.
function M.install(callback: (boolean, string) -> ())
	local ok = pcall(function()
		tern.process.run({ "tern", "plugin", "install", REPO_INSTALL, "--force" }, { timeout_ms = 120000 }, function(res: any)
			local done = res ~= nil and res.status == 0
			callback(done, if done then "" else string.sub(tostring(res and res.stderr or "install failed"), 1, 200))
		end)
	end)
	if not ok then
		callback(false, "spawn failed")
	end
end

return M
