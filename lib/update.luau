-- Update check: a daily look at the releases atom feed (no GitHub API quota), a ⬆ status
-- segment when a newer release exists, and a one-click reinstall (tern plugin install
-- --force, after which the daemon and windows hot-reload the new code). Pattern after
-- joaodutra88/tern-omp-usage.
local M = {}

M.VERSION = "1.2.1"
local REPO_INSTALL = "github.com/DoraJasmine/dora-tern-omp-usage"
local FEED = "https://github.com/DoraJasmine/dora-tern-omp-usage/releases.atom"

local latest: any = nil -- {version, url} when the feed reports a newer release

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

-- check(callback): queries the releases feed once; callback(new_version_or_nil, cx)
-- fires when the answer arrives (new_version set only when it is newer than M.VERSION).
function M.check(callback: (string?, any?) -> ())
	local ok = pcall(function()
		tern.fetch(FEED, nil, function(res: any, cx: any)
			local newver: string? = nil
			if res ~= nil and res.status == 200 and type(res.body) == "string" then
				-- The atom feed lists entries newest-first: the first releases/tag/vX.Y.Z
				-- link carries the latest version. No GitHub API quota involved.
				local ver = string.match(res.body :: string, "releases/tag/v([%d%.]+)")
				if ver and M.newer(ver, M.VERSION) then
					latest = { version = ver, url = "https://github.com/DoraJasmine/dora-tern-omp-usage/releases/tag/v" .. ver }
					newver = ver
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
