function GLib.Enumerator.Concat (enumerator, separator)
	return table.concat (GLib.Enumerator.ToArray (GLib.Enumerator.Map (enumerator, tostring)), separator)
end

function GLib.Enumerator.Filter (enumerator, f)
	return function ()
		local a, b, c, d = nil
		repeat
			a, b, c, d = enumerator ()
			if a == nil then return nil end
		until f (a, b, c, d)
		
		return a, b, c, d
	end
end

function GLib.Enumerator.Map (enumerator, f)
	return function ()
		return f (enumerator ())
	end
end

function GLib.Enumerator.Skip (enumerator, n)
	local skipped = false
	return function ()
		if not skipped then
			for i = 1, n do
				local item = enumerator ()
				if item == nil then return nil end
			end
			skipped = true
		end
		
		return enumerator ()
	end
end

function GLib.Enumerator.Take (enumerator, n)
	local i = 0
	return function ()
		i = i + 1
		if i > n then return nil end
		
		return enumerator ()
	end
end

function GLib.Enumerator.ToArray (enumerator)
	local t = {}
	
	for v in enumerator do
		t [#t + 1] = v
	end
	
	return t
end

function GLib.Enumerator.ToMap (enumerator)
	local t = {}
	
	for k, v in enumerator do
		 t [k] = v
	end
	
	return t
end
GLib.Enumerator.ToTable = GLib.Enumerator.ToMap