local M = {}

M.config = {
	keymap = "<leader>cl",
	compiler = "clang",
	args = {},
	compile_commands = true, -- auto-detect flags from compile_commands.json
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "cpp", "c", "objc", "objcpp" },
		callback = function(ev)
			vim.keymap.set("n", M.config.keymap, M.show, {
				buffer = ev.buf,
				desc = "Show class memory layout",
			})
		end,
	})
end

--- Walk up from `start_path` looking for compile_commands.json.
--- Returns the path to compile_commands.json or nil.
function M.find_compile_commands(start_path)
	local dir = vim.fn.fnamemodify(start_path, ":h")
	local prev = nil
	while dir and dir ~= prev do
		local candidate = dir .. "/compile_commands.json"
		if vim.fn.filereadable(candidate) == 1 then
			return candidate
		end
		prev = dir
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	return nil
end

--- Extract compiler flags relevant to layout dumping from a compile_commands.json entry.
--- Keeps -I, -D, -std, -isystem flags and drops everything else.
function M.extract_flags(command_str)
	local flags = {}
	-- Match flags that take a value either as -Xval or -X val
	local i = 1
	local tokens = {}
	for token in command_str:gmatch("%S+") do
		tokens[#tokens + 1] = token
	end

	-- Skip the compiler (first token) and the source file / -o / -c tokens
	i = 2
	while i <= #tokens do
		local t = tokens[i]
		if t:match("^%-D") or t:match("^%-std") then
			flags[#flags + 1] = t
		elseif t:match("^%-I") then
			if t == "-I" then
				-- value is next token
				i = i + 1
				if tokens[i] then
					flags[#flags + 1] = "-I" .. tokens[i]
				end
			else
				flags[#flags + 1] = t
			end
		elseif t == "-isystem" then
			i = i + 1
			if tokens[i] then
				flags[#flags + 1] = "-isystem"
				flags[#flags + 1] = tokens[i]
			end
		end
		i = i + 1
	end
	return flags
end

-- Cache: keyed by compile_commands.json path
-- { path = { mtime = number, file_flags = { [resolved_path] = flags }, fallback_flags = flags } }
M._cc_cache = {}

-- Cache: keyed by resolved filepath
-- { path = { mtime = number, output = string } }
M._dump_cache = {}

--- Get compiler flags from compile_commands.json for the given filepath.
--- For header files (not in compile_commands.json), falls back to flags from any entry in the same project.
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

	local cached = M._cc_cache[real_cc_path]
	if not cached or cached.mtime ~= mtime then
		local content = vim.fn.readfile(cc_path)
		if not content or #content == 0 then
			return {}
		end

		local ok, entries = pcall(vim.json.decode, table.concat(content, "\n"))
		if not ok or not entries or #entries == 0 then
			return {}
		end

		-- Build lookup table: resolved file path -> flags
		local file_flags = {}
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

	local real_filepath = vim.fn.resolve(filepath)
	return cached.file_flags[real_filepath] or cached.fallback_flags
end

--- Try to get the type name of the symbol under the cursor via LSP hover.
--- Returns the resolved type string (e.g. "std::basic_string<char>") or nil.
function M.get_type_from_lsp()
	local clients = vim.lsp.get_clients({ bufnr = 0 })
	if #clients == 0 then
		return nil
	end

	local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
	local results = vim.lsp.buf_request_sync(0, "textDocument/hover", params, 2000)
	if not results then
		return nil
	end

	for _, res in pairs(results) do
		if res.result and res.result.contents then
			local value = ""
			if type(res.result.contents) == "table" then
				value = res.result.contents.value or ""
			else
				value = tostring(res.result.contents)
			end

			-- clangd hover for variables includes "Type: `...`"
			local type_str = value:match("Type:%s*`([^`]+)`")
			if type_str then
				return type_str
			end

			-- clangd hover for struct/class declarations: "### struct `Name`" + "// In namespace X"
			local decl_name = value:match("### %w+ `([^`]+)`")
			if decl_name then
				local ns = value:match("// In namespace ([%w_:]+)")
				if ns then
					return ns .. "::" .. decl_name
				end
				return decl_name
			end
		end
	end

	return nil
end

--- Clean a type string: strip qualifiers and template args, keep namespaces.
--- e.g. "const std::basic_string<char> &" -> "std::basic_string"
--- e.g. "instprof::EventItem" -> "instprof::EventItem"
function M.extract_class_name(type_str)
	local without_template = type_str:match("^([^<]+)") or type_str
	without_template = without_template:gsub("[%s%*&]+$", "")
	without_template = without_template:gsub("^const%s+", "")
	without_template = without_template:gsub("^volatile%s+", "")
	return without_template
end

function M.resolve_typedef_name(file, line_nr)
	local ok, lines = pcall(vim.fn.readfile, file)
	if not ok or not lines then
		return nil
	end
	local depth = 0
	for i = line_nr, #lines do
		for _ in lines[i]:gmatch("{") do
			depth = depth + 1
		end
		for _ in lines[i]:gmatch("}") do
			depth = depth - 1
		end
		if depth <= 0 then
			return lines[i]:match("}%s*(%w+)%s*;")
		end
	end
	return nil
end

function M.show()
	local ft = vim.bo.filetype
	if ft ~= "cpp" and ft ~= "c" then
		vim.notify("ClassLayout: not a C/C++ file", vim.log.levels.WARN)
		return
	end

	-- Try LSP first to resolve the actual type, fall back to word under cursor
	local lsp_type = M.get_type_from_lsp()
	local class_name
	local full_lsp_type
	if lsp_type then
		class_name = M.extract_class_name(lsp_type)
		-- Keep the cleaned full type (with templates) for exact matching
		local cleaned = lsp_type:gsub("[%s%*&]+$", "")
		cleaned = cleaned:gsub("^const%s+", "")
		cleaned = cleaned:gsub("^volatile%s+", "")
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

	local filepath = vim.api.nvim_buf_get_name(0)
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

	local output
	if M._dump_cache[real_filepath] and M._dump_cache[real_filepath].mtime == mtime then
		output = M._dump_cache[real_filepath].output
	else
		local args = { compiler, "-Xclang", "-fdump-record-layouts-complete", "-fsyntax-only" }
		if ft == "cpp" then
			args[#args + 1] = "-x"
			args[#args + 1] = "c++"
		end
		args[#args + 1] = filepath

		if M.config.compile_commands then
			for _, flag in ipairs(M.get_compile_flags(filepath)) do
				args[#args + 1] = flag
			end
		end

		for _, arg in ipairs(M.config.args or {}) do
			args[#args + 1] = arg
		end

		local result = vim.system(args, { text = true }):wait()
		output = result.stdout or ""
		M._dump_cache[real_filepath] = { mtime = mtime, output = output }
	end

	local block = M.parse(output, class_name, full_lsp_type)

	if not block then
		vim.notify("ClassLayout: no layout found for '" .. class_name .. "'", vim.log.levels.WARN)
		return
	end

	M.open_float(block, class_name)
end

function M.parse(output, class_name, full_type_hint)
	local blocks = {}
	local current = {}
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

	local unqualified_name = class_name:match("::([%w_]+)$") or class_name
	local exact_match = nil
	local stripped_match = nil
	local fallback = nil
	local unnamed_blocks = {}

	for _, block in ipairs(blocks) do
		local line = block[1]
		if line then
			local full_type = line:match("^%s*%d+%s*|%s*[%w]+%s+(.+)$")
			if full_type then
				full_type = full_type:gsub("%s*%(empty%)%s*$", "")
				full_type = full_type:gsub("%s*%(sizeof.*$", "")

				local file, line_nr = full_type:match("%(unnamed at (.+):(%d+):%d+%)")
				if file and line_nr then
					unnamed_blocks[#unnamed_blocks + 1] = { block = block, file = file, line_nr = tonumber(line_nr) }
				else
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
					if not fallback then
						local unqualified = without_template:match("::([%w_]+)$") or without_template
						if unqualified == unqualified_name then
							fallback = block
						end
					end
				end
			end
		end
	end

	if not (exact_match or stripped_match or fallback) then
		for _, entry in ipairs(unnamed_blocks) do
			local typedef_name = M.resolve_typedef_name(entry.file, entry.line_nr)
			if typedef_name and (typedef_name == class_name or typedef_name == unqualified_name) then
				return entry.block
			end
		end
	end

	return exact_match or stripped_match or fallback
end

--- Strip verbose anonymous type source locations and extract sizeof/align metadata.
function M.clean(raw_lines)
	local lines = {}
	local sizeof, align
	for _, line in ipairs(raw_lines) do
		line = line:gsub("%(anonymous at [^)]+%)", "(anonymous)")
		line = line:gsub("%(unnamed at [^)]+%)", "(unnamed)")
		local s, a = line:match("%[sizeof=(%d+).*align=(%d+)")
		if s then
			sizeof, align = s, a
		elseif line:match("^%s*%d+%s*|%s*[%w]+%s+%(unnamed%)") then
		-- skip redundant top-level unnamed struct line
		elseif not line:match("^%s*|%s*%[") then
			lines[#lines + 1] = line
		end
	end
	return lines, sizeof, align
end

function M.open_float(lines, class_name)
	local sizeof, align
	lines, sizeof, align = M.clean(lines)

	local header = class_name
	if sizeof then
		header = header .. " (" .. sizeof .. " bytes, align " .. align .. ")"
	end
	local separator = string.rep("-", math.max(#header, 40))

	table.insert(lines, 1, header)
	table.insert(lines, 2, separator)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

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
	local close = function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
end

return M
