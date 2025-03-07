local Sidebar = {}
local api = vim.api

-- Simplified configuration
local config = {
	width = 30, -- Default width (used as initial value)
	min_width = 20, -- Minimum width
	max_width = 60, -- Maximum width
	selector_char = "▶",
	show_modified = true,
}

-- Internal state
local state = {
	win_id = nil,
	buf_id = nil,
	is_open = false,
	buffer_counts = {},
	current_width = config.width, -- Track current width
}

-- Load buffer counts from a file
local function load_buffer_counts()
	local count_file = vim.fn.stdpath("data") .. "/sidebar_buffer_counts.json"
	local file = io.open(count_file, "r")
	if file then
		local content = file:read("*all")
		file:close()
		local success, counts = pcall(vim.fn.json_decode, content)
		if success and type(counts) == "table" then
			state.buffer_counts = counts
		end
	end
end

-- Save buffer counts to a file
local function save_buffer_counts()
	local count_file = vim.fn.stdpath("data") .. "/sidebar_buffer_counts.json"
	local file = io.open(count_file, "w")
	if file then
		file:write(vim.fn.json_encode(state.buffer_counts))
		file:close()
	end
end

-- Increment buffer access count
local function increment_buffer_count(buf_id)
	local buf_name = api.nvim_buf_get_name(buf_id)
	if buf_name ~= "" then
		-- Use the full path as the key
		state.buffer_counts[buf_name] = (state.buffer_counts[buf_name] or 0) + 1
		save_buffer_counts()
	end
end

