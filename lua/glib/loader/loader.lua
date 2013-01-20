GLib.Loader = {}
GLib.Loader.File = {}

for k, v in pairs (file) do
	GLib.Loader.File [k] = v
end

if CLIENT then
	CreateClientConVar ("glib_use_local_files", 0, true, false)
end

function GLib.Loader.CompileString (code, path, errorMode)
	code = table.concat (
		{
			"local AddCSLuaFile = GLib.NullCallback ",
			"local file         = GLib.Loader.File ",
			"local include      = GLib.Loader.Include ",
			"return function () ",
			code,
			" end"
		}
	)
	local compiled = CompileString (code, path, errorMode)
	if type (compiled) == "function" then
		compiled = compiled ()
	end
	return compiled
end

function GLib.Loader.File.Exists (path, pathId)
	if pathId ~= "LUA" and pathId ~= "LCL" then return file.Exists (path, pathId) end
	
	if file.Exists (path, pathId) then return true end
	if GLib.Loader.ServerPackFileSystem:Exists (path) then return true end
	return false
end

function GLib.Loader.File.Find (path, pathId)
	if pathId ~= "LUA" and pathId ~= "LCL" then return file.Find (path, pathId) end
	
	local files, folders = file.Find (path, pathId)
	local fileSet = {}
	local folderSet = {}
	
	for _, v in ipairs (files  ) do fileSet   [v:lower ()] = true end
	for _, v in ipairs (folders) do folderSet [v:lower ()] = true end
	
	local files2, folders2 = GLib.Loader.ServerPackFileSystem:Find (path)
	for _, v in ipairs (files2) do
		if not fileSet [v:lower ()] then files [#files + 1] = v end
	end
	for _, v in ipairs (folders2) do
		if not folderSet [v:lower ()] then folders [#folders + 1] = v end
	end
	return files, folders
end

function GLib.Loader.File.Read (path, pathId)
	if pathId ~= "LUA" and pathId ~= "LCL" then return file.Read (path, pathId) end
	local otherPathId = pathId == "LUA" and "LCL" or "LUA"
	local canRunLocal = pathId == "LCL" or GetConVar ("sv_allowcslua"):GetBool ()
	
	-- pathId is LUA or LCL, assume that we're trying to include () the file.
	
	local contents = nil
	local compiled = nil
	if GLib.Loader.ShouldPackOverrideLocalFiles () then
		-- Check pack file
		contents, compiled = GLib.Loader.ServerPackFileSystem:Read (path)
		
		-- Check given path
		if not contents and not compiled and
		   file.Exists (path, pathId) then
			contents = file.Read (path, pathId)
			compiled = function ()
				include (path)
			end
		end
		
		-- Check other path
		local canRunOtherPath = otherPathId == "LUA" or canRunLocal
		if not contents and not compiled and
		   canRunOtherPath and file.Exists (path, otherPathId) then
			contents = file.Read (path, otherPathId)
			compiled = function ()
				include (path)
			end
		end
	else
		-- Check LCL path
		if canRunLocal and file.Exists (path, "LCL") then
			contents = file.Read (path, "LCL")
			compiled = function ()
				include (path)
			end
		end
		
		-- Check pack file
		if not contents and not compiled then
			contents, compiled = GLib.Loader.ServerPackFileSystem:Read (path)
		end
		
		-- Check LUA path
		if not contents and not compiled and
		   file.Exists (path, "LUA") then
			contents = file.Read (path, "LUA")
			compiled = function ()
				include (path)
			end
		end
	end
	return contents, compiled
end

GLib.Loader.Exists = GLib.Loader.File.Exists
GLib.Loader.Find   = GLib.Loader.File.Find
GLib.Loader.Read   = GLib.Loader.File.Read

local pathStack = { "" }
function GLib.Loader.Include (path)
	local callerPath = debug.getinfo (2).short_src
	if callerPath:sub (1, 1) == "@" then callerPath = callerPath:sub (2) end
	callerPath = callerPath:match ("lua/(.*)") or callerPath
	local callerDirectory = ""
	if callerPath:find ("/") then
		callerDirectory = callerPath:sub (1, callerPath:find ("/[^/]*$"))
	else
		callerDirectory = ""
	end
	
	local fullPath = pathStack [#pathStack] .. path
	local code, compiled = GLib.Loader.File.Read (pathStack [#pathStack] .. path, "LUA")
	if not code and not compiled then
		fullPath = callerDirectory .. path
		code, compiled = GLib.Loader.File.Read (callerDirectory .. path, "LUA")
	end
	if not code and not compiled then
		fullPath = path
		code, compiled = GLib.Loader.File.Read (path, "LUA")
	end
	if not code and not compiled then
		ErrorNoHalt ("GLib.Loader.Include : " .. path .. ": File not found (Path was " .. pathStack [#pathStack] .. ", caller path was " .. callerDirectory .. ").\n")
	else
		compiled = compiled or GLib.Loader.CompileString (code, "lua/" .. fullPath, false)
		if type (compiled) == "function" then
			pathStack [#pathStack + 1] = fullPath:sub (1, fullPath:find ("/[^/]*$"))
			xpcall (compiled, GLib.Error)
			pathStack [#pathStack] = nil
		else
			ErrorNoHalt ("GLib.Loader.Include : " .. fullPath .. ": File failed to compile:\n\t" .. tostring (compiled) .. "\n")
		end
	end
end

function GLib.Loader.RunPackFile (executionTarget, packFile, packFileName)
	local shouldRun = executionTarget == "sh"
	shouldRun = shouldRun or executionTarget == "m"
	if SERVER and executionTarget == "sv" then shouldRun = true end
	if CLIENT and executionTarget == "cl" then shouldRun = true end
	
	if shouldRun then
		local packFileSystem = GLib.Loader.PackFileSystem ()
		packFileSystem:SetName (packFileName)
		local startTime = SysTime ()
		packFileSystem:Deserialize (packFile,
			function ()
				MsgN ("GLib : Running pack file \"" .. packFileSystem:GetName () .. "\", deserialization took " .. GLib.FormatDuration (SysTime () - startTime) .. " (" .. packFileSystem:GetFileCount () .. " total files, " .. GLib.FormatFileSize (#packFile) .. ").")
				for i = 1, packFileSystem:GetSystemTableCount () do
					GLib.Loader.ServerPackFileSystem:AddSystemTable (packFileSystem:GetSystemTableName (i))
				end
				
				if GLib.Loader.ShouldPackOverrideLocalFiles () then
					-- Unload systems in reverse load order
					for i = packFileSystem:GetSystemTableCount (), 1, -1 do
						local systemTableName = packFileSystem:GetSystemTableName (i)
						if _G [systemTableName] then
							print ("GLib : Unloading " .. systemTableName .. " to prepare for replacement...")
							GLib.UnloadSystem (systemTableName)
						end
					end
				end
				
				packFileSystem:MergeInto (GLib.Loader.ServerPackFileSystem)
				
				local files, _ = packFileSystem:Find ("autorun/*.lua")
				for _, fileName in ipairs (files) do
					GLib.Loader.Include ("autorun/" .. fileName)
				end
				
				local files, _ = packFileSystem:Find ("autorun/" .. (SERVER and "server" or "client") .. "/*.lua")
				for _, fileName in ipairs (files) do
					GLib.Loader.Include ("autorun/" .. (SERVER and "server" or "client") .. "/" .. fileName)
				end
			end
		)
	end
	
	if SERVER then
		if executionTarget == "sh" or executionTarget == "cl" then
			if not shouldRun then
				print ("GLib : Forwarding pack file \"" .. packFileName .. "\" on to clients.")
			end
			GLib.Loader.Networker:StreamPack (GLib.GetEveryoneId (), executionTarget, packFile, packFileName)
		end
	end
end

function GLib.Loader.ShouldPackOverrideLocalFiles ()
	if SERVER then return true end
	if not GetConVar ("sv_allowcslua"):GetBool () then return true end
	return not GetConVar ("glib_use_local_files"):GetBool ()
end

-- HTTP Pack Loading
local executionTargets = SERVER and { "sv", "sh", "cl" } or { "m" }
for _, executionTarget in ipairs (executionTargets) do
	concommand.Add ("glib_download_pack_" .. executionTarget,
		function (ply, _, args)
			if not ply or not ply:IsValid () then return end
			if not ply:IsSuperAdmin () then return end
			if #args == 0 then return end
			args = table.concat (args)
			if args == "" then return end
			
			print ("glib_download_pack_" .. executionTarget .. ": Fetching " .. args .. ".")
			http.Fetch (args,
				function (data, dataSize, headers, httpCode)
					print ("glib_download_pack_" .. executionTarget .. ": Received " .. args .. " (" .. GLib.FormatFileSize (dataSize) .. ")")
					GLib.Loader.RunPackFile (executionTarget, data, args)
				end,
				function (err)
					print ("glib_download_pack_" .. executionTarget .. ": HTTP fetch failed (" .. tostring (err) .. ")")
				end
			)
		end
	)
end

if SERVER then
	concommand.Add ("glib_request_pack",
		function (ply)
			if not ply or not ply:IsValid () then return end
			
			GLib.Loader.Networker:StreamPack (GLib.GetPlayerId (ply), "cl", GLib.Loader.ServerPackFileSystem:GetPackFile (), "Server")
		end
	)
elseif CLIENT then
	GLib.WaitForLocalPlayer (
		function ()
			timer.Simple (10,
				function ()
					RunConsoleCommand ("glib_request_pack")
				end
			)
		end
	)
	
	concommand.Add ("glib_pack",
		function (ply, _, args)
			if #args == 0 then
				print ("glib_pack <addon_directory>")
				return
			end
			
			local addonName = table.concat (args, " ")
			if not file.IsDir ("addons/" .. addonName .. "/lua", "GAME") then
				print ("glib_pack: addons/" .. addonName .. "/lua not found.")
				return
			end
			
			local packFileSystem = GLib.Loader.PackFileSystem ()
			local packFileName = addonName:gsub ("[\\/: %-]", "_")
			packFileSystem:SetName (packFileName)
			local pathPrefix = "addons/" .. addonName .. "/lua/"
			GLib.EnumerateFolderRecursive ("addons/" .. addonName .. "/lua", "GAME",
				function (path)
					if path:sub (-4):lower () ~= ".lua" then return end
					packFileSystem:Write (
						path:sub (#pathPrefix + 1),
						file.Read (path, "GAME")
					)
				end
			)
			
			local autoruns, _ = packFileSystem:Find ("autorun/*.lua")
			for _, autorun in ipairs (autoruns) do
				local code = packFileSystem:Read ("autorun/" .. autorun) or ""
				local includedPath = code:match ("[iI]nclude[ \t]*%(\"([^\"]*)\"%)") or ""
				code = packFileSystem:Read (includedPath) or ""
				local systemName = code:match ("^if ([^ ]*) then return end")
				if systemName then
					packFileSystem:AddSystemTable (systemName)
				end
			end
			
			-- Write pack file
			file.CreateDir ("glibpack")
			local f = file.Open ("glibpack/" .. packFileName .. "_pack.txt", "wb", "DATA")
			f:Write (packFileSystem:GetPackFile ())
			f:Close ()
		end,
		function (command, arg)
			if arg:sub (1, 1) == " " then arg = arg:sub (2) end
			
			local _, addons = file.Find ("addons/*", "GAME")
			local autocomplete = {}
			for _, addonName in ipairs (addons) do
				if addonName:lower ():sub (1, arg:len ()) == arg:lower () and
				   file.IsDir ("addons/" .. addonName .. "/lua", "GAME") then
					autocomplete [#autocomplete + 1] = command .. " " .. addonName
				end
			end
			return autocomplete
		end
	)
	
	local executionTargets = { "cl", "sh", "sv", "m" }
	for _, executionTarget in ipairs (executionTargets) do
		concommand.Add ("glib_upload_pack_" .. executionTarget,
			function (_, _, args)
				if #args == 0 then
					print ("glib_upload_pack_" .. executionTarget .. " <pack file name>")
					return
				end
				
				local packFileName = table.concat (args, " ")
				
				-- Read pack file
				local packFile = nil
				local f = file.Open ("data/glibpack/" .. packFileName, "rb", "GAME")
				if not f then
					print ("glib_upload_pack_" .. executionTarget .. " : " .. "data/glibpack/" .. packFileName .. " not found!")
					return
				end
				
				packFile = f:Read (f:Size ())
				f:Close ()
				
				if executionTarget == "m" then
					if GetConVar ("sv_allowcslua"):GetBool () then
						GLib.Loader.RunPackFile ("m", packFile, packFileName)
					else
						print ("glib_upload_pack_m : sv_allowcslua is 0!")
					end
				else
					GLib.Loader.Networker:StreamPack (GLib.GetServerId (), executionTarget, packFile, packFileName)
				end
			end,
			function (command, arg)
				if arg:sub (1, 1) == " " then arg = arg:sub (2) end
				
				local files, _ = file.Find ("data/glibpack/*.txt", "GAME")
				local autocomplete = {}
				for _, packName in ipairs (files) do
					if packName:lower ():sub (1, arg:len ()) == arg:lower () then
						autocomplete [#autocomplete + 1] = command .. " " .. packName
					end
				end
				return autocomplete
			end
		)
	end
end