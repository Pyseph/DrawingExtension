if getgenv().DrawingAPILoaded then
	return
end
getgenv().DrawingAPILoaded = true

local EventEnums = {
	MouseButton1Down = 'MouseButton1Down',
	MouseButton1Up = 'MouseButton1Up',
	MouseButton2Down = 'MouseButton2Down',
	MouseButton2Up = 'MouseButton2Up',
	MouseButton1Click = 'MouseButton1Click',
	MouseButton2Click = 'MouseButton2Click',
	MouseEnter = 'MouseEnter',
	MouseLeave = 'MouseLeave',
	MouseMoved = 'MouseMoved',
	InputBegan = 'InputBegan',
	InputChanged = 'InputChanged',
	InputEnded = 'InputEnded'
}


-- https://github.com/PysephRBX/RBXConnection/wiki
-- Maid source, used in Nevermore engine
-- I should be using Janitor instead, but I cannot be asked to swap out Maid.

---	Manages the cleaning of events and other things.
-- Useful for encapsulating state and make deconstructors easy
-- @classmod Maid
-- @see Signal

local Maid = {}
Maid.ClassName = "Maid"

--- Returns a new Maid object
-- @constructor Maid.new()
-- @treturn Maid
function Maid.new()
	return setmetatable({
		_tasks = {}
	}, Maid)
end

function Maid.isMaid(value)
	return type(value) == "table" and value.ClassName == "Maid"
end

--- Returns Maid[key] if not part of Maid metatable
-- @return Maid[key] value
function Maid:__index(index)
	if Maid[index] then
		return Maid[index]
	else
		return self._tasks[index]
	end
end

--- Add a task to clean up. Tasks given to a maid will be cleaned when
--  maid[index] is set to a different value.
-- @usage
-- Maid[key] = (function)         Adds a task to perform
-- Maid[key] = (event connection) Manages an event connection
-- Maid[key] = (Maid)             Maids can act as an event connection, allowing a Maid to have other maids to clean up.
-- Maid[key] = (Object)           Maids can cleanup objects with a `Destroy` method
-- Maid[key] = nil                Removes a named task. If the task is an event, it is disconnected. If it is an object,
--                                it is destroyed.
function Maid:__newindex(index, newTask)
	if Maid[index] ~= nil then
		error(string.format("'%s' is reserved", tostring(index)), 2)
	end

	local tasks = self._tasks
	local oldTask = tasks[index]

	if oldTask == newTask then
		return
	end

	tasks[index] = newTask

	if oldTask then
		if type(oldTask) == "function" then
			oldTask()
		elseif typeof(oldTask) == "RBXScriptConnection" then
			oldTask:Disconnect()
		elseif oldTask.Destroy then
			oldTask:Destroy()
		end
	end
end

--- Same as indexing, but uses an incremented number as a key.
-- @param task An item to clean
-- @treturn number taskId
function Maid:GiveTask(task)
	if not task then
		error("Task cannot be false or nil", 2)
	end

	local taskId = #self._tasks+1
	self[taskId] = task

	if type(task) == "table" and (not task.Destroy) then
		warn("[Maid.GiveTask] - Gave table task without .Destroy\n\n" .. debug.traceback())
	end

	return taskId
end

function Maid:GivePromise(promise)
	if not promise:IsPending() then
		return promise
	end

	local newPromise = promise.resolved(promise)
	local id = self:GiveTask(newPromise)

	-- Ensure GC
	newPromise:Finally(function()
		self[id] = nil
	end)

	return newPromise
end

--- Cleans up all tasks.
-- @alias Destroy
function Maid:DoCleaning()
	local tasks = self._tasks

	-- Disconnect all events first as we know this is safe
	for index, task in pairs(tasks) do
		if typeof(task) == "RBXScriptConnection" then
			tasks[index] = nil
			task:Disconnect()
		end
	end

	-- Clear out tasks table completely, even if clean up tasks add more tasks to the maid
	local index, task = next(tasks)
	while task ~= nil do
		tasks[index] = nil
		if type(task) == "function" then
			task()
		elseif typeof(task) == "RBXScriptConnection" then
			task:Disconnect()
		elseif task.Destroy then
			task:Destroy()
		end
		index, task = next(tasks)
	end
