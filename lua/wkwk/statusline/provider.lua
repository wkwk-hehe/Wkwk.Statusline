--- Factories and formatters used by the default statusline components.
local api = vim.api
local lsp = vim.lsp
local diagnostics = vim.diagnostic
local modify_filename = vim.fn.fnamemodify

local M = {}

--- Escape percent signs so user-provided text is literal in statusline syntax.
---@param text any Value to display.
---@return string Statusline-safe text.
local function escape_statusline_text(text)
	return (tostring(text):gsub("%%", "%%%%"))
end

local mode_names = {
	--Normal
	["n"] = "Normal",
	["no"] = "O-Pending",
	["nov"] = "O-Pending",
	["noV"] = "O-Pending",
	["no\x16"] = "O-Pending",
	["niI"] = "Normal",
	["niR"] = "Normal",
	["niV"] = "Normal",
	["nt"] = "Normal",
	["ntT"] = "Normal",
	["v"] = "Visual",
	["vs"] = "Visual",
	["V"] = "V-Line",
	["Vs"] = "V-Line",
	["\x16"] = "V-Block",
	["\x16s"] = "V-Block",
	["s"] = "Select",
	["S"] = "S-Line",
	["\x13"] = "S-Block",
	["i"] = "Insert",
	["ic"] = "Insert",
	["ix"] = "Insert",
	["R"] = "Replace",
	["Rc"] = "Replace",
	["Rx"] = "Replace",
	["Rv"] = "V-Replace",
	["Rvc"] = "V-Replace",
	["Rvx"] = "V-Replace",
	["c"] = "Command",
	["cv"] = "Ex",
	["ce"] = "Ex",
	["r"] = "Replace",
	["rm"] = "More",
	["r?"] = "Confirm",
	["!"] = "Shell",
	["t"] = "Terminal",
}

local mode_highlight_groups = {
	Insert = "DiagnosticInfo",
	["O-Pending"] = "@markup.heading.6.markdown",
	Visual = "DiagnosticVirtualTextWarn",
	["V-Line"] = "DiagnosticVirtualTextWarn",
	["V-Block"] = "DiagnosticWarn",
	Select = "IncSearch",
	["S-Line"] = "IncSearch",
	["S-Block"] = "IncSearch",
}

--- Return the current mode label, wrapped in a highlight when configured.
---@return string Statusline-format mode label.
function M.format_mode()
	local mode = api.nvim_get_mode().mode
	local mode_name = mode_names[mode] or mode_names[mode:sub(1, 1)] or "Unknown"
	local mode_label = mode_name:sub(1, 3):upper()
	local highlight_group = mode_highlight_groups[mode_name]
	return highlight_group and ("%%#%s#%s%%*"):format(highlight_group, mode_label) or mode_label
end

--- Create a global mode component refreshed only when Neovim changes modes.
---@return table component
function M.create_mode_component()
	return {
		metadata = {
			id = "Mode",
			scope = "global",
			events = { "ModeChanged" },
			default = M.format_mode(),
		},
		render = M.format_mode,
	}
end

local encoding_mnemonics = {
	["utf-8"] = "U",
	["utf8"] = "U",
	["latin1"] = "1",
	["iso-8859-1"] = "1",
}

local function get_encoding_mnemonic(encoding)
	return encoding_mnemonics[(encoding or ""):lower()] or "-"
end

local default_encoding_mnemonic = get_encoding_mnemonic(vim.o.encoding)

local function get_coding_system(buffer_number)
	local buffer_options = vim.bo[buffer_number]
	local file_encoding = buffer_options.fileencoding
	local file_format = buffer_options.fileformat
	local line_ending_symbol = file_format == "dos" and "\\" or file_format == "mac" and "/" or ":"
	local file_encoding_mnemonic = file_encoding ~= "" and get_encoding_mnemonic(file_encoding)
		or default_encoding_mnemonic
	return file_encoding_mnemonic .. default_encoding_mnemonic .. line_ending_symbol
end

--- Format the current buffer's encoding and line-ending indicator.
---@return string Coding-system label.
function M.format_coding_system()
	return get_coding_system(0)