-- Get list of valid buffers with sorting by count
local function get_buffer_list()
	local buffers = api.nvim_list_bufs()
	local valid_buffers = {}
	local max_line_length = 0
	local has_named_buffers = false

	-- First pass: collect buffers and check for named buffers
	for _, buf in ipairs(buffers) do
		if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_option(buf, "buflisted") then
			local full_name = api.nvim_buf_get_name(buf)
			if full_name ~= "" then
				has_named_buffers = true
				break
			end
		end
	end

	-- Second pass: build the list, excluding [No Name] if named buffers exist
	for _, buf in ipairs(buffers) do
		if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_option(buf, "buflisted") then
			local full_name = api.nvim_buf_get_name(buf)
			local file_name = full_name ~= "" and vim.fn.fnamemodify(full_name, ":t") or "[No Name]"
			local parent_dir = full_name ~= "" and vim.fn.fnamemodify(full_name, ":h:t") or ""
			local display_name = full_name ~= "" and (parent_dir .. "/" .. file_name) or "[No Name]"
			local count = state.buffer_counts[full_name] or 0

			-- Skip [No Name] if there are named buffers
			if full_name == "" and has_named_buffers then
				goto continue
			end

			local line_text = string.format(
				"%s %s%s%s",
				config.selector_char,
				display_name,
				count > 0 and string.format(" (%dx)", count) or "",
				api.nvim_buf_get_option(buf, "modified") and config.show_modified and " [+]" or ""
			)
			max_line_length = math.max(max_line_length, #line_text)

			table.insert(valid_buffers, {
				id = buf,
				name = display_name,
				full_name = full_name,
				modified = api.nvim_buf_get_option(buf, "modified"),
				count = count,
			})
			::continue::
		end
	end

	-- Sort buffers by count (descending), then by name alphabetically
	table.sort(valid_buffers, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.name < b.name
	end)

	-- Update current_width, including space for title
	local title_length = #"Buffer Counts" + 3 -- +2 for padding
	state.current_width =
		math.max(config.min_width, math.min(config.max_width, math.max(max_line_length, title_length) + 2))

	return valid_buffers
end

-- Render sidebar content
local function render_content()
	if not state.buf_id or not api.nvim_buf_is_valid(state.buf_id) then
		return
	end
	if not state.win_id or not api.nvim_win_is_valid(state.win_id) then
		return
	end

	local buffers = get_buffer_list() -- Updates state.current_width
	local lines = {}
	local current_buf = api.nvim_get_current_buf()

	-- Add title as first line
	local title = " Buffers Counts "
	table.insert(lines, title)

	-- Add separator line
	table.insert(lines, string.rep("─", state.current_width))

	-- Generate display lines for all buffers
	for _, buf in ipairs(buffers) do
		local is_current = buf.id == current_buf
		local modified_marker = (buf.modified and config.show_modified) and " [+]" or ""
		local count_display = buf.count > 0 and string.format(" (%dx)", buf.count) or ""

		local line = string.format(
			"%s %s%s%s",
			is_current and config.selector_char or " ",
			buf.name,
			count_display,
			modified_marker
		)
		table.insert(lines, line)
	end

	-- Update window width
	api.nvim_win_set_width(state.win_id, state.current_width)

	api.nvim_buf_set_option(state.buf_id, "modifiable", true)
	api.nvim_buf_set_lines(state.buf_id, 0, -1, false, lines)
	api.nvim_buf_set_option(state.buf_id, "modifiable", false)

	-- Position cursor on current buffer, accounting for title and separator
	for i, buf in ipairs(buffers) do
		if buf.id == current_buf then
			local line_num = i + 2 -- +2 for title and separator
			for j = 1, i - 1 do
				local line_length = #lines[j + 2] -- Offset by title and separator
				if line_length > state.current_width then
					line_num = line_num + math.floor((line_length - 1) / state.current_width)
				end
			end
			pcall(api.nvim_win_set_cursor, state.win_id, { line_num, 0 })
			break
		end
	end
end

-- Switch to selected buffer
local function switch_buffer()
	if not state.win_id or not api.nvim_win_is_valid(state.win_id) then
		return
	end

	local cursor_pos = api.nvim_win_get_cursor(state.win_id)
	local cursor_line = cursor_pos[1]
	local buffers = get_buffer_list()

	-- Convert visual line number to buffer index, accounting for wrapping
	local buffer_index = 1
	local current_line = 1
	for i, buf in ipairs(buffers) do
		local line_text = string.format(
			"%s %s%s%s",
			buf.id == api.nvim_get_current_buf() and config.selector_char or " ",
			buf.name,
			buf.count > 0 and string.format(" (%dx)", buf.count) or "",
			buf.modified and config.show_modified and " [+]" or ""
		)
		local line_length = #line_text
		local wrapped_lines = math.floor((line_length - 1) / config.width) + 1

		if cursor_line <= current_line + wrapped_lines - 1 then
			buffer_index = i
			break
		end
		current_line = current_line + wrapped_lines
	end

	if buffers[buffer_index] then
		local current_win = api.nvim_get_current_win()
		if current_win ~= state.win_id then
			api.nvim_set_current_win(current_win)
			api.nvim_set_current_buf(buffers[buffer_index].id)
			increment_buffer_count(buffers[buffer_index].id)
		else
			local wins = api.nvim_list_wins()
			for _, win in ipairs(wins) do
				if win ~= state.win_id and api.nvim_win_is_valid(win) then
					api.nvim_set_current_win(win)
					api.nvim_set_current_buf(buffers[buffer_index].id)
					increment_buffer_count(buffers[buffer_index].id)
					break
				end
			end
		end
		render_content()
	end
end

-- Delete buffer from list
local function delete_buffer()
	if not state.win_id or not api.nvim_win_is_valid(state.win_id) then
		return
	end

	local cursor_pos = api.nvim_win_get_cursor(state.win_id)
	local cursor_line = cursor_pos[1]
	local buffers = get_buffer_list()

	-- Convert visual line number to buffer index
	local buffer_index = 1
	local current_line = 1
	for i, buf in ipairs(buffers) do
		local line_text = string.format(
			"%s %s%s%s",
			buf.id == api.nvim_get_current_buf() and config.selector_char or " ",
			buf.name,
			buf.count > 0 and string.format(" (%dx)", buf.count) or "",
			buf.modified and config.show_modified and " [+]" or ""
		)
		local line_length = #line_text
		local wrapped_lines = math.floor((line_length - 1) / config.width) + 1

		if cursor_line <= current_line + wrapped_lines - 1 then
			buffer_index = i
			break
		end
		current_line = current_line + wrapped_lines
	end

	if buffers[buffer_index] then
		local buf_id = buffers[buffer_index].id

		if api.nvim_buf_get_option(buf_id, "modified") then
			vim.notify("Buffer is modified. Use :bd! to force delete", vim.log.levels.WARN)
			return
		end

		pcall(api.nvim_buf_delete, buf_id, { force = false })
		render_content()
	end
end

-- Open sidebar
local function open()
	if state.win_id and api.nvim_win_is_valid(state.win_id) then
		return
	end

	local current_win = api.nvim_get_current_win()

	state.buf_id = api.nvim_create_buf(false, true)
	api.nvim_buf_set_option(state.buf_id, "bufhidden", "wipe")
	api.nvim_buf_set_option(state.buf_id, "filetype", "sidebar")
	api.nvim_buf_set_option(state.buf_id, "swapfile", false)

	vim.cmd("botright vnew")
	state.win_id = api.nvim_get_current_win()
	api.nvim_win_set_buf(state.win_id, state.buf_id)

	api.nvim_win_set_width(state.win_id, state.current_width)

	api.nvim_win_set_option(state.win_id, "cursorline", true)
	api.nvim_win_set_option(state.win_id, "number", false)
	api.nvim_win_set_option(state.win_id, "relativenumber", false)
	api.nvim_win_set_option(state.win_id, "signcolumn", "no")

	render_content() -- This will now include the title

	local keymaps = {
		["<CR>"] = '<cmd>lua require("sidebar").switch_buffer()<CR>',
		["q"] = '<cmd>lua require("sidebar").toggle()<CR>',
		["d"] = '<cmd>lua require("sidebar").delete_buffer()<CR>',
		["r"] = '<cmd>lua require("sidebar").render()<CR>',
	}

	for key, cmd in pairs(keymaps) do
		api.nvim_buf_set_keymap(state.buf_id, "n", key, cmd, { noremap = true, silent = true })
	end

	api.nvim_set_current_win(current_win)

	local group = api.nvim_create_augroup("SidebarAutocmds", { clear = true })
	api.nvim_create_autocmd(
		{ "BufEnter", "BufAdd", "BufDelete", "BufWipeout", "BufFilePost", "BufNew", "BufNewFile" },
		{
			group = group,
			callback = function()
				if state.buf_id and api.nvim_buf_is_valid(state.buf_id) then
					render_content()
				end
			end,
		}
	)

	api.nvim_create_autocmd({ "BufEnter" }, {
		group = group,
		callback = function()
			local buf = api.nvim_get_current_buf()
			if buf ~= state.buf_id then
				increment_buffer_count(buf)
				if state.buf_id and api.nvim_buf_is_valid(state.buf_id) then
					render_content()
				end
			end
		end,
	})

	api.nvim_create_autocmd({ "VimResized" }, {
		group = group,
		callback = function()
			if state.is_open and state.win_id and api.nvim_win_is_valid(state.win_id) then
				api.nvim_win_set_width(state.win_id, state.current_width)
				render_content()
			end
		end,
	})

	state.is_open = true
end

-- Close sidebar
local function close()
	if state.win_id and api.nvim_win_is_valid(state.win_id) then
		api.nvim_win_close(state.win_id, true)
		state.win_id = nil
		state.buf_id = nil
	end

	state.is_open = false
	save_buffer_counts()
end

-- Initialization
local function initialize()
	-- Load buffer counts from file
	load_buffer_counts()

	-- Set up autocmd to save counts on exit
	local group = api.nvim_create_augroup("SidebarPersist", { clear = true })
	api.nvim_create_autocmd("VimLeave", {
		group = group,
		callback = function()
			save_buffer_counts()
		end,
	})
end

-- Public API
function Sidebar.setup(opts)
	opts = opts or {}
	config.width = opts.width or config.width
	config.min_width = opts.min_width or config.min_width
	config.max_width = opts.max_width or config.max_width
	config.selector_char = opts.selector_char or config.selector_char
	config.show_modified = opts.show_modified ~= nil and opts.show_modified or config.show_modified

	state.current_width = config.width -- Initialize current_width

	initialize()

	api.nvim_create_user_command("BuffCountsToggle", Sidebar.toggle, {})
	api.nvim_create_user_command("BuffCountsRefresh", Sidebar.render, {})
	api.nvim_create_user_command("BuffCountsReset", Sidebar.clear_counts, {})

	api.nvim_set_keymap("n", "<leader>b", ":BuffCountToggle<CR>", { noremap = true, silent = true })
end

-- Toggle sidebar
function Sidebar.toggle()
	if state.is_open then
		close()
	else
		open()
	end
end

-- Render sidebar content
function Sidebar.render()
	render_content()
end

-- Switch to buffer under cursor
function Sidebar.switch_buffer()
	switch_buffer()
end

-- Delete buffer under cursor
function Sidebar.delete_buffer()
	delete_buffer()
end

-- Clear buffer counts
function Sidebar.clear_counts()
	state.buffer_counts = {}
	save_buffer_counts()
	render_content()
end

-- Return module
return Sidebar
