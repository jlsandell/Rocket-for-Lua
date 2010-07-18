require "luasql.sqlite3"
require "rocket_utils"
require "promise"
sql = luasql.sqlite3
env = sql()

con = assert (env:connect("test.db"))

model = {}

function model.Model(self, fields)
	if not fields.id then fields.id = model.AutoField{pk = true} end
	if not fields[1] then error "Model must be named" end
	local Model = {static = {}, on = {}, model_name = fields[1].."_model"}
	local mt = {}

	table.remove(fields, 1)



	function mt.__call(self, args)
		--Construct a new lazy model
		local all = {}
		for field, value in pairs(args) do
			if fields[field] then
				if type(value) == "string" and fields[field].deserialize then
					value = fields[field].deserialize(value)
					args[field] = value
				end
				local validate =  fields[field](value)
				if validate ~= nil or fields[field].null then
					all[field] = validate
				end
			end
		end
		for field, validator in pairs(fields) do
			if not all[field] then all[field] = validator() end
		end

		local modelInstance = {all=all, on = self.on, super = self}
		local imt = {}
		function imt.__index(self, key)

			return self.all[key]
		end

		function imt.__newindex(self, key, val)
			if fields[key] then
				if fields[key](val) then
					self.all[key] = fields[key](val)
				end
			end

		end

		function imt.__eq(self, other)
			return self.id == other.id
		end

		function imt.__tostring(self)
			if self.super.on.string then
				return self.super.on.string(self)
			end
			return tostring("<%s Instance@%s>"%{self.super.model_name, self.id or "NaN"})
		end

		function modelInstance.save(self)
			if self.on.save then
				local r = self.on.save(self)
				if r then return end
			end
			for field, validator in pairs(fields) do
				if validator.on_save then
					validator.on_save(self)
				end

				if not validator.null then
					if not self[field] and not validator.pk then
						error("Improper Field: "..field.." failed the validation.")
					end
				end
			end

			--SAVE
			local insert = true
			if self.id then
				insert = false
			end
			local stack = {}
			local fieldstack = {}
			local objectstack = {}
			for field,object in pairs(self.all) do
				if fields[field].serialize then
					object = fields[field].serialize(object)
				else
					object = tostring(object)
				end
				table.insert(stack, field.."="..object)
				table.insert(fieldstack, field)
				table.insert(objectstack, object)
			end
			local stmt = "UPDATE %s SET %s WHERE id=%s;"
			stmt = stmt:format(Model.model_name, table.concat(stack, ","), tostring(self.id))
			if insert then
				stmt = "INSERT INTO %s (%s) VALUES (%s);"
				stmt = stmt:format(Model.model_name, table.concat(fieldstack,","), table.concat(objectstack,","))
			end

			assert(con:execute(stmt))

			if insert then
				local cur = con:execute("SELECT id FROM "..Model.model_name .. " ORDER BY id DESC")
				self.id = tonumber(cur:fetch())
			end
		end

		function modelInstance.delete(self)
			--CHECK FOR FOREIGN DEPENDENCIES

			--Make sure self exists
			if self.id then
				local sql = "DELETE FROM %s WHERE id=%s"%{self.super.model_name, self.id}
				print(sql)
				assert(con:execute(sql))
			end

			setmetatable(self, nil)
			for k in pairs(self) do rawset(self,k,nil) end
			self = nil
		end

		setmetatable(modelInstance, imt)
		return modelInstance
	end


	function Model.sync_db(self)
		local cur = con:execute(string.format("select * from sqlite_master where tbl_name = \"%s\";", self.model_name))
		if not cur:fetch() then
			--Need to setup the model in the database
			local stack = {}
			for field, validator in pairs(fields) do
				if(validator.sql)then
					local part = validator:sql(field)
					if not part then error("Cannot Create the DATABASE for model "..self.model_name.. "'s field "..field) end
					table.insert(stack,part)
				else
					error("Need a sql() function for model "..self.model_name.. "'s field "..field)
				end
			end
			local sql = string.format("CREATE TABLE %s (%s);", self.model_name, table.concat(stack, ", "))
			assert(con:execute(sql))
		end
	end

	--QuerySet mt
	local qmt = {}
	function qmt.__call(self)
		local sql = self.sql
		local stack = {self.select, self.table}
		if self._where then
			sql = sql .. " WHERE"
			for key, where in pairs(self._where) do
				sql = sql .. " \"%s\""
				table.insert(stack, key)
				if where.exact then
					sql = sql .. " = %s"
					table.insert(stack, where.obj)
				elseif where.flag then
					sql = sql .. " %s %s"
					table.insert(stack, where.flag)
					table.insert(stack, where.obj)
				else
					sql = sql .. ' LIKE %s ESCAPE \'\\\''
					table.insert(stack, where.obj)
				end
				sql = sql .. " AND"
			end
			sql = sql:sub(1,#sql-4)
		end
		if self._order_by then
			sql = sql .. " ORDER BY"
			for key, ordering in pairs(self._order_by) do
				sql = sql .. ' "%s" %s,'
				table.insert(stack, key)
				table.insert(stack, ordering:upper())
			end
			sql = sql:sub(1, #sql-1)
		end
		if self._limit then
			sql = sql .. " LIMIT %s"
			table.insert(stack, self._limit)
		end
		if self._offset then
			sql = sql .. " OFFSET %s"
			table.insert(stack, self._offset)
		end
		print(sql%stack)
		local cur = con:execute(sql%stack)
		local results = {}
		local row = cur:fetch({},"a")
		while row do
			table.insert(results, Model(row))
			row = cur:fetch({},"a")
		end
		results.iter = list_iter
		setmetatable(results, {__tostring=dump})
		return results
	end

	--DEFAULT MANAGER
	Model.objects = {}
	function Model.objects.all()
		local sql = "SELECT %s FROM %s"
		local self = {}
		self.sql = sql
		self.select = "*"
		self.table = Model.model_name

		function self.where(self, args)
			if not self._where then self._where = {} end
			local where
			for field,expr in pairs(args) do
				where = {}
				local s = field:split("__")
				field = s[1]
				local flags = {select(2, unpack(s))}
				if Model.fields[field] then
					local val = Model.fields[field]
					if val(expr) then
						if #flags == 0 then
							where.exact = true
							where.obj = (val.serialize or tostring)(expr)
						else
							local flag = flags[1]
							if flag == "startswith" then
								expr = expr .. "%"
							elseif flag == "endswith" then
								expr = "%"..expr
							elseif flag == "contains" then
								expr = "%"..expr.."%"
							elseif flag == "gt" then
								where.flag = ">"
							elseif flag == "ge" then
								where.flag = ">="
							elseif flag == "lt" then
								where.flag = "<"
							elseif flag == "le" then
								where.flag = "<="
							end
							where.obj = (val.serialize or tostring)(expr)
						end

					else
						error("Cannot validate field %s with expr %s"%{field, expr})
					end
				else
					error("Field does not exist: %s"%field)
				end
				self._where[field] = where
			end
			return self
		end
		function self.order_by(self, args)
			if not self._order_by then self._order_by = {} end
			local order_by
			for field,expr in pairs(args) do
				if Model.fields[field] then
					if expr:lower():inside{"asc", "ascending", "+"} then
						order_by = "ASC"
					else
						order_by = "DESC"
					end
				end
				self._order_by[field] = order_by
			end
			return self
		end
		function self.limit(self, n)
			if n then self._limit = n end
			return self
		end
		function self.offset(self, n)
			if n then self._offset = n end
			return self
		end
		setmetatable(self, qmt)
		return self
	end

	function mt.__newindex(self, key, val)
		if key:sub(1,3) == "on_" then
			self.on[key:sub(4)] = val
			return
		end

		if type(val) == "function" then
			rawset(self, key, val)
		end
	end

	setmetatable(Model, mt)

	for field, validator in pairs(fields) do
		rawset(getmetatable(validator).__index, "field_name", field)
		rawset(getmetatable(validator).__index, "super", Model)
	end

	rawset(Model, "fields", fields)
	Model:sync_db()

	return Model
end

setmetatable(model, {__call = model.Model})

require "field"

Person = model{
	"Person",
	name 	= model.CharField{},
}

Band = model{
	"Band",
	band_name = model.CharField{max_length = 20},
	website = model.CharField{max_length = 100, null = true, default = "http://example.com/"},
}

function Band.on_string(self)
	return "<Band: %s>"%(self.band_name or self.id or "NaN")
end

q = Band.objects.all():order_by{id="+"}()
for o in q:iter() do
	print(o)
end
