-- Test longer-running sessions of snippets.
-- Should cover things like deletion (handle removed text gracefully) and insertion.
local helpers = require("test.functional.helpers")(after_each)
local exec_lua, feed, exec = helpers.exec_lua, helpers.feed, helpers.exec
local ls_helpers = require("helpers")
local Screen = require("test.functional.ui.screen")

local function expand()
	exec_lua("ls.expand()")
end
local function jump(dir)
	exec_lua("ls.jump(...)", dir)
end
local function change(dir)
	exec_lua("ls.change_choice(...)", dir)
end

describe("session", function()
	local screen

	before_each(function()
		helpers.clear()
		ls_helpers.setup_jsregexp()
		ls_helpers.session_setup_luasnip({ hl_choiceNode = true })

		-- add a rather complicated snippet.
		-- It may be a bit hard to grasp, but will cover lots and lots of
		-- edge-cases.
		exec_lua([[
			local function jdocsnip(args, _, old_state)
				local nodes = {
					t({"/**"," * "}),
					old_state and i(1, old_state.descr:get_text()) or i(1, {"A short Description"}),
					t({"", ""})
				}

				-- These will be merged with the snippet; that way, should the snippet be updated,
				-- some user input eg. text can be referred to in the new snippet.
				local param_nodes = {
					descr = nodes[2]
				}

				-- At least one param.
				if string.find(args[2][1], " ") then
					vim.list_extend(nodes, {t({" * ", ""})})
				end

				local insert = 2
				for indx, arg in ipairs(vim.split(args[2][1], ", ", true)) do
					-- Get actual name parameter.
					arg = vim.split(arg, " ", true)[2]
					if arg then
						arg = arg:gsub(",", "")
						local inode
						-- if there was some text in this parameter, use it as static_text for this new snippet.
						if old_state and old_state["arg"..arg] then
							inode = i(insert, old_state["arg"..arg]:get_text())
						else
							inode = i(insert)
						end
						vim.list_extend(nodes, {t({" * @param "..arg.." "}), inode, t({"", ""})})
						param_nodes["arg"..arg] = inode

						insert = insert + 1
					end
				end

				if args[1][1] ~= "void" then
					local inode
					if old_state and old_state.ret then
						inode = i(insert, old_state.ret:get_text())
					else
						inode = i(insert)
					end

					vim.list_extend(nodes, {t({" * ", " * @return "}), inode, t({"", ""})})
					param_nodes.ret = inode
					insert = insert + 1
				end

				if vim.tbl_count(args[3]) ~= 1 then
					local exc = string.gsub(args[3][2], " throws ", "")
					local ins
					if old_state and old_state.ex then
						ins = i(insert, old_state.ex:get_text())
					else
						ins = i(insert)
					end
					vim.list_extend(nodes, {t({" * ", " * @throws "..exc.." "}), ins, t({"", ""})})
					param_nodes.ex = ins
					insert = insert + 1
				end

				vim.list_extend(nodes, {t({" */"})})

				local snip = sn(nil, nodes)
				-- Error on attempting overwrite.
				snip.old_state = param_nodes
				return snip
			end

			ls.add_snippets("all", {
				s({trig="fn"}, {
					d(6, jdocsnip, {ai[2], ai[4], ai[5]}), t({"", ""}),
					c(1, {
						t({"public "}),
						t({"private "})
					}),
					c(2, {
						t({"void"}),
						i(nil, {""}),
						t({"String"}),
						t({"char"}),
						t({"int"}),
						t({"double"}),
						t({"boolean"}),
					}),
					t({" "}),
					i(3, {"myFunc"}),
					t({"("}), i(4), t({")"}),
					c(5, {
						t({""}),
						sn(nil, {
							t({""," throws "}),
							i(1)
						})
					}),
					t({" {", "\t"}),
					i(0),
					t({"", "}"})
				})
			})
		]])

		screen = Screen.new(50, 30)
		screen:attach()
		screen:set_default_attr_ids({
			[0] = { bold = true, foreground = Screen.colors.Blue },
			[1] = { bold = true, foreground = Screen.colors.Brown },
			[2] = { bold = true },
			[3] = { background = Screen.colors.LightGray },
			[4] = {
				background = Screen.colors.Red1,
				foreground = Screen.colors.White,
			},
		})
	end)

	it("Deleted snippet is handled properly in expansion.", function()
		feed("o<Cr><Cr><Up>fn")
		exec_lua("ls.expand()")
		screen:expect({
			grid = [[
			                                                  |
			                                                  |
			/**                                               |
			 * A short Description                            |
			 */                                               |
			^public void myFunc() { {4:●}                          |
			                                                  |
			}                                                 |
			                                                  |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
		jump(1)
		jump(1)
		jump(1)
		screen:expect({
			grid = [[
			                                                  |
			                                                  |
			/**                                               |
			 * A short Description                            |
			 */                                               |
			public void myFunc(^) {                            |
			                                                  |
			}                                                 |
			                                                  |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
		-- delete whole buffer.
		feed("<Esc>ggVGcfn")
		-- immediately expand at the old position of the snippet.
		exec_lua("ls.expand()")
		-- first jump goes to i(-1), second might go back into deleted snippet,
		-- if we did something wrong.
		jump(-1)
		jump(-1)
		screen:expect({
			grid = [[
			^/**                                               |
			 * A short Description                            |
			 */                                               |
			public void myFunc() {                            |
			                                                  |
			}                                                 |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
		-- seven jumps to go to i(0), 8th, again, should not do anything.
		jump(1)
		jump(1)
		jump(1)
		jump(1)
		jump(1)
		jump(1)
		jump(1)
		jump(1)
		screen:expect({
			grid = [[
			/**                                               |
			 * A short Description                            |
			 */                                               |
			public void myFunc() {                            |
			        ^                                          |
			}                                                 |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
	end)
	it("Deleted snippet is handled properly when jumping.", function()
		feed("o<Cr><Cr><Up>fn")
		exec_lua("ls.expand()")
		screen:expect({
			grid = [[
			                                                  |
			                                                  |
			/**                                               |
			 * A short Description                            |
			 */                                               |
			^public void myFunc() { {4:●}                          |
			                                                  |
			}                                                 |
			                                                  |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
		jump(1)
		jump(1)
		jump(1)
		screen:expect({
			grid = [[
			                                                  |
			                                                  |
			/**                                               |
			 * A short Description                            |
			 */                                               |
			public void myFunc(^) {                            |
			                                                  |
			}                                                 |
			                                                  |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
		-- delete whole buffer.
		feed("<Esc>ggVGd")
		-- should not cause an error.
		jump(1)
	end)
	it("Deleting nested snippet only removes it.", function()
		feed("o<Cr><Cr><Up>fn")
		exec_lua("ls.expand()")
		screen:expect({
			grid = [[
			                                                  |
			                                                  |
			/**                                               |
			 * A short Description                            |
			 */                                               |
			^public void myFunc() { {4:●}                          |
			                                                  |
			}                                                 |
			                                                  |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
		feed("<Esc>jlafn")
		expand()
		screen:expect({
			grid = [[
			                                                  |
			                                                  |
			/**                                               |
			 * A short Description                            |
			 */                                               |
			public void myFunc() {                            |
			        /**                                       |
			         * A short Description                    |
			         */                                       |
			        ^public void myFunc() { {4:●}                  |
			                                                  |
			        }                                         |
			}                                                 |
			                                                  |
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{0:~                                                 }|
			{2:-- INSERT --}                                      |]],
		})
		jump(1)
		jump(1)
		feed("<Esc>llllvbbbx")
		screen:snapshot_util()
		jump(-1)
		jump(-1)
		screen:snapshot_util()
	end)
end)
