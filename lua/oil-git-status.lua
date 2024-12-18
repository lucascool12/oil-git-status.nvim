local oil = require("oil")
local namespace = vim.api.nvim_create_namespace("oil-git-status")
local system = require("oil-git-status.system").system

local default_config = {
  show_ignored = true,
}

local current_config = vim.tbl_extend("force", default_config, {})

local function set_filename_status_code(filename, index_status_code, working_status_code, status)
  local dir_index = filename:find("/")
  if dir_index ~= nil then
    filename = filename:sub(1, dir_index - 1)
    local nested = string.sub(filename, dir_index):find("/")
    if nested == nil and working_status_code == "!" then
      return
    end

    if not status[filename] then
      status[filename] = {
        index = index_status_code,
        working_tree = working_status_code,
      }
    else
      if index_status_code ~= " " then
        status[filename].index = "M"
      end
      if working_status_code ~= " " then
        status[filename].working_tree = "M"
      end
    end
  else
    status[filename] = {
      index = index_status_code,
      working_tree = working_status_code,
    }
  end
end

local function parse_git_status(git_status_stdout)
  local status_lines = vim.split(git_status_stdout, "\n")
  local status = {}
  for _, line in ipairs(status_lines) do
    local index_status_code = line:sub(1, 1)
    local working_status_code = line:sub(2, 2)
    local filename = line:sub(4)

    if vim.endswith(filename, "/") then
      filename = filename:sub(1, -2)
    end

    set_filename_status_code(filename, index_status_code, working_status_code, status)
  end

  return status
end

local highlight_group_suffix_for_status_code = {
  ["!"] = "Ignored",
  ["?"] = "Untracked",
  ["A"] = "Added",
  ["C"] = "Copied",
  ["D"] = "Deleted",
  ["M"] = "Modified",
  ["R"] = "Renamed",
  ["T"] = "TypeChanged",
  ["U"] = "Unmerged",
  [" "] = "Unmodified",
}

local function highlight_group(code, index)
  local location = index and "Index" or "WorkingTree"

  return "OilGitStatus" .. location .. (highlight_group_suffix_for_status_code[code] or "Unmodified")
end

local function add_status_extmarks(buffer, status)
  vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)

  if status then
    for n = 1, vim.api.nvim_buf_line_count(buffer) do
      local entry = oil.get_entry_on_line(buffer, n)
      if entry then
        local name = entry.name
        local status_codes = status[name]

        if status_codes then
          vim.api.nvim_buf_set_extmark(buffer, namespace, n - 1, 0, {
            sign_text = status_codes.index,
            sign_hl_group = highlight_group(status_codes.index, true),
            priority = 1,
          })
          vim.api.nvim_buf_set_extmark(buffer, namespace, n - 1, 0, {
            sign_text = status_codes.working_tree,
            sign_hl_group = highlight_group(status_codes.working_tree, false),
            priority = 2,
          })
        end
      end
    end
  end
end

local function concurrent(fns, callback)
  local number_of_results = 0
  local results = {}

  for i, fn in ipairs(fns) do
    fn(function(args, ...)
      number_of_results = number_of_results + 1
      results[i] = args

      if number_of_results == #fns then
        callback(results, ...)
      end
    end)
  end
end

local function load_git_status(buffer, callback)
  local oil_url = vim.api.nvim_buf_get_name(buffer)
  local file_url = oil_url:gsub("^oil", "file")
  local path = vim.uri_to_fname(file_url)
  vim.uv.fs_stat(path, function (err, _)
    if err then
      return
    end
    concurrent({
      function(cb)
        local args = { "git", "-c", "status.relativePaths=true", "status", ".", "--short" }
        if current_config.show_ignored then
          table.insert(args, "--ignored")
        end
        system(args, { text = true, cwd = path }, cb)
      end,
    }, function(results)
      vim.schedule(function()
        local git_status_results = results[1]

        if git_status_results.code ~= 0 then
          return callback()
        end

        callback(parse_git_status(git_status_results.stdout))
      end)
    end)
  end)
end

local function validate_oil_config()
  local oil_config = require("oil.config")
  local signcolumn = oil_config.win_options.signcolumn
  if not (vim.startswith(signcolumn, "yes") or vim.startswith(signcolumn, "auto")) then
    vim.notify(
      "oil-git-status requires win_options.signcolumn to be set to at least 'yes:2' or 'auto:2'",
      vim.log.levels.WARN,
      {
        title = "oil-git-status",
      }
    )
  end
end

local function generate_highlight_groups()
  local highlight_groups = {}
  for status_code, suffix in pairs(highlight_group_suffix_for_status_code) do
    table.insert(
      highlight_groups,
      { hl_group = "OilGitStatusIndex" .. suffix, index = true, status_code = status_code }
    )
    table.insert(
      highlight_groups,
      { hl_group = "OilGitStatusWorkingTree" .. suffix, index = false, status_code = status_code }
    )
  end
  return highlight_groups
end

--- @type table<string, {hl_group: string, index: boolean, status_code: string}>
local highlight_groups = generate_highlight_groups()

--- @param config {show_ignored: boolean}
local function setup(config)
  current_config = vim.tbl_extend("force", default_config, config or {})

  validate_oil_config()

  vim.api.nvim_create_autocmd({ "FileType" }, {
    pattern = { "oil" },

    callback = function()
      local buffer = vim.api.nvim_get_current_buf()
      local current_status = nil

      if vim.b[buffer].oil_git_status_started then
        return
      end

      vim.b[buffer].oil_git_status_started = true

      vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufEnter" }, {
        buffer = buffer,

        callback = function()
          load_git_status(buffer, function(status)
            current_status = status
            add_status_extmarks(buffer, current_status)
          end)
        end,
      })

      vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
        buffer = buffer,

        callback = function()
          if current_status then
            add_status_extmarks(buffer, current_status)
          end
        end,
      })
    end,
  })

  for _, hl_group in ipairs(highlight_groups) do
    if hl_group.index then
      vim.api.nvim_set_hl(0, hl_group.hl_group, { link = "DiagnosticSignInfo", default = true })
    else
      vim.api.nvim_set_hl(0, hl_group.hl_group, { link = "DiagnosticSignWarn", default = true })
    end
  end
end

return {
  setup = setup,
  highlight_groups = highlight_groups,
}
