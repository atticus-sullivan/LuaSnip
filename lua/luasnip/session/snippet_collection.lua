-- store snippets by some key.
-- also ordered by filetype, eg.
-- {
--	key = {
--		ft1 = {...},
--		ft2 = {...}
--	}
-- }
local M = {
	invalidated_count = 0,
}

do
	local auto
	function auto(self, key, depth)
		print("auto", key)
		local t = {}
		if depth ~= 1 then
			setmetatable(t, {
			-- TODO not sure if this is that nice, creating a new function on
			-- each time (lua-users does this by a seperate mamber)
				__index = function(s,k) return auto(s,k,depth-1) end,
			})
		end
		self[key] = t
		return t
	end
	function AutomagicTable(depth)
		return setmetatable({}, {__index = function(s,k) return auto(s,k, depth or 0) end})
	end
end
-- TODO use AutomagicTable with by_prio.autosnippets(2), by_prio.snippets(2)
-- TODO use AutomagicTable with by_ft.autosnippets(1), by_ft.snippets(1)

local by_key = {}

-- stores snippets/autosnippets by priority.
local by_prio = {
	snippets = {
		-- stores sorted keys, eg 1=1000, 2=1010, 3=1020,..., used for
		-- quick iterating.
		order = {
			1000,
		},
		[1000] = {
			all = {},
		},
	},
	autosnippets = {
		order = {
			1000,
		},
		[1000] = {
			all = {},
		},
	},
}

-- this isn't in util/util.lua due to circular dependencies. Would be cleaner
-- to include it there, but it's alright to keep here for now.
--
-- this is linear, binary search would certainly be nicer, but for our
-- applications this should easily be enough.
local function insert_sorted_unique(t, k)
	local tbl_len = #t

	local i = 1
	-- k does not yet exist in table, find first i so t[i] > k.
	for _ = 1, tbl_len do
		if t[i] > k then
			break
		end
		i = i + 1
	end

	-- shift all t[j] with j > i back by one.
	for j = tbl_len, i, -1 do
		t[j + 1] = t[j]
	end

	t[i] = k
end

local sort_mt = {
	__newindex = function(t, k, v)
		-- update priority-order as well.
		insert_sorted_unique(t.order, k)
		rawset(t, k, v)
	end,
}

setmetatable(by_prio.snippets, sort_mt)
setmetatable(by_prio.autosnippets, sort_mt)

-- iterate priorities, high to low.
local function prio_iter(type)
	local order = by_prio[type].order
	local i = #order + 1

	return function()
		i = i - 1
		if i > 0 then
			return by_prio[type][order[i]]
		end
		return nil
	end
end

local by_ft = {
	snippets = {},
	autosnippets = {},
}

local by_id = setmetatable({}, {
	-- make by_id-table weak (v).
	-- this means it won't be necessary to explicitly nil values (snippets) in
	-- this table.
	__mode = "v",
})

-- ft: any filetype, optional.
function M.clear_snippets(ft)
	if ft then
		-- remove all ft-(auto)snippets for all priorities.
		-- set to empty table so we won't need to rebuild/clear the order-table.
		for _, prio in ipairs(by_prio.snippets.order) do
			by_prio.snippets[prio][ft] = {}
		end
		for _, prio in ipairs(by_prio.autosnippets.order) do
			by_prio.autosnippets[prio][ft] = {}
		end

		by_ft.snippets[ft] = nil
		by_ft.autosnippets[ft] = nil

		for key, _ in pairs(by_key) do
			by_key[key][ft] = nil
		end
	else
		-- remove all (auto)snippets for all priorities.
		for _, prio in ipairs(by_prio.snippets.order) do
			by_prio.snippets[prio] = {}
		end
		for _, prio in ipairs(by_prio.autosnippets.order) do
			by_prio.autosnippets[prio] = {}
		end

		by_ft.snippets = {}
		by_ft.autosnippets = {}
		by_key = {}
	end
end