end

--- Alias for DoCleaning()
-- @function Destroy
Maid.Destroy = Maid.DoCleaning


-- Signal Source


local Signal = {}

local SignalBase = {}
local ConnectionBase = {}
SignalBase.__index = SignalBase
ConnectionBase.__index = ConnectionBase



function SignalBase:Invoke(...)
	for _, Data in next, self.Listeners do
		coroutine.wrap(Data.Callback)(...)
	end
	for Index, YieldedThread in next, self.Yielded do
		self.Yielded[Index] = nil
		coroutine.resume(YieldedThread, ...)
	end
end
function SignalBase:Destroy()
	self._Maid:Destroy()
end



function ConnectionBase:Connect(f)
	local SignalReference = self._Reference
	local Timestamp = os.clock()
	local Data = {
		Disconnect = function(self)
			self.Connected = false
			SignalReference.Listeners[Timestamp] = nil
		end,
		Callback = f,
		Connected = true
	}
	Data.Destroy = Data.Disconnect

	SignalReference._Maid['Clean' .. Timestamp .. 'Connection'] = Data
	SignalReference.Listeners[Timestamp] = Data
	return Data
end
function ConnectionBase:Wait()
	local SignalReference = self._Reference
	local Thread = coroutine.running()

	table.insert(SignalReference.Yielded, Thread)
	return coroutine.yield()
end



function Signal.new()
	local SignalObject = setmetatable({
		Listeners = {},
		Invoked = setmetatable({_Reference = false}, ConnectionBase),
		Yielded = {},
		_Maid = Maid.new()
	}, SignalBase)
	SignalObject.Invoked._Reference = SignalObject

	return SignalObject
end


local Event = {
	Enums = {},
	Events = {}
}

for i in next, EventEnums do
	Event.Events[i] = {}
end

Event.new = function(Enum, Id)
	local NewEvent = Signal.new()

	Event.Events[Enum][Id] = NewEvent
	return NewEvent.Invoked, NewEvent
end

function Event:Invoke(Enum, ObjId, ...)
	self.Events[Enum][ObjId]:Invoke(...)
end





local UIS = game:GetService('UserInputService')
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local TweenService = game:GetService('TweenService')

local RenderStepped = RunService.RenderStepped
local Mouse = Players.LocalPlayer:GetMouse()

local CurrentlyInside = {}
local NotInside = {}

local LastRemoved = {}
local LastDown = {}

local QueueSignal = Signal.new()

local Cleaning = false
local function AwaitClean()
	if Cleaning then
		QueueSignal.Invoked:Wait()
	end
end
local function QueueRemove(Table, Index)
	coroutine.wrap(function()
		AwaitClean()
		Table[Index] = nil
	end)()
end
local function QueueAdd(Table, Index)
	coroutine.wrap(function()
		AwaitClean()
		Table[Index] = true
	end)()
end
local function QueueSwap(Table1, Table2, Index)
	coroutine.wrap(function()
		AwaitClean()

		Table1[Index] = nil
		Table2[Index] = true
	end)()
end

local MouseX, MouseY = Mouse.X, Mouse.Y + 36
RenderStepped:Connect(function()
	MouseX, MouseY = Mouse.X, Mouse.Y + 36

	AwaitClean()
	Cleaning = true

	debug.profilebegin('Detect UI inputs')

	for obj in next, CurrentlyInside do
		if (MouseX <= obj.LeftEdge or MouseX >= obj.RightEdge) or (MouseY <= obj.TopEdge or MouseY >= obj.BottomEdge) then
			QueueSwap(CurrentlyInside, NotInside, obj)

			LastRemoved[obj.ReferenceId] = os.clock()
			Event:Invoke('MouseLeave', obj.ReferenceId, MouseX, MouseY)
		else
			Event:Invoke('MouseMoved', obj.ReferenceId, MouseX, MouseY)
		end
	end


	for obj in next, NotInside do
		if (MouseX >= obj.LeftEdge and MouseX <= obj.RightEdge) and (MouseY >= obj.TopEdge and MouseY <= obj.BottomEdge) then
			QueueSwap(NotInside, CurrentlyInside, obj)

			Event:Invoke('MouseEnter', obj.ReferenceId, MouseX, MouseY)
		end
	end

	debug.profileend()

	Cleaning = false
	QueueSignal:Invoke()
end)