end

--- Create the buffer-local encoding component and its update events.
---@return table component
function M.create_coding_component()
	return {
		metadata = {
			label = "Coding system",
			scope = "buffer",
			events = {
				"BufReadPost",
				"BufWritePost",
				"OptionSet fileencoding,fileformat",
			},
		},
		render = function(buffer_number)
			return " " .. get_coding_system(buffer_number)
		end,
		targets = function(event_args)
			return { event_args.event == "OptionSet" and api.nvim_get_current_buf() or event_args.buf }
		end,
	}
end

local lsp_progress_state = { clients = {}, last_event = nil }

--- Find any still-active progress token after the current token completes.
local function find_latest_active_token(client_progress)
	for progress_token, progress_text in pairs(client_progress.texts) do
		if progress_text then
			return progress_token
		end
	end
end

--- Update cached progress state from LSP progress and detach events.
local function update_lsp_progress_state(event_args)
	if not event_args or event_args == lsp_progress_state.last_event then
		return
	end
	lsp_progress_state.last_event = event_args
	local event_data = event_args.data or {}
	local client_id = event_data.client_id
	if client_id == nil then
		return
	end

	if event_args.event == "LspDetach" then
		local client = lsp.get_client_by_id(client_id)
		if not client or client.is_stopped(client) or vim.tbl_count(client.attached_buffers or {}) <= 1 then
			lsp_progress_state.clients[client_id] = nil
		end
		return
	end
	if event_args.event ~= "LspProgress" then
		return
	end

	local params = event_data.params
	local value = params and params.value
	local token = params and params.token
	if type(value) ~= "table" or token == nil then
		return
	end

	local client_state = lsp_progress_state.clients[client_id]
	if not client_state then
		client_state = { titles = {}, texts = {} }
		lsp_progress_state.clients[client_id] = client_state
	end

	if value.kind == "end" then
		client_state.titles[token], client_state.texts[token] = nil, nil
		if client_state.latest_token == token then
			client_state.latest_token = find_latest_active_token(client_state)
		end
		if next(client_state.texts) == nil then
			lsp_progress_state.clients[client_id] = nil
		end
		return
	end

	client_state.titles[token] = value.title or client_state.titles[token]
	local title = client_state.titles[token]
	---@type string|false
	local progress_text = false
	if title then
		progress_text = type(value.percentage) == "number"
				and ("%s %d%%"):format(title, math.floor(value.percentage))
			or title
		client_state.latest_token = token
	end
	client_state.texts[token] = progress_text
end

--- Return whether any LSP client currently has active progress.
local function is_lsp_progress_active()
	return next(lsp_progress_state.clients) ~= nil
end

--- Get the latest visible progress message for an LSP client.
local function get_lsp_progress_text(client_id)
	local client_state = lsp_progress_state.clients[client_id]
	return client_state and client_state.latest_token and client_state.texts[client_state.latest_token]
		or nil
end

--- Create the global LSP progress spinner component.
---@return table component
function M.create_lsp_progress_component()
	local spinner_frames = { "⣶", "⣧", "⣏", "⡟", "⠿", "⢻", "⣹", "⣼" }
	local spinner_index = 0
	return {
		metadata = {
			id = "LSP progress",
			scope = "global",
			events = { "LspProgress", "LspDetach" },
			highlight_group = "LspProgress",
			highlight = { link = "Type" },
		},
		render = function(_, event_args)
			if not event_args then
				return
			end
			if not is_lsp_progress_active() then
				return ""
			end
			if event_args.event == "LspProgress" then
				spinner_index = spinner_index % #spinner_frames + 1
			end
			return spinner_frames[math.max(spinner_index, 1)]
		end,
		prepare = update_lsp_progress_state,
	}
end

