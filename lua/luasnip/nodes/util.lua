local util = require("luasnip.util.util")
local ext_util = require("luasnip.util.ext_opts")
local types = require("luasnip.util.types")
local key_indexer = require("luasnip.nodes.key_indexer")

local function subsnip_init_children(parent, children)
	for _, child in ipairs(children) do
		if child.type == types.snippetNode then
			child.snippet = parent.snippet
			child:resolve_child_ext_opts()
		end
		child:resolve_node_ext_opts()
		child:subsnip_init()
	end
end

local function init_child_positions_func(
	key,
	node_children_key,
	child_func_name
)
	-- maybe via load()?
	return function(node, position_so_far)
		node[key] = vim.deepcopy(position_so_far)
		local pos_depth = #position_so_far + 1

		for indx, child in ipairs(node[node_children_key]) do
			position_so_far[pos_depth] = indx
			child[child_func_name](child, position_so_far)
		end
		-- undo changes to position_so_far.
		position_so_far[pos_depth] = nil
	end
end

local function make_args_absolute(args, parent_insert_position, target)
	for i, arg in ipairs(args) do
		if type(arg) == "number" then
			-- the arg is a number, should be interpreted relative to direct
			-- parent.
			local t = vim.deepcopy(parent_insert_position)
			table.insert(t, arg)
			target[i] = { absolute_insert_position = t }
		else
			-- insert node, absolute_indexer, or key itself, node's
			-- absolute_insert_position may be nil, check for that during
			-- usage.
			target[i] = arg
		end
	end
end

local function wrap_args(args)
	-- stylua: ignore
	if type(args) ~= "table" or
	  (type(args) == "table" and args.absolute_insert_position) or
	  key_indexer.is_key(args) then
		-- args is one single arg, wrap it.
		return { args }
	else
		return args
	end
end

