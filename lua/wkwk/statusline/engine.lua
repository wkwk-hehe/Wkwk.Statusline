local api = vim.api

--- Stateful renderer that evaluates component specs and maintains their cached values.
---@class WkwkStatuslineEngine
---@field components WkwkStatuslineComponent[] Ordered component definitions.
---@field components_by_event table<string, integer[]> Component indexes grouped by autocmd event.
---@field global_component_values table<integer, string> Latest rendered values for global components.
---@field buffer_component_values table<integer, table<integer, string>> Latest rendered values by buffer and component.
---@field default_component_values table<integer, string> Formatted defaults used before first render.
---@field initialized_buffers table<integer, boolean> Buffers whose components have been initialized.
---@field initializing_buffers table<integer, boolean> Buffers with initialization already scheduled.
---@field cached_statuslines table<integer, string> Composed statusline cache by buffer.
---@field cached_global_versions table<integer, integer> Global value version used by each cached statusline.
---@field global_value_version integer Incremented whenever a global component changes.
---@field async_render_versions table<integer, table<integer, integer>> Latest async render generation by component and buffer.
---@field reported_errors table<string, boolean> Component errors already reported.
---@field redraw_scheduled boolean Whether a statusline redraw is queued.
---@field global_statusline_enabled boolean Whether `laststatus` is set to 3.
---@field last_normal_window integer? Last non-floating window.
---@field fallback string Fallback statusline used if composition fails.
local M = {}
M.__index = M

--- Wrap statusline text in a plugin-owned highlight group.
---@param hl_group string Highlight group suffix, without the `WkwkStatusline` prefix.
---@param text string Statusline-format string to highlight.
---@return string formatted Statusline expression.
local function format_hl(hl_group, text)
	return ("%%#WkwkStatusline%s#%s%%*"):format(hl_group, text)
end

--- Create an engine and index component metadata for event dispatch.
---@param cmp_specs WkwkStatuslineComponent[] Ordered text and provider component specifications.
---@return WkwkStatuslineEngine
function M.new(cmp_specs)
	local self = setmetatable({
		components = cmp_specs,
		components_by_event = {},
		global_component_values = {},
		buffer_component_values = {},
		default_component_values = {},
		initialized_buffers = {},
		initializing_buffers = {},
		cached_statuslines = {},
		cached_global_versions = {},
		global_value_version = 0,
		async_render_versions = {},
		reported_errors = {},
		redraw_scheduled = false,
		global_statusline_enabled = vim.o.laststatus == 3,
		last_normal_window = nil,
	}, M)

	for index, cmp in ipairs(cmp_specs) do
		assert(type(cmp) == "table", ("component %d must be a table"):format(index))
		if cmp.kind == "text" then
			assert(type(cmp.value) == "string", ("text component %d needs a string value"):format(index))
		else
			assert(type(cmp.metadata) == "table", ("component %d needs metadata"):format(index))
			assert(
				cmp.metadata.scope == "buffer" or cmp.metadata.scope == "global",
				("component %d has an invalid scope"):format(index)
			)
			assert(type(cmp.render) == "function", ("component %d needs a render function"):format(index))
		end
		local cmp_metadata = cmp.metadata
		if cmp_metadata then
			for _, event_name in ipairs(cmp_metadata.events or {}) do
				self.components_by_event[event_name] = self.components_by_event[event_name] or {}
				table.insert(self.components_by_event[event_name], index)
			end
			if cmp_metadata.default ~= nil then
				self.default_component_values[index] = self:_format_component_value(index, cmp_metadata.default)
			end
		end
	end

	return self
end

function M:_get_component_name(index)
	local cmp_metadata = self.components[index].metadata
	return cmp_metadata.label or cmp_metadata.id or ("component #" .. index)
end

--- Apply component-specific statusline highlighting to a rendered value.
function M:_format_component_value(index, value)
	local cmp_metadata = self.components[index].metadata
	local hl_group = cmp_metadata.statusline_group
	return hl_group and value ~= "" and format_hl(hl_group, value) or value
end

--- Report a component failure once, avoiding repeated notifications on redraw.
function M:_report_component_error(name, error_msg)
	if self.reported_errors[name] then
		return
	end
	self.reported_errors[name] = true
	vim.schedule(function()
		vim.notify(("[WkwkStatusline] %s failed: %s"):format(name, error_msg), vim.log.levels.ERROR)
	end)
end

--- Install component highlight definitions, restoring them after colorscheme changes.
function M:_apply_component_highlights()
	for _, cmp in ipairs(self.components) do
		local cmp_metadata = cmp.metadata
		if cmp_metadata and cmp_metadata.highlight_group and cmp_metadata.highlight then
			api.nvim_set_hl(
				0,
				"WkwkStatusline" .. cmp_metadata.highlight_group,
				vim.tbl_extend("force", { default = true }, cmp_metadata.highlight)
			)
		end
	end
end