local ButtonEvents = {}
UIS.InputBegan:Connect(function(Input)
	local UserInput = Input.UserInputType.Name
	local IsButton = string.find(UserInput, 'MouseButton')

	AwaitClean()
	Cleaning = true
	if IsButton then
		local InputDown = UserInput .. 'Down'
		for obj in next, CurrentlyInside do
			local ReferenceId = obj.ReferenceId

			LastDown[ReferenceId] = os.clock()
			ButtonEvents[obj] = true

			Event:Invoke(InputDown, ReferenceId, MouseX, MouseY)
			Event:Invoke('InputBegan', ReferenceId, Input)
		end
	else
		for obj in next, CurrentlyInside do
			Event:Invoke('InputBegan', obj.ReferenceId, Input)
		end
	end
	Cleaning = false

	QueueSignal:Invoke()
end)
UIS.InputChanged:Connect(function(Input)
	for obj in next, CurrentlyInside do
		Event:Invoke('InputEnded', obj.ReferenceId, Input)
	end
end)
UIS.InputEnded:Connect(function(Input)
	local UserInput = Input.UserInputType.Name

	if string.match(UserInput, 'MouseButton[^3]') then
		local InputUp = UserInput .. 'Up'
		local InputClick = UserInput .. 'Click'

		for obj in next, ButtonEvents do
			local ReferenceId = obj.ReferenceId

			Event:Invoke(InputUp, ReferenceId, MouseX, MouseY)
			if LastDown[ReferenceId] > LastRemoved[ReferenceId] then
				Event:Invoke(InputClick, ReferenceId, MouseX, MouseY)
			end
		end
		ButtonEvents = {}
	end
	for obj in next, CurrentlyInside do
		Event:Invoke('InputEnded', obj.ReferenceId, Input)
	end
end)

local SupportedClasses = {
	Square = true,
	Line = true,
	Text = true
}

local DrawingChildren = {}
local ReferenceIds = 0

local ClassProperties = {
	Line = {'From', 'To', 'Color', 'Thickness', 'Transparency'},
	Text = {'Text', 'Position', 'Size', 'Color', 'Center', 'Outline', 'Transparency', 'TextBounds'},
	Square = {'Position', 'Size', 'Color', 'Thickness', 'Filled', 'Transparency'}
}
for i,v in next, ClassProperties do
	local t = {}

	for _,b in next, v do
		t[b] = b
	end
	ClassProperties[i] = t
end

local Tween = {}

local function lerp(a, b, t)
	return a * (1-t) + b * t
end