local function get_nodes_between(parent, child)
	local nodes = {}

	-- special case for nodes without absolute_position (which is only
	-- start_node).
	if child.pos == -1 then
		-- no nodes between, only child.
		nodes[1] = child
		return nodes
	end

	local child_pos = child.absolute_position

	local indx = #parent.absolute_position + 1
	local prev = parent
	while child_pos[indx] do
		local next = prev:resolve_position(child_pos[indx])
		nodes[#nodes + 1] = next
		prev = next
		indx = indx + 1
	end

	return nodes
end

-- assumes that children of child are not even active.
-- If they should also be left, do that separately.
local function leave_nodes_between(parent, child, no_move)
	local nodes = get_nodes_between(parent, child)
	if #nodes == 0 then
		return
	end

	-- reverse order, leave child first.
	for i = #nodes, 2, -1 do
		-- this only happens for nodes where the parent will also be left
		-- entirely (because we stop at nodes[2], and handle nodes[1]
		-- separately)
		nodes[i]:input_leave(no_move)
		nodes[i-1]:input_leave_children()
	end
	nodes[1]:input_leave(no_move)
end

local function enter_nodes_between(parent, child, no_move)
	local nodes = get_nodes_between(parent, child)
	if #nodes == 0 then
		return
	end

	for i = 1, #nodes-1 do
		-- only enter children for nodes before the last (lowest) one.
		nodes[i]:input_enter(no_move)
		nodes[i]:input_enter_children()
	end
	nodes[#nodes]:input_enter(no_move)
end

local function select_node(node)
	local node_begin, node_end = node.mark:pos_begin_end_raw()
	util.any_select(node_begin, node_end)
end

local function print_dict(dict)
	print(vim.inspect(dict, {
		process = function(item, path)
			if path[#path] == "node" or path[#path] == "dependent" then
				return "node@" .. vim.inspect(item.absolute_position)
			elseif path[#path] ~= vim.inspect.METATABLE then
				return item
			end
		end,
	}))
end

local function init_node_opts(opts)
	local in_node = {}
	if not opts then
		opts = {}
	end

	-- copy once here, the opts might be reused.
	in_node.node_ext_opts =
		ext_util.complete(vim.deepcopy(opts.node_ext_opts or {}))

	if opts.merge_node_ext_opts == nil then
		in_node.merge_node_ext_opts = true
	else
		in_node.merge_node_ext_opts = opts.merge_node_ext_opts
	end

	in_node.key = opts.key

	return in_node
end

local function snippet_extend_context(arg, extend)
	if type(arg) == "string" then
		arg = { trig = arg }
	end

	-- both are table or nil now.
	return vim.tbl_extend("keep", arg or {}, extend or {})
end

local function wrap_context(context)
	if type(context) == "string" then
		return { trig = context }
	else
		return context
	end
end

local function linkable_node(node)
	-- node.type has to be one of insertNode, exitNode.
	return vim.tbl_contains({types.insertNode, types.exitNode}, rawget(node, "type"))
end

-- mainly used internally, by binarysearch_pos.
-- these are the nodes that are definitely not linkable, there are nodes like
-- dynamicNode or snippetNode that might be linkable, depending on their
-- content. Could look into that to make this more complete, but that does not
-- feel appropriate (higher runtime), most cases should be served well by this
-- heuristic.
local function non_linkable_node(node)
	return vim.tbl_contains({types.textNode, types.functionNode}, rawget(node, "type"))
end
-- return whether a node is certainly (not) interactive.
-- Coincindentially, the same nodes as (non-)linkable ones, but since there is a
-- semantic difference, use separate names.
local interactive_node = linkable_node
local non_interactive_node = non_linkable_node

local function prefer_nodes(prefer_func, reject_func)
	return function(cmp_mid_to, cmp_mid_from, mid_node)
		local reject_mid = reject_func(mid_node)
		local prefer_mid = prefer_func(mid_node)

		-- if we can choose which node to continue in, prefer the one that
		-- may be linkable/interactive.
		if cmp_mid_to == 0 and reject_mid then
			return true, false
		elseif cmp_mid_from == 0 and reject_mid then
			return false, true
		elseif (cmp_mid_to == 0 or cmp_mid_from == 0) and prefer_mid then
			return false, false
		else
			return cmp_mid_to >= 0, cmp_mid_from < 0
		end
	end
end

-- functions for resolving conflicts, if `pos` is on the boundary of two nodes.
-- Return whether to continue behind or before mid (in that order).
-- At most one of those may be true, of course.
local binarysearch_preference = {
	outside = function(cmp_mid_to, cmp_mid_from, _)
		return cmp_mid_to >= 0, cmp_mid_from <= 0
	end,
	linkable = prefer_nodes(linkable_node, non_linkable_node),
	interactive = prefer_nodes(interactive_node, non_interactive_node)
}
-- `nodes` is a list of nodes ordered by their occurrence in the buffer.
-- `pos` is a row-column-tuble, byte-columns, and we return the node the LEFT
-- EDGE(/side) of `pos` is inside.
-- This convention is chosen since a snippet inserted at `pos` will move the
-- character at `pos` to the right.
-- The exact meaning of "inside" can be influenced with `respect_rgravs` and
-- `boundary_resolve_mode`:
-- * if `respect_rgravs` is true, "inside" emulates the shifting-behaviour of
--   extmarks:
--   First of all, we compare the left edge of `pos` with the left/right edges
--   of from/to, depending on rgrav.
--   If the left edge is <= left/right edge of from, and < left/right edge of
--   to, `pos` is inside the node.
--
-- * if `respect_rgravs` is false, pos has to be fully inside a node to be
--   considered inside it. If pos is on the left endpoint, it is considered to be
--   left of the node, and likewise for the right endpoint.
--
-- * `boundary_resolve_mode` changes how a position on the boundary of a node
-- is treated:
-- * for `"prefer_linkable/interactive"`, we assume that the nodes in `nodes` are
-- contiguous, and prefer falling into the previous/next node if `pos` is on
-- mid's boundary, and mid is not linkable/interactie.
-- This way, we are more likely to return a node that can handle a new
-- snippet/is interactive.
-- * `"prefer_outside"` makes sense when the nodes are not contiguous, and we'd
-- like to find a position between two nodes.  
-- This mode makes sense for finding the snippet a new snippet should be
-- inserted in, since we'd like to prefer inserting before/after a snippet, if
-- the position is ambiguous.
-- 
-- In general:  
-- These options are useful for making this function more general: When
-- searching in the contiguous nodes of a snippet, we'd like this routine to
-- return any of them (obviously the one pos is inside/or on the border of, and
-- we'd like to prefer returning a node that can be linked), but in no case
-- fail.
-- However! when searching the top-level snippets with the intention of finding
-- the snippet/node a new snippet should be expanded inside, it seems better to
-- shift an existing snippet to the right/left than expand the new snippet
-- inside it (when the expand-point is on the boundary).
local function binarysearch_pos(nodes, pos, respect_rgravs, boundary_resolve_mode)
	local left = 1
	local right = #nodes

	-- actual search-routine from
	-- https://github.com/Roblox/Wiki-Lua-Libraries/blob/master/StandardLibraries/BinarySearch.lua
	if #nodes == 0 then
		return nil, 1
	end
	while true do
		local mid = left + math.floor((right-left)/2)
		local mid_mark = nodes[mid].mark
		local ok, mid_from, mid_to = pcall(mid_mark.pos_begin_end_raw, mid_mark)

		if not ok then
			-- error while running this procedure!
			-- return false (because I don't know how to do this with `error`
			-- and the offending node).
			-- (returning data instead of a message in `error` seems weird..)
			return false, mid
		end

		if respect_rgravs then
			-- if rgrav is set on either endpoint, the node considers its
			-- endpoint to be the right, not the left edge.
			-- We only want to work with left edges but since the right edge is
			-- the left edge of the next column, this is not an issue :)
			-- TODO: does this fail with multibyte characters???
			if mid_mark:get_rgrav(-1) then
				mid_from[2] = mid_from[2] + 1
			end
			if mid_mark:get_rgrav(1) then
				mid_to[2] = mid_to[2] + 1
			end
		end

		local cmp_mid_to = util.pos_cmp(pos, mid_to)
		local cmp_mid_from = util.pos_cmp(pos, mid_from)

		local cont_behind_mid, cont_before_mid = boundary_resolve_mode(cmp_mid_to, cmp_mid_from, nodes[mid])

		if cont_behind_mid then
			-- make sure right-left becomes smaller.
			left = mid + 1
			if left > right then
				return nil, mid + 1
			end
		elseif cont_before_mid then
			-- continue search on left side
			right = mid - 1
			if left > right then
				return nil, mid
			end
		else
			-- greater-equal than mid_from, smaller or equal to mid_to => left edge
			-- of pos is inside nodes[mid] :)
			return nodes[mid], mid
		end
	end
end

-- a and b have to be in the same snippet, return their first (as seen from
-- them) common parent.
local function first_common_node(a, b)
	local a_pos = a.absolute_position
	local b_pos = b.absolute_position

	-- last as seen from root.
	local i = 0
	local last_common = a.parent.snippet
	-- invariant: last_common is parent of both a and b.
	while (a_pos[i+1] ~= nil) and a_pos[i + 1] == b_pos[i + 1] do
		last_common = last_common:resolve_position(a_pos[i + 1])
		i = i + 1
	end

	return last_common
end

-- roots at depth 0, children of root at depth 1, their children at 2, ...
local function snippettree_depth(snippet)
	local depth = 0
	while snippet.parent_node ~= nil do
		snippet = snippet.parent_node.parent.snippet
		depth = depth + 1
	end
	return depth
end

-- find the first common snippet a and b have on their respective unique paths
-- to the snippet-roots.
-- if no common ancestor exists (ie. a and b are roots of their buffers'
-- forest, or just in different trees), return nil.
-- in both cases, the paths themselves are returned as well.
-- The common ancestor is included in the paths, except if there is none.
-- Instead of storing the snippets in the paths, they are represented by the
-- node which contains the next-lower snippet in the path (or `from`/`to`, if it's
-- the first node of the path)
-- This is a bit complicated, but this representation contains more information
-- (or, more easily accessible information) than storing snippets: the
-- immediate parent of the child along the path cannot be easily retrieved if
-- the snippet is stored, but the snippet can be easily retrieved if the child
-- is stored (.parent.snippet).
-- And, so far this is pretty specific to refocus, and thus modeled so there is
-- very little additional work in that method.
-- At most one of a,b may be nil.
local function first_common_snippet_ancestor_path(a, b)
	local a_path = {}
	local b_path = {}

	-- general idea: we find the depth of a and b, walk upward with the deeper
	-- one until we find its first ancestor with the same depth as the less
	-- deep snippet, and then follow both paths until they arrive at the same
	-- snippet (or at the root of their respective trees).
	-- if either is nil, we treat it like it's one of the roots (the code will
	-- behave correctly this way, and return an empty path for the nil-node,
	-- and the correct path for the non-nil one).
	local a_depth = a ~= nil and snippettree_depth(a) or 0
	local b_depth = b ~= nil and snippettree_depth(b) or 0

	-- bit subtle: both could be 0, but one could be nil.
	-- deeper should not be nil! (this allows us to do the whole walk for the
	-- non-nil node in the first for-loop, as opposed to needing some special
	-- handling).
	local deeper, deeper_path, other, other_path
	if b == nil or (a ~= nil and a_depth > b_depth) then
		deeper = a
		other = b
		deeper_path = a_path
		other_path = b_path
	else
		-- we land here if `b ~= nil and (a == nil or a_depth >= b_depth)`, so
		-- exactly what we want.
		deeper = b
		other = a
		deeper_path = b_path
		other_path = a_path
	end

	for _ = 1, math.abs(a_depth - b_depth) do
		table.insert(deeper_path, deeper.parent_node)
		deeper = deeper.parent_node.parent.snippet
	end
	-- here: deeper and other are at the same depth.
	-- If we walk upwards one step at a time, they will meet at the same
	-- parent, or hit their respective roots.

	-- deeper can't be nil, if other is, we are done here and can return the
	-- paths (and there is no shared node)
	if other == nil then
		return nil, a_path, b_path
	end
	-- beyond here, deeper and other are not nil.

	while deeper ~= other do
		if deeper.parent_node == nil then
			-- deeper is at depth 0 => other as well => both are roots.
			return nil, a_path, b_path
		end

		table.insert(deeper_path, deeper.parent_node)
		table.insert(other_path, other.parent_node)

		-- walk one step towards root.
		deeper = deeper.parent_node.parent.snippet
		other = other.parent_node.parent.snippet
	end

	-- either one will do here.
	return deeper, a_path, b_path
end

-- removes focus from `from` and upwards up to the first common ancestor
-- (node!) of `from` and `to`, and then focuses nodes between that f.c.a. and
-- `to`.
-- Requires that `from` is currently entered/focused, and that no snippet
-- between `to` and its root is invalid.
local function refocus(from, to)
	if from == nil and to == nil then
		-- absolutely nothing to do, should not happen.
		return
	end
	-- pass nil if from/to is nil.
	-- if either is nil, first_common_node is nil, and the corresponding list empty.
	local first_common_snippet, from_snip_path, to_snip_path = first_common_snippet_ancestor_path(from and from.parent.snippet, to and to.parent.snippet)

	-- we want leave/enter_path to be s.t. leaving/entering all nodes between
	-- each entry and its snippet (and the snippet itself) will leave/enter all
	-- nodes between the first common snippet (or the root-snippet) and
	-- from/to.
	-- Then, the nodes between the first common node and the respective
	-- entrypoints (also nodes) into the first common snippet will have to be
	-- left/entered, which is handled by final_leave_/first_enter_/common_node.

	-- from, to are not yet in the paths.
	table.insert(from_snip_path, 1, from)
	table.insert(to_snip_path, 1, to)

	-- determine how far to leave: if there is a common snippet, only up to the
	-- first (from from/to) common node, otherwise leave the one snippet, and
	-- enter the other completely.
	local final_leave_node, first_enter_node, common_node
	if first_common_snippet then
		-- there is a common snippet => there is a common node => we have to
		-- set final_leave_node, first_enter_node, and common_node.
		final_leave_node = from_snip_path[#from_snip_path]
		first_enter_node = to_snip_path[#to_snip_path]
		common_node = first_common_node(first_enter_node, final_leave_node)

		-- Also remove these last nodes from the lists, their snippet is not
		-- supposed to be left entirely.
		from_snip_path[#from_snip_path] = nil
		to_snip_path[#to_snip_path] = nil
	end

	-- now do leave/enter, set no_move on all operations.
	-- if one of from/to was nil, there are no leave/enter-operations done for
	-- it (from/to_snip_path is {}, final_leave/first_enter_* is nil).

	-- leave_children on all from-nodes except the original from.
	if #from_snip_path > 0 then
		-- we know that the first node is from.
		local ok1 = pcall(leave_nodes_between, from.parent.snippet, from, true)
		local ok2 = pcall(from.parent.snippet.input_leave, from.parent.snippet, true)
		if not ok1 or not ok2 then
			from.parent.snippet:remove_from_jumplist()
		end
	end
	for i = 2, #from_snip_path do
		local node = from_snip_path[i]
		local ok1 = pcall(node.input_leave_children, node)
		local ok2 = pcall(leave_nodes_between, node.parent.snippet, node, true)
		local ok3 = pcall(node.parent.snippet.input_leave, node.parent.snippet, true)
		if not ok1 or not ok2 or not ok3 then
			from.parent.snippet:remove_from_jumplist()
		end
	end

	-- this leave, and the following enters should be safe: the path to `to`
	-- was verified via extmarks_valid.
	if common_node and final_leave_node then
		final_leave_node:input_leave_children()
		leave_nodes_between(common_node, final_leave_node, true)
	end

	if common_node and first_enter_node then
		-- In general we assume that common_node is active when we are here.
		-- This may not be the case if we are currently inside the i(0) or
		-- i(-1), since the snippet might be the common node and in this case,
		-- it is inactive.
		-- This means that, if we want to enter a non-exitNode, we have to
		-- explicitly activate the snippet for all jumps to behave correctly.
		-- (if we enter a i(0)/i(-1), this is not necessary, of course).
		if final_leave_node.type == types.exitNode and first_enter_node.type ~= types.exitNode then
			common_node:input_enter()
		end
		-- symmetrically, entering an i(0)/i(-1) requires leaving the snippet.
		if final_leave_node.type ~= types.exitNode and first_enter_node.type == types.exitNode then
			common_node:input_leave()
		end
		enter_nodes_between(common_node, first_enter_node, true)
		first_enter_node:input_enter_children()
	end

	-- same here, input_enter_children has to be called manually for the
	-- to-nodes of the path we are entering (since enter_nodes_between does not
	-- call it for the child-node).

	for i = #to_snip_path, 2, -1 do
		local node = to_snip_path[i]
		node.parent.snippet:input_enter(true)
		enter_nodes_between(node.parent.snippet, node, true)
		node:input_enter_children()
	end
	if #to_snip_path > 0 then
		-- we know that the first node is from.
		enter_nodes_between(to.parent.snippet, to, true)
		to.parent.snippet:input_enter(true)
	end
end

local function generic_extmarks_valid(node, child)
	-- valid if
	-- - extmark-extents match.
	-- - current choice is valid
	local ok1, self_from, self_to = pcall(node.mark.pos_begin_end_raw, node.mark)
	local ok2, child_from, child_to = pcall(child.mark.pos_begin_end_raw, child.mark)

	if not ok1 or not ok2 or util.pos_cmp(self_from, child_from) ~= 0 or util.pos_cmp(self_to, child_to) ~= 0 then
		return false
	end
	return child:extmarks_valid()
end

return {
	subsnip_init_children = subsnip_init_children,
	init_child_positions_func = init_child_positions_func,
	make_args_absolute = make_args_absolute,
	wrap_args = wrap_args,
	wrap_context = wrap_context,
	get_nodes_between = get_nodes_between,
	leave_nodes_between = leave_nodes_between,
	enter_nodes_between = enter_nodes_between,
	select_node = select_node,
	print_dict = print_dict,
	init_node_opts = init_node_opts,
	snippet_extend_context = snippet_extend_context,
	linkable_node = linkable_node,
	binarysearch_pos = binarysearch_pos,
	binarysearch_preference = binarysearch_preference,
	refocus = refocus,
	generic_extmarks_valid = generic_extmarks_valid
}