--- Redraw statuslines when Neovim is not in a transient replace/popup-menu state.
function M:_redraw_statusline()
	local current_mode = api.nvim_get_mode().mode
	if current_mode:sub(1, 1) == "r" or vim.fn.pumvisible() == 1 then
		vim.defer_fn(function()
			self:_redraw_statusline()
		end, 100)
		return
	end
	self.redraw_scheduled = false
	pcall(vim.cmd.redrawstatus, { bang = true })
end

--- Coalesce multiple component updates into one scheduled statusline redraw.
function M:_schedule_statusline_redraw()
	if self.redraw_scheduled then
		return
	end
	self.redraw_scheduled = true
	vim.schedule(function()
		self:_redraw_statusline()
	end)
end

--- Store a changed rendered value and invalidate the affected cached statusline.
function M:_update_component_value(index, bufnr, value)
	if value == nil then
		return
	end
	local formatted_value = self:_format_component_value(index, value)
	if bufnr == nil then
		if self.global_component_values[index] == formatted_value then
			return
		end
		self.global_component_values[index] = formatted_value
		self.global_value_version = self.global_value_version + 1
	else
		if not self.initialized_buffers[bufnr] then
			return
		end
		local buffer_values = self.buffer_component_values[bufnr]
		if not buffer_values then
			buffer_values = {}
			self.buffer_component_values[bufnr] = buffer_values
		end
		if buffer_values[index] == formatted_value then
			return
		end
		buffer_values[index] = formatted_value
		self.cached_statuslines[bufnr] = nil
	end
	self:_schedule_statusline_redraw()
end

--- Wrap asynchronous callbacks so provider failures are reported consistently.
function M:_protect_callback(cmp_name, callback)
	return function(...)
		local ok, error_message = pcall(callback, ...)
		if not ok then
			self:_report_component_error(cmp_name, error_message)
		end
	end
end

--- Render one provider component, ignoring stale asynchronous responses.
function M:_render_component(cmp_index, buffer_number, event_args)
	local cmp = self.components[cmp_index]
	local cmp_metadata = cmp.metadata
	if not cmp_metadata.async then
		return self:_update_component_value(cmp_index, buffer_number, cmp.render(buffer_number, event_args))
	end

	local render_versions = self.async_render_versions[cmp_index] or {}
	self.async_render_versions[cmp_index] = render_versions
	local buffer_key = buffer_number or 0
	local render_version = (render_versions[buffer_key] or 0) + 1
	render_versions[buffer_key] = render_version
	cmp.render(buffer_number, event_args, function(cmp_value)
		if render_versions[buffer_key] == render_version then
			self:_update_component_value(cmp_index, buffer_number, cmp_value)
		end
	end, function(callback)
		return self:_protect_callback(self:_get_component_name(cmp_index), callback)
	end)
end

--- Render a component while containing and reporting provider errors.
function M:_render_component_safely(cmp_index, bufnr, event_args)
	local ok, error_message = pcall(self._render_component, self, cmp_index, bufnr, event_args)
	if not ok then
		self:_report_component_error(self:_get_component_name(cmp_index), error_message)
	end
end

--- Re-render all components, or only one component/buffer when specified.
---@param only_cmp_index? integer Component array index to refresh.
---@param only_bufnr? integer Buffer handle to refresh.
function M:refresh_components(only_cmp_index, only_bufnr)
	for index, cmp in ipairs(self.components) do
		local cmp_metadata = cmp.metadata
		if cmp_metadata and (only_cmp_index == nil or only_cmp_index == index) then
			if cmp_metadata.scope == "global" then
				if only_bufnr == nil then
					self:_render_component_safely(index, nil, nil)
				end
			elseif only_bufnr then
				if self.initialized_buffers[only_bufnr] then
					self:_render_component_safely(index, only_bufnr, nil)
				end
			else
				for buffer_number in pairs(self.initialized_buffers) do
					self:_render_component_safely(index, buffer_number, nil)
				end
			end
		end
	end
end

--- Run a component's preparation and render callbacks for an autocmd event.
function M:_handle_component_event(cmp_index, event_args)
	local cmp = self.components[cmp_index]
	if cmp.prepare then
		cmp.prepare(event_args)
	end
	if cmp.condition and cmp.condition(event_args) == false then
		return
	end
	if cmp.metadata.scope == "global" then
		return self:_render_component(cmp_index, nil, event_args)
	end
	local target_buffers = cmp.targets and cmp.targets(event_args) or { event_args.buf }
	for _, buffer_number in ipairs(target_buffers) do
		if self.initialized_buffers[buffer_number] then
			self:_render_component(cmp_index, buffer_number, event_args)
		end
	end
end

--- Dispatch an event to the components registered for it.
---@param event_key string Event name, optionally followed by an autocmd pattern.
---@param event_args table Neovim autocmd callback arguments.
function M:handle_event(event_key, event_args)
	for _, cmp_index in ipairs(self.components_by_event[event_key] or {}) do
		local ok, error_message = pcall(self._handle_component_event, self, cmp_index, event_args)
		if not ok then
			self:_report_component_error(self:_get_component_name(cmp_index), error_message)
		end
	end
end