local Epsilon = 10 ^ -3
local Connections = {}
function Tween.new(Object, FakeObj, TweenInfo, TweenValues, Callback)
	Connections[Object] = Connections[Object] or {}

	local ObjConns = Connections[Object]
	for Name, Conn in next, ObjConns do
		if TweenValues[Name] ~= nil then
			Conn:Disconnect()
			Connections[Object] = {}
			break
		end
	end

	local TimePassed = 0

	local TweenTime = TweenInfo.Time
	local TweenStyle = TweenInfo.EasingStyle
	local EasingDir = TweenInfo.EasingDirection

	local StartVals = {}
	for PropName in next, TweenValues do
		StartVals[PropName] = FakeObj[PropName]
	end

	-- edge case: for some reason tweening to 1 breaks stuff
	TweenValues.Transparency = TweenValues.Transparency and math.clamp(TweenValues.Transparency, Epsilon, 1 - Epsilon)

	for PropName, PropVal in next, TweenValues do
		local StartVal = FakeObj[PropName]

		-- Update object with new, lerped property
		FakeObj[PropName] = type(PropVal) == 'number' and lerp(StartVal, PropVal, 0) or StartVal:Lerp(PropVal, 0)
	end

	xpcall(function()

		local Conn
		Conn = RenderStepped:Connect(function(Delta)
			TimePassed = TimePassed + Delta

			local Alpha = TweenService:GetValue(math.min(TimePassed / TweenTime, 1), TweenStyle, EasingDir)
			for PropName, PropVal in next, TweenValues do
				local StartVal = StartVals[PropName]

				-- Lerp / tween value
				local LerpedVal = type(PropVal) == 'number' and lerp(StartVal, PropVal, Alpha) or StartVal:Lerp(PropVal, Alpha)

				-- Update object with new, lerped property
				FakeObj[PropName] = LerpedVal
			end
			-- Update position and data after lerping all values

			if TimePassed > TweenTime then
				Conn:Disconnect()
				for Name in next, TweenValues do
					Connections[Object][Name] = nil
				end

				if Callback then
					local Worked, Error = pcall(Callback)
					if not Worked then
						error(Error, 3)
					end
				end
				return
			end
		end)
		for Name in next, TweenValues do
			Connections[Object][Name] = Conn
		end

	end, function(ErrorMsg)
		for Name in next, TweenValues do
			local ObjConn = Connections[Object][Name]
			Connections[Object][Name] = nil

			if ObjConn then
				ObjConn:Disconnect()
				Connections[Object] = {}
				break
			end
		end

		error('Tween error', ErrorMsg)
	end)
end

Tween.TweenBase = {}
function Tween.TweenBase.new()
	local Base = {}

	function Base:Tween(...)
		return Tween.new(...)
	end

	return Base
end

local AvailableTweens = {
	Line = {
		Transparency = {'Transparency'},
		From = {'From'},
		To = {'To'},
		ToAndFrom = {'To', 'From'},
		Color = {'Color'}
	},

	Square = {
		Transparency = {'Transparency'},
		Size = {'Size'},
		Position = {'Position'},
		SizeAndPosition = {'Size', 'Position'},
		Color = {'Color'}
	}
}
local ExpectedTweenClasses = {
	Line = {
		Transparency = {'number'},
		From = {'Vector2'},
		To = {'Vector2'},
		ToAndFrom = {'Vector2', 'Vector2'},
		Color = {'Color3'}
	},

	Square = {
		Transparency = {'number'},
		Size = {'Vector2'},
		Position = {'Vector2'},
		SizeAndPosition = {'Vector2', 'Vector2'},
		Color = {'Color3'}
	}
}
AvailableTweens.Text = AvailableTweens.Square
ExpectedTweenClasses.Text = ExpectedTweenClasses.Square

local OnNewDrawing

local TweenBase = Tween.TweenBase
local DrawingObjs = {}

local function Assert(Value, Class)
	local Type = typeof(Value)
	assert(Type == Class, 'invalid argument #3  (expected ' .. Class .. ', got ' .. Type .. ')')
end