function M.match_snippet(line, fts, type)
	local expand_params

	for prio_by_ft in prio_iter(type) do
		for _, ft in ipairs(fts) do
			for _, snip in ipairs(prio_by_ft[ft] or {}) do
				expand_params = snip:matches(line)
				if expand_params then
					-- return matching snippet and table with expand-parameters.
					return snip, expand_params
				end
			end
		end
	end

	return nil
end

local function without_invalidated(snippets_by_ft)
	local new_snippets = {}

	for ft, ft_snippets in pairs(snippets_by_ft) do
		new_snippets[ft] = {}
		for _, snippet in ipairs(ft_snippets) do
			if not snippet.invalidated then
				table.insert(new_snippets[ft], snippet)
			end
		end
	end

	return new_snippets
end

function M.clean_invalidated(opts)
	if opts.inv_limit then
		if M.invalidated_count <= opts.inv_limit then
			return
		end
	end

	-- remove invalidated snippets from all tables.
	for _, type_snippets in pairs(by_prio) do
		for key, prio_snippets in pairs(type_snippets) do
			if key ~= "order" then
				type_snippets[key] = without_invalidated(prio_snippets)
			end
		end
	end

	for type, type_snippets in pairs(by_ft) do
		by_ft[type] = without_invalidated(type_snippets)
	end

	for key, key_snippets in pairs(by_key) do
		by_key[key] = without_invalidated(key_snippets)
	end

	M.invalidated_count = 0
end

local function invalidate_snippets(snippets_by_ft)
	for _, ft_snippets in pairs(snippets_by_ft) do
		for _, snip in ipairs(ft_snippets) do
			snip:invalidate()
		end
	end
	M.clean_invalidated({ inv_limit = 100 })
end

local current_id = 0
-- snippets like {ft1={<snippets>}, ft2={<snippets>}}, opts should be properly
-- initialized with default values.
function M.add_snippets(snippets, opts)
	for ft, ft_snippets in pairs(snippets) do
		local prios = {
			autosnippets = {},
			snippets = {}
		}
		local types = {
			autosnippets = false,
			snippets = false
		}

		-- collect which tables should be added
		-- and do some initialization
		for _, snip in ipairs(ft_snippets) do
			snip.priority = opts.override_priority
				or (snip.priority ~= -1 and snip.priority)
				or opts.default_priority
				or 1000

			-- TODO
			-- prefer more specific option I guess.
			-- snip.autotriggered may not acutally default to nil, that will
			-- cause problems with snippetProxy.
			snip.autotriggered = snip.autotriggered ~= nil and snip.autotriggered or opts.type == "autosnippets"

			snip.id = current_id
			current_id = current_id + 1

			types[snip.autotriggered and "autosnippets" or "snippets"] = true
			prios[snip.autotriggered and "autosnippets" or "snippets"][snip.priority] = true
		end

		-- create necessary tables
		for _, typename in ipairs({"autosnippets", "snippets"}) do
			-- only create table if there are snippets for it.
			if types[typename] then
				if not by_ft[typename][ft] then
					by_ft[typename][ft] = {}
				end

				local prio_snippet_table = by_prio[typename]
				for prio, _ in pairs(prios[typename]) do
					if not prio_snippet_table[prio] then
						prio_snippet_table[prio] = {
							[ft] = {}
						}
					elseif not prio_snippet_table[prio][ft] then
						prio_snippet_table[prio][ft] = {}
					end
				end
			end
		end

		-- do the actual insertion
		for _, snip in ipairs(ft_snippets) do
			table.insert(by_prio[snip.autotriggered and "autosnippets" or "snippets"][snip.priority][ft], snip)
			table.insert(by_ft[snip.autotriggered and "autosnippets" or "snippets"][ft], snip)
			by_id[snip.id] = snip
		end
	end

	if opts.key then
		if by_key[opts.key] then
			invalidate_snippets(by_key[opts.key])
		end
		by_key[opts.key] = snippets
	end
end

-- ft may be nil, type not.
function M.get_snippets(ft, type)
	if ft then
		return by_ft[type][ft]
	else
		return by_ft[type]
	end
end

function M.get_id_snippet(id)
	return by_id[id]
end

return M