--- Mark a buffer initialized and schedule its initial component refresh.
function M:_initialize_buffer(bufnr)
	if self.initialized_buffers[bufnr] or self.initializing_buffers[bufnr] then
		return
	end
	self.initializing_buffers[bufnr] = true
	vim.schedule(function()
		self.initializing_buffers[bufnr] = nil
		if api.nvim_buf_is_valid(bufnr) then
			self.initialized_buffers[bufnr] = true
			self:refresh_components(nil, bufnr)
		end
	end)
end

--- Determine which buffer's statusline is being rendered.
function M:_get_statusline_buffer()
	if self.global_statusline_enabled then
		local window_id = api.nvim_get_current_win()
		if
			window_id ~= self.last_normal_window
			and self.last_normal_window
			and api.nvim_win_is_valid(self.last_normal_window)
			and api.nvim_win_get_config(window_id).relative ~= ""
		then
			return api.nvim_win_get_buf(self.last_normal_window)
		end
	end
	return api.nvim_get_current_buf()
end

--- Concatenate the ordered text and most recently rendered provider values.
function M:_compose_statusline(bufnr)
	local buff_values = self.buffer_component_values[bufnr] or {}
	local parts = {}
	for index, cmp in ipairs(self.components) do
		local cmp_metadata = cmp.metadata
		if cmp.kind == "text" then
			parts[index] = cmp.value
		elseif cmp_metadata.scope == "global" then
			parts[index] = self.global_component_values[index]
				or self.default_component_values[index]
				or ""
		else
			parts[index] = buff_values[index]
				or self.default_component_values[index]
				or ""
		end
	end
	return table.concat(parts)
end

--- Return the cached statusline or compose it from current component values.
function M:_render_statusline()
	local bufnr = self:_get_statusline_buffer()
	self:_initialize_buffer(bufnr)
	if self.cached_statuslines[bufnr] and self.cached_global_versions[bufnr] == self.global_value_version then
		return self.cached_statuslines[bufnr]
	end
	local statusline = self:_compose_statusline(bufnr)
	self.cached_statuslines[bufnr], self.cached_global_versions[bufnr] = statusline, self.global_value_version
	return statusline
end

--- Public renderer called by the `statusline` option.
---@return string statusline-format expression.
function M:render()
	local ok, statusline = pcall(self._render_statusline, self)
	if ok then
		return statusline
	end
	self:_report_component_error("statusline renderer", statusline)
	return self.fallback
end

--- Release cached state after a buffer is wiped out.
---@param buffer_number integer Neovim buffer handle.
function M:cleanup_buffer(buffer_number)
	self.buffer_component_values[buffer_number] = nil
	self.initialized_buffers[buffer_number] = nil
	self.initializing_buffers[buffer_number] = nil
	self.cached_statuslines[buffer_number] = nil
	self.cached_global_versions[buffer_number] = nil
	for _, render_versions in pairs(self.async_render_versions) do
		render_versions[buffer_number] = nil
	end
end

--- Track whether Neovim is using a single global statusline.
---@param laststatus_value integer Value of the `laststatus` option.
function M:set_global_statusline_enabled(laststatus_value)
	self.global_statusline_enabled = laststatus_value == 3
end

--- Remember the current normal window for floating-window statusline rendering.
function M:remember_normal_window()
	local win_id = api.nvim_get_current_win()
	if api.nvim_win_get_config(win_id).relative == "" then
		self.last_normal_window = win_id
	end
end

--- Register autocmds, initialize highlights, and initialize provider hooks.
function M:setup()
	self.fallback = self:_compose_statusline(-1)
	local augroup_id = api.nvim_create_augroup("WkwkStatusline", { clear = true })

	local function create_autocmd(event_name, options)
		options.group = augroup_id
		api.nvim_create_autocmd(event_name, options)
	end

	self:_apply_component_highlights()
	create_autocmd("ColorScheme", {
		callback = function()
			self:_apply_component_highlights()
		end,
		desc = "[WkwkStatusline] restore highlights",
	})
	create_autocmd("OptionSet", {
		pattern = "laststatus",
		callback = function()
			self:set_global_statusline_enabled(vim.o.laststatus)
		end,
		desc = "[WkwkStatusline] track laststatus",
	})
	create_autocmd("WinEnter", {
		callback = function()
			self:remember_normal_window()
		end,
		desc = "[WkwkStatusline] track last normal window",
	})
	create_autocmd("BufWipeout", {
		callback = function(event_args)
			self:cleanup_buffer(event_args.buf)
		end,
		desc = "[WkwkStatusline] cleanup",
	})

	for event_key in pairs(self.components_by_event) do
		local event_name, event_pattern = event_key:match("^(%S+)%s+(%S+)$")
		create_autocmd(event_name or event_key, {
			pattern = event_pattern and vim.split(event_pattern, ",") or nil,
			callback = function(event_args)
				self:handle_event(event_key, event_args)
			end,
			desc = "[WkwkStatusline] update",
		})
	end

	for cmp_index, cmp in ipairs(self.components) do
		if cmp.init then
			cmp.init(function(buffer_number)
				self:refresh_components(cmp_index, buffer_number)
			end)
		end
	end

	self:remember_normal_window()
end

return M
