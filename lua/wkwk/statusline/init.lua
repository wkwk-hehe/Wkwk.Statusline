local Engine = require("wkwk.statusline.engine")
local create_default_components = require("wkwk.statusline.components")

local Statusline = {
	Api = {},
}

local statusline_engine

--- Initialize the statusline once and expose its public Lua entrypoints.
function Statusline.setup()
	if statusline_engine then
		return
	end

	_G.Wkwk = _G.Wkwk or {}
	_G.Wkwk.Statusline = Statusline

	local components = create_default_components()
	local engine = Engine.new(components)

	engine:setup()
	statusline_engine = engine
	Statusline.Api.render = function()
		return engine:render()
	end
	vim.go.statusline = "%{%v:lua.Wkwk.Statusline.Api.render()%}"
end

return Statusline
