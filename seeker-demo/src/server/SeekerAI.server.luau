--!strict
-- Connected Discord-GitHub
-- (If your GitHub is NOT linked to Discord, replace the line above with:)
-- Discord: YOUR_DISCORD_USERNAME | Roblox: YOUR_ROBLOX_USERNAME
--
-- ============================================================================
--  Seeker AI  -  a line-of-sight hunter NPC for hide-and-seek style games.
-- ============================================================================
--  WHAT THIS SCRIPT DOES
--  ---------------------
--  A single server Script that turns an ordinary R6/R15 rig into an autonomous
--  "Seeker". The Seeker drives itself with a three-state machine:
--
--      Patrol  ->  walks a loop of waypoint parts, scanning the world.
--      Chase   ->  a player entered its vision cone AND is unobstructed, so it
--                  runs them down until it either catches them or loses sight.
--      Search  ->  it lost the target; it travels to the last-known position
--                  and sweeps the area before giving up and resuming Patrol.
--
--  HOW DETECTION WORKS (the interesting math)
--  ------------------------------------------
--  "Can I see player X?" is answered in two cheap-to-expensive stages so we
--  never raycast more than we have to:
--      1. Cone test  - a dot product between the Seeker's flattened LookVector
--                      and the flattened direction to the target. If the target
--                      is outside the field-of-view angle we reject instantly.
--      2. Ray test   - only if the cone test passes do we fire a single ray to
--                      confirm nothing solid sits between the eye and the target.
--
--  A translucent "vision beam" part is CFrame-interpolated every frame so the
--  detection volume is visible in-game and recolours with the current state.
--
--  DESIGN NOTES
--  ------------
--  * The Seeker is built as a metatable-based class so several NPCs can run
--    independently from the same code with their own isolated state.
--  * Movement uses Humanoid:MoveTo, but we only re-issue the command when the
--    goal actually changes - re-spamming MoveTo every frame is wasteful.
--  * Raycasts are throttled to a fixed scan interval rather than run per-frame.
-- ============================================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- ----------------------------------------------------------------------------
--  CONFIG  -  every tunable in one place so the behaviour can be retuned
--  without hunting through the logic below.
-- ----------------------------------------------------------------------------
local CONFIG = {
	SEEKER_NAME = "Seeker", -- name of the rig Model in Workspace
	WAYPOINTS_FOLDER = "Waypoints", -- folder of BaseParts the Seeker patrols

	VIEW_DISTANCE = 60, -- how far (studs) the Seeker can see
	FIELD_OF_VIEW = 110, -- full cone angle in degrees
	EYE_HEIGHT = 2, -- vertical offset of the "eyes" above the root

	PATROL_SPEED = 8, -- WalkSpeed while patrolling
	CHASE_SPEED = 20, -- WalkSpeed while chasing
	SEARCH_SPEED = 12, -- WalkSpeed while searching

	WAYPOINT_REACH_DISTANCE = 4, -- how close counts as "arrived" at a waypoint
	CATCH_DISTANCE = 4, -- how close the Seeker must be to "catch" a player
	GOAL_RESET_DISTANCE = 2, -- only re-issue MoveTo if the goal moved this much

	SCAN_INTERVAL = 0.1, -- seconds between vision scans (throttle)
	SEARCH_DURATION = 5, -- seconds spent searching before giving up
	SEARCH_SWEEP_POINTS = 4, -- points sampled in a ring while searching
	SEARCH_RADIUS = 12, -- radius of the search sweep ring

	BEAM_LERP_ALPHA = 0.2, -- 0..1 easing factor for the vision beam each frame
}

-- State colours for the vision beam, indexed by the state string.
local STATE_COLOURS: { [string]: Color3 } = {
	Patrol = Color3.fromRGB(120, 200, 255),
	Search = Color3.fromRGB(255, 200, 60),
	Chase = Color3.fromRGB(255, 70, 70),
}

-- ----------------------------------------------------------------------------
--  TYPES
-- ----------------------------------------------------------------------------
type SeekerState = "Patrol" | "Chase" | "Search"

-- The exported object type. Declaring the field shape up-front lets --!strict
-- type-check every `self.field` access inside the methods below.
export type Seeker = typeof(setmetatable(
	{} :: {
		model: Model,
		humanoid: Humanoid,
		root: BasePart,

		state: SeekerState,
		waypoints: { BasePart },
		waypointIndex: number,

		target: Player?,
		lastKnownPosition: Vector3?,
		searchTimer: number,
		searchPoints: { Vector3 },
		searchIndex: number,

		currentGoal: Vector3?,
		scanAccumulator: number,
		beam: BasePart,

		raycastParams: RaycastParams,
		connection: RBXScriptConnection?,
	},
	{} :: SeekerImpl
))