--- Create a buffer-local component showing attached LSP clients or their progress.
---@return table component
function M.create_lsp_status_component()
	return {
		metadata = {
			id = "LSP status",
			scope = "buffer",
			events = { "LspProgress", "LspAttach", "LspDetach" },
			statusline_group = "Lsp",
		},
		render = function(buffer_number, event_args)
			local event_data = event_args and event_args.data or {}
			local detached_client_id = event_args
					and event_args.event == "LspDetach"
					and event_args.buf == buffer_number
					and event_data.client_id
				or nil

			local client_labels, workspace_root, progress_message = {}, nil, nil
			for _, client in ipairs(lsp.get_clients({ bufnr = buffer_number })) do
				if client.id ~= detached_client_id then
					workspace_root = client.root_dir or workspace_root
					client_labels[#client_labels + 1] = ("%d.%s"):format(client.id, client.name)
					progress_message = progress_message or get_lsp_progress_text(client.id)
				end
			end
			if #client_labels == 0 then
				return ""
			end
			progress_message = progress_message
				or ("[ %s: %s ]"):format(
					workspace_root and modify_filename(workspace_root, ":t") or "single",
					table.concat(client_labels, ", ")
				)
			return "   " .. escape_statusline_text(progress_message)
		end,
		prepare = update_lsp_progress_state,
		targets = function(event_args)
			if event_args.event ~= "LspProgress" then
				return { event_args.buf }
			end
			local event_data = event_args.data
			local client = event_data and lsp.get_client_by_id(event_data.client_id)
			return client and vim.tbl_keys(client.attached_buffers or {}) or {}
		end,
	}
end

--- Create a buffer-local Git status component backed by gitsigns.
---@return table component
function M.create_git_status_component()
	local highlight_groups = { "Head", "plus", "delta", "minus" }
	local status_prefixes = { "Git:", "+", "~", "-" }
	local status_fields = { "head", "added", "changed", "removed" }

	local configured_default_branch
	local default_branch_callbacks = {}

	--- Resolve the configured default branch once and notify queued callers.
	local function resolve_default_branch(callback)
		if configured_default_branch ~= nil then
			return callback(configured_default_branch or nil)
		end
		default_branch_callbacks[#default_branch_callbacks + 1] = callback
		if #default_branch_callbacks > 1 then
			return
		end
		local function complete_lookup(branch_name)
			configured_default_branch = branch_name or false
			local callbacks = default_branch_callbacks
			default_branch_callbacks = {}
			for _, pending_callback in ipairs(callbacks) do
				pending_callback(branch_name)
			end
		end
		local ok = pcall(
			vim.system,
			{ "git", "config", "--get", "init.defaultBranch" },
			{ text = true },
			function(result)
				local branch_name = result.code == 0 and vim.trim(result.stdout or "") or ""
				vim.schedule(function()
					complete_lookup(branch_name ~= "" and branch_name or nil)
				end)
			end
		)
		if not ok then
			complete_lookup(nil)
		end
	end

	--- Format the branch and change counts using diff highlight groups.
	local function format_git_status(git_status, branch_name)
		local statusline_parts = {}
		for part_index = 1, 4 do
			local part_value = part_index == 1 and escape_statusline_text(branch_name)
				or git_status[status_fields[part_index]]
			if part_index == 1 or (type(part_value) == "number" and part_value > 0) then
				statusline_parts[#statusline_parts + 1] = ("%%#@diff.%s#%s%s%%*"):format(
					highlight_groups[part_index],
					status_prefixes[part_index],
					part_value
				)
			end
		end
		return " " .. table.concat(statusline_parts, " ")
	end

	return {
		metadata = {
			id = "Git status",
			scope = "buffer",
			events = { "User GitSignsUpdate", "BufEnter" },
			async = true,
			statusline_group = "git",
		},
		render = function(buffer_number, _, complete, protect_callback)
			local git_status = vim.b[buffer_number].gitsigns_status_dict
			if type(git_status) ~= "table" or next(git_status) == nil then
				return complete("")
			end
			if git_status.head and git_status.head ~= "" then
				return complete(format_git_status(git_status, git_status.head))
			end
			resolve_default_branch(protect_callback(function(branch_name)
				complete(format_git_status(git_status, branch_name or ""))
			end))
		end,
		targets = function(event_args)
			local event_data = event_args.data
			return { event_data and event_data.buffer or event_args.buf }
		end,
	}
end

--- Create a buffer-local diagnostics-count component.
---@return table component
function M.create_diagnostics_component()
	local severity_names = { "Error", "Warn", "Info" }
	return {
		metadata = {
			label = "Diagnostics",
			scope = "buffer",
			events = { "DiagnosticChanged", "LspAttach", "LspDetach" },
		},
		render = function(buffer_number, event_args)
			local detached_client_id = event_args
				and event_args.event == "LspDetach"
				and event_args.data
				and event_args.data.client_id
			local has_attached_client = false
			for _, client in ipairs(lsp.get_clients({ bufnr = buffer_number })) do
				if client.id ~= detached_client_id then
					has_attached_client = true
					break
				end
			end
			if not has_attached_client or not diagnostics.is_enabled({ bufnr = buffer_number }) then
				return ""
			end
			local diagnostic_counts = diagnostics.count(buffer_number)
			local formatted_counts = {}
			for severity_index = 1, 3 do
				formatted_counts[severity_index] = ("%%#Diagnostic%s#%d%%*"):format(
					severity_names[severity_index],
					diagnostic_counts[severity_index] or 0
				)
			end
			return (" ☾ %s ☽"):format(table.concat(formatted_counts, " "))
		end,
		init = function(refresh_component)
			local enable_diagnostics = diagnostics.enable
			if type(enable_diagnostics) ~= "function" then
				return
			end
			-- Wrap the public function to redraw diagnostics after enable/disable.
			rawset(diagnostics, "enable", function(...)
				local return_value = enable_diagnostics(...)
				vim.schedule(refresh_component)
				return return_value
			end)
		end,
	}
end

--- Get the LSP range for either a document symbol or a symbol location.
local function get_symbol_range(document_symbol)
	return document_symbol.range or (document_symbol.location and document_symbol.location.range)
end

--- Find the innermost document symbol containing a zero-based cursor line.
local function find_symbol_at_line(document_symbols, cursor_line)
	local nearest_symbol, smallest_range_span
	for _, document_symbol in ipairs(document_symbols) do
		local symbol_range = get_symbol_range(document_symbol)
		if symbol_range and cursor_line >= symbol_range.start.line and cursor_line <= symbol_range["end"].line then
			local range_span = symbol_range["end"].line - symbol_range.start.line
			if not nearest_symbol or range_span < smallest_range_span then
				nearest_symbol, smallest_range_span = document_symbol, range_span
			end
		end
	end
	if nearest_symbol and type(nearest_symbol.children) == "table" then
		return find_symbol_at_line(nearest_symbol.children, cursor_line) or nearest_symbol
	end
	return nearest_symbol
end

--- Create an asynchronous component showing the symbol under the cursor.
---@return table component
function M.create_document_symbol_component()
	local document_symbol_method = "textDocument/documentSymbol"
	return {
		metadata = {
			id = "Document symbol",
			scope = "buffer",
			async = true,
			events = { "CursorHold" },
			statusline_group = "DocumentSymbol",
		},
		render = function(buffer_number, _, complete, protect_callback)
			if #lsp.get_clients({ bufnr = buffer_number, method = document_symbol_method }) == 0 then
				return complete("")
			end
			local window_id = buffer_number == api.nvim_get_current_buf() and api.nvim_get_current_win()
				or vim.fn.bufwinid(buffer_number)
			if window_id == -1 then
				return
			end
			local cursor_line = api.nvim_win_get_cursor(window_id)[1] - 1
			local request_params = {
				textDocument = lsp.util.make_text_document_params(buffer_number),
			}
			lsp.buf_request_all(
				buffer_number,
				document_symbol_method,
				request_params,
				protect_callback(function(client_results)
					if not api.nvim_buf_is_valid(buffer_number) then
						return
					end
					for _, client_result in pairs(client_results or {}) do
						local document_symbols = client_result.result
						if not (client_result.err or client_result.error) and type(document_symbols) == "table" then
							local current_symbol = find_symbol_at_line(document_symbols, cursor_line)
							if current_symbol then
								return complete((" %s "):format(escape_statusline_text(current_symbol.name)))
							end
						end
					end
					complete("")
				end)
			)
		end,
	}
end

return M
