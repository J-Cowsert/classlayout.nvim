--- @class ClassLayout
--- @field config ClassLayoutOpts
--- @field _cc_cache table<string, { mtime: integer, file_flags: table<string, string[]>, fallback_flags: string[] }>
--- @field _dump_cache table<string, { mtime: integer, output: string }>
local M = {}

M.augroup = vim.api.nvim_create_augroup("ClassLayout", { clear = true })

--- @class ClassLayoutOpts
--- @field args? string[]
--- @field compile_commands? boolean
--- @field compiler? string
--- @field keymap? string

--- @return ClassLayoutOpts defaults
local function get_defaults()
	return {
		keymap = "<leader>cl",
		compiler = "clang",
		args = {},
		compile_commands = true, -- auto-detect flags from compile_commands.json
	}
end

--- @param opts? ClassLayoutOpts
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", get_defaults(), M.config or {}, opts or {})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "cpp", "c" },
		group = M.augroup,
		callback = function(ev)
			vim.keymap.set("n", M.config.keymap, M.show, {
				buffer = ev.buf,
				desc = "Show class memory layout",
			})
		end,
	})
end

--- Walk up from `start_path` looking for `compile_commands.json`.
--- Returns the path to `compile_commands.json` or `nil`.
--- @param start_path string
--- @return string|nil candidate
function M.find_compile_commands(start_path)
	local dir = vim.fn.fnamemodify(start_path, ":h")
	local prev = nil
	while dir and dir ~= prev do
		local candidate = vim.fs.joinpath(dir, "compile_commands.json")
		if vim.fn.filereadable(candidate) == 1 then
			return candidate
		end
		prev = dir
		dir = vim.fn.fnamemodify(dir, ":h")
	end
end

--- Extract compiler flags relevant to layout dumping from a compile_commands.json entry.
--- Keeps -I, -D, -std, -isystem flags and drops everything else.
--- @param command_str string
--- @return string[] flags
function M.extract_flags(command_str)
	local flags = {} --- @type string[]
	-- Match flags that take a value either as -Xval or -X val
	local i = 1
	local tokens = {} --- @type string[]
	for token in command_str:gmatch("%S+") do
		table.insert(tokens, token)
	end

	-- Skip the compiler (first token) and the source file / -o / -c tokens
	i = 2
	while i <= #tokens do
		local t = tokens[i]
		if t:match("^%-D") or t:match("^%-std") then
			table.insert(flags, t)
		elseif t:match("^%-I") then
			if t == "-I" then
				-- value is next token
				i = i + 1
				if tokens[i] then
					table.insert(flags, "-I" .. tokens[i])
				end
			else
				table.insert(flags, t)
			end
		elseif t == "-isystem" then
			i = i + 1
			if tokens[i] then
				table.insert(flags, "-isystem")
				table.insert(flags, tokens[i])
			end
		end
		i = i + 1
	end
	return flags
end

-- Cache: keyed by compile_commands.json path
M._cc_cache = {}

-- Cache: keyed by resolved filepath
M._dump_cache = {}

--- Get compiler flags from compile_commands.json for the given filepath.
--- For header files (not in compile_commands.json), falls back to flags from any entry in the same project.
--- @param filepath string
--- @return string[] flags
function M.get_compile_flags(filepath)
	local cc_path = M.find_compile_commands(filepath)
	if not cc_path then
		return {}
	end

	local real_cc_path = vim.fn.resolve(cc_path)
	local stat = vim.uv.fs_stat(real_cc_path)
	if not stat then
		return {}
	end
	local mtime = stat.mtime.sec

	local cached = vim.deepcopy(M._cc_cache[real_cc_path])
	if not cached or cached.mtime ~= mtime then
		local content = vim.fn.readfile(cc_path)
		if not content or #content == 0 then
			return {}
		end

		--- @type boolean, { file?: string, command?: string }|nil
		local ok, entries = pcall(vim.json.decode, table.concat(content, "\n"))
		if not (ok and entries) or #entries == 0 then
			return {}
		end

		-- Build lookup table: resolved file path -> flags
		local file_flags = {} --- @type table<string, string[]>
		for _, entry in ipairs(entries) do
			local resolved = vim.fn.resolve(entry.file or "")
			file_flags[resolved] = M.extract_flags(entry.command or "")
		end

		cached = {
			mtime = mtime,
			file_flags = file_flags,
			fallback_flags = M.extract_flags(entries[1].command or ""),
		}

		M._cc_cache[real_cc_path] = cached
	end

	return cached.file_flags[vim.fn.resolve(filepath)] or cached.fallback_flags