-- Method table type. Separated out so `Seeker` (above) can reference it.
type SeekerImpl = {
	__index: SeekerImpl,
	new: (model: Model, waypoints: { BasePart }) -> Seeker,
	hasLineOfSight: (self: Seeker, targetRoot: BasePart) -> boolean,
	isInViewCone: (self: Seeker, targetPosition: Vector3) -> boolean,
	acquireTarget: (self: Seeker) -> Player?,
	goTo: (self: Seeker, position: Vector3) -> (),
	setState: (self: Seeker, newState: SeekerState) -> (),
	updateBeam: (self: Seeker) -> (),
	updatePatrol: (self: Seeker) -> (),
	updateChase: (self: Seeker) -> (),
	updateSearch: (self: Seeker, dt: number) -> (),
	onStep: (self: Seeker, dt: number) -> (),
	start: (self: Seeker) -> (),
	destroy: (self: Seeker) -> (),
}

-- ----------------------------------------------------------------------------
--  CLASS DEFINITION
-- ----------------------------------------------------------------------------
local Seeker = {} :: SeekerImpl
Seeker.__index = Seeker

-- Builds the translucent beam used to visualise the line of sight in-game.
-- Returned as a plain part the caller parents and owns; kept non-queryable so
-- it can never interfere with the Seeker's own detection raycasts.
local function createVisionBeam(): BasePart
	local beam = Instance.new("Part")
	beam.Name = "VisionBeam"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanTouch = false
	beam.CanQuery = false -- excluded from all raycasts implicitly
	beam.Massless = true
	beam.Material = Enum.Material.Neon
	beam.Transparency = 0.75
	-- A long, thin block. Its Z axis runs along the view direction so the part
	-- "points" out of the Seeker's face when oriented with CFrame.lookAt.
	beam.Size = Vector3.new(1.5, 1.5, CONFIG.VIEW_DISTANCE)
	return beam
end

-- Constructs a Seeker bound to an existing rig Model and a list of waypoints.
function Seeker.new(model: Model, waypoints: { BasePart }): Seeker
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	assert(humanoid, "Seeker model is missing a Humanoid")
	assert(root, "Seeker model is missing a HumanoidRootPart")

	-- Raycasts should ignore the Seeker's own body, otherwise its torso would
	-- block every line-of-sight test. We mutate this filter list as needed.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }

	local self = setmetatable({}, Seeker) :: Seeker
	self.model = model
	self.humanoid = humanoid
	self.root = root

	self.state = "Patrol"
	self.waypoints = waypoints
	self.waypointIndex = 1

	self.target = nil
	self.lastKnownPosition = nil
	self.searchTimer = 0
	self.searchPoints = {}
	self.searchIndex = 1

	self.currentGoal = nil
	self.scanAccumulator = 0
	self.raycastParams = params

	local beam = createVisionBeam()
	beam.Parent = model
	self.beam = beam

	self.humanoid.WalkSpeed = CONFIG.PATROL_SPEED
	return self
end

-- Fires a single ray from the Seeker's eyes to the target's root. Returns true
-- only if the very first thing the ray strikes belongs to the target - any
-- wall, prop, or other player in between counts as a blocked view.
function Seeker.hasLineOfSight(self: Seeker, targetRoot: BasePart): boolean
	local origin = self.root.Position + Vector3.new(0, CONFIG.EYE_HEIGHT, 0)
	local offset = targetRoot.Position - origin
	local result = Workspace:Raycast(origin, offset, self.raycastParams)

	-- Nothing was hit along the segment to the target: clear line of sight.
	if not result then
		return true
	end
	-- Something was hit; it only counts as "seen" if that something IS the
	-- target's character (e.g. we struck their torso, not a wall).
	return result.Instance:IsDescendantOf(targetRoot.Parent :: Instance)
end

-- Cheap angular gate run before any raycast. Both vectors are flattened onto
-- the XZ plane so the Seeker's pitch never affects the horizontal cone, then a
-- dot product is compared against cos(halfFOV). Targets directly overhead (zero
-- horizontal distance) are treated as inside the cone.
function Seeker.isInViewCone(self: Seeker, targetPosition: Vector3): boolean
	local toTarget = targetPosition - self.root.Position
	local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
	if flatToTarget.Magnitude < 1e-3 then
		return true
	end

	local look = self.root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude < 1e-3 then
		return false
	end

	-- dot of two unit vectors == cosine of the angle between them.
	local cosAngle = flatLook.Unit:Dot(flatToTarget.Unit)
	local cosHalfFov = math.cos(math.rad(CONFIG.FIELD_OF_VIEW * 0.5))
	return cosAngle >= cosHalfFov
