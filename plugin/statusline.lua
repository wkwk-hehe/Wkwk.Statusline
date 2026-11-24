if vim.g.loaded_wkwk_statusline then
	return
end

-- Defer setup until a buffer exists, while allowing plugin loading to be idempotent.
vim.g.loaded_wkwk_statusline = true

vim.api.nvim_create_autocmd({ "BufEnter", "BufNewFile" }, {
	callback = function()
		require("wkwk.statusline").setup()
	end,
})