end

--- Try to get the type name of the symbol under the cursor via LSP hover.
--- Returns the resolved type string (e.g. "std::basic_string<char>") or nil.
--- @return string|nil lsp_type
function M.get_type_from_lsp()
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	if #clients == 0 then
		return
	end

	local params = vim.lsp.util.make_position_params(win, clients[1].offset_encoding)
	local results = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", params, 2000)
	if not results then
		return
	end

	for _, res in pairs(results) do
		if res.result and res.result.contents then
			local value = type(res.result.contents) == "table" and (res.result.contents.value or "")
				or tostring(res.result.contents)

			-- clangd hover for variables includes "Type: `...`"
			local type_str = value:match("Type:%s*`([^`]+)`") --[[@as string]]
			if type_str then
				return type_str
			end

			-- clangd hover for struct/class declarations: "### struct `Name`" + "// In namespace X"
			local decl_name = value:match("### %w+ `([^`]+)`")
			if decl_name then
				local ns = value:match("// In namespace ([%w_:]+)") --[[@as string|nil]]
				return ns and (ns .. "::" or "") .. decl_name
			end
		end
	end
end

--- Clean a type string: strip qualifiers and template args, keep namespaces.
--- e.g. "const std::basic_string<char> &" -> "std::basic_string"
--- e.g. "instprof::EventItem" -> "instprof::EventItem"
--- @param type_str string
--- @return string no_template
function M.extract_class_name(type_str)
	return (type_str:match("^([^<]+)") or type_str):gsub("[%s%*&]+$", ""):gsub("^const%s+", ""):gsub("^volatile%s+", "")
end

function M.show()
	local ft = vim.api.nvim_get_option_value("filetype", { buf = vim.api.nvim_get_current_buf() }) --[[@as string]]
	if not vim.list_contains({ "cpp", "c" }, ft) then
		vim.notify("ClassLayout: not a C/C++ file", vim.log.levels.WARN)
		return
	end

	-- Try LSP first to resolve the actual type, fall back to word under cursor
	local lsp_type = M.get_type_from_lsp()
	local class_name --- @type string
	local full_lsp_type --- @type string
	if lsp_type then
		class_name = M.extract_class_name(lsp_type)
		-- Keep the cleaned full type (with templates) for exact matching
		local cleaned = lsp_type:gsub("[%s%*&]+$", ""):gsub("^const%s+", ""):gsub("^volatile%s+", "")
		if cleaned ~= class_name then
			full_lsp_type = cleaned
		end
	else
		class_name = vim.fn.expand("<cword>")
	end

	if class_name == "" then
		vim.notify("ClassLayout: no word under cursor", vim.log.levels.WARN)
		return
	end

	local filepath = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
	if filepath == "" then
		vim.notify("ClassLayout: buffer has no file", vim.log.levels.WARN)
		return
	end

	local compiler = M.config.compiler or "clang++"

	-- Check if compiler exists
	if vim.fn.executable(compiler) ~= 1 then
		vim.notify("ClassLayout: '" .. compiler .. "' not found in PATH", vim.log.levels.ERROR)
		return
	end

	local real_filepath = vim.fn.resolve(filepath)
	local stat = vim.uv.fs_stat(real_filepath)
	local mtime = stat and stat.mtime.sec or 0
	local cached = M._dump_cache[real_filepath]

	local output --- @type string
	if cached and cached.mtime == mtime then
		output = cached.output
	else
		--- @type string[]
		local args = { compiler, "-Xclang", "-fdump-record-layouts-complete", "-fsyntax-only" }
		if ft == "cpp" then
			table.insert(args, "-x")
			table.insert(args, "c++")
		end
		table.insert(args, filepath)

		if M.config.compile_commands then
			for _, flag in ipairs(M.get_compile_flags(filepath)) do
				table.insert(args, flag)
			end
		end

		for _, arg in ipairs(M.config.args or {}) do
			table.insert(args, arg)
		end

		local result = vim.system(args, { text = true }):wait()
		output = (result.stdout or "") .. (result.stderr or "")
		M._dump_cache[real_filepath] = { mtime = mtime, output = output }
	end

	local block = M.parse(output, class_name, full_lsp_type)
	if not block then
		vim.notify("ClassLayout: no layout found for '" .. class_name .. "'", vim.log.levels.WARN)
		return
	end

	M.open_float(block, class_name)