local DrawingAPI = Drawing.new
OnNewDrawing = function(Class, Parameter)

	return coroutine.wrap(function()
		if Parameter == 'Default' then
			return OnNewDrawing(Class)
		end
		if Class == 'TweenBase' then
			return TweenBase.new()
		end

		local DrawingObj = DrawingAPI(Class)
		local WrappedDrawing = {}

		if SupportedClasses[Class] then
			debug.profilebegin('creating class')
			local DrawingObject = DrawingObj

			ReferenceIds = ReferenceIds + 1

			local ReferenceId = ReferenceIds
			local Metatable = {}

			local Children = {}
			local ChildrenDict = {}

			DrawingObjs[ReferenceId] = DrawingObject
			LastRemoved[ReferenceId] = 0
			LastDown[ReferenceId] = 1

			local Properties = {Visible = DrawingObject.Visible, ZIndex = DrawingObject.ZIndex}

			for _, Prop in next, ClassProperties[Class] do
				Properties[Prop] = DrawingObject[Prop]
			end
			DrawingChildren[ReferenceId] = {Children, ChildrenDict}

			local IsntLine = Class ~= 'Line'
			local IsLine = not IsntLine

			local SetParent
			local SetPosition = IsntLine and DrawingObject.Position
			local SetSize = Class == 'Circle' and DrawingObject.Radius or (IsntLine and (Class == 'Text' and DrawingObject.TextBounds or DrawingObject.Size))

			local ObjEvents = {}
			for _, Enum in next, EventEnums do
				Properties[Enum], ObjEvents[Enum] = Event.new(Enum, ReferenceId)
			end

			Properties.Class = Class
			Properties.ReferenceId = ReferenceId
			Properties.Name = Class

			if IsntLine then
				Properties.AbsolutePosition = SetPosition
				Properties.Position = SetPosition
			else
				Properties.AbsoluteFrom = DrawingObject.From
				Properties.AbsoluteTo = DrawingObject.To
			end

			function Properties:GetChildren()
				return Children
			end
			function Properties:GetDescendants()
				local Flattened = {}
				local Idx = 0

				local function RecursiveFlatten(Input)
					for _, Obj in next, Input do
						Idx = Idx + 1
						Flattened[Idx] = Obj

						local ObjChildren = Obj:GetChildren()
						if #ObjChildren > 0 then
							RecursiveFlatten(ObjChildren)
						end
					end
				end

				RecursiveFlatten(Children)
				return Flattened
			end
			function Properties:FindFirstChild(Name)
				for _, Obj in next, Children do
					if Obj.Name == Name then
						return Obj
					end
				end
			end
			function Properties:FindFirstIndex(Index)
				return Children[Index]
			end
			function Properties:FindFirstObject(Object)
				return ChildrenDict[Object]
			end

			function Properties:Remove()
				if Properties.INTERNAL_Removed then
					return
				end

				Properties.INTERNAL_Removed = true
				-- Remove Children
				for _,v in next, Properties:GetDescendants() do
					v:Remove()
				end

				-- Remove events
				for Enum, ObjEvent in next, ObjEvents do
					ObjEvent:Destroy()
					Properties[Enum] = nil
				end

				-- Remove from children
				if SetParent then
					local ChildrenData = DrawingChildren[SetParent.ReferenceId]
					local Dict = ChildrenData[2]
					if Dict[WrappedDrawing] then
						local Array = ChildrenData[1]
						Dict[WrappedDrawing] = nil
						table.remove(Array, table.find(Array, WrappedDrawing))
					end
				end

				-- Remove from main events (MouseEnter, ...)
				QueueRemove(NotInside, DrawingObj)
				QueueRemove(CurrentlyInside, DrawingObj)

				-- Remove Drawing
				DrawingObject:Remove()
			end

			DrawingObj = setmetatable(WrappedDrawing, Metatable)

			if IsLine then
				local To, From = DrawingObject.To, DrawingObject.From
				Properties.AbsoluteTo = To
				Properties.To = To

				Properties.From = From
				Properties.AbsoluteFrom = From
			end

			local function GetPosition(Object)
				return Object.Class == 'Line' and Object.AbsoluteFrom or Object.AbsolutePosition
			end
			local function UpdatePosition(Position)
				debug.profilebegin('UpdatePosition')
				if IsntLine then
					DrawingObject.Position = Position
					Properties.AbsolutePosition = Position
					SetPosition = Position

					local xPos, yPos = Position.X, Position.Y
					Properties.LeftEdge = xPos
					Properties.RightEdge = xPos + SetSize.X
					Properties.TopEdge = yPos
					Properties.BottomEdge = yPos + SetSize.Y
				else
					for PropName, PropVal in next, {From = Properties.From, To = Properties.To} do
						local NewPos = PropVal + Position

						Properties['Absolute' .. PropName] = PropVal + Position
						DrawingObject[PropName] = NewPos
					end
				end

				debug.profilebegin('ParentAllocated')
				for _, Child in next, Children do
					Child.INTERNAL_ParentAllocated()
				end
				debug.profileend()

				debug.profileend()
			end

			local function UpdateEdges(Setting)
				UpdatePosition(Setting or SetPosition or Properties.AbsoluteFrom)
				if IsntLine and Class ~= 'Text' then
					DrawingObject.Size = SetSize
					Properties.Size = SetSize
				end
			end
			UpdateEdges()

			Properties.UpdateEdges = UpdateEdges
			Properties.UpdatePosition = UpdatePosition
			Properties.INTERNAL_GetPosition = GetPosition
			Properties.IncrementPosition = function(DeltaPosition)
				UpdatePosition(SetPosition + DeltaPosition)
			end
			Properties.INTERNAL_ParentAllocated = function()
				UpdatePosition(SetParent.AbsolutePosition + (Properties.Position or Properties.From))
			end

			function Properties:GetFullName()
				local Name = ''
				local ObjParent = SetParent

				local ParentNames = {}
				while ObjParent do
					table.insert(ParentNames, ObjParent.Name)
					ObjParent = ObjParent.Parent
				end

				for Idx = #ParentNames, 1, -1 do
					Name = ParentNames[Idx] .. '.'
				end

				return Name .. Properties.Name
			end

			function Properties:INTERNAL_ToggleVisible(Bool, AlreadyToggled)
				if SetParent then
					DrawingObject.Visible = SetParent.AbsoluteVisible and (Properties.Visible and Bool)
				else
					DrawingObject.Visible = Bool
				end

				if not AlreadyToggled then
					for _, Descendant in next, Properties:GetDescendants() do
						Descendant:INTERNAL_ToggleVisible(Bool, true)
					end
				end

				if DrawingObject.Visible then
					QueueAdd(NotInside, DrawingObj)
				else
					QueueRemove(NotInside, DrawingObj)
					QueueRemove(CurrentlyInside, DrawingObj)
				end
			end

			for ClassName, ClassData in next, AvailableTweens do
				for TweenName, TweenData in next, ClassData do
					local ExpectedClasses = ExpectedTweenClasses[ClassName][TweenName]

					Properties['Tween' .. TweenName] = newcclosure(function(self, ...)
						local Callback, TweenInfo = ...
						if type(Callback) ~= 'function' then
							TweenInfo = Callback
							Callback = nil
						end

						assert(typeof(TweenInfo) == 'TweenInfo', 'Unexpected argument #1 to Tween' .. TweenName .. ' (TweenInfo expected, got ' .. typeof(TweenInfo) .. ')')

						local Data = {}
						local NumEnumerated = 1
						for Idx, Value in next, {select(Callback and 3 or 2, ...)} do
							local ExpectedClass = ExpectedClasses[Idx]
							if ExpectedClass == nil then
								ExpectedClass = 'nil'
							end

							Idx = TweenData[Idx]
							NumEnumerated = NumEnumerated + 1
							local ValueClass = typeof(Value)
							assert(Idx ~= nil and ValueClass == ExpectedClass, string.format(
								'invalid argument #%s to %s (%s expected, got %s)',
								NumEnumerated,
								'Tween' .. TweenName,
								ExpectedClass or '?',
								typeof(Value)
							))
							Data[Idx] = Value
						end

						Tween.new(DrawingObject, DrawingObj, TweenInfo, Data, Callback)
						if ClassProperties[Class].Size then
							if Class == 'Text' then
								SetSize = DrawingObject.TextBounds
								Properties.TextBounds = SetSize
							else
								SetSize = DrawingObject.Size
								Properties.Size = SetSize
							end
						end
						if ClassProperties[Class].Position then
							SetPosition = DrawingObject.Position
							Properties.AbsolutePosition = SetPosition
							Properties.Position = SetParent and SetPosition - GetPosition(SetParent) or SetPosition
							UpdatePosition(DrawingObject.Position)
						end
					end)
				end
			end

			local function RecursiveParentCheck(Object, NewParent)
				while NewParent do
					if NewParent == Object then
						return true
					end
					NewParent = NewParent.Parent
				end

				return false
			end

			function Metatable:__index(key)
				if key == 'AbsoluteVisible' then
					return DrawingObject.Visible
				end
				return Properties[key]
			end
			function Metatable:__newindex(key, value)
				debug.profilebegin('__newindex ' .. key)
				if key == 'Parent' then
					debug.profilebegin('Validating Parent property')

					assert(not Properties.INTERNAL_Removed, 'The Parent property of ' .. Properties.Name .. ' is locked, current parent: NULL, new parent ' .. tostring(value))
					assert(value == nil or (typeof(value) == 'table' and value.Class), 'invalid argument #3 (DrawingObject expected, got ' .. typeof(value) .. ')')

					debug.profileend()

					debug.profilebegin('validating parent')
					if value ~= nil then
						if value == Properties.Parent then
							return debug.profileend()
						end
						assert(not RecursiveParentCheck(DrawingObj, value), 'Attempt to set parent of ' .. DrawingObj:GetFullName() .. ' to ' .. value:GetFullName() .. ' would result in a circular reference')
					end
					Properties.Parent = value
					debug.profileend()

					debug.profilebegin('Update edge data')
					UpdateEdges(value and GetPosition(value) + SetPosition)
					debug.profileend()

					if SetParent then
						debug.profilebegin('Removing from existing Parent')
						local ChildrenData = DrawingChildren[SetParent.ReferenceId]
						local Dict = ChildrenData[2]

						if Dict[WrappedDrawing] then
							local Array = ChildrenData[1]
							Dict[WrappedDrawing] = nil
							table.remove(Array, table.find(Array, WrappedDrawing))
						end

						SetParent = nil
						debug.profileend()
					end

					SetParent = value
					debug.profilebegin('Set new Parent')
					if value ~= nil then
						local ChildrenData = DrawingChildren[SetParent.ReferenceId]
						local Dict = ChildrenData[2]

						if Dict[WrappedDrawing] then
							local Array = ChildrenData[1]
							Dict[WrappedDrawing] = nil
							table.remove(Array, table.find(Array, WrappedDrawing))
						end

						ChildrenData = DrawingChildren[value.ReferenceId]
						table.insert(ChildrenData[1], WrappedDrawing)
						ChildrenData[2][WrappedDrawing] = true

						Properties:INTERNAL_ToggleVisible(value.Visible)
					else
						Properties:INTERNAL_ToggleVisible(Properties.Visible)
					end
					debug.profileend()

					return debug.profileend()
				elseif key == 'Position' then
					Assert(value, 'Vector2')
					Properties.Position = value
					UpdatePosition(SetParent and GetPosition(SetParent) + value or value)
					return debug.profileend()
				elseif key == 'Text' then
					Assert(value, 'string')
					Properties[key] = value
					DrawingObject[key] = value
					SetSize = DrawingObject.TextBounds
					Properties.TextBounds = DrawingObject.TextBounds

					UpdateEdges()
					return debug.profileend()
				elseif key == 'Size' and Class ~= 'Text' then
					Assert(value, 'Vector2')
					SetSize = value
					UpdateEdges()
				elseif key == 'From' or key == 'To' then
					Assert(value, 'Vector2')
					Properties[key] = value
					UpdatePosition(SetParent and GetPosition(SetParent) + value or value)
					return
				elseif key == 'Visible' then
					Assert(value, 'boolean')
					Properties.Visible = value
					Properties:INTERNAL_ToggleVisible(value)
					return debug.profileend()
				elseif key == 'Name' then
					Assert(value, 'string')
					Properties.Name = value
					return debug.profileend()
				end

				Properties[key] = value
				DrawingObject[key] = value
				debug.profileend()
			end
		end

		debug.profileend()
		return DrawingObj
	end)()
end
DrawingAPI = hookfunction(Drawing.new, OnNewDrawing)