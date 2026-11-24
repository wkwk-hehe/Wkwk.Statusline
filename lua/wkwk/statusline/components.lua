local providers = require("wkwk.statusline.provider")

---@class WkwkStatuslineComponentMetadata
---@field id? string Stable component identifier used in error messages.
---@field label? string Human-readable component name used in error messages.
---@field scope? "buffer"|"global" Whether the component value is per-buffer or shared.
---@field events? string[] Autocmd events that trigger a component refresh.
---@field async? boolean Whether `render` completes through its callback.
---@field default? string Value used before a component has rendered.
---@field statusline_group? string Highlight suffix applied to the rendered value.
---@field highlight_group? string Plugin-owned highlight group to initialize.
---@field highlight? vim.api.keyset.highlight Highlight definition for `highlight_group`.
---@class WkwkStatuslineTextComponent
---@field kind "text"
---@field value string Literal Neovim statusline-format expression.
---@class WkwkStatuslineProviderComponent
---@field metadata WkwkStatuslineComponentMetadata
---@field render function Compute component content for a buffer.
---@field prepare? function Update provider state before rendering.
---@field targets? function Select buffers affected by an event.
---@field condition? function Return false to skip a render for an event.
---@field init? function Initialize provider hooks and receive a refresh callback.
---@alias WkwkStatuslineComponent WkwkStatuslineTextComponent|WkwkStatuslineProviderComponent

--- Build the ordered components for the default statusline.
--- Literal components contain Neovim statusline syntax; provider components
--- include render callbacks and metadata consumed by the engine. Provider
--- metadata defines update events, buffer/global scope, defaults, and highlights.
--- A new list is returned each time so stateful providers get fresh state.
---@return WkwkStatuslineComponent[] components
local function create_default_components()
	return {
		-- Mode and buffer encoding.
		providers.create_mode_component(),
		providers.create_coding_component(),

		-- Read-only/modified state, tab, filename, and cursor position.
		{
			kind = "text",
			value = "—%{&readonly?(&modified?'⚠—■':'⚠—⚠'):(&modified?'■—■':'———')}—",
		},
		{
			kind = "text",
			value = "  T%{tabpagenr()} %#WkwkStatuslineFileName#%t%*",
		},
		{
			kind = "text",
			value = "  %P  L%-5lC%-5c    ",
		},
		providers.create_git_status_component(),

		-- Right-align the filetype and diagnostics after the Git section.
		{
			kind = "text",
			value = " %=",
		},
		{
			kind = "text",
			value = [[%{(bufname() !=# '' && &bt !=# 'terminal' ? ' —[ ' : '')}]],
		},
		{
			kind = "text",
			value = "%{( &ft ==# 'htmlangular' ? ' htmlangular' : toupper(strpart(&ft, 0, 1)) . strpart(&ft, 1)) }",
		},
		providers.create_diagnostics_component(),

		-- LSP progress and attached-client information at the far right.
		{
			kind = "text",
			value = [[%{(bufname() !=# '' && &bt !=# 'terminal' ? ' ]— ' : ' ')}]],
		},
		providers.create_lsp_progress_component(),
		{
			kind = "text",
			value = "%=%=",
		},
		providers.create_lsp_status_component(),
	}
end

return create_default_components