end

-- Scans every player and returns the closest one that is alive, within range,
-- inside the cone, AND visible. Cheap checks (alive, distance, cone) run first
-- so the expensive raycast is only reached for genuine candidates.
function Seeker.acquireTarget(self: Seeker): Player?
	local origin = self.root.Position
	local closest: Player? = nil
	local closestDistance = CONFIG.VIEW_DISTANCE

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local targetRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not (character and humanoid and targetRoot) then
			continue
		end
		if humanoid.Health <= 0 then
			continue
		end

		local distance = (targetRoot.Position - origin).Magnitude
		if distance >= closestDistance then
			continue -- already have a nearer candidate, or out of range
		end
		if not self:isInViewCone(targetRoot.Position) then
			continue
		end
		if not self:hasLineOfSight(targetRoot) then
			continue
		end

		closest = player
		closestDistance = distance
	end

	return closest
end

-- Issues a walk command, but only when the destination has meaningfully moved.
-- Re-sending an identical MoveTo every frame would restart the pathing each
-- tick and is the classic source of jittery, "stuttering" NPCs.
function Seeker.goTo(self: Seeker, position: Vector3): ()
	local goal = self.currentGoal
	if goal and (goal - position).Magnitude < CONFIG.GOAL_RESET_DISTANCE then
		return
	end
	self.currentGoal = position
	self.humanoid:MoveTo(position)
end

-- Centralised state transition so per-state setup (speed, beam colour, timers)
-- lives in exactly one place and can never drift out of sync.
function Seeker.setState(self: Seeker, newState: SeekerState): ()
	if self.state == newState then
		return
	end
	self.state = newState
	self.currentGoal = nil -- force the next goTo to re-issue a MoveTo

	if newState == "Patrol" then
		self.humanoid.WalkSpeed = CONFIG.PATROL_SPEED
	elseif newState == "Chase" then
		self.humanoid.WalkSpeed = CONFIG.CHASE_SPEED
	elseif newState == "Search" then
		self.humanoid.WalkSpeed = CONFIG.SEARCH_SPEED
		self.searchTimer = CONFIG.SEARCH_DURATION
		self.searchIndex = 1
		self.searchPoints = {}

		-- Pre-compute a ring of sweep points around the last-known position by
		-- rotating a fixed forward offset about the world up axis with
		-- CFrame.Angles. This is the demo's main bit of CFrame construction.
		local centre = self.lastKnownPosition
		if centre then
			local step = (2 * math.pi) / CONFIG.SEARCH_SWEEP_POINTS
			for i = 0, CONFIG.SEARCH_SWEEP_POINTS - 1 do
				local rotation = CFrame.Angles(0, step * i, 0)
				local offset = rotation * CFrame.new(0, 0, -CONFIG.SEARCH_RADIUS)
				table.insert(self.searchPoints, centre + offset.Position)
			end
		end
	end
end

-- Eases the vision beam toward "pointing where the Seeker faces" every frame
-- and tints it to match the current state. Using CFrame:Lerp gives the beam a
-- smooth, weighty swing instead of snapping instantly to the new orientation.
function Seeker.updateBeam(self: Seeker): ()
	local eye = self.root.Position + Vector3.new(0, CONFIG.EYE_HEIGHT, 0)
	local look = self.root.CFrame.LookVector
	-- Place the beam's centre half its length ahead of the eye so its near end
	-- starts at the face, and orient it down the look direction.
	local centre = eye + look * (CONFIG.VIEW_DISTANCE * 0.5)
	local goalCFrame = CFrame.lookAt(centre, centre + look)

	self.beam.CFrame = self.beam.CFrame:Lerp(goalCFrame, CONFIG.BEAM_LERP_ALPHA)
	self.beam.Color = STATE_COLOURS[self.state]
end