end

--- @param output string
--- @param class_name string
--- @param full_type_hint? string
--- @return string[]|nil match
function M.parse(output, class_name, full_type_hint)
	local blocks = {} --- @type string[][]
	local current = {} --- @type string[]
	local in_block = false

	for line in output:gmatch("[^\n]+") do
		if line:match("%*%*%* Dumping AST Record Layout") then
			if #current > 0 then
				table.insert(blocks, current)
			end
			current = {}
			in_block = true
		elseif in_block then
			table.insert(current, line)
		end
	end
	if #current > 0 then
		table.insert(blocks, current)
	end

	local unqualified_name = class_name:match("::([%w_]+)$") or class_name --[[@as string]]
	local exact_match = nil
	local stripped_match = nil
	local fallback = nil

	for _, block in ipairs(blocks) do
		local line = block[1]
		if line then
			local full_type = line:match("^%s*%d+%s*|%s*[%w]+%s+(.+)$") --[[@as string]]
			if full_type then
				full_type = full_type:gsub("%s*%(empty%)%s*$", ""):gsub("%s*%(sizeof.*$", "") --[[@as string]]
				-- Exact match with full type (including template args)
				if full_type_hint and full_type == full_type_hint then
					return block
				end
				local without_template = full_type:gsub("<.+>", "")
				if without_template == class_name then
					if not full_type_hint then
						return block
					end
					stripped_match = stripped_match or block
				end
				if not fallback and (without_template:match("::([%w_]+)$") or without_template) == unqualified_name then
					fallback = block
				end
			end
		end
	end

	return exact_match or stripped_match or fallback
end

--- @param lines string[]
--- @return string[] lines
function M.clean(lines)
	for i, line in ipairs(lines) do
		-- Strip verbose anonymous type source locations
		-- e.g. "(anonymous at /usr/bin/../lib64/.../basic_string.h:220:7)" -> "(anonymous)"
		lines[i] = line:gsub("%(anonymous at [^)]+%)", "(anonymous)")
	end
	return lines
end

--- @param lines string[]
--- @param class_name string
function M.open_float(lines, class_name)
	lines = M.clean(lines)

	local header = "Class Layout: " .. class_name
	local separator = ("-"):rep(40)

	table.insert(lines, 1, header)
	table.insert(lines, 2, separator)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

	-- Calculate window size based on content and screen
	local max_width = vim.o.columns - 4
	local content_width = 0
	for _, l in ipairs(lines) do
		content_width = math.max(content_width, #l)
	end
	local width = math.min(content_width + 2, max_width)

	-- Account for wrapped lines when calculating height
	local height = 0
	for _, l in ipairs(lines) do
		height = height + math.max(1, math.ceil(#l / width))
	end
	height = math.min(height, vim.o.lines - 4)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
	})

	-- Close on q or Esc
	local function close()
		pcall(vim.api.nvim_win_close, win, true)
	end

	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
end

return M
