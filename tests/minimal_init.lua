local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")

vim.opt.runtimepath:prepend(root)
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false

if vim.env.UX_CHROME_ROOT then
  assert(vim.env.UX_FOUNDATION_ROOT, "UX_FOUNDATION_ROOT is required with UX_CHROME_ROOT")
  vim.opt.runtimepath:prepend(vim.env.UX_FOUNDATION_ROOT)
  vim.opt.runtimepath:prepend(vim.env.UX_CHROME_ROOT)
  require('ux_foundation').setup({ load_active = false })
end