-- PATROL: march toward the active waypoint; advance to the next once reached.
function Seeker.updatePatrol(self: Seeker): ()
	if #self.waypoints == 0 then
		return
	end

	local waypoint = self.waypoints[self.waypointIndex]
	self:goTo(waypoint.Position)

	local flatDistance = (waypoint.Position - self.root.Position) * Vector3.new(1, 0, 1)
	if flatDistance.Magnitude <= CONFIG.WAYPOINT_REACH_DISTANCE then
		-- Wrap the index with modulo so the patrol loops endlessly.
		self.waypointIndex = (self.waypointIndex % #self.waypoints) + 1
	end
end

-- CHASE: drive at the target. Catch them if close enough, drop to Search if the
-- target vanished, died, or broke line of sight this scan.
function Seeker.updateChase(self: Seeker): ()
	local target = self.target
	local character = target and target.Character
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

	if not (target and targetRoot) then
		self:setState("Search")
		return
	end

	self.lastKnownPosition = targetRoot.Position
	self:goTo(targetRoot.Position)

	local distance = (targetRoot.Position - self.root.Position).Magnitude
	if distance <= CONFIG.CATCH_DISTANCE then
		-- "Catch": tag the caught humanoid. Swap this for your own game logic
		-- (teleport, score, round-end event, etc.).
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:TakeDamage(humanoid.Health)
		end
		self.target = nil
		self:setState("Patrol")
	end
end

-- SEARCH: visit each pre-computed sweep point around the last-known position.
-- Re-acquiring the target promotes back to Chase; running out of time or points
-- demotes back to Patrol.
function Seeker.updateSearch(self: Seeker, dt: number): ()
	self.searchTimer -= dt

	local reacquired = self:acquireTarget()
	if reacquired then
		self.target = reacquired
		self:setState("Chase")
		return
	end

	if self.searchTimer <= 0 or self.searchIndex > #self.searchPoints then
		self:setState("Patrol")
		return
	end

	local point = self.searchPoints[self.searchIndex]
	self:goTo(point)

	local flatDistance = (point - self.root.Position) * Vector3.new(1, 0, 1)
	if flatDistance.Magnitude <= CONFIG.WAYPOINT_REACH_DISTANCE then
		self.searchIndex += 1
	end
end

-- Per-frame entry point. The vision scan is throttled to SCAN_INTERVAL so we
-- aren't raycasting at full frame-rate, then the active state is dispatched.
function Seeker.onStep(self: Seeker, dt: number): ()
	if self.humanoid.Health <= 0 then
		return
	end

	self.scanAccumulator += dt
	if self.scanAccumulator >= CONFIG.SCAN_INTERVAL then
		self.scanAccumulator = 0
		-- Patrol and Search both watch for targets; Chase tracks its own.
		if self.state ~= "Chase" then
			local spotted = self:acquireTarget()
			if spotted then
				self.target = spotted
				local spottedRoot = spotted.Character
					and spotted.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if spottedRoot then
					self.lastKnownPosition = spottedRoot.Position
				end
				self:setState("Chase")
			end
		end
	end

	if self.state == "Patrol" then
		self:updatePatrol()
	elseif self.state == "Chase" then
		self:updateChase()
	elseif self.state == "Search" then
		self:updateSearch(dt)
	end

	self:updateBeam()
end

-- Binds the Seeker's update loop to Heartbeat and stores the connection so it
-- can be cleanly severed in destroy().
function Seeker.start(self: Seeker): ()
	if self.connection then
		return
	end
	self.connection = RunService.Heartbeat:Connect(function(dt: number)
		self:onStep(dt)
	end)
end

-- Tears everything down: disconnect the loop and remove the beam. Always pair a
-- start() with a destroy() to avoid leaking a Heartbeat connection per NPC.
function Seeker.destroy(self: Seeker): ()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	if self.beam then
		self.beam:Destroy()
	end
end

-- ----------------------------------------------------------------------------
--  BOOTSTRAP  -  wires the demo place to the class above.
--  Expected Workspace layout:
--      Workspace/Seeker          (an R6 or R15 rig)
--      Workspace/Waypoints/...   (a folder of parts to patrol between)
-- ----------------------------------------------------------------------------
local function collectWaypoints(): { BasePart }
	local folder = Workspace:FindFirstChild(CONFIG.WAYPOINTS_FOLDER)
	local points: { BasePart } = {}
	if not folder then
		warn(("Seeker: no '%s' folder found in Workspace"):format(CONFIG.WAYPOINTS_FOLDER))
		return points
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(points, child)
		end
	end
	-- Sort by name so "Waypoint1, Waypoint2, ..." patrol in a predictable order.
	table.sort(points, function(a, b)
		return a.Name < b.Name
	end)
	return points
end

local function bootstrap(): ()
	local model = Workspace:WaitForChild(CONFIG.SEEKER_NAME, 10) :: Model?
	if not model then
		warn(("Seeker: no model named '%s' found in Workspace"):format(CONFIG.SEEKER_NAME))
		return
	end

	local waypoints = collectWaypoints()
	local seeker = Seeker.new(model, waypoints)
	seeker:start()

	-- Clean up if the rig is ever removed from the world (e.g. a round reset).
	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			seeker:destroy()
		end
	end)
end

bootstrap()
