-- Plugin UI strings, en base with zh-CN. `M.get(language)` returns a table whose
-- missing keys fall back to en.
local M = {}

local en = {
	-- status bar
	tokens = "tokens",
	usage = "usage",
	-- card
	left = "left",
	resets_in = "resets in %s",
	resets_soon = "resets soon",
	saved_reset = "+%d saved reset",
	saved_reset_plural = "+%d saved resets",
	expires_in = "expires in %s",
	settings_hint = "settings · Ctrl+Alt+U",
	today_line = "today on %s  %s tokens · $%.0f",
	today_unavailable = "today on %s · data unavailable",
	window_word = "%s window",
	-- menu
	menu_title = "Dora omp Usage",
	menu_panel = "Settings…",
	menu_mode_current = "Show: current model's provider",
	menu_mode_all = "Show: all providers",
	menu_mode_selected = "Show: selected providers…",
	menu_choose = "Choose providers…",
	menu_reorder = "Reorder providers…",
	menu_colors = "Provider colors…",
	menu_refresh = "Refresh now",
	menu_dashboard = "Open dashboard",
	menu_language = "Language: 简体中文",
	menu_language_en = "Language: English",
	menu_reset = "Reset settings",
	chooser_title = "Providers shown when Show is \"selected\" (pick to toggle)",
	reorder_title = "Reorder providers (pick one, then move it)",
	move_up = "Move up",
	move_down = "Move down",
	move_top = "Move to top",
	move_bottom = "Move to bottom",
	colors_title = "Colors",
	color_custom = "Custom…",
	color_reset = "Reset",
	prompt_custom = "Custom colors, one or two hex values like #d97757 or #9aa7b4, #5b8def",
	prompt_warn = "Amber threshold, percent left (e.g. 25)",
	prompt_bad = "Red threshold, percent left (e.g. 10)",
	prompt_interval = "Usage refresh interval in seconds (60–600)",
	-- toasts
	toast_refresh_ok = "Refreshing usage…",
	toast_saved = "Saved",
	toast_reset = "Dora omp Usage settings reset",
	toast_bad_number = "Not a number: %s",
	toast_interval_bad = "The interval is a whole number of seconds from 60 to 600",
	toast_threshold_bad = "The threshold is a percentage from 1 to 49",
	toast_stale = "Usage data is %s old — omp may be signed out or the CLI missing",
	-- dashboard
	dash_title = "Dora omp Usage",
	dash_loading = "Reading omp usage history…",
	dash_failed = "omp usage --history failed — is omp installed and signed in?",
	dash_no_history = "No usage history recorded yet.",
	dash_cost = "API-price cost (all providers)",
	dash_cost_empty = "Nothing spent since this plugin started recording.",
	dash_today = "Today",
	dash_week = "Last 7 days",
	dash_month = "This month",
	dash_updated = "updated %s · r refresh",
}

local zh = {
	tokens = "tokens",
	usage = "用量",
	left = "剩余",
	resets_in = "%s 后重置",
	resets_soon = "即将重置",
	saved_reset = "+%d 次已存重置",
	saved_reset_plural = "+%d 次已存重置",
	expires_in = "%s 后过期",
	settings_hint = "设置 · Ctrl+Alt+U",
	today_line = "%s 今日 %s tokens · $%.0f",
	today_unavailable = "%s 今日 · 数据不可用",
	window_word = "%s 窗口",
	menu_title = "Dora omp Usage",
	menu_panel = "设置…",
	menu_mode_current = "显示:当前模型的提供商",
	menu_mode_all = "显示:全部提供商",
	menu_mode_selected = "显示:勾选的提供商…",
	menu_choose = "选择提供商…",
	menu_reorder = "提供商排序…",
	menu_colors = "提供商配色…",
	menu_refresh = "立即刷新",
	menu_dashboard = "打开仪表盘",
	menu_language = "Language: English",
	menu_language_en = "语言:简体中文",
	menu_reset = "重置设置",
	chooser_title = "“显示勾选的提供商”模式下的列表(点选切换)",
	reorder_title = "提供商排序(先选一个,再移动)",
	move_up = "上移",
	move_down = "下移",
	move_top = "移到最前",
	move_bottom = "移到最后",
	colors_title = "配色",
	color_custom = "自定义…",
	color_reset = "重置",
	prompt_custom = "自定义颜色,一到两个 hex,如 #d97757 或 #9aa7b4, #5b8def",
	prompt_warn = "琥珀色阈值,剩余百分比(如 25)",
	prompt_bad = "红色阈值,剩余百分比(如 10)",
	prompt_interval = "用量刷新间隔,秒(60–600)",
	toast_refresh_ok = "正在刷新用量…",
	toast_saved = "已保存",
	toast_reset = "Dora omp Usage 设置已重置",
	toast_bad_number = "不是数字:%s",
	toast_interval_bad = "间隔应为 60 到 600 的整数秒",
	toast_threshold_bad = "阈值应为 1 到 49 的百分比",
	toast_stale = "用量数据已 %s 未更新 —— omp 可能未登录或 CLI 缺失",
	dash_title = "Dora omp Usage",
	dash_loading = "正在读取 omp 用量历史…",
	dash_failed = "omp usage --history 失败 —— omp 是否已安装并登录?",
	dash_no_history = "还没有用量历史记录。",
	dash_cost = "API 价格费用(全部提供商)",
	dash_cost_empty = "自本插件开始记录以来还没有消费。",
	dash_today = "今日",
	dash_week = "近 7 天",
	dash_month = "本月",
	dash_updated = "更新于 %s · r 刷新",
}

setmetatable(zh, { __index = en })

local TABLES = { en = en, ["zh-CN"] = zh }

function M.get(language: string?): typeof(en)
	local t = TABLES[language or ""] or en
	return t
end

M.LANGUAGES = { "en", "zh-CN" }

return M
