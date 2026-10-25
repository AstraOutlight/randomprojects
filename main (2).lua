-- GelatekReanimate fork 0.1.0-rc1. See LICENSE.md and CREDITS.md.
local factories, cache = {}, {}
local require
require = function(name)
 if cache[name] ~= nil then return cache[name] end
 assert(factories[name], "unknown bundled module: "..tostring(name))
 local result = factories[name]()
 cache[name] = result
 return result
end
factories["adapters/standalone"] = function()
local Joints = require("core/joints")
return function()
    local Players=game:GetService("Players")
    local RunService=game:GetService("RunService")
    local Input=game:GetService("UserInputService")
    local player=Players.LocalPlayer
    local reanimate={Control={Jump=false}, CharacterLTMs={}}
    local connections={}
    local force, trackedRoot, jumpUntil
    local savedCameraSubject
    local mirroredHumanoid, mirroredSit
    local settings={TheoBridge={Gelatek={}}, AnimLibOptions={ReplicationWriters={}}}
    local context={Player=player, SaveData=settings, Reanimate=reanimate,
        GlobalBridge={}, Util=Joints, Config={}, Lifecycle={}}
    context.SaveSettingsNow=function() return false, "export GetSettings to save standalone settings" end -- caller exports GetSettings explicitly
    reanimate.Camera={Scriptable=false, IsMouseLocked=function()
        return Input.MouseBehavior==Enum.MouseBehavior.LockCenter
    end}
    function reanimate:ShouldRotationType()
        return self.ShiftlockEnabled and Input.MouseBehavior==Enum.MouseBehavior.LockCenter
    end
    function reanimate:CameraLockCharacter()
        local root=self.Character and self.Character:FindFirstChild("HumanoidRootPart")
        local camera=workspace.CurrentCamera
        if root and camera then
            local direction=camera.CFrame.LookVector*Vector3.new(1,0,1)
            if direction.Magnitude>0.001 then root.CFrame=CFrame.lookAt(root.Position,root.Position+direction) end
        end
    end
    function reanimate.ApplyControllerCollision(character, humanoid, root, noclipOverridesPassive)
        local state=humanoid:GetState().Name
        local passive=not table.find({"Running","Jumping","Freefall","Landed","Climbing","Swimming"},state)
        for _,part in character:GetChildren() do
            if part:IsA("BasePart") then
                part.CanCollide=(passive or (not reanimate.Noclip and part==root))
                    and not (noclipOverridesPassive and reanimate.Noclip)
            end
        end
        return state
    end
    function context.StopHost()
        for _,connection in ipairs(connections) do connection:Disconnect() end
        table.clear(connections)
        if force then force:Destroy(); force=nil end
        trackedRoot=nil
        if mirroredHumanoid and mirroredHumanoid.Parent then mirroredHumanoid.Sit=mirroredSit end
        mirroredHumanoid, mirroredSit=nil, nil
        jumpUntil=nil
        if workspace.CurrentCamera and savedCameraSubject and savedCameraSubject.Parent then
            workspace.CurrentCamera.CameraSubject=savedCameraSubject
        end
    end
    function context.StartHost(backend)
        context.StopHost()
        savedCameraSubject=workspace.CurrentCamera and workspace.CurrentCamera.CameraSubject
        table.insert(connections,Input.JumpRequest:Connect(function() jumpUntil=os.clock()+0.12 end))
        table.insert(connections,RunService.PreSimulation:Connect(function()
            reanimate.Control.Jump=jumpUntil~=nil and os.clock()<jumpUntil
            local rig=backend.Rig
            local humanoid=rig and rig:FindFirstChildOfClass("Humanoid")
            local root=rig and rig:FindFirstChild("HumanoidRootPart")
            if not backend.Running or not humanoid or not root then return end
            humanoid.WalkSpeed=reanimate.WalkSpeed
            humanoid.UseJumpPower=true
            humanoid.JumpPower=reanimate.JumpPower
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated,reanimate.SeatSit)
            if not reanimate.SeatSit then humanoid.Sit=false end
            if trackedRoot~=root then
                if force then force:Destroy() end
                force=Instance.new("BodyForce")
                force.Name="GelatekScaleGravity"
                force.Parent=root
                trackedRoot=root
            end
            local state=humanoid:GetState().Name
            local airborne=state=="Freefall" or state=="Jumping"
            force.Force=reanimate.ScaleGravity and airborne
                and Vector3.new(0,-workspace.Gravity*(reanimate.CharacterScale-1)*root.AssemblyMass,0)
                or Vector3.zero
            local realHumanoid=backend.RealCharacter and backend.RealCharacter:FindFirstChildOfClass("Humanoid")
            if realHumanoid and reanimate.SeatSit and reanimate.KeepSeatSitState and humanoid.SeatPart then
                if mirroredHumanoid~=realHumanoid then
                    mirroredHumanoid, mirroredSit=realHumanoid, realHumanoid.Sit
                end
                realHumanoid.Sit=humanoid.Sit
            elseif mirroredHumanoid then
                if mirroredHumanoid.Parent then mirroredHumanoid.Sit=mirroredSit end
                mirroredHumanoid, mirroredSit=nil, nil
            end
        end))
        table.insert(connections,RunService.PreRender:Connect(function(dt)
            local rig=backend.Rig
            local humanoid=rig and rig:FindFirstChildOfClass("Humanoid")
            local root=rig and rig:FindFirstChild("HumanoidRootPart")
            local camera=workspace.CurrentCamera
            if not backend.Running or not humanoid or not root or not camera then return end
            local focus=rig:FindFirstChild(reanimate.CameraFocusPart=="Root" and "HumanoidRootPart" or reanimate.CameraFocusPart) or root
            local desired=root.CFrame:PointToObjectSpace(focus.Position)-Vector3.new(0,1.5,0)
            humanoid.CameraOffset=reanimate.SmoothCam
                and humanoid.CameraOffset:Lerp(desired,1-math.exp(-9.8*dt)) or desired
            for _,part in ipairs(rig:GetChildren()) do
                if part:IsA("BasePart") then
                    part.Transparency=reanimate.ShowControllerCharacter and part~=root and 0.35 or 1
                end
            end
            -- The shared backend owns first-person visibility in every host.
            if reanimate:ShouldRotationType() then reanimate:CameraLockCharacter() end
        end))
        -- Native PlayerModule drives Player.Character after backend handoff.
        -- ToolGrab controls this adapter's contact auto-equip only.
        -- Game scripts/native pickup remain outside this adapter's authority.
        local touchConnections={}
        table.insert(connections,RunService.Heartbeat:Connect(function()
            local rig=backend.Rig
            if not backend.Running or not rig then return end
            for _,part in ipairs(rig:GetChildren()) do
                if part:IsA("BasePart") and not touchConnections[part] then
                    touchConnections[part]=true
                    table.insert(connections,part.Touched:Connect(function(hit)
                        if not reanimate.ToolGrab then return end
                        local tool=hit.Parent
                        local hum=rig:FindFirstChildOfClass("Humanoid")
                        if tool and tool:IsA("Tool") and tool.Parent==workspace and hum then hum:EquipTool(tool) end
                    end))
                end
            end
        end))
    end
    return context
end

end
factories["core/backend"] = function()

local Visibility=require("core/visibility")
return function(Context)
    local UI = Context.UI
    local SaveData = Context.SaveData
    local Reanimate = Context.Reanimate
    local Bridge = Context.GlobalBridge
    local Util = Context.Util
    local Player = Context.Player
    local RunService = game:GetService("RunService")
    local StarterGui = game:GetService("StarterGui")
    local Lifecycle = Context.Lifecycle or {}
    local SaveSettingsNow =
        type(Context.SaveSettingsNow) == "function"
        and Context.SaveSettingsNow
        or function()
            return false, "save callback unavailable"
        end

    SaveData.TheoBridge = type(SaveData.TheoBridge) == "table" and SaveData.TheoBridge or {}
    local options = type(SaveData.TheoBridge.Gelatek) == "table" and SaveData.TheoBridge.Gelatek or {}
    SaveData.TheoBridge.Gelatek = options

    local CURRENT_OPTIONS_SCHEMA = 11
    local defaults = {
        -- Match Gelatek's original behavior: its controller can animate even
        -- when permanent death is disabled and no Uhhhhhh moveset is active.
        AnimationsDisabled = false,
        DontBreakHairWelds = false,
        PermanentDeath = false,
        TeleportBackWhenVoided = false,
        AlignReanimate = false,
        FullForceAlign = false,
        FasterHeartbeat = false,
        DynamicalVelocity = false,
        DisableTweaks = false,
        LoadLibrary = false,
        DetailedCredits = false,
        TorsoFling = false,
        BulletEnabled = false,
        BulletRunAfter = false,
        BulletLockTorso = false,
        NonPDRecoveryRadiusPercent = 25,
        DirectPositionCorrection = false,
        RagdollSelfCollision = true,
        DisableDirectionalWalking = false,
        ShowMeHowILook = false,
        AntiSleep = true,
        RecoverBeforeVoid = true,
    }
    for key, value in pairs(defaults) do
        if options[key] == nil then
            options[key] = value
        end
    end
    options.NonPDRecoveryRadiusPercent =
        math.clamp(tonumber(options.NonPDRecoveryRadiusPercent) or 25, 5, 100)
    options.DirectPositionCorrection = options.DirectPositionCorrection == true
    options.DisableDirectionalWalking = options.DisableDirectionalWalking == true
    options.ShowMeHowILook = options.ShowMeHowILook == true

    -- Schema migrations are additive only. A new script version must not erase
    -- choices already stored in tree.ehehetilde.
    options.SchemaVersion = CURRENT_OPTIONS_SCHEMA

    SaveData.AnimLibOptions =
        type(SaveData.AnimLibOptions) == "table"
        and SaveData.AnimLibOptions
        or {}
    SaveData.AnimLibOptions.ReplicationWriters =
        type(SaveData.AnimLibOptions.ReplicationWriters) == "table"
        and SaveData.AnimLibOptions.ReplicationWriters
        or {}
    local replicationWriters = SaveData.AnimLibOptions.ReplicationWriters
    local writerDefaults = {
        GelatekTorso = "Gelatek Physics",
        GelatekHead = "CurrentAngle6D",
        LimbTorso = "CurrentAngle6D",
        LimbHead = "CurrentAngle6D",
        LimbRightArm = "CurrentAngle6D",
        LimbLeftArm = "CurrentAngle6D",
        LimbRightLeg = "CurrentAngle6D",
        LimbLeftLeg = "CurrentAngle6D",
    }
    for key, value in pairs(writerDefaults) do
        if replicationWriters[key] == nil then
            replicationWriters[key] = value
        end
    end
    -- Gelatek non-PD Torso intentionally uses Gelatek's native physical writer.
    -- Older experimental builds may have persisted a CurrentAngle torso mode.
    replicationWriters.GelatekTorso = "Gelatek Physics"
    local backend = {
        Name = "Gelatek",
        DetectedRig = nil,
        ControllerRig = nil,
        Rig = nil,
        RealCharacter = nil,
        ActiveRealCharacter = nil,
        StaticRoot = nil,
        RigGeneration = 0,
        Running = false,
        LastError = nil,
        EffectivePermanentDeath = false,
        PermanentDeathFallback = false,
        ServerPreparedPermanentDeath = false,
        IgnoreSharedFling = false,
    }

    local originalCharacter
    local originalCameraSubject
    local originalFace
    local cameraBridgeConnection
    local visibility=Visibility.new(Reanimate)
    local visibilityBinding="AetherVisibility_"..game:GetService("HttpService"):GenerateGUID(false)
    local scaleBridgeConnection
    local controllerCollisionConnection
    local ragdollCollisionFolder
    local neckBridgeConnection
    local physicalAnimatorConnection
    local safeTrackerConnection
    local limbRecoveryConnection
    local flingBridgeConnection
    local accessoryBodyHideConnection
    local accessoryRecoveryConnection
    local accessoryBodyHideWeldStates = setmetatable({}, { __mode = "k" })
    local accessoryRecoveryStates = setmetatable({}, { __mode = "k" })
    local lastAppliedScale
    local lastJump = false
    local activeFling = nil
    local recentFlingTargets = {}
    local destroyHeightCaptured = false
    local originalDestroyHeight
    local staticRootPart
    local staticRootCFrame
    local poseMirrorRig
    local poseMirrorConnection
    local placeholderModel
    local placeholderParts = {}
    local placeholderActive = false
    local resetBindable
    local resetBindableConnection
    local resetInFlight = false
    local rebindInProgress = false
    local pendingPhysicalCharacter
    local isolatedPartStates = setmetatable({}, { __mode = "k" })
    local accessoryTemplates = {}
    local accessorySnapshotCaptured = false
    local capturedSimulationRadius
    local capturedMaximumSimulationRadius

    local restoreAccessoryRecoveryStates = function() end
    -- Forward declaration: detachScaleBridge is defined before the production
    -- Head-writer implementation and must close over this local, not a nil global.
    local restoreGelatekHeadWriter = function() end
    local function readHiddenNumber(instance, propertyName)
        local getter = gethiddenproperty or gethiddenprop or get_hidden_property
        if type(getter) == "function" then
            local ok, value = pcall(getter, instance, propertyName)
            if ok and type(value) == "number" and value == value and value > 0 then
                return value
            end
        end
        local ok, value = pcall(function()
            return instance[propertyName]
        end)
        if ok and type(value) == "number" and value == value and value > 0 then
            return value
        end
        return nil
    end

    local function captureSimulationRadius()
        -- Capture before Gelatek's vendor loop overwrites both hidden properties
        -- with its huge ownership-claim values.
        if not capturedSimulationRadius then
            capturedSimulationRadius = readHiddenNumber(Player, "SimulationRadius")
        end
        if not capturedMaximumSimulationRadius then
            capturedMaximumSimulationRadius = readHiddenNumber(Player, "MaximumSimulationRadius")
        end
        backend.SimulationRadius = capturedSimulationRadius
        backend.MaximumSimulationRadius = capturedMaximumSimulationRadius
        local basis = capturedSimulationRadius or capturedMaximumSimulationRadius or 1000
        backend.NonPDRecoveryDistance =
            math.max(32, basis * (options.NonPDRecoveryRadiusPercent / 100))
        return basis
    end

    local function ownsPhysicalPart(part)
        if typeof(part) ~= "Instance"
            or not part:IsA("BasePart")
            or not part.Parent
        then
            return false
        end

        local assemblyRoot = part
        pcall(function()
            assemblyRoot = part.AssemblyRootPart or part
        end)

        -- Ownership belongs to the assembly. If isnetworkowner() can answer,
        -- an explicit false must stay false; ReceiveAge is not ownership proof.
        if type(isnetworkowner) == "function" then
            local rootOk, rootOwned =
                pcall(isnetworkowner, assemblyRoot)
            if rootOk then
                return rootOwned == true
            end

            local partOk, partOwned = pcall(isnetworkowner, part)
            if partOk then
                return partOwned == true
            end
        end

        -- Executor compatibility only. Never use this to override a successful
        -- isnetworkowner(false).
        local okAge, age = pcall(function()
            return assemblyRoot.ReceiveAge
        end)
        return okAge and age == 0 and assemblyRoot.Anchored ~= true
    end

    local function scaledRecoveryOffset(offset)
        offset = typeof(offset) == "CFrame" and offset or CFrame.identity
        local global = (getgenv and getgenv()) or shared or _G
        local scale = tonumber(global.UhhhhhhTBZGelatekCharacterSpacingScale) or 1
        return offset.Rotation + offset.Position * scale
    end

    local function bodyPartIsIntentionallyHidden(physicalPart, controllerPart)
        local global = (getgenv and getgenv()) or shared or _G
        local resolver = global.UhhhhhhTBZGetBodyHideTargetInfo
        if type(resolver) ~= "function" then
            return false
        end
        local ok, hidden = pcall(resolver, physicalPart, controllerPart)
        return ok and hidden == true
    end

    local function getGelatekRecoveryPairs(rig, physical)
        local pairsList = {}
        if not rig or not physical then
            return pairsList
        end

        local function add(physicalName, controllerName, offset, directOnly)
            local physicalPart = physical:FindFirstChild(physicalName)
            local controllerPart = rig:FindFirstChild(controllerName)
            if physicalPart and physicalPart:IsA("BasePart")
                and controllerPart and controllerPart:IsA("BasePart")
            then
                table.insert(pairsList, {
                    Physical = physicalPart,
                    Controller = controllerPart,
                    Offset = scaledRecoveryOffset(offset),
                    Name = physicalName,
                    DirectOnly = directOnly == true,
                })
            end
        end

        local isPD = backend.EffectivePermanentDeath == true

        if physical:FindFirstChild("UpperTorso") then
            -- Gelatek's R15 -> R6 mapping. These are the same positional offsets
            -- used by its Offsets table/CFrameAlign path.
            add("RightUpperArm", "Right Arm", CFrame.new(0, 0.4085, 0))
            add("RightLowerArm", "Right Arm", CFrame.new(0, -0.184, 0))
            add("RightHand", "Right Arm", CFrame.new(0, -0.83, 0))

            add("LeftUpperArm", "Left Arm", CFrame.new(0, 0.4085, 0))
            add("LeftLowerArm", "Left Arm", CFrame.new(0, -0.184, 0))
            add("LeftHand", "Left Arm", CFrame.new(0, -0.83, 0))

            add("RightUpperLeg", "Right Leg", CFrame.new(0, 0.575, 0))
            add("RightLowerLeg", "Right Leg", CFrame.new(0, -0.199, 0))
            add("RightFoot", "Right Leg", CFrame.new(0, -0.849, 0))

            add("LeftUpperLeg", "Left Leg", CFrame.new(0, 0.575, 0))
            add("LeftLowerLeg", "Left Leg", CFrame.new(0, -0.199, 0))
            add("LeftFoot", "Left Leg", CFrame.new(0, -0.849, 0))

            -- Torso pieces are native Gelatek physics followers in non-PD.
            -- Direct Position Correction may hard-correct their position every
            -- frame, but ordinary haymaker recovery leaves them alone.
            add("UpperTorso", "Torso", CFrame.new(0, 0.194, 0), not isPD)
            add("LowerTorso", "Torso", CFrame.new(0, -0.79, 0), not isPD)
            if isPD then
                add("Head", "Head", CFrame.identity)
            end
        else
            add("Right Arm", "Right Arm", CFrame.identity)
            add("Left Arm", "Left Arm", CFrame.identity)
            add("Right Leg", "Right Leg", CFrame.identity)
            add("Left Leg", "Left Leg", CFrame.identity)

            add("Torso", "Torso", CFrame.identity, not isPD)
            if isPD then
                add("Head", "Head", CFrame.identity)
            end
        end

        -- Detached accessories use Gelatek's exact object->target map. This is
        -- valid in PD and non-PD: non-PD destroys many AccessoryWelds too.
        local global = (getgenv and getgenv()) or shared or _G
        local targetMap = global.UhhhhhhTBZGelatekAccessoryTargets
        if type(targetMap) == "table" then
            for _, accessory in ipairs(physical:GetChildren()) do
                if accessory:IsA("Accessory") then
                    local physicalHandle = accessory:FindFirstChild("Handle")
                    local controllerAccessory = targetMap[accessory]
                    local controllerHandle =
                        controllerAccessory
                        and controllerAccessory:IsA("Accessory")
                        and controllerAccessory:FindFirstChild("Handle")

                    if physicalHandle
                        and physicalHandle:IsA("BasePart")
                        and controllerHandle
                        and controllerHandle:IsA("BasePart")
                    then
                        local liveAccessoryWeld =
                            physicalHandle:FindFirstChild("AccessoryWeld")
                        local detached =
                            isPD
                            or not (
                                liveAccessoryWeld
                                and liveAccessoryWeld:IsA("JointInstance")
                                and liveAccessoryWeld.Enabled ~= false
                            )
                        if detached then
                            table.insert(pairsList, {
                                Physical = physicalHandle,
                                Controller = controllerHandle,
                                Offset = CFrame.identity,
                                Name = accessory.Name .. ".Handle",
                                IsAccessory = true,
                            })
                        end
                    end
                end
            end
        end

        return pairsList
    end

    local function environment()
        return (getgenv and getgenv()) or shared or _G
    end

    local function preparePermanentDeathWithServerCodeRemote()
        local activeCharacter = Player.Character
        if activeCharacter
            and activeCharacter:GetAttribute("UhhhhhhServerGelatekPrepared") == true
            and activeCharacter:GetAttribute("UhhhhhhServerGelatekPD") == true
        then
            return true, {
                NeckJointsBroken = 0,
                OwnedParts = 0,
                GenericLoadstringRemote = true,
            }
        end
        return false
    end

    local function suppressPhysicalAnimation(character)
        if typeof(character) ~= "Instance"
            or not character:IsA("Model")
            or not character.Parent
        then
            return
        end

        local animate = character:FindFirstChild("Animate")
        if animate and animate:IsA("LocalScript") then
            pcall(function()
                animate.Disabled = true
            end)
        end

        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            for _, child in ipairs(humanoid:GetChildren()) do
                if child:IsA("Animator") then
                    pcall(function()
                        child:Destroy()
                    end)
                end
            end
        end
    end

    local function attachPhysicalAnimationSuppression(character)
        if physicalAnimatorConnection then
            pcall(function()
                physicalAnimatorConnection:Disconnect()
            end)
            physicalAnimatorConnection = nil
        end

        suppressPhysicalAnimation(character)
        if typeof(character) ~= "Instance" or not character.Parent then
            return
        end

        physicalAnimatorConnection =
            character.DescendantAdded:Connect(function(instance)
                if not backend.Running
                    or backend.EffectivePermanentDeath == true
                then
                    return
                end

                if instance:IsA("Animator") then
                    task.defer(function()
                        if instance.Parent then
                            pcall(function()
                                instance:Destroy()
                            end)
                        end
                    end)
                elseif instance:IsA("LocalScript")
                    and instance.Name == "Animate"
                then
                    pcall(function()
                        instance.Disabled = true
                    end)
                end
            end)
    end

    local function isolatePhysicalCharacter(character)
        -- Never let a handoff reference turn the animation controller into
        -- a frozen, non-collidable physical shell.
        if character == backend.Rig or character == Reanimate.Character then
            return
        end
        if typeof(character) ~= "Instance" or not character:IsA("Model") or not character.Parent then
            return
        end
        for _, instance in ipairs(character:GetDescendants()) do
            if instance:IsA("BasePart") then
                if not isolatedPartStates[instance] then
                    isolatedPartStates[instance] = {
                        CanCollide = instance.CanCollide,
                        CanTouch = instance.CanTouch,
                        CanQuery = instance.CanQuery,
                    }
                end
                -- A CharacterAdded shell can overlap the persistent controller
                -- for several simulation steps before Gelatek maps its parts.
                -- Remove every contact/query path and any inherited spawn
                -- impulse for that short hand-off window.
                instance.CanCollide = false
                instance.CanTouch = false
                instance.CanQuery = false
                instance.AssemblyLinearVelocity = Vector3.zero
                instance.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end

    local function restoreIsolatedPhysicalCharacter(character)
        if typeof(character) ~= "Instance" or not character:IsA("Model") or not character.Parent then
            return
        end
        for _, instance in ipairs(character:GetDescendants()) do
            if instance:IsA("BasePart") then
                local state = isolatedPartStates[instance]
                if state then
                    pcall(function()
                        instance.CanCollide = state.CanCollide
                        instance.CanTouch = state.CanTouch
                        instance.CanQuery = state.CanQuery
                    end)
                    isolatedPartStates[instance] = nil
                end
            end
        end
    end

    local function collectReadyAccessories(character)
        local accessories = {}
        if typeof(character) ~= "Instance" or not character:IsA("Model") then
            return accessories, false
        end
        local allReady = true
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Accessory") then
                if child:FindFirstChild("Handle") then
                    table.insert(accessories, child)
                else
                    allReady = false
                end
            end
        end
        return accessories, allReady
    end

    local function clearAccessoryTemplates()
        for _, template in ipairs(accessoryTemplates) do
            pcall(function()
                template:Destroy()
            end)
        end
        table.clear(accessoryTemplates)
        accessorySnapshotCaptured = false
    end

    local function snapshotAccessoryAppearance(character)
        local accessories = collectReadyAccessories(character)
        local replacements = {}
        for _, accessory in ipairs(accessories) do
            local ok, clone = pcall(function()
                return accessory:Clone()
            end)
            if ok and clone and clone:IsA("Accessory") and clone:FindFirstChild("Handle") then
                clone.Parent = nil
                table.insert(replacements, clone)
            end
        end
        clearAccessoryTemplates()
        for _, replacement in ipairs(replacements) do
            table.insert(accessoryTemplates, replacement)
        end
        accessorySnapshotCaptured = true
        return #accessoryTemplates
    end

    local function restoreMissingAccessories(character, humanoid)
        if not accessorySnapshotCaptured or #accessoryTemplates == 0 then
            return 0
        end
        local existing = {}
        for _, accessory in ipairs(collectReadyAccessories(character)) do
            existing[accessory.Name] = (existing[accessory.Name] or 0) + 1
        end
        local visited = {}
        local restored = 0
        for _, template in ipairs(accessoryTemplates) do
            local name = template.Name
            visited[name] = (visited[name] or 0) + 1
            if visited[name] > (existing[name] or 0) then
                local ok, clone = pcall(function()
                    return template:Clone()
                end)
                if ok and clone and clone:IsA("Accessory") then
                    local handle = clone:FindFirstChild("Handle")
                    if handle then
                        for _, child in ipairs(handle:GetChildren()) do
                            if child:IsA("Weld") and child.Name == "AccessoryWeld" then
                                child:Destroy()
                            end
                        end
                        clone:SetAttribute("_UhhhhhhGelatekRestoredAccessory", true)
                        local added = pcall(function()
                            humanoid:AddAccessory(clone)
                        end)
                        if not added or not clone.Parent then
                            clone.Parent = character
                        end
                        restored += 1
                    else
                        clone:Destroy()
                    end
                end
            end
        end
        return restored
    end

    local function addDescription(parent, text)
        UI.CreateText(parent, text, 9, Enum.TextXAlignment.Left)
    end

    local function persistOption(label)
        local saved, reason = SaveSettingsNow()
        if not saved then
            warn("Gelatek save failed " .. tostring(label) .. ": " .. tostring(reason))
            Util.Notify("Failed to save Gelatek setting")
        end
        return saved
    end

    local function addSwitch(parent, text, key, description)
        local control = UI.CreateSwitch(parent, text, options[key])
        control.Changed:Connect(function(value)
            options[key] = value == true
            if key == "AntiSleep" then
                environment().UhhhhhhTBZGelatekAntiSleep = options.AntiSleep
            elseif key == "DirectPositionCorrection" then
                local config = environment().GelatekReanimateConfig
                if type(config) == "table" then
                    config.DirectPositionCorrection = options.DirectPositionCorrection
                end
            end
            persistOption(text)
        end)
        if description then
            addDescription(parent, "-> " .. description)
        end
        return control
    end


    local function compatibility()
        local missing = {}
        if type(sethiddenproperty) ~= "function"
            and type(sethiddenprop) ~= "function"
            and type(set_hidden_property) ~= "function"
        then
            table.insert(missing, "sethiddenproperty")
        end
        if type(loadstring) ~= "function" then
            table.insert(missing, "loadstring")
        end
        return #missing == 0, missing
    end

    local function debugSafe(callable, fallback)
        local ok, value = pcall(callable)
        if ok then
            return value
        end
        return fallback
    end

    local function debugVector(value)
        if typeof(value) ~= "Vector3" then
            return "nil"
        end
        return string.format("%.3f,%.3f,%.3f", value.X, value.Y, value.Z)
    end

    local function debugCFrame(value)
        if typeof(value) ~= "CFrame" then
            return "nil"
        end
        local x, y, z = value:ToOrientation()
        return string.format(
            "P(%.3f,%.3f,%.3f) R(%.1f,%.1f,%.1f)",
            value.X,
            value.Y,
            value.Z,
            math.deg(x),
            math.deg(y),
            math.deg(z)
        )
    end

    local function debugPath(instance)
        if typeof(instance) ~= "Instance" then
            return "nil"
        end
        return debugSafe(function()
            return instance:GetFullName()
        end, instance.Name)
    end

    local function debugNetworkOwner(part)
        if not part or not part:IsA("BasePart") then
            return "n/a"
        end
        local ok, owned = pcall(isnetworkowner, part)
        return ok and tostring(owned) or "unsupported"
    end

    local function debugPart(label, part, lines)
        if not part or not part:IsA("BasePart") then
            table.insert(lines, label .. "=MISSING")
            return
        end
        local assemblyRoot = debugSafe(function()
            return part.AssemblyRootPart
        end, nil)
        table.insert(lines, string.format(
            "%s=%s | cf=%s | vel=%s | asmRoot=%s | owned=%s receiveAge=%s | massless=%s | priority=%s | collide=%s",
            label,
            debugPath(part),
            debugCFrame(part.CFrame),
            debugVector(part.AssemblyLinearVelocity),
            assemblyRoot and debugPath(assemblyRoot) or "nil",
            debugNetworkOwner(part),
            tostring(debugSafe(function() return part.ReceiveAge end, "n/a")),
            tostring(part.Massless),
            tostring(part.RootPriority),
            tostring(part.CanCollide)
        ))
        table.insert(lines, string.format(
            "%s physics: anchored=%s collisionGroup=%s sleeping=%s",
            label, tostring(part.Anchored), tostring(part.CollisionGroup),
            tostring(debugSafe(function()
                return gethiddenproperty(assemblyRoot or part, "NetworkIsSleeping")
            end, "unavailable"))
        ))
    end

    local function debugFindJoint(character, part0Name, part1Name)
        local constraint, motor
        if not character then
            return constraint, motor
        end
        for _, joint in ipairs(character:GetDescendants()) do
            if Util.IsCharacterJoint(joint) then
                local p0, p1 = Util.GetCharacterJointParts(joint)
                if p0 and p1
                    and p0.Name == part0Name
                    and p1.Name == part1Name
                then
                    if joint:IsA("Motor6D") then
                        motor = joint
                    else
                        constraint = joint
                    end
                end
            end
        end
        return constraint, motor
    end

    local function debugJoint(label, character, part0Name, part1Name, lines)
        local constraint, motor =
            debugFindJoint(character, part0Name, part1Name)

        local function append(kind, joint)
            if not joint then
                table.insert(lines, label .. "." .. kind .. "=MISSING")
                return
            end

            local enabled = debugSafe(function()
                return joint.Enabled
            end, "n/a")
            local active = debugSafe(function()
                return joint.Active
            end, "n/a")
            local transform = debugSafe(function()
                return joint.Transform
            end, nil)
            local currentAngle = debugSafe(function()
                return joint.CurrentAngle
            end, "n/a")
            local desiredAngle = debugSafe(function()
                return joint.DesiredAngle
            end, "n/a")
            local repAngle = debugSafe(function()
                return gethiddenproperty(joint, "ReplicateCurrentAngle6D")
            end, nil)
            local repOffset = debugSafe(function()
                return gethiddenproperty(joint, "ReplicateCurrentOffset6D")
            end, nil)

            table.insert(lines, string.format(
                "%s.%s=%s | enabled=%s active=%s | Transform=%s | CurrentAngle=%s DesiredAngle=%s | RepAngle=%s RepOffset=%s",
                label,
                kind,
                debugPath(joint),
                tostring(enabled),
                tostring(active),
                debugCFrame(transform),
                tostring(currentAngle),
                tostring(desiredAngle),
                debugVector(repAngle),
                debugVector(repOffset)
            ))
        end

        append("Constraint", constraint)
        append("Motor", motor)
    end

    local function debugHumanoid(label, humanoid, lines)
        if not humanoid then
            table.insert(lines, label .. ".Humanoid=MISSING")
            return
        end

        table.insert(lines, string.format(
            "%s.Humanoid=%s | state=%s | Evaluate=%s | AutoRotate=%s | Sit=%s | MoveDirection=%s | WalkSpeed=%s",
            label,
            debugPath(humanoid),
            humanoid:GetState().Name,
            tostring(humanoid.EvaluateStateMachine),
            tostring(humanoid.AutoRotate),
            tostring(humanoid.Sit),
            debugVector(humanoid.MoveDirection),
            tostring(humanoid.WalkSpeed)
        ))

        local animator = humanoid:FindFirstChildOfClass("Animator")
        local animate = humanoid.Parent and humanoid.Parent:FindFirstChild("Animate")
        local tracks = {}
        if animator then
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                local animation = track.Animation
                table.insert(tracks, string.format(
                    "%s[%s] weight=%.3f speed=%.3f playing=%s",
                    track.Name,
                    animation and animation.AnimationId or "?",
                    track.WeightCurrent,
                    track.Speed,
                    tostring(track.IsPlaying)
                ))
            end
        end

        table.insert(lines, string.format(
            "%s.Animator=%s | Animate=%s disabled=%s | tracks=%d {%s}",
            label,
            animator and debugPath(animator) or "nil",
            animate and debugPath(animate) or "nil",
            animate and tostring(debugSafe(function()
                return animate.Disabled
            end, "n/a")) or "n/a",
            #tracks,
            table.concat(tracks, " ; ")
        ))
    end

    local function debugDistance(label, first, second, lines)
        if first and second
            and first:IsA("BasePart")
            and second:IsA("BasePart")
        then
            table.insert(lines, string.format(
                "%s=%.3f studs",
                label,
                (first.Position - second.Position).Magnitude
            ))
        end
    end

    local function buildGelatekRuntimeDump()
        local lines = {}
        local rig = backend.Rig
        local physical = backend.RealCharacter or originalCharacter
        local staticRoot = backend.StaticRoot or staticRootPart

        local cRoot = rig and rig:FindFirstChild("HumanoidRootPart")
        local cTorso = rig and (
            rig:FindFirstChild("Torso")
            or rig:FindFirstChild("UpperTorso")
        )
        local cHead = rig and rig:FindFirstChild("Head")

        local pRoot = physical and physical:FindFirstChild("HumanoidRootPart")
        local pLower = physical and physical:FindFirstChild("LowerTorso")
        local pTorso = physical and (
            physical:FindFirstChild("UpperTorso")
            or physical:FindFirstChild("Torso")
        )
        local pHead = physical and physical:FindFirstChild("Head")

        table.insert(lines, "=== GELATEK RUNTIME DUMP ===")
        table.insert(lines, "clock=" .. tostring(os.clock()))
        table.insert(lines, "running=" .. tostring(backend.Running))
        table.insert(lines, "generation=" .. tostring(backend.RigGeneration))
        table.insert(lines, "detectedRig=" .. tostring(backend.DetectedRig))
        table.insert(lines, "effectivePD=" .. tostring(backend.EffectivePermanentDeath))
        table.insert(lines, "fallbackPD=" .. tostring(backend.PermanentDeathFallback))
        table.insert(
            lines,
            "options=" .. game:GetService("HttpService"):JSONEncode(options)
        )
        table.insert(lines, "controller=" .. debugPath(rig))
        table.insert(lines, "physical=" .. debugPath(physical))
        table.insert(lines, "staticRoot=" .. debugPath(staticRoot))
        table.insert(lines, string.format(
            "ROTATION RotationType=%s Shiftlocked=%s MouseLocked=%s DisableDirectionalWalking=%s",
            tostring(debugSafe(function()
                return UserSettings():GetService("UserGameSettings").RotationType
            end, "n/a")),
            tostring(Reanimate.Shiftlocked),
            tostring(
                type(Reanimate.Camera) == "table"
                and type(Reanimate.Camera.IsMouseLocked) == "function"
                and Reanimate.Camera:IsMouseLocked()
                or false
            ),
            tostring(options.DisableDirectionalWalking)
        ))

        debugHumanoid(
            "C",
            rig and rig:FindFirstChildOfClass("Humanoid"),
            lines
        )
        debugHumanoid(
            "P",
            physical and physical:FindFirstChildOfClass("Humanoid"),
            lines
        )

        debugPart("C.Root", cRoot, lines)
        debugPart("C.Torso", cTorso, lines)
        debugPart("C.Head", cHead, lines)
        debugPart("P.Root", pRoot, lines)
        debugPart("P.LowerTorso", pLower, lines)
        debugPart("P.Torso", pTorso, lines)
        debugPart("P.Head", pHead, lines)
        debugPart("StaticRoot", staticRoot, lines)

        debugDistance("DIST.Root(C-P)", cRoot, pRoot, lines)
        debugDistance("DIST.Torso(C-P)", cTorso, pTorso, lines)
        debugDistance("DIST.Head(C-P)", cHead, pHead, lines)
        debugDistance("DIST.Static-C.Root", staticRoot, cRoot, lines)
        debugDistance("DIST.Static-P.Root", staticRoot, pRoot, lines)

        if pTorso and pTorso:IsA("BasePart") then
            local torsoIsRoot = debugSafe(function()
                return pTorso.AssemblyRootPart == pTorso
            end, false)
            table.insert(lines, string.format(
                "FALLBACK_AUTHORITY TorsoAssemblyRoot=%s TorsoPriority=%s TorsoMassless=%s HeadPriority=%s HeadMassless=%s RootPriority=%s RootMassless=%s",
                tostring(torsoIsRoot),
                tostring(pTorso.RootPriority),
                tostring(pTorso.Massless),
                tostring(pHead and pHead.RootPriority or "nil"),
                tostring(pHead and pHead.Massless or "nil"),
                tostring(pRoot and pRoot.RootPriority or "nil"),
                tostring(pRoot and pRoot.Massless or "nil")
            ))
        end

        table.insert(lines, string.format(
            "ANIMATION_BRIDGE PoseCharacter=%s PoseSerial=%s CachedJoints=%s RobloxTrackActive=%s",
            debugPath(__TheoGelatekPoseCharacter),
            tostring(__TheoGelatekPoseSerial),
            tostring((function()
                local count = 0
                for _ in pairs(type(__TheoGelatekPoseCache) == "table" and __TheoGelatekPoseCache or {}) do
                    count += 1
                end
                return count
            end)()),
            tostring(type(__TheoHasPlayingRobloxTrack) == "function" and __TheoHasPlayingRobloxTrack(rig) or false)
        ))

        if rig then
            debugJoint("C.RootTorso", rig, "HumanoidRootPart", "Torso", lines)
            debugJoint("C.TorsoHead", rig, "Torso", "Head", lines)
        end

        if physical then
            if physical:FindFirstChild("UpperTorso") then
                debugJoint(
                    "P.RootLower",
                    physical,
                    "HumanoidRootPart",
                    "LowerTorso",
                    lines
                )
                debugJoint(
                    "P.LowerUpper",
                    physical,
                    "LowerTorso",
                    "UpperTorso",
                    lines
                )
                debugJoint(
                    "P.UpperHead",
                    physical,
                    "UpperTorso",
                    "Head",
                    lines
                )
            else
                debugJoint(
                    "P.RootTorso",
                    physical,
                    "HumanoidRootPart",
                    "Torso",
                    lines
                )
                debugJoint(
                    "P.TorsoHead",
                    physical,
                    "Torso",
                    "Head",
                    lines
                )
            end
        end

        local env = (getgenv and getgenv()) or shared or _G
        table.insert(lines, "--- CFrameAlign ---")
        local stats = env.UhhhhhhTBZGelatekAlignStats
        if type(stats) == "table" then
            for part, stat in pairs(stats) do
                if typeof(part) == "Instance" and type(stat) == "table" then
                    table.insert(lines, string.format(
                        "%s | calls=%s owned=%s unowned=%s currentOwned=%s | targetPart=%s target=%s | errorBefore=%s errorAfter=%s",
                        debugPath(part),
                        tostring(stat.Calls),
                        tostring(stat.OwnedCalls),
                        tostring(stat.UnownedCalls),
                        tostring(stat.NetworkOwned),
                        tostring(stat.Part1Name),
                        debugCFrame(stat.TargetCFrame),
                        tostring(stat.ErrorBefore),
                        tostring(stat.ErrorAfter)
                    ))
                end
            end
        else
            table.insert(lines, "CFrameAlign stats unavailable")
        end

        if type(Reanimate.ShouldBodyHidePart) == "function" then
            table.insert(lines, string.format(
                "BodyHide Root=%s Torso=%s Head=%s",
                tostring(Reanimate.ShouldBodyHidePart("HumanoidRootPart")),
                tostring(Reanimate.ShouldBodyHidePart("Torso")),
                tostring(Reanimate.ShouldBodyHidePart("Head"))
            ))
        end

        local detachedAccessoryWelds = {}
        for weld, originalEnabled in pairs(accessoryBodyHideWeldStates) do
            if typeof(weld) == "Instance" and weld.Parent then
                local enabled = debugSafe(function()
                    return weld.Enabled
                end, "n/a")
                if enabled == false then
                    table.insert(
                        detachedAccessoryWelds,
                        string.format(
                            "%s(original=%s)",
                            debugPath(weld),
                            tostring(originalEnabled)
                        )
                    )
                end
            end
        end
        table.insert(
            lines,
            "ACCESSORY_HIDE detachedWelds="
                .. tostring(#detachedAccessoryWelds)
                .. " {"
                .. table.concat(detachedAccessoryWelds, " ; ")
                .. "}"
        )

        local recoveryNames = {}
        local recoveryPhysical = backend.RealCharacter or originalCharacter
        if rig and recoveryPhysical then
            for _, pair in ipairs(getGelatekRecoveryPairs(rig, recoveryPhysical)) do
                table.insert(recoveryNames, tostring(pair.Name))
            end
        end
        table.insert(
            lines,
            "RECOVERY_COVERAGE PD="
                .. tostring(backend.EffectivePermanentDeath)
                .. " {"
                .. table.concat(recoveryNames, ", ")
                .. "}"
        )

        local physicalAnimatorCount = 0
        local physicalAnimateState = "missing"
        if physical then
            for _, descendant in ipairs(physical:GetDescendants()) do
                if descendant:IsA("Animator") then
                    physicalAnimatorCount += 1
                end
            end
            local physicalAnimate = physical:FindFirstChild("Animate")
            if physicalAnimate and physicalAnimate:IsA("LocalScript") then
                physicalAnimateState =
                    physicalAnimate.Disabled and "disabled" or "enabled"
            end
        end
        table.insert(
            lines,
            "NONPD_ROOT_FOLLOW RootIsAssemblyRoot="
                .. tostring(
                    pRoot
                    and debugSafe(
                        function()
                            return pRoot.AssemblyRootPart == pRoot
                        end,
                        false
                    )
                    or false
                )
                .. " RootOwned="
                .. tostring(pRoot and debugNetworkOwner(pRoot) or "n/a")
                .. " PhysicalAnimators="
                .. tostring(physicalAnimatorCount)
                .. " PhysicalAnimate="
                .. tostring(physicalAnimateState)
        )

        table.insert(
            lines,
            "DIRECT_CORRECTION enabled="
                .. tostring(options.DirectPositionCorrection)
                .. " recoveryDistance="
                .. tostring(backend.NonPDRecoveryDistance)
        )

        local headMoverNames = {}
        if pHead then
            for _, child in ipairs(pHead:GetChildren()) do
                if child:IsA("BodyMover")
                    or child:IsA("LinearVelocity")
                    or child:IsA("AngularVelocity")
                then
                    table.insert(
                        headMoverNames,
                        child.ClassName .. ":" .. child.Name
                    )
                end
            end
        end
        table.insert(
            lines,
            "HEAD_TRANSPORT BodyMovers={"
                .. table.concat(headMoverNames, ", ")
                .. "} hidden="
                .. tostring(
                    type(Reanimate.ShouldBodyHidePart) == "function"
                    and Reanimate.ShouldBodyHidePart("Head") == true
                    or false
                )
        )

        local accessoryStateCount = 0
        local accessoryWriteCount = 0
        local accessoryOwnership = {}
        for handle, state in pairs(accessoryRecoveryStates) do
            if handle and handle.Parent and type(state) == "table" then
                accessoryStateCount += 1
                accessoryWriteCount += tonumber(state.Writes) or 0
                local source = state.OwnershipSource or "unknown"
                accessoryOwnership[source] =
                    (accessoryOwnership[source] or 0) + 1
            end
        end
        local ownershipSummary = {}
        for source, count in pairs(accessoryOwnership) do
            table.insert(
                ownershipSummary,
                tostring(source) .. "=" .. tostring(count)
            )
        end
        table.sort(ownershipSummary)
        table.insert(
            lines,
            "ACCESSORY_TRANSPORT states="
                .. tostring(accessoryStateCount)
                .. " writes="
                .. tostring(accessoryWriteCount)
                .. " {"
                .. table.concat(ownershipSummary, ", ")
                .. "}"
        )

        table.insert(
            lines,
            "WRITE_METHODS GelatekTorso="
                .. tostring(replicationWriters.GelatekTorso)
                .. " GelatekHead="
                .. tostring(replicationWriters.GelatekHead)
        )

        table.insert(lines, "=== END GELATEK RUNTIME DUMP ===")
        return table.concat(lines, "\n")
    end

    backend.GetDebugDump = buildGelatekRuntimeDump
    local debugEnvironment = (getgenv and getgenv()) or shared or _G
    debugEnvironment.UhhhhhhGelatekDebugDump = function()
        local dump = buildGelatekRuntimeDump()
        warn(dump)
        return dump
    end

    function backend.Config(parent)
        local ok, missing = compatibility()
        local character = Player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local detected = humanoid and humanoid.RigType.Name or "unknown"

        UI.CreateText(
            parent,
            "<b>Gelatek</b>\nDetected rig: " .. detected,
            18,
            Enum.TextXAlignment.Center
        )
        UI.CreateText(
            parent,
            "Non-PD keeps Torso on Gelatek's native physical follower. Head is driven from the physical Torso by the selected replication writer.",
            9,
            Enum.TextXAlignment.Center
        )
        UI.CreateText(
            parent,
            "Head write method: Animation Options > Write Methods / Replication Writers",
            9,
            Enum.TextXAlignment.Center
        )
        UI.CreateSeparator(parent)

        UI.CreateText(parent, "<b>Basic</b>", 14, Enum.TextXAlignment.Left)
        addSwitch(parent, "Permanent Death", "PermanentDeath")
        addSwitch(parent, "Anti-sleep (live)", "AntiSleep",
            "Optional Gelatek follower dither, separate from netless velocity. Changes apply during reanimation.")
        addSwitch(parent, "Ragdoll Self Collision (live)", "RagdollSelfCollision",
            "On preserves normal body self-contact. Off disables only body-to-body contact in passive states; map collision is unchanged.")
        addSwitch(
            parent,
            "Direct Position Correction (live)",
            "DirectPositionCorrection",
            "Corrects owned limbs and accessories before physics, including constraint alignment mode."
        )
        addSwitch(parent, "Teleport Back When Voided", "TeleportBackWhenVoided")
        addSwitch(parent, "Recover Before Void (live)", "RecoverBeforeVoid",
            "Moves the whole controller back to its last grounded position before it reaches the void.")
        addSwitch(
            parent,
            "Disable Directional Walking",
            "DisableDirectionalWalking",
            "Uses vanilla MovementRelative unshiftlocked and CameraRelative in shiftlock/first-person."
        )
        addSwitch(
            parent,
            "Show me how I look!",
            "ShowMeHowILook",
            "Only the non-PD Head writer is sampled at 10 FPS. Torso stays full-rate physics."
        )

        UI.CreateText(parent, "<b>Physical recovery</b>", 12, Enum.TextXAlignment.Left)
        local recoveryPercent = UI.CreateSlider(
            parent,
            "Recovery Distance (% SimulationRadius)",
            options.NonPDRecoveryRadiusPercent,
            5,
            100,
            5
        )
        recoveryPercent.Changed:Connect(function(value)
            options.NonPDRecoveryRadiusPercent =
                math.clamp(tonumber(value) or 25, 5, 100)
            if capturedSimulationRadius or capturedMaximumSimulationRadius then
                local basis = capturedSimulationRadius or capturedMaximumSimulationRadius
                backend.NonPDRecoveryDistance =
                    math.max(32, basis * (options.NonPDRecoveryRadiusPercent / 100))
            end
            persistOption("Recovery Distance")
        end)
        UI.CreateText(
            parent,
            "Recovery catches badly separated owned limbs. Detached accessories use their exact Gelatek target and do not wait for this large radius.",
            9,
            Enum.TextXAlignment.Center
        )

        local advancedPage = UI.CreatePage()
        advancedPage.ZIndex = 3
        advancedPage.Visible = false
        advancedPage.Interactable = false

        local function showPage(fromPage, toPage)
            if fromPage then
                fromPage.Interactable = false
                fromPage.Visible = false
            end
            toPage.Visible = true
            toPage.Interactable = true
        end

        UI.CreateButton(parent, "Advanced Gelatek >", 15)
            .Activated:Connect(function()
                showPage(parent, advancedPage)
            end)

        UI.CreateButton(advancedPage, "< Back to Gelatek", 16)
            .Activated:Connect(function()
                showPage(advancedPage, parent)
            end)

        UI.CreateText(
            advancedPage,
            "<b>Advanced Gelatek</b>",
            18,
            Enum.TextXAlignment.Center
        )
        UI.CreateText(
            advancedPage,
            "Ownership, constraint, animator and fling internals. Leave these alone unless you are testing a specific problem.",
            9,
            Enum.TextXAlignment.Center
        )

        UI.CreateText(advancedPage, "<b>Rig / animation</b>", 12, Enum.TextXAlignment.Left)
        addSwitch(
            advancedPage,
            "Disable Gelatek's Own Animator",
            "AnimationsDisabled",
            "The controller Roblox Animator is still preserved for generic AnimationTrack content."
        )
        addSwitch(advancedPage, "Don't Break Hair Welds", "DontBreakHairWelds")

        UI.CreateText(advancedPage, "<b>Follower internals</b>", 12, Enum.TextXAlignment.Left)
        addSwitch(
            advancedPage,
            "Align Reanimate",
            "AlignReanimate",
            "Off uses Gelatek's native direct-CFrame follower."
        )
        addSwitch(advancedPage, "Full Force Align", "FullForceAlign")
        addSwitch(advancedPage, "Faster Heartbeat (PD only)", "FasterHeartbeat")
        addSwitch(advancedPage, "Dynamical Velocity", "DynamicalVelocity")
        addSwitch(
            advancedPage,
            "Disable Tweaks",
            "DisableTweaks",
            "Disables Gelatek's ownership/stability tweaks and can lose physical parts."
        )

        UI.CreateText(advancedPage, "<b>Optional extras</b>", 12, Enum.TextXAlignment.Left)
        addSwitch(advancedPage, "Load Library", "LoadLibrary")
        addSwitch(advancedPage, "Detailed Credits", "DetailedCredits")

        UI.CreateText(advancedPage, "<b>Flinging</b>", 12, Enum.TextXAlignment.Left)
        addSwitch(advancedPage, "Torso Fling", "TorsoFling")
        addSwitch(advancedPage, "Bullet Enabled", "BulletEnabled")
        addSwitch(advancedPage, "Bullet Run After Reanimate", "BulletRunAfter")
        addSwitch(advancedPage, "Lock Bullet On Torso", "BulletLockTorso")

        UI.CreateText(advancedPage, "<b>Diagnostics</b>", 12, Enum.TextXAlignment.Left)
        UI.CreateButton(advancedPage, "Copy Gelatek Runtime State", 12)
            .Activated:Connect(function()
                local dump = buildGelatekRuntimeDump()
                warn(dump)
                local clipboard = setclipboard or toclipboard
                local copied = type(clipboard) == "function" and pcall(clipboard, dump)
                pcall(
                    StarterGui.SetCore,
                    StarterGui,
                    "SendNotification",
                    {
                        Title = "Gelatek runtime state",
                        Text = copied and "Copied to clipboard." or "Printed to Developer Console.",
                        Duration = 5,
                    }
                )
            end)

        if not ok then
            UI.CreateText(
                parent,
                "Missing: " .. table.concat(missing, ", "),
                10,
                Enum.TextXAlignment.Center
            )
        end
    end

    local function snapshotWorkspaceModels()
        local result = {}
        for _, child in ipairs(workspace:GetChildren()) do
            if child:IsA("Model") then
                result[child] = true
            end
        end
        return result
    end

    local function looksLikeControllerRig(model, before)
        if not model or not model:IsA("Model") or model == originalCharacter then
            return false
        end
        if not model.Parent then
            return false
        end
        local humanoid = model:FindFirstChildOfClass("Humanoid")
        local root = model:FindFirstChild("HumanoidRootPart")
        if not humanoid or not root then
            return false
        end
        if humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead then
            return false
        end
        if model.Name == "GelatekReanimate" or model.Name == "ReanimatedRig" then
            return true
        end
        if model.Name == Player.Name .. "_Fake" then
            return true
        end
        if Player.Character == model and not before[model] then
            return true
        end
        return not before[model]
    end

    local function findControllerRig(before)
        local direct = workspace:FindFirstChild("GelatekReanimate")
            or workspace:FindFirstChild("ReanimatedRig")
            or workspace:FindFirstChild(Player.Name .. "_Fake")
        if looksLikeControllerRig(direct, before) then
            return direct
        end
        if looksLikeControllerRig(Player.Character, before) then
            return Player.Character
        end
        for _, child in ipairs(workspace:GetChildren()) do
            if looksLikeControllerRig(child, before) then
                return child
            end
        end
        return nil
    end

    local function disableBackendAnimations(rig)
        local animate = rig and rig:FindFirstChild("Animate")
        if animate and animate:IsA("LocalScript") then
            animate.Disabled = true
        end
        local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
        local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
        if animator then
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                pcall(function()
                    track:Stop(0)
                end)
            end
        end
    end

    local function captureOriginalFace(character)
        local head = character and character:FindFirstChild("Head")
        local face = head and head:FindFirstChildWhichIsA("Decal")
        if face then
            local ok, clone = pcall(function()
                return face:Clone()
            end)
            if ok then
                originalFace = clone
            end
        end
    end

    local function ensureVisibleHead(_rig)
        -- Fake controller remains invisible.
    end

    local function hideControllerBody(rig)
        if not rig then
            return
        end
        pcall(function()
            rig:SetAttribute("UhhhhhhGelatekRespawnPlaceholder", nil)
        end)
        local showController = Reanimate.ShowControllerCharacter == true
        for _, part in ipairs(rig:GetChildren()) do
            if part:IsA("BasePart") then
                part.Transparency =
                    showController and (part.Name == "HumanoidRootPart" and 1 or 0.35) or 1
            end
        end
    end

    local function destroyRespawnPlaceholder()
        table.clear(placeholderParts)
        if placeholderModel then
            pcall(function()
                placeholderModel:Destroy()
            end)
            placeholderModel = nil
        end
    end

    local function createPlaceholderPart(sourcePart)
        local ok, proxy = pcall(function()
            return sourcePart:Clone()
        end)
        if not ok or not proxy or not proxy:IsA("BasePart") then
            proxy = Instance.new("Part")
            proxy.Name = sourcePart.Name
            proxy.Size = sourcePart.Size
            pcall(function()
                proxy.Shape = sourcePart.Shape
            end)
        end
        for _, child in ipairs(proxy:GetChildren()) do
            if not child:IsA("DataModelMesh") then
                child:Destroy()
            else
                pcall(function()
                    child.TextureId = ""
                end)
            end
        end
        proxy.Name = sourcePart.Name
        proxy.Anchored = true
        proxy.CanCollide = false
        proxy.CanQuery = false
        proxy.CanTouch = false
        proxy.CastShadow = false
        proxy.Massless = true
        proxy.Color = Color3.fromRGB(255, 45, 45)
        proxy.Material = Enum.Material.SmoothPlastic
        proxy.Transparency = 1
        pcall(function()
            proxy.TextureID = ""
        end)
        pcall(function()
            proxy.LocalTransparencyModifier = 0
        end)
        return proxy
    end

    local function ensureRespawnPlaceholder(rig)
        if placeholderModel and placeholderModel.Parent then
            return placeholderModel
        end
        destroyRespawnPlaceholder()
        local model = Instance.new("Model")
        model.Name = "_UhhhhhhGelatekResetPlaceholder"
        model.Archivable = false
        model.Parent = workspace
        placeholderModel = model
        for _, sourcePart in ipairs(rig:GetChildren()) do
            if sourcePart:IsA("BasePart") and sourcePart.Name ~= "HumanoidRootPart" then
                local proxy = createPlaceholderPart(sourcePart)
                proxy.CFrame = sourcePart.CFrame
                proxy.Size = sourcePart.Size
                proxy.Parent = model
                placeholderParts[sourcePart] = proxy
            end
        end
        return model
    end

    local function ensureStaticRoot(controllerRoot)
        if not staticRootPart or not staticRootPart.Parent then
            local part = Instance.new("Part")
            part.Name = "_UhhhhhhGelatekStaticRoot"
            part.Archivable = false
            part.Anchored = true
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.CastShadow = false
            part.Massless = true
            part.Transparency = 1
            part.Size = controllerRoot and controllerRoot.Size or Vector3.new(2, 2, 1)
            if staticRootCFrame then
                part.CFrame = staticRootCFrame
            elseif controllerRoot then
                part.CFrame = controllerRoot.CFrame
            end
            part.Parent = workspace
            staticRootPart = part
        end
        backend.StaticRoot = staticRootPart
        return staticRootPart
    end

    local function updatePoseMirror(rig)
        local controllerRoot = rig and rig:FindFirstChild("HumanoidRootPart")
        if controllerRoot
            and controllerRoot:IsA("BasePart")
            and controllerRoot.Parent
            and not placeholderActive
            and not rebindInProgress
        then
            staticRootCFrame = controllerRoot.CFrame
            local tracker = ensureStaticRoot(controllerRoot)
            tracker.CFrame = controllerRoot.CFrame
            tracker.Size = controllerRoot.Size
            environment().UhhhhhhTBZGelatekStaticRootCFrame = staticRootCFrame
        end

        if not placeholderActive then
            if placeholderModel then
                for _, proxy in pairs(placeholderParts) do
                    if proxy and proxy.Parent then
                        proxy.Transparency = 1
                    end
                end
            end
            return
        end

        if not placeholderModel or not placeholderModel.Parent then
            ensureRespawnPlaceholder(rig)
        end
        local transparency = 1
        if Reanimate.ShowResetPlaceholder == true then
            transparency = math.min(tonumber(Reanimate.PlaceholderTransparency) or 0.5, 0.5)
        end
        for sourcePart, proxy in pairs(placeholderParts) do
            if proxy and proxy.Parent and sourcePart and sourcePart.Parent then
                -- While reset/rebind is active the placeholder is a snapshot,
                -- not a live mirror. A dying controller can fall through the
                -- map after Roblox disables/destroys it; following that fall is
                -- what previously buried the red placeholder underground.
                local sourceMesh = sourcePart:FindFirstChildWhichIsA("DataModelMesh")
                local proxyMesh = proxy:FindFirstChildWhichIsA("DataModelMesh")
                if sourceMesh and proxyMesh then
                    pcall(function()
                        proxyMesh.Scale = sourceMesh.Scale
                        proxyMesh.Offset = sourceMesh.Offset
                    end)
                end
                proxy.Color = Color3.fromRGB(255, 45, 45)
                proxy.Material = Enum.Material.SmoothPlastic
                proxy.Transparency = transparency
            elseif proxy and proxy.Parent then
                -- If Roblox destroyed the controller during a default reset, keep
                -- the final mirrored pose frozen until its replacement is ready.
                proxy.Transparency = transparency
            end
        end
    end

    local function detachPoseMirror(destroyInfrastructure)
        if poseMirrorConnection then
            pcall(function()
                poseMirrorConnection:Disconnect()
            end)
            poseMirrorConnection = nil
        end
        poseMirrorRig = nil
        if destroyInfrastructure then
            placeholderActive = false
            destroyRespawnPlaceholder()
            if staticRootPart then
                pcall(function()
                    staticRootPart:Destroy()
                end)
                staticRootPart = nil
            end
            backend.StaticRoot = nil
            staticRootCFrame = nil
        end
    end

    local function attachPoseMirror(rig)
        if poseMirrorRig == rig and poseMirrorConnection then
            updatePoseMirror(rig)
            return
        end
        detachPoseMirror(false)
        poseMirrorRig = rig
        if placeholderModel then
            destroyRespawnPlaceholder()
        end
        hideControllerBody(rig)
        updatePoseMirror(rig)
        poseMirrorConnection = RunService.PreRender:Connect(function()
            if rig and rig.Parent then
                hideControllerBody(rig)
            end
            -- Keep applying placeholder visibility even after Roblox destroys a
            -- default-reset controller; its proxy pose intentionally stays frozen.
            updatePoseMirror(rig)
        end)
    end

    local function setRespawnPlaceholderActive(active, rig)
        placeholderActive = active == true
        if placeholderActive and rig and rig.Parent then
            ensureRespawnPlaceholder(rig)
            updatePoseMirror(rig)
        elseif not placeholderActive then
            destroyRespawnPlaceholder()
        end
    end

    local function detachCameraBridge()
        RunService:UnbindFromRenderStep(visibilityBinding)
        visibility:Stop()
        if cameraBridgeConnection then
            pcall(function()
                cameraBridgeConnection:Disconnect()
            end)
            cameraBridgeConnection = nil
        end
        if type(Reanimate.CharacterLTMs) == "table" then
            table.clear(Reanimate.CharacterLTMs)
        end
    end

    local function attachCameraBridge(rig)
        detachCameraBridge()
        Reanimate.GelatekDisableDirectionalWalking =
            options.DisableDirectionalWalking == true
        local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
        if not humanoid then
            return
        end
        pcall(function()
            humanoid.AutoRotate = true
        end)
        if type(Reanimate.CharacterLTMs) == "table" then
            for _, instance in ipairs(rig:GetDescendants()) do
                local ok = pcall(function()
                    local _ = instance.LocalTransparencyModifier
                end)
                if ok then
                    table.insert(Reanimate.CharacterLTMs, instance)
                end
            end
        end
        local camera = workspace.CurrentCamera
        if camera then
            pcall(function()
                camera.CameraSubject = humanoid
            end)
        end
        -- Run after both native and host camera fading. The physical shell is
        -- not Player.Character after handoff, so Roblox will not fade it for us.
        RunService:BindToRenderStep(visibilityBinding,Enum.RenderPriority.Last.Value+1,function()
            if backend.Running and rig.Parent then
                visibility:Track(rig,backend.RealCharacter)
                visibility:Step(workspace.CurrentCamera)
            end
        end)
        cameraBridgeConnection = RunService.PreRender:Connect(function()
            if not backend.Running or not rig.Parent then
                return
            end
            local currentCamera = workspace.CurrentCamera
            if currentCamera and currentCamera.CameraSubject ~= humanoid then
                pcall(function()
                    currentCamera.CameraSubject = humanoid
                end)
            end
            local shouldLock = false
            if type(Reanimate.ShouldRotationType) == "function" then
                local ok, result = pcall(Reanimate.ShouldRotationType, Reanimate)
                shouldLock = ok and result == true
            end
            if not shouldLock
                and Reanimate.ShiftlockEnabled ~= false
                and type(Reanimate.Camera) == "table"
                and type(Reanimate.Camera.IsMouseLocked) == "function"
                and not Reanimate.Camera.Scriptable
            then
                local ok, result =
                    pcall(Reanimate.Camera.IsMouseLocked, Reanimate.Camera)
                shouldLock = ok and result == true
            end
            if shouldLock and type(Reanimate.CameraLockCharacter) == "function" then
                pcall(Reanimate.CameraLockCharacter)
            end
        end)
    end

    local function normalizedDestroyHeight(value)
        if type(value) ~= "number" or value ~= value then
            return -500
        end
        return value
    end

    local function disableVoidDestruction()
        if not destroyHeightCaptured then
            originalDestroyHeight = workspace.FallenPartsDestroyHeight
            destroyHeightCaptured = true
        end
        local global = environment()
        global.UhhhhhhTBZGelatekDestroyHeight = normalizedDestroyHeight(originalDestroyHeight)
        global.UhhhhhhTBZGelatekHiddenPartsY = global.UhhhhhhTBZGelatekDestroyHeight + 5
        pcall(function()
            workspace.FallenPartsDestroyHeight = 0 / 0
        end)
    end

    local function restoreVoidDestruction()
        if destroyHeightCaptured then
            pcall(function()
                workspace.FallenPartsDestroyHeight = originalDestroyHeight
            end)
        end
        destroyHeightCaptured = false
        originalDestroyHeight = nil
        local global = environment()
        global.UhhhhhhTBZGelatekDestroyHeight = nil
        global.UhhhhhhTBZGelatekHiddenPartsY = nil
    end

    local function characterScale()
        return math.clamp(tonumber(Reanimate.CharacterScale) or 1, 0.5, 5)
    end

    local SCALE_ATTRIBUTE = "UhhhhhhCharacterSpacingScale"

    local function applyCharacterScale(rig, force)
        if not rig or not rig.Parent then
            return false
        end
        local scale = characterScale()
        environment().UhhhhhhTBZGelatekCharacterSpacingScale = scale
        local previousScale = lastAppliedScale
        if type(previousScale) ~= "number" then
            local ok, value = pcall(rig.GetScale, rig)
            previousScale = ok and type(value) == "number" and value or 1
        end
        if not force and scale == previousScale then
            return true
        end
        local scaled = pcall(function()
            -- Model:ScaleTo owns body sizes, meshes, attachments, and joint spacing.
            -- Never rewrite Motor6D frames here: VR and jointless modules own them.
            rig:ScaleTo(scale)
            rig:SetAttribute(SCALE_ATTRIBUTE, scale)
        end)
        if not scaled then
            return false
        end
        lastAppliedScale = scale
        return true
    end

    local function jumpVelocity(humanoid)
        local useJumpPower = true
        pcall(function()
            useJumpPower = humanoid.UseJumpPower
        end)
        if useJumpPower then
            return math.max(tonumber(humanoid.JumpPower) or 0, 0)
        end
        return math.sqrt(2 * workspace.Gravity * math.max(tonumber(humanoid.JumpHeight) or 0, 0))
    end

    local function updateInfiniteJump(rig)
        local jump = type(Reanimate.Control) == "table" and Reanimate.Control.Jump == true
        if jump and not lastJump and Reanimate.InfiniteJump then
            local humanoid = rig:FindFirstChildOfClass("Humanoid")
            local root = rig:FindFirstChild("HumanoidRootPart")
            if humanoid
                and root
                and humanoid:GetState() == Enum.HumanoidStateType.Freefall
            then
                local velocity = root.AssemblyLinearVelocity
                root.AssemblyLinearVelocity = Vector3.new(velocity.X, jumpVelocity(humanoid), velocity.Z)
                pcall(function()
                    humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end)
            end
        end
        lastJump = jump
    end

    local function restoreAccessoryBodyHideWelds()
        for weld, originalEnabled in pairs(accessoryBodyHideWeldStates) do
            if typeof(weld) == "Instance" and weld.Parent then
                pcall(function()
                    weld.Enabled = originalEnabled
                end)
            end
        end
        table.clear(accessoryBodyHideWeldStates)
    end

    local function snapAccessoryHandleToWeld(handle, weld)
        if not handle
            or not handle:IsA("BasePart")
            or not weld
            or not weld:IsA("JointInstance")
        then
            return false
        end

        local part0, part1 = weld.Part0, weld.Part1
        local c0, c1
        local okFrames = pcall(function()
            c0 = weld.C0
            c1 = weld.C1
        end)
        if not okFrames or typeof(c0) ~= "CFrame" or typeof(c1) ~= "CFrame" then
            return false
        end

        local anchor, desired
        if part0 == handle and part1 and part1:IsA("BasePart") then
            anchor = part1
            -- Weld equation: Part1*C1 = Part0*C0
            desired = part1.CFrame * c1 * c0:Inverse()
        elseif part1 == handle and part0 and part0:IsA("BasePart") then
            anchor = part0
            desired = part0.CFrame * c0 * c1:Inverse()
        end

        if not desired then
            return false
        end

        return pcall(function()
            handle.CFrame = desired
            if anchor then
                handle.AssemblyLinearVelocity = anchor.AssemblyLinearVelocity
                handle.AssemblyAngularVelocity = anchor.AssemblyAngularVelocity
            end
        end)
    end

    local function updateAccessoryBodyHideWelds()
        if not backend.Running or rebindInProgress then
            return
        end

        local physical = backend.RealCharacter or originalCharacter
        if not physical or not physical.Parent then
            restoreAccessoryBodyHideWelds()
            return
        end

        local global = environment()
        local resolver =
            global.UhhhhhhTBZShouldDetachAccessoryForBodyHide
        local seen = setmetatable({}, { __mode = "k" })

        for _, accessory in ipairs(physical:GetChildren()) do
            if accessory:IsA("Accessory") then
                local handle = accessory:FindFirstChild("Handle")
                if handle and handle:IsA("BasePart") then
                    local weld = handle:FindFirstChild("AccessoryWeld")
                    if weld and weld:IsA("JointInstance") then
                        seen[weld] = true

                        if accessoryBodyHideWeldStates[weld] == nil then
                            local enabled = true
                            pcall(function()
                                enabled = weld.Enabled
                            end)
                            accessoryBodyHideWeldStates[weld] = enabled
                        end

                        local shouldDetach = false
                        if type(resolver) == "function" then
                            local ok, result =
                                pcall(resolver, handle, nil)
                            shouldDetach = ok and result == true
                        end

                        local originalEnabled =
                            accessoryBodyHideWeldStates[weld]

                        if shouldDetach then
                            pcall(function()
                                weld.Enabled = false
                            end)
                        else
                            local currentlyEnabled =
                                debugSafe(function()
                                    return weld.Enabled
                                end, originalEnabled)

                            if originalEnabled == true
                                and currentlyEnabled == false
                            then
                                -- Move the independent Handle onto the exact
                                -- weld solution before merging it back into the
                                -- Head/Torso assembly.
                                snapAccessoryHandleToWeld(handle, weld)
                            end

                            pcall(function()
                                weld.Enabled = originalEnabled
                            end)
                        end
                    end
                end
            end
        end

        for weld, originalEnabled in pairs(accessoryBodyHideWeldStates) do
            if not seen[weld] then
                if typeof(weld) == "Instance" and weld.Parent then
                    pcall(function()
                        weld.Enabled = originalEnabled
                    end)
                end
                accessoryBodyHideWeldStates[weld] = nil
            end
        end
    end

    local function detachScaleBridge()
        environment().UhhhhhhTBZGelatekAccessoryWriterActive = nil
        if ragdollCollisionFolder then
            ragdollCollisionFolder:Destroy()
            ragdollCollisionFolder = nil
        end
        pcall(stopReplicationLab, true)
        if scaleBridgeConnection then
            pcall(function()
                scaleBridgeConnection:Disconnect()
            end)
            scaleBridgeConnection = nil
        end
        if controllerCollisionConnection then
            pcall(function()
                controllerCollisionConnection:Disconnect()
            end)
            controllerCollisionConnection = nil
        end
        if neckBridgeConnection then
            pcall(function()
                neckBridgeConnection:Disconnect()
            end)
            neckBridgeConnection = nil
        end
        restoreGelatekHeadWriter()
        if physicalAnimatorConnection then
            pcall(function()
                physicalAnimatorConnection:Disconnect()
            end)
            physicalAnimatorConnection = nil
        end
        if safeTrackerConnection then
            pcall(function()
                safeTrackerConnection:Disconnect()
            end)
            safeTrackerConnection = nil
        end
        if limbRecoveryConnection then
            pcall(function()
                limbRecoveryConnection:Disconnect()
            end)
            limbRecoveryConnection = nil
        end
        if flingBridgeConnection then
            pcall(function()
                flingBridgeConnection:Disconnect()
            end)
            flingBridgeConnection = nil
        end
        if accessoryBodyHideConnection then
            pcall(function()
                accessoryBodyHideConnection:Disconnect()
            end)
            accessoryBodyHideConnection = nil
        end
        if accessoryRecoveryConnection then
            pcall(function()
                accessoryRecoveryConnection:Disconnect()
            end)
            accessoryRecoveryConnection = nil
        end
        restoreAccessoryBodyHideWelds()
        restoreAccessoryRecoveryStates()
        activeFling = nil
        local global = environment()
        global.UhhhhhhTBZGelatekFlingActive = nil
        lastAppliedScale = nil
        lastJump = false
    end

    local bodyChainPoseCache = {}
    local bodyChainLastSample = 0
    local lastHeadHiddenState = nil

    local function findLimbStyleJointChannels(character, part0Name, part1Name)
        local constraint = nil
        local motor = nil
        for _, joint in ipairs(character:GetDescendants()) do
            if Util.IsCharacterJoint(joint) then
                local part0, part1 = Util.GetCharacterJointParts(joint)
                if part0
                    and part1
                    and part0.Name == part0Name
                    and part1.Name == part1Name
                then
                    if joint:IsA("Motor6D") then
                        motor = joint
                    else
                        constraint = joint
                    end
                end
            end
        end
        return constraint, motor
    end

    local function computeMappedJointFromCFrames(
        physicalCharacter,
        map,
        p0CFrame,
        p1CFrame
    )
        local constraint, motor =
            findLimbStyleJointChannels(physicalCharacter, map.Part0, map.Part1)
        local reference = constraint or motor
        if not reference then
            return nil
        end

        local cf
        if map.Type == 1 then
            cf = p0CFrame:ToObjectSpace(p1CFrame)
        elseif map.Type == 2 then
            local offset = map.Offset or CFrame.identity
            local c0, c1 = CFrame.new(map.C0), CFrame.new(map.C1)
            local transform = offset
                * (p0CFrame * c0):ToObjectSpace(p1CFrame * c1)
                * offset:Inverse()
            local jointC0, jointC1 = Util.GetCharacterJointFrames(reference)
            if not jointC0 or not jointC1 then
                return nil
            end
            cf = jointC0 * transform * jointC1:Inverse()
        end
        return cf
    end

    local function applyCachedMappedJoint(
        physicalCharacter,
        map,
        p0CFrame,
        p1CFrame,
        cacheKey,
        sampleNow
    )
        if sampleNow or not bodyChainPoseCache[cacheKey] then
            local cf = computeMappedJointFromCFrames(
                physicalCharacter,
                map,
                p0CFrame,
                p1CFrame
            )
            if cf then
                bodyChainPoseCache[cacheKey] = cf
            end
        end

        local cf = bodyChainPoseCache[cacheKey]
        if not cf then
            return false
        end

        local constraint, motor =
            findLimbStyleJointChannels(physicalCharacter, map.Part0, map.Part1)
        local reference = constraint or motor
        if not reference then
            return false
        end

        -- One active joint owns Head. A second channel must not solve the
        -- same Torso/Head pair with a different pose.
        local replicated = Util.SetCharacterJointOffset(reference, cf)
        -- This helper is used only by the guarded non-PD head path. The
        -- hidden writer alone does not guarantee the local Motor6D pose.
        -- Set the same transform locally without changing the shared R6 writer.
        if reference:IsA("Motor6D") then
            local c0, c1 = Util.GetCharacterJointFrames(reference)
            if c0 and c1 then
                reference.Transform = c0:Inverse() * cf * c1
            end
        end
        return replicated
    end

    local function setLimbStyleJointIdentity(character, part0Name, part1Name)
        local constraint, motor =
            findLimbStyleJointChannels(character, part0Name, part1Name)
        local reference = constraint or motor
        if reference then
            Util.SetCharacterJointTransform(reference, CFrame.identity)
        end
        if motor and motor ~= reference then
            Util.SetCharacterJointTransform(motor, CFrame.identity)
        end
    end

    local gelatekHeadWriter = {
        WeldConstraint = nil,
        Part0 = nil,
        Part1 = nil,
        SavedJointStates = setmetatable({}, { __mode = "k" }),
        SavedTransforms = setmetatable({}, { __mode = "k" }),
    }

    local function setGelatekHeadJointEnabled(joint, enabled)
        if not joint or not joint.Parent then
            return
        end
        if gelatekHeadWriter.SavedJointStates[joint] == nil then
            local original = true
            pcall(function()
                original = joint.Enabled
            end)
            gelatekHeadWriter.SavedJointStates[joint] = original
            if joint:IsA("Motor6D") then
                gelatekHeadWriter.SavedTransforms[joint] = joint.Transform
            end
        end
        pcall(function()
            joint.Enabled = enabled
        end)
    end

    restoreGelatekHeadWriter = function()
        if gelatekHeadWriter.WeldConstraint then
            pcall(function()
                gelatekHeadWriter.WeldConstraint:Destroy()
            end)
            gelatekHeadWriter.WeldConstraint = nil
        end
        for joint, original in pairs(gelatekHeadWriter.SavedJointStates) do
            if typeof(joint) == "Instance" and joint.Parent then
                pcall(function()
                    joint.Enabled = original
                    local transform = gelatekHeadWriter.SavedTransforms[joint]
                    if transform then
                        joint.Transform = transform
                    end
                end)
            end
        end
        table.clear(gelatekHeadWriter.SavedJointStates)
        table.clear(gelatekHeadWriter.SavedTransforms)
        gelatekHeadWriter.Part0 = nil
        gelatekHeadWriter.Part1 = nil
    end

    local function writeGelatekHead(
        physical,
        physicalTorso,
        physicalHead,
        controllerTorsoCFrame,
        targetHeadCFrame,
        sampleNow
    )
        local part0Name =
            physical:FindFirstChild("UpperTorso")
            and "UpperTorso"
            or "Torso"
        local constraint, motor =
            findLimbStyleJointChannels(
                physical,
                part0Name,
                "Head"
            )
        local reference = constraint or motor
        if not reference then
            return
        end

        local currentWriters = SaveData.AnimLibOptions.ReplicationWriters
        local method = tostring(currentWriters.GelatekHead or "CurrentAngle6D")

        if method == "WeldConstraint CFrame0" then
            setGelatekHeadJointEnabled(constraint, false)
            if motor and motor ~= constraint then
                setGelatekHeadJointEnabled(motor, false)
            end

            local wc = gelatekHeadWriter.WeldConstraint
            if not wc
                or not wc.Parent
                or gelatekHeadWriter.Part0 ~= physicalTorso
                or gelatekHeadWriter.Part1 ~= physicalHead
            then
                restoreGelatekHeadWriter()
                setGelatekHeadJointEnabled(constraint, false)
                if motor and motor ~= constraint then
                    setGelatekHeadJointEnabled(motor, false)
                end
                wc = Instance.new("WeldConstraint")
                wc.Name = "_UhhhhhhGelatekHeadWriter"
                wc.Part0 = physicalTorso
                wc.Part1 = physicalHead
                wc.Enabled = true
                wc.Parent = physicalTorso
                gelatekHeadWriter.WeldConstraint = wc
                gelatekHeadWriter.Part0 = physicalTorso
                gelatekHeadWriter.Part1 = physicalHead
            end

            -- Encode the controller's Torso->Head pose. The physical Torso
            -- remains the world-space authority.
            local desiredRelative =
                controllerTorsoCFrame:ToObjectSpace(targetHeadCFrame)
            local written, result = pcall(
                sethiddenproperty,
                wc,
                "CFrame0",
                desiredRelative
            )
            if written and result ~= false then
                return
            end
            restoreGelatekHeadWriter()
            currentWriters.GelatekHead = "CurrentAngle6D"
            warn("Gelatek weld Head write failed; restored native neck writer")
        end

        -- CurrentAngle6D is the production/default writer. A native Neck stays
        -- enabled, making the physical Torso the positional base for Head.
        if gelatekHeadWriter.WeldConstraint then
            restoreGelatekHeadWriter()
        end
        setGelatekHeadJointEnabled(constraint, true)
        if motor and motor ~= constraint then
            setGelatekHeadJointEnabled(motor, constraint == nil)
        end

        if physical:FindFirstChild("UpperTorso") then
            applyCachedMappedJoint(
                physical,
                {
                    Part0 = "UpperTorso",
                    Part1 = "Head",
                    Type = 1,
                },
                -- Gelatek puts the physical UpperTorso above the proxy Torso.
                -- Use that mapped frame as the neck base, including scaling.
                controllerTorsoCFrame * CFrame.new(0, 0.194 * characterScale(), 0),
                targetHeadCFrame,
                "TorsoToHead",
                sampleNow
            )
        else
            applyCachedMappedJoint(
                physical,
                {
                    Part0 = "Torso",
                    Part1 = "Head",
                    Type = 1,
                },
                controllerTorsoCFrame,
                targetHeadCFrame,
                "TorsoToHead",
                sampleNow
            )
        end
    end

    local function updateNonPDBodyChain(rig)
        if not backend.Running
            or backend.EffectivePermanentDeath == true
            or rebindInProgress
            or not rig
            or not rig.Parent
        then
            return
        end

        local physical = backend.RealCharacter or originalCharacter
        if not physical or not physical.Parent then
            return
        end

        local controllerTorso = rig:FindFirstChild("Torso")
        local controllerHead = rig:FindFirstChild("Head")
        local physicalTorso =
            physical:FindFirstChild("UpperTorso")
            or physical:FindFirstChild("Torso")
        local physicalHead = physical:FindFirstChild("Head")
        local physicalHumanoid = physical:FindFirstChildOfClass("Humanoid")

        if not controllerTorso
            or not controllerHead
            or not physicalTorso
            or not physicalHead
        then
            return
        end

        if physicalHumanoid then
            pcall(function()
                physicalHumanoid.RequiresNeck = false
                physicalHumanoid.BreakJointsOnDeath = false
                physicalHumanoid.AutoRotate = false
                physicalHumanoid:ChangeState(Enum.HumanoidStateType.Physics)
            end)
        end

        -- Restore Gelatek's natural non-PD topology: Torso is an independently
        -- network-animated physical piece. Head remains its Neck child.
        pcall(function()
            physicalTorso.Massless = false
            physicalTorso.RootPriority = 127
            physicalHead.Massless = true
            physicalHead.RootPriority = -127
        end)

        if physicalHumanoid and physicalHumanoid.Health > 0 then
            local neck = physicalTorso:FindFirstChild("Neck")
            if not (neck and neck:IsA("Motor6D") and neck.Part0 == physicalTorso and neck.Part1 == physicalHead) then
                for _, joint in ipairs(physicalTorso:GetChildren()) do
                    if joint:IsA("Motor6D") and joint.Part0 == physicalTorso and joint.Part1 == physicalHead then
                        neck = joint
                        break
                    end
                end
                if not neck then
                    neck = Instance.new("Motor6D")
                    neck.Name = "Neck"
                    neck.Part0 = physicalTorso
                    neck.Part1 = physicalHead
                    neck.C0 = CFrame.new(0, 1, 0)
                    neck.C1 = CFrame.new(0, -0.5, 0)
                    neck.Parent = physicalTorso
                end
            end
        end

        local targetHeadCFrame = controllerHead.CFrame
        if type(Reanimate.ResolveBodyHideTargetCFrame) == "function" then
            targetHeadCFrame =
                Reanimate.ResolveBodyHideTargetCFrame(
                    physicalHead,
                    targetHeadCFrame,
                    "Head",
                    false
                )
        end

        local headHidden =
            type(Reanimate.ShouldBodyHidePart) == "function"
            and Reanimate.ShouldBodyHidePart("Head") == true
            or false
        local visibilityChanged =
            lastHeadHiddenState ~= nil
            and lastHeadHiddenState ~= headHidden
        lastHeadHiddenState = headHidden

        local sampleNow = true
        if options.ShowMeHowILook and not visibilityChanged then
            sampleNow = false
            local now = os.clock()
            local elapsed = now - bodyChainLastSample
            if elapsed >= 1 / 10 then
                sampleNow = true
                elapsed %= 1 / 10
                bodyChainLastSample = now - elapsed
            end
        end

        if visibilityChanged then
            -- Never reuse the large hidden/void Neck offset when Head is
            -- shown again.
            bodyChainPoseCache.TorsoToHead = nil
            sampleNow = true
        end

        do
            writeGelatekHead(
                physical,
                physicalTorso,
                physicalHead,
                controllerTorso.CFrame,
                targetHeadCFrame,
                sampleNow
            )
        end
    end

    local function accessoryWriteEligible(handle)
        if not handle or not handle:IsA("BasePart") or not handle.Parent then
            return false, "missing"
        end

        if ownsPhysicalPart(handle) then
            return true, "assembly-check"
        end
        -- ownsPhysicalPart already handles missing executor capabilities.
        -- Never override its explicit ownership rejection with ReceiveAge.
        return false, "unowned"
    end

    local function resolveGelatekAccessoryTargetCFrame(handle, controllerHandle)
        local targetCFrame = controllerHandle.CFrame
        local weld = controllerHandle:FindFirstChild("AccessoryWeld")
        if weld and weld:IsA("JointInstance") and weld.Part0 == controllerHandle
            and weld.Part1 and weld.Part1.Parent then
            -- Resolve the current attachment pose rather than a stale solver pose
            -- after teleport, scale, or a jointless controller movement.
            targetCFrame = weld.Part1.CFrame * weld.C1 * weld.C0:Inverse()
        end
        local global = environment()
        local resolver = global.UhhhhhhTBZGetBodyHideTargetInfo

        if type(resolver) == "function" then
            local ok, shouldHide, anchorName =
                pcall(resolver, handle, controllerHandle, nil, true)
            if ok and shouldHide == true
                and type(Reanimate.ResolveBodyHideTargetCFrame) == "function"
            then
                targetCFrame =
                    Reanimate.ResolveBodyHideTargetCFrame(
                        handle,
                        targetCFrame,
                        anchorName,
                        false
                    )
            end
        end
        return targetCFrame
    end

    restoreAccessoryRecoveryStates = function()
        for handle, state in pairs(accessoryRecoveryStates) do
            if handle and handle.Parent and type(state) == "table" then
                pcall(function()
                    if state.Massless ~= nil then
                        handle.Massless = state.Massless
                    end
                    handle.CustomPhysicalProperties =
                        state.CustomPhysicalProperties
                end)
            end
        end
        table.clear(accessoryRecoveryStates)
    end

    local function writeDetachedGelatekAccessory(pair, dt)
        local handle = pair and pair.Physical
        local controllerHandle = pair and pair.Controller
        if not handle
            or not handle:IsA("BasePart")
            or not handle.Parent
            or not controllerHandle
            or not controllerHandle:IsA("BasePart")
            or not controllerHandle.Parent
        then
            return false
        end

        local eligible, ownershipSource =
            accessoryWriteEligible(handle)

        local state = accessoryRecoveryStates[handle]
        if not state then
            state = {
                LastCFrame = handle.CFrame,
                ClaimTime = nil,
                Massless = handle.Massless,
                CustomPhysicalProperties = handle.CustomPhysicalProperties,
                OwnershipSource = ownershipSource,
                Writes = 0,
            }
            accessoryRecoveryStates[handle] = state
        end
        state.OwnershipSource = ownershipSource

        if not eligible then
            state.ClaimTime = nil
            state.LastCFrame = handle.CFrame
            return false
        end

        local targetCFrame =
            resolveGelatekAccessoryTargetCFrame(
                handle,
                controllerHandle
            )

        dt = math.max(tonumber(dt) or (1 / 60), 1 / 240)
        local now = os.clock()
        local previous =
            typeof(state.LastCFrame) == "CFrame"
            and state.LastCFrame
            or handle.CFrame

        if not state.ClaimTime then
            state.ClaimTime = now
        end

        local claimAge = now - state.ClaimTime
        pcall(function()
            if claimAge < 5.67 then
                handle.Massless = false
                handle.CustomPhysicalProperties = nil
            else
                handle.Massless = true
                handle.CustomPhysicalProperties =
                    PhysicalProperties.new(0.01, 0, 0, 0, 0)
            end
        end)

        local baseNetless =
            math.max(tonumber(Reanimate.NetlessVelocity) or 25.1, 1)
        local netlessY =
            baseNetless + (math.sin(now * 0.5) + 1) * 0.5

        local targetVelocity =
            controllerHandle.AssemblyLinearVelocity
        local horizontal =
            Vector3.new(targetVelocity.X, 0, targetVelocity.Z)
        if horizontal.Magnitude > baseNetless then
            horizontal = horizontal.Unit * baseNetless
        end

        local relative = previous:ToObjectSpace(targetCFrame)
        local axis, angle = relative:ToAxisAngle()
        local discontinuity = (previous.Position - targetCFrame.Position).Magnitude > 16
            or dt > 0.25
        local angular = discontinuity and Vector3.zero or axis * angle / dt
        if angular.Magnitude > 30 then
            angular = angular.Unit * 30
        end
        local idleAngular =
            Vector3.new(
                math.sin(now * 14),
                math.sin(now * 15 + 1.0472),
                math.sin(now * 16 + 2.0944)
            ) * 0.001

        local written, writeError = pcall(function()
            if options.AlignReanimate ~= true then
                local antiSleep = options.AntiSleep and math.sin(now * 15) * 0.0015 or 0
                handle.CFrame = targetCFrame + Vector3.new(0, antiSleep, 0)
            end
            handle.AssemblyLinearVelocity =
                Vector3.new(horizontal.X, netlessY, horizontal.Z)
            handle.AssemblyAngularVelocity =
                Reanimate.UseAngularVelocity
                and (angular + (options.AntiSleep and idleAngular or Vector3.zero))
                or (options.AntiSleep and idleAngular or Vector3.zero)
        end)

        state.LastWriteError = not written and tostring(writeError) or nil
        if not written then
            state.LastCFrame = handle.CFrame
            return false
        end
        state.LastCFrame = targetCFrame
        state.Writes += 1
        return true
    end

    local function attachScaleBridge(rig)
        detachScaleBridge()
        if backend.EffectivePermanentDeath ~= true then
            attachPhysicalAnimationSuppression(
                backend.RealCharacter or originalCharacter
            )
        end
        applyCharacterScale(rig, true)
        local generationSafePivot = rig:GetPivot()
        local floatSafeY = rig:FindFirstChild("HumanoidRootPart").Position.Y
        scaleBridgeConnection = RunService.Heartbeat:Connect(function()
            if not backend.Running or not rig.Parent then
                return
            end
            Reanimate.GelatekDisableDirectionalWalking =
                options.DisableDirectionalWalking == true
            applyCharacterScale(rig)
            updateInfiniteJump(rig)
            environment().UhhhhhhTBZGelatekAntiSleep = options.AntiSleep == true

        end)

        neckBridgeConnection = RunService.PreSimulation:Connect(function()
            updateNonPDBodyChain(rig)
        end)

        accessoryBodyHideConnection =
            RunService.PreSimulation:Connect(function()
                if not backend.Running or not rig.Parent then
                    return
                end
                updateAccessoryBodyHideWelds()
            end)

        -- The proxy owns locomotion. Detached physical followers stay isolated.
        -- Collision is shared with Limb; this name set is only for void recovery.
        local controllerBodyNames = {
            Head = true, Torso = true, UpperTorso = true, LowerTorso = true,
            HumanoidRootPart = true,
            ["Left Arm"] = true, ["Right Arm"] = true,
            ["Left Leg"] = true, ["Right Leg"] = true,
            LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
            RightUpperArm = true, RightLowerArm = true, RightHand = true,
            LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
            RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
        }
        controllerCollisionConnection = RunService.PreSimulation:Connect(function(dt)
            if not backend.Running or not rig.Parent then
                return
            end
            local humanoid = rig:FindFirstChildOfClass("Humanoid")
            local root = rig:FindFirstChild("HumanoidRootPart")
            if not humanoid or not root then
                return
            end
            local stateName = Reanimate.ApplyControllerCollision(rig, humanoid, root, true)
            local passive = not table.find(
                {"Running", "Jumping", "Freefall", "Landed", "Climbing", "Swimming"}, stateName)
            if options.RagdollSelfCollision == false and passive then
                if not ragdollCollisionFolder then
                    ragdollCollisionFolder = Instance.new("Folder")
                    ragdollCollisionFolder.Name = "_UhhhhhhOptionalRagdollSelfCollision"
                    ragdollCollisionFolder.Parent = rig
                    local parts = {}
                    for _, part in ipairs(rig:GetChildren()) do
                        if part:IsA("BasePart") and controllerBodyNames[part.Name] then
                            table.insert(parts, part)
                        end
                    end
                    for i, part in ipairs(parts) do
                        for j = i + 1, #parts do
                            local exclusion = Instance.new("NoCollisionConstraint")
                            exclusion.Part0, exclusion.Part1 = part, parts[j]
                            exclusion.Parent = ragdollCollisionFolder
                        end
                    end
                end
            elseif ragdollCollisionFolder then
                ragdollCollisionFolder:Destroy()
                ragdollCollisionFolder = nil
            end
            if rebindInProgress then
                isolatePhysicalCharacter(pendingPhysicalCharacter)
            end
            if options.RecoverBeforeVoid then
                local floor = environment().UhhhhhhTBZGelatekDestroyHeight or -500
                -- A detached limb below the root must not repeatedly teleport
                -- the whole ragdoll while its controller root is still safe.
                local predictedY = root.Position.Y
                    + math.min(root.AssemblyLinearVelocity.Y, 0) * math.clamp(dt or 0, 0, 0.25)
                if math.min(root.Position.Y, predictedY) < floor + 80 then
                    -- Move the whole controller, including jointless parts.
                    rig:PivotTo(generationSafePivot + Vector3.new(0, 3, 0))
                    for _, part in ipairs(rig:GetChildren()) do
                        if part:IsA("BasePart") and controllerBodyNames[part.Name] then
                            part.AssemblyLinearVelocity = Vector3.zero
                            part.AssemblyAngularVelocity = Vector3.zero
                        end
                    end
                end
            end
            rig:SetAttribute(
                "_Uhhhhhh_SeatWeldActive",
                stateName == "Seated" and (humanoid.Sit or humanoid.SeatPart ~= nil)
            )
        end)

        local safeParams = RaycastParams.new()
        safeParams.FilterType = Enum.RaycastFilterType.Exclude
        safeParams.RespectCanCollide = true
        safeParams.IgnoreWater = false
        safeTrackerConnection = RunService.PostSimulation:Connect(function()
            if not backend.Running or not rig.Parent or rebindInProgress then
                return
            end
            local humanoid = rig:FindFirstChildOfClass("Humanoid")
            local root = rig:FindFirstChild("HumanoidRootPart")
            if not humanoid or not root or not root:IsA("BasePart") then
                return
            end

            -- Excluding rig excludes both the controller and Gelatek's nested
            -- physical Character. Non-collidable helper parts are ignored by
            -- RespectCanCollide, so they cannot become LastSafe.
            safeParams.FilterDescendantsInstances = { rig }
            local scale = math.max(tonumber(Reanimate.CharacterScale) or 1, 0.001)
            local maximumGroundDistance = 3 * scale + 8 + humanoid.HipHeight
            local safe = true
            local void = true
            for i = 1, 8 do
                local offset =
                    CFrame.Angles(0, (i / 4) * math.pi, 0)
                        :VectorToWorldSpace(Vector3.new(0, 0, -0.5 * scale))
                local hit = workspace:Raycast(
                    root.Position + offset,
                    Vector3.new(0, -65536, 0),
                    safeParams
                )
                if hit then
                    void = false
                end
                if not hit or hit.Distance > maximumGroundDistance then
                    safe = false
                end
            end
            if safe then
                Reanimate.LastSafeCFrame = root.CFrame
                generationSafePivot = rig:GetPivot()
            end
            if humanoid:GetState().Name == "Climbing" or not void then
                floatSafeY = root.Position.Y
            elseif Reanimate.PatchmaVoidFloat then
                -- Same no-ground-below trigger as Limb; translate the whole
                -- controller to retain relative jointless/ragdoll poses.
                rig:PivotTo(rig:GetPivot() + Vector3.new(0, floatSafeY - root.Position.Y, 0))
                for _, part in ipairs(rig:GetChildren()) do
                    if part:IsA("BasePart") and controllerBodyNames[part.Name] then
                        part.AssemblyLinearVelocity *= Vector3.new(1, 0, 1)
                    end
                end
            end
        end)

        -- Position recovery is per physical body part, not root-motion based.
        -- This catches a single arm/leg/torso segment drifting away even when the
        -- controller root did not teleport. It works for PD and non-PD detached
        -- parts; non-PD Head is deliberately excluded because its Neck is intact.
        limbRecoveryConnection = RunService.PreSimulation:Connect(function()
            if not backend.Running or rebindInProgress or not rig.Parent then
                return
            end
            local physical = backend.RealCharacter
            if not physical or not physical.Parent then
                return
            end

            local threshold = tonumber(backend.NonPDRecoveryDistance) or 250
            for _, pair in ipairs(getGelatekRecoveryPairs(rig, physical)) do
                local physicalPart = pair.Physical
                local controllerPart = pair.Controller
                if physicalPart.Parent
                    and controllerPart.Parent
                    and ownsPhysicalPart(physicalPart)
                    and (
                        pair.IsAccessory == true
                        or not bodyPartIsIntentionallyHidden(
                            physicalPart,
                            controllerPart
                        )
                    )
                then
                    local targetCFrame = controllerPart.CFrame * pair.Offset
                    if pair.IsAccessory == true then
                        targetCFrame = resolveGelatekAccessoryTargetCFrame(physicalPart, controllerPart)
                    end
                    local positionError =
                        (physicalPart.Position - targetCFrame.Position).Magnitude

                    if options.DirectPositionCorrection == true then
                        -- Independent of Gelatek CFrame-vs-Align mode. This is a
                        -- positional safety writer, not a second rotation writer.
                        pcall(function()
                            physicalPart.Position = targetCFrame.Position
                        end)
                    elseif pair.DirectOnly ~= true
                        and positionError >= threshold
                    then
                        pcall(function()
                            physicalPart.Position = targetCFrame.Position
                        end)
                    end
                end
            end
        end)

        -- Detached accessories must be written AFTER Gelatek's own
        -- ArtificalEvent velocity pass. This mirrors Hat reanimation's
        -- ownership-preserving netless behavior much more closely.
        accessoryRecoveryConnection =
            RunService.PostSimulation:Connect(function(dt)
                if not backend.Running
                    or rebindInProgress
                    or not rig.Parent
                then
                    return
                end

                local physical =
                    backend.RealCharacter or originalCharacter
                if not physical or not physical.Parent then
                    return
                end

                for _, pair in ipairs(
                    getGelatekRecoveryPairs(rig, physical)
                ) do
                    if pair.IsAccessory == true then
                        writeDetachedGelatekAccessory(pair, dt)
                    end
                end
            end)
        environment().UhhhhhhTBZGelatekAccessoryWriterActive = true

        -- Gelatek's exact physical root is the network-owned flinger. Its normal
        -- follower pauses while this late PostSimulation writer is targeting.
        flingBridgeConnection = RunService.PostSimulation:Connect(function()
            local global = environment()
            local physicalRoot = global.UhhhhhhTBZGelatekPhysicalRoot
            local fling = activeFling
            if not backend.Running
                or not rig.Parent
                or not fling
                or typeof(physicalRoot) ~= "Instance"
                or not physicalRoot.Parent
            then
                global.UhhhhhhTBZGelatekFlingActive = nil
                return
            end
            if os.clock() >= fling.Deadline then
                activeFling = nil
                global.UhhhhhhTBZGelatekFlingActive = nil
                pcall(sethiddenproperty, physicalRoot, "PhysicsRepRootPart", nil)
                return
            end
            local targetCFrame, invalid = Util.PredictionFling(fling.Target)
            if invalid then
                activeFling = nil
                global.UhhhhhhTBZGelatekFlingActive = nil
                pcall(sethiddenproperty, physicalRoot, "PhysicsRepRootPart", nil)
                return
            end
            global.UhhhhhhTBZGelatekFlingActive = true
            physicalRoot.CFrame = targetCFrame + Vector3.new(0, 0, math.random(0, 1) * 0.005)
            physicalRoot.AssemblyLinearVelocity = Vector3.new(0, -16384, 0)
            physicalRoot.AssemblyAngularVelocity = Vector3.one * 16384
            pcall(
                sethiddenproperty,
                physicalRoot,
                "PhysicsRepRootPart",
                Reanimate.UsePhysicsRepRootPart and Util.PredictionFlingPart(fling.Target) or nil
            )
        end)
    end

    local function requestInternalStop(preserveController)
        local rig = backend.Rig
        local global = environment()
        local preserve = preserveController == true and rig and rig.Parent ~= nil
        if not preserve and placeholderActive and rig and rig.Parent then
            updatePoseMirror(rig)
            detachCameraBridge()
            local camera = workspace.CurrentCamera
            local tracker = staticRootPart or ensureStaticRoot(rig:FindFirstChild("HumanoidRootPart"))
            if camera and tracker then
                pcall(function()
                    camera.CameraType = Enum.CameraType.Custom
                    camera.CameraSubject = tracker
                end)
            end
        end
        if preserve then
            local root = rig:FindFirstChild("HumanoidRootPart")
            if root and root:IsA("BasePart") then
                staticRootCFrame = root.CFrame
                global.UhhhhhhTBZGelatekStaticRootCFrame = staticRootCFrame
            end
            global.UhhhhhhTBZGelatekPreservedController = rig
        else
            global.UhhhhhhTBZGelatekPreservedController = nil
        end
        global.UhhhhhhTBZGelatekPreserveController = preserve
        global.UhhhhhhTBZGelatekBridgeStopping = true
        local directStop = global.UhhhhhhTBZGelatekStop
        if type(directStop) == "function" then
            local finished = false
            local stopThread = task.spawn(function()
                pcall(directStop)
                finished = true
            end)
            local deadline = os.clock() + math.max(game:GetService("Players").RespawnTime + 5, 8)
            repeat
                task.wait(0.05)
            until finished or os.clock() >= deadline
            if not finished then
                pcall(task.cancel, stopThread)
            end
        end
        global.UhhhhhhTBZGelatekPreserveController = nil
        global.UhhhhhhTBZGelatekBridgeStopping = nil
        local preserved = preserve and rig and rig.Parent ~= nil
        if preserved then
            global.UhhhhhhTBZGelatekPreservedController = rig
            return true
        end
        global.UhhhhhhTBZGelatekPreservedController = nil
        if rig and rig.Parent then
            local humanoid = rig:FindFirstChildOfClass("Humanoid")
            if humanoid then
                pcall(function() humanoid.BreakJointsOnDeath = true end)
                pcall(function() humanoid.Health = 0 end)
                pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Dead) end)
            end
            local deadline = os.clock() + 4
            repeat
                task.wait(0.05)
            until not rig.Parent or os.clock() >= deadline
        end
        return false
    end

    local function countConnectedBodyJoints(character)
        local count = 0
        if typeof(character) ~= "Instance" or not character:IsA("Model") then
            return count
        end
        for _, instance in ipairs(character:GetDescendants()) do
            if instance:IsA("Motor6D") then
                local part0 = instance.Part0
                local part1 = instance.Part1
                if part0
                    and part1
                    and part0:IsDescendantOf(character)
                    and part1:IsDescendantOf(character)
                then
                    count += 1
                end
            end
        end
        return count
    end

    local function isDetachedPermadeathShell(character, humanoid)
        if typeof(character) ~= "Instance"
            or not character:IsA("Model")
            or not character.Parent
            or Player.Character ~= character
        then
            return false
        end
        humanoid = humanoid or character:FindFirstChildOfClass("Humanoid")
        local root = character:FindFirstChild("HumanoidRootPart")
        local head = character:FindFirstChild("Head")
        if not humanoid
            or not root
            or not head
            or humanoid.Health <= 0
        then
            return false
        end
        -- Gelatek's normal path removes every body Motor6D except Neck. A
        -- healthy Roblox spawn has several connected body joints in both R6
        -- and R15, so zero/one means this is a retained reanimation shell,
        -- not a newly assembled avatar.
        return countConnectedBodyJoints(character) <= 1
    end

    local function getPlayableCandidate(character, excluded, secondExcluded)
        if not character
            or character == excluded
            or character == secondExcluded
            or not character.Parent
        then
            return nil
        end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local root = character:FindFirstChild("HumanoidRootPart")
        if not humanoid
            or not root
            or humanoid.Health <= 0
            or humanoid:GetState() == Enum.HumanoidStateType.Dead
        then
            return nil
        end
        return character, humanoid
    end

    local function restoreCharacterRuntime(character, humanoid)
        if not character or not humanoid then
            return false
        end
        restoreIsolatedPhysicalCharacter(character)
        pcall(function() Player.Character = character end)
        for _, instance in ipairs(character:GetDescendants()) do
            if instance:IsA("LocalScript") then
                pcall(function() instance.Disabled = false end)
            end
        end
        local animateDeadline = os.clock() + 3
        repeat
            local animate = character:FindFirstChild("Animate")
            if animate and animate:IsA("LocalScript") then
                pcall(function() animate.Disabled = false end)
                break
            end
            task.wait(0.05)
        until os.clock() >= animateDeadline or Player.Character ~= character
        if not humanoid:FindFirstChildOfClass("Animator") then
            pcall(function()
                local animator = Instance.new("Animator")
                animator.Parent = humanoid
            end)
        end
        pcall(function() humanoid.AutoRotate = true end)
        pcall(function() humanoid.PlatformStand = false end)
        pcall(function() humanoid.Sit = false end)
        pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", true)
        pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Health, true)
        Reanimate.Shiftlocked = false
        local camera = workspace.CurrentCamera
        if camera then
            pcall(function()
                camera.CameraType = Enum.CameraType.Custom
                camera.CameraSubject = humanoid
            end)
            if type(Reanimate.Camera) == "table" then
                pcall(function()
                    Reanimate.Camera.CFrame = camera.CFrame
                    Reanimate.Camera.Focus = camera.Focus
                    if type(Reanimate.Camera.OnReset) == "function" then
                        Reanimate.Camera:OnReset()
                    end
                end)
            end
        end
        return true
    end

    local function waitForPlayableCharacter(excluded, timeout, preferred, secondExcluded)
        local latestCharacter = preferred
        local characterAddedConnection = Player.CharacterAdded:Connect(function(character)
            if character ~= excluded and character ~= secondExcluded then
                latestCharacter = character
            end
        end)
        local deadline = os.clock() + timeout
        repeat
            local character, humanoid = getPlayableCandidate(latestCharacter, excluded, secondExcluded)
            if not character then
                character, humanoid = getPlayableCandidate(Player.Character, excluded, secondExcluded)
            end
            if character then
                characterAddedConnection:Disconnect()
                return character, humanoid
            end
            task.wait(0.05)
        until os.clock() >= deadline
        characterAddedConnection:Disconnect()
        return nil
    end

    local function waitForAppearance(character, timeout, expectedAccessoryCount)
        if not character or Player.Character ~= character then
            return false, 0
        end
        expectedAccessoryCount = math.max(math.floor(tonumber(expectedAccessoryCount) or 0), 0)
        local startedAt = os.clock()
        local lastAccessoryChange = startedAt
        local deadline = startedAt + math.max(tonumber(timeout) or 0, 0.1)
        local function accessoryChanged(child)
            if child:IsA("Accessory") then
                lastAccessoryChange = os.clock()
            end
        end
        local addedConnection = character.ChildAdded:Connect(accessoryChanged)
        local removedConnection = character.ChildRemoved:Connect(accessoryChanged)
        local ready = false
        local count = 0
        repeat
            local accessories, allReady = collectReadyAccessories(character)
            count = #accessories
            local now = os.clock()
            local observedLongEnough = now - startedAt >= (expectedAccessoryCount > 0 and 0.35 or 1)
            local stable = now - lastAccessoryChange >= 0.65
            local appearanceLoaded = false
            local loadedOk, loaded = pcall(Player.HasAppearanceLoaded, Player)
            if loadedOk then
                appearanceLoaded = loaded == true
            end
            ready = count >= expectedAccessoryCount
                and allReady
                and observedLongEnough
                and stable
                and (appearanceLoaded or now - startedAt >= 1.25)
            if ready then
                break
            end
            RunService.Heartbeat:Wait()
        until Player.Character ~= character or os.clock() >= deadline
        addedConnection:Disconnect()
        removedConnection:Disconnect()
        return ready and Player.Character == character, count
    end

    local function prepareCharacterAppearance(character, humanoid, isRespawnGeneration)
        local expected = accessorySnapshotCaptured and #accessoryTemplates or 0
        local ready, count = waitForAppearance(
            character,
            isRespawnGeneration and 5 or 3,
            expected
        )
        local restored = 0
        if accessorySnapshotCaptured and count < expected then
            restored = restoreMissingAccessories(character, humanoid)
            if restored > 0 then
                RunService.Heartbeat:Wait()
                RunService.Heartbeat:Wait()
            end
        end
        local accessories = collectReadyAccessories(character)
        local finalCount = #accessories
        if not accessorySnapshotCaptured or finalCount >= expected then
            snapshotAccessoryAppearance(character)
        end
        if isRespawnGeneration then
            warn(
                ("Gelatek respawn appearance: %d/%d accessories ready%s%s"):format(
                    finalCount,
                    expected,
                    restored > 0 and ("; restored " .. tostring(restored) .. " from the prior generation") or "",
                    ready and "" or "; appearance wait reached its deadline"
                )
            )
        end
        return finalCount
    end

    local function findRespawnSignal()
        if type(replicatesignal) ~= "function" then
            return nil
        end
        for _, signalName in ipairs({ "ConnectDiedSignalBackend", "Kill" }) do
            local ok, signal = pcall(function()
                return Player[signalName]
            end)
            if ok and typeof(signal) == "RBXScriptSignal" then
                return signal
            end
        end
        return nil
    end

    local function requestSingleRespawn(excluded)
        local current = Player.Character
        if current and current ~= excluded then
            local humanoid = current:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > 0 then
                pcall(function() humanoid.BreakJointsOnDeath = true end)
                pcall(function() humanoid.Health = 0 end)
                pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Dead) end)
                return true
            end
        end
        local respawnSignal = findRespawnSignal()
        if respawnSignal then
            return pcall(replicatesignal, respawnSignal)
        end
        return false
    end

    local function uninstallResetBridge()
        if resetBindableConnection then
            pcall(function()
                resetBindableConnection:Disconnect()
            end)
            resetBindableConnection = nil
        end
        if resetBindable then
            pcall(function()
                resetBindable:Destroy()
            end)
            resetBindable = nil
        end
        resetInFlight = false
        rebindInProgress = false
        pendingPhysicalCharacter = nil
        pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", true)
    end

    local function installResetBridge()
        if not findRespawnSignal() then
            -- Executors without a callable respawn signal keep Roblox's default
            -- reset path; controller-death recovery below still preserves place.
            return false
        end
        if not resetBindable then
            resetBindable = Instance.new("BindableEvent")
            resetBindable.Name = "_UhhhhhhGelatekReset"
            resetBindableConnection = resetBindable.Event:Connect(function()
                local rig = backend.Rig
                if resetInFlight
                    or not backend.Running
                    or Reanimate.Stopping
                    or not rig
                    or not rig.Parent
                then
                    return
                end
                resetInFlight = true
                rebindInProgress = true
                pendingPhysicalCharacter = backend.RealCharacter
                isolatePhysicalCharacter(pendingPhysicalCharacter)
                updatePoseMirror(rig)
                setRespawnPlaceholderActive(true, rig)
                if not requestSingleRespawn(rig) then
                    task.defer(function()
                        uninstallResetBridge()
                        Util.Notify("Gelatek reset bridge unavailable; press Reset again")
                    end)
                else
                    task.delay(math.max(game:GetService("Players").RespawnTime + 8, 12), function()
                        if resetInFlight and backend.Rig == rig and rig.Parent then
                            local physical = backend.RealCharacter
                            local physicalHumanoid = physical and physical:FindFirstChildOfClass("Humanoid")
                            local replacement = Player.Character
                            if replacement and replacement ~= rig and replacement ~= physical then
                                local replacementHumanoid = replacement:FindFirstChildOfClass("Humanoid")
                                if replacementHumanoid and replacementHumanoid.Health > 0 then
                                    pendingPhysicalCharacter = replacement
                                    isolatePhysicalCharacter(replacement)
                                    return
                                end
                            end
                            if physicalHumanoid and physicalHumanoid.Health <= 0 then
                                local retried = requestSingleRespawn(rig)
                                if retried then
                                    task.delay(math.max(game:GetService("Players").RespawnTime + 5, 9), function()
                                        if resetInFlight and backend.Rig == rig then
                                            resetInFlight = false
                                            rebindInProgress = false
                                            pendingPhysicalCharacter = nil
                                            setRespawnPlaceholderActive(false)
                                            warn("Gelatek: respawn request failed twice; physical character is dead")
                                            Util.Notify("Gelatek reset failed: no new character spawned")
                                        end
                                    end)
                                    return
                                end
                            end
                            resetInFlight = false
                            rebindInProgress = false
                            pendingPhysicalCharacter = nil
                            setRespawnPlaceholderActive(false)
                            warn("Gelatek: reset timed out; no replacement physical character")
                            Util.Notify("Gelatek reset failed: no replacement character")
                        end
                    end)
                end
            end)
        end
        return pcall(StarterGui.SetCore, StarterGui, "ResetButtonCallback", resetBindable)
    end

    local function recoverAfterStop(excluded, preferred, awaitAppearance, continueRespawn, retiredCharacter)
        -- After Gelatek stops, its Death function briefly restores the old
        -- physical shell to Player.Character. Never accept that as a normal
        -- CharacterAdded replacement: Gelatek has already removed its body
        -- joints. Wait for a genuinely new server spawn first.
        local retiredExclusion = continueRespawn and retiredCharacter or nil
        local character, humanoid = waitForPlayableCharacter(
            excluded,
            math.max(game:GetService("Players").RespawnTime + 4, 8),
            preferred,
            retiredExclusion
        )
        local permanentDeathFallback = false
        if not character and continueRespawn then
            local retiredHumanoid = retiredCharacter
                and retiredCharacter:FindFirstChildOfClass("Humanoid")
            if isDetachedPermadeathShell(retiredCharacter, retiredHumanoid) then
                -- Some places retain the jointless physical shell instead of
                -- sending a normal CharacterAdded spawn. Reusing it is valid,
                -- but the next generation must follow Gelatek's PD branch.
                character = retiredCharacter
                humanoid = retiredHumanoid
                permanentDeathFallback = true
            end
        end
        if not character then
            requestSingleRespawn(excluded)
            character, humanoid = waitForPlayableCharacter(
                excluded,
                math.max(game:GetService("Players").RespawnTime + 8, 12),
                nil,
                retiredExclusion
            )
        end
        if not character then
            return false, "Roblox did not provide a fresh playable character after Gelatek stopped"
        end
        if continueRespawn then
            rebindInProgress = true
            pendingPhysicalCharacter = character
            -- Complete the same normal-character recovery that a manual
            -- deanimate performs. Gelatek is not started again from inside the
            -- CharacterAdded/reset stack; the outer serialized loop waits for
            -- this fresh character to animate and settle first.
            restoreCharacterRuntime(character, humanoid)
            local settleDeadline = os.clock() + 0.35
            repeat
                RunService.Heartbeat:Wait()
            until Player.Character ~= character
                or humanoid.Health <= 0
                or os.clock() >= settleDeadline
            if Player.Character ~= character or humanoid.Health <= 0 then
                return false, "fresh Roblox character disappeared before Gelatek could restart"
            end
            if isDetachedPermadeathShell(character, humanoid) then
                permanentDeathFallback = true
            end
        else
            restoreCharacterRuntime(character, humanoid)
            if awaitAppearance then
                waitForAppearance(character, 3, 0)
            end
        end
        return true, nil, character, permanentDeathFallback
    end

    local function destroyRetiredPhysicalCharacter(retired, active, queued)
        if not retired
            or not retired.Parent
            or retired == active
            or retired == queued
        then
            return false
        end
        return pcall(function()
            retired:Destroy()
        end)
    end

    local function fallbackCleanup(preserveCharacter, continueRespawn, preserveController)
        local global = environment()
        local accessoryTargetFolder = global.UhhhhhhTBZGelatekAccessoryTargetFolder
        if typeof(accessoryTargetFolder) == "Instance" and accessoryTargetFolder.Parent then
            pcall(function()
                accessoryTargetFolder:Destroy()
            end)
        end
        local bodyHideTargetFolder = global.UhhhhhhTBZGelatekBodyHideTargetFolder
        if typeof(bodyHideTargetFolder) == "Instance" and bodyHideTargetFolder.Parent then
            pcall(function()
                bodyHideTargetFolder:Destroy()
            end)
        end
        if type(global.TableOfEvents) == "table" then
            for _, connection in pairs(global.TableOfEvents) do
                pcall(function()
                    connection:Disconnect()
                end)
            end
            table.clear(global.TableOfEvents)
        end
        if preserveCharacter
            and preserveCharacter.Parent
            and backend.Rig
            and preserveCharacter:IsDescendantOf(backend.Rig)
        then
            pcall(function()
                preserveCharacter.Parent = workspace
            end)
        end

        if continueRespawn then
            if not preserveController then
                detachCameraBridge()
                detachScaleBridge()
                if backend.Rig and backend.Rig.Parent then
                    pcall(function()
                        backend.Rig:Destroy()
                    end)
                end
                backend.Rig = nil
                Reanimate.Character = nil
                Bridge.Character = nil
                backend.Running = false
            else
                backend.Running = true
                Reanimate.Character = backend.Rig
                Bridge.Character = backend.Rig
                global.UhhhhhhTBZGelatekPreservedController = backend.Rig
            end
            backend.RealCharacter = nil
            backend.ActiveRealCharacter = nil
            Bridge.RealCharacter = nil
            global.RealChar = nil
            global.Stopped = false
            global.UhhhhhhTBZGelatekStop = nil
            global.UhhhhhhTBZGelatekPermaReady = nil
            global.UhhhhhhTBZGelatekPermaError = nil
            global.UhhhhhhTBZGelatekControllerReady = nil
            global.UhhhhhhTBZGelatekAlignStats = nil
            global.UhhhhhhTBZGelatekAccessoryTargetFolder = nil
            global.UhhhhhhTBZGelatekBodyHideTargetFolder = nil
            global.UhhhhhhTBZGelatekPhysicalRoot = nil
            global.UhhhhhhTBZGelatekControllerRoot = nil
            global.UhhhhhhTBZGelatekFlingActive = nil
            global.UhhhhhhTBZGelatekPreserveController = nil
            global.UhhhhhhTBZGelatekStaticRootCFrame = staticRootCFrame
            global.UhhhhhhTBZGelatekControllerDied = nil
            global.TableOfEvents = nil
            return
        end

        detachCameraBridge()
        detachScaleBridge()
        detachPoseMirror(true)
        uninstallResetBridge()
        clearAccessoryTemplates()
        rebindInProgress = false
        pendingPhysicalCharacter = nil
        restoreVoidDestruction()
        if backend.Rig and backend.Rig.Parent then
            pcall(function()
                backend.Rig:Destroy()
            end)
        end
        backend.Rig = nil
        backend.RealCharacter = nil
        backend.ActiveRealCharacter = nil
        backend.Running = false
        Reanimate.GelatekDisableDirectionalWalking = nil
        backend.EffectivePermanentDeath = false
        backend.PermanentDeathFallback = false
        backend.ServerPreparedPermanentDeath = false
        Reanimate.Character = nil
        Bridge.Character = nil
        Bridge.RealCharacter = nil
        global.HubMode = nil
        global.GelatekReanimateConfig = nil
        global.PartDisconnected = nil
        global.RealChar = nil
        global.Stopped = false
        global.UhhhhhhTBZGelatekStop = nil
        global.UhhhhhhTBZGelatekPermaReady = nil
        global.UhhhhhhTBZGelatekPermaError = nil
        global.UhhhhhhTBZGelatekControllerReady = nil
        global.UhhhhhhTBZShouldNoclip = nil
        global.UhhhhhhTBZGelatekDestroyHeight = nil
        global.UhhhhhhTBZGelatekHiddenPartsY = nil
        global.UhhhhhhTBZGelatekCharacterSpacingScale = nil
        global.UhhhhhhTBZGelatekAccessoryTargetFolder = nil
        global.UhhhhhhTBZGelatekBodyHideTargetFolder = nil
        global.UhhhhhhTBZGelatekPhysicalRoot = nil
        global.UhhhhhhTBZGelatekControllerRoot = nil
        global.UhhhhhhTBZGelatekFlingActive = nil
        global.UhhhhhhTBZGelatekPreserveController = nil
        global.UhhhhhhTBZGelatekPreservedController = nil
        global.UhhhhhhTBZGelatekStaticRootCFrame = nil
        global.UhhhhhhTBZGelatekControllerDied = nil
        global.UhhhhhhTBZGelatekBridgeStopping = nil
        global.UhhhhhhTBZGelatekDeathRunning = nil
        global.TableOfEvents = nil
    end

    function backend.Start()
        backend.LastError = nil
        backend.Running = false
        backend.EffectivePermanentDeath = false
        backend.PermanentDeathFallback = false
        backend.ServerPreparedPermanentDeath = false
        Reanimate.Starting = true
        Reanimate.Stopping = false

        local restartRequested = true
        local pendingReturnCFrame = nil
        local pendingPermanentDeathFallback = false
        while restartRequested and not Reanimate.Stopping do
        restartRequested = false
        local returnToStaticRoot = pendingReturnCFrame
        pendingReturnCFrame = nil
        local inheritedPermanentDeathFallback = pendingPermanentDeathFallback
        pendingPermanentDeathFallback = false
        local isRespawnGeneration = typeof(returnToStaticRoot) == "CFrame"
        if not (backend.Rig and backend.Rig.Parent) then
            backend.Running = false
        end
        local queuedRespawnCharacter = nil
        local respawnObserved = false
        local controllerDiedObserved = false
        local controllerPreserved = false
        local preservedControllerAtStart = backend.Rig and backend.Rig.Parent and backend.Rig or nil
        rebindInProgress = preservedControllerAtStart ~= nil
        local respawnConnections = {}
        local generationRunToken = {}
        local function disconnectRespawnObservers()
            for _, connection in ipairs(respawnConnections) do
                pcall(function()
                    connection:Disconnect()
                end)
            end
            table.clear(respawnConnections)
        end

        local ok, reason = xpcall(function()
            local compatible, missing = compatibility()
            assert(compatible, "missing required functions: " .. table.concat(missing, ", "))

            originalCharacter = Player.Character
            assert(originalCharacter and originalCharacter.Parent, "real character is not ready")
            captureSimulationRadius()
            local originalHumanoid = originalCharacter:FindFirstChildOfClass("Humanoid")
            assert(originalHumanoid, "real character Humanoid is not ready")
            local effectivePermanentDeath = options.PermanentDeath == true
            local permanentDeathFallback = false
            if not effectivePermanentDeath
                and isRespawnGeneration
                and (inheritedPermanentDeathFallback
                    or isDetachedPermadeathShell(originalCharacter, originalHumanoid))
            then
                effectivePermanentDeath = true
                permanentDeathFallback = true
                warn(
                    "Gelatek: retained jointless shell detected; using PD fallback for this generation only"
                )
                Util.Notify("Gelatek PD fallback (this respawn only)")
            end
            backend.EffectivePermanentDeath = effectivePermanentDeath
            backend.PermanentDeathFallback = permanentDeathFallback
            local serverPreparedPermanentDeath = false
            if effectivePermanentDeath then
                local prepared, response = preparePermanentDeathWithServerCodeRemote()
                serverPreparedPermanentDeath = prepared == true
                if serverPreparedPermanentDeath then
                    warn(
                        ("Gelatek: selected code remote prepared PD; %d neck joint(s) removed, %d owned part(s)"):format(
                            tonumber(response.NeckJointsBroken) or 0,
                            tonumber(response.OwnedParts) or 0
                        )
                    )
                end
            end
            backend.ServerPreparedPermanentDeath = serverPreparedPermanentDeath
            prepareCharacterAppearance(originalCharacter, originalHumanoid, isRespawnGeneration)
            rebindInProgress = preservedControllerAtStart ~= nil
            pendingPhysicalCharacter = originalCharacter
            isolatePhysicalCharacter(originalCharacter)
            backend.RealCharacter = originalCharacter
            backend.ActiveRealCharacter = originalCharacter
            Bridge.RealCharacter = originalCharacter
            captureOriginalFace(originalCharacter)
            originalCameraSubject = workspace.CurrentCamera and workspace.CurrentCamera.CameraSubject
            local before = snapshotWorkspaceModels()
            backend.DetectedRig = originalHumanoid.RigType.Name
            backend.ControllerRig = "R6"
            disableVoidDestruction()

            local global = environment()
            global.HubMode = true
            global.UhhhhhhTBZGelatekPermaReady = false
            global.UhhhhhhTBZGelatekAntiSleep = options.AntiSleep == true
            global.UhhhhhhTBZGelatekPermaError = nil
            global.UhhhhhhTBZGelatekControllerReady = false
            global.UhhhhhhTBZGelatekRunToken = generationRunToken
            global.UhhhhhhTBZGelatekCharacterSpacingScale = characterScale()
            global.UhhhhhhTBZGelatekPreserveController = nil
            global.UhhhhhhTBZGelatekPreservedController = preservedControllerAtStart
            -- Do not inject the tracker into Gelatek's rig maker. A respawn
            -- generation starts where Roblox spawned it, just like a manual
            -- reanimate, and is moved back only after ControllerReady below.
            global.UhhhhhhTBZGelatekStaticRootCFrame = nil
            global.UhhhhhhTBZGelatekControllerDied = function(diedRig)
                if Reanimate.Stopping
                    or controllerDiedObserved
                    or (diedRig and backend.Rig and diedRig ~= backend.Rig)
                then
                    return
                end
                controllerDiedObserved = true
                rebindInProgress = true
                pendingPhysicalCharacter = Player.Character ~= diedRig and Player.Character or backend.RealCharacter
                isolatePhysicalCharacter(pendingPhysicalCharacter)
                if diedRig and diedRig.Parent then
                    updatePoseMirror(diedRig)
                    setRespawnPlaceholderActive(true, diedRig)
                end
            end
            global.UhhhhhhTBZShouldNoclip = function()
                return Reanimate.Noclip == true
            end
            global.GelatekReanimateConfig = {
                AnimationsDisabled = options.AnimationsDisabled,
                RunToken = generationRunToken,
                -- Uhhhhhh's movement styles and ragdoll modules target an R6
                -- controller. Gelatek still auto-detects and maps every physical
                -- R15 body part to that controller.
                R15ToR6 = backend.DetectedRig == "R15",
                DontBreakHairWelds = options.DontBreakHairWelds,
                PermanentDeath = effectivePermanentDeath,
                ServerPermanentDeathReady = serverPreparedPermanentDeath,
                TeleportBackWhenVoided = options.TeleportBackWhenVoided,
                AlignReanimate = options.AlignReanimate,
                FullForceAlign = options.FullForceAlign,
                FasterHeartbeat = effectivePermanentDeath and options.FasterHeartbeat,
                DynamicalVelocity = options.DynamicalVelocity,
                DirectPositionCorrection = options.DirectPositionCorrection,
                -- Torso remains native Gelatek physics. Only Head/Neck uses a
                -- replication writer in non-PD.
                CurrentAngleBodyChain = false,
                CurrentAngleHeadOnly = not effectivePermanentDeath,
                DisableDirectionalWalking = options.DisableDirectionalWalking,
                DisableTweaks = options.DisableTweaks,
                LoadLibrary = options.LoadLibrary,
                DetailedCredits = options.DetailedCredits,
                TorsoFling = options.TorsoFling,
                BulletEnabled = options.BulletEnabled,
                BulletConfig = {
                    RunAfterReanimate = options.BulletRunAfter,
                    LockBulletOnTorso = options.BulletLockTorso,
                },
            }

            local compat = Context.LoadCompat()
            local source = assert(Context.GelatekSource, "missing bundled Gelatek runtime")
            compat.compile(source, "@Gelatek-Uhhhhhh")()

            local respawnTime = game:GetService("Players").RespawnTime
            local deadline = os.clock() + math.max(respawnTime + 25, 35)
            local rig
            repeat
                task.wait()
                rig = findControllerRig(before)
            until rig or os.clock() >= deadline

            assert(rig and rig.Parent, "Gelatek did not create a detectable controller rig")
            backend.Rig = rig
            local reusedController = preservedControllerAtStart ~= nil and rig == preservedControllerAtStart
            local controllerHumanoid = rig:FindFirstChildOfClass("Humanoid")
            assert(controllerHumanoid, "Gelatek controller is missing its Humanoid")
            -- Jointless ragdoll and Immersive VR intentionally disable the neck
            -- Motor6D. The controller must not die merely because that joint is off.
            pcall(function() controllerHumanoid.RequiresNeck = false end)
            pcall(function() controllerHumanoid.BreakJointsOnDeath = false end)
            -- Match the local Limb controller, not the real character's PD
            -- lifecycle. A jointless pose must not start the death/rebind loop.
            controllerHumanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
            backend.ControllerRig = controllerHumanoid.RigType.Name
            assert(
                backend.ControllerRig == "R6",
                "Gelatek created an incompatible " .. tostring(backend.ControllerRig) .. " controller"
            )
            if options.AnimationsDisabled then
                disableBackendAnimations(rig)
            end
            ensureVisibleHead(rig)

            local readyDeadline = os.clock() + math.max(respawnTime + 12, 18)
            repeat
                ensureVisibleHead(rig)
                task.wait(0.05)
            until (
                effectivePermanentDeath
                    and global.UhhhhhhTBZGelatekPermaReady == true
                    and global.UhhhhhhTBZGelatekControllerReady == true
                or not effectivePermanentDeath
                    and global.UhhhhhhTBZGelatekControllerReady == true
            )
                or global.UhhhhhhTBZGelatekPermaError ~= nil
                or not rig.Parent
                or os.clock() >= readyDeadline
            if effectivePermanentDeath then
                assert(
                    global.UhhhhhhTBZGelatekPermaReady == true
                        and global.UhhhhhhTBZGelatekControllerReady == true,
                    global.UhhhhhhTBZGelatekPermaError
                        and ("Gelatek permanent death failed: " .. tostring(global.UhhhhhhTBZGelatekPermaError))
                        or "Gelatek controller appeared, but permanent-death assignment did not finish"
                )
            else
                assert(
                    global.UhhhhhhTBZGelatekControllerReady == true,
                    "Gelatek controller appeared, but controller assignment did not finish"
                )
            end

            -- Finish this generation's assignment. A later fresh Roblox
            -- character is queued for the next serialized generation.
            pcall(function()
                Player.Character = rig
            end)
            if not reusedController then
                for _, attribute in ipairs({
                    "MovementInit",
                    "MovesetInternalName",
                    "IsDancing",
                    "DanceInternalName",
                }) do
                    pcall(function()
                        rig:SetAttribute(attribute, nil)
                    end)
                end
            end
            Reanimate.Character = rig
            Bridge.Character = rig
            local assignedRoot = rig:FindFirstChild("HumanoidRootPart")
            if assignedRoot and assignedRoot:IsA("BasePart") then
                Reanimate.LastSafeCFrame = returnToStaticRoot or assignedRoot.CFrame
            end
            backend.RigGeneration += 1
            backend.Running = true
            attachScaleBridge(rig)
            if typeof(returnToStaticRoot) == "CFrame" then
                local returned = pcall(function()
                    rig:PivotTo(returnToStaticRoot)
                    local root = rig:FindFirstChild("HumanoidRootPart")
                    if root and root:IsA("BasePart") then
                        root.AssemblyLinearVelocity = Vector3.zero
                        root.AssemblyAngularVelocity = Vector3.zero
                    end
                end)
                assert(returned, "fresh Gelatek controller could not return to the static root")
            end
            attachCameraBridge(rig)
            attachPoseMirror(rig)
            if (isRespawnGeneration or reusedController) and type(Lifecycle.RefreshController) == "function" then
                Lifecycle.RefreshController(rig)
            end
            if isRespawnGeneration then
                warn(
                    ("Gelatek respawn controller ready: generation %d; movement runtime refreshed"):format(
                        backend.RigGeneration
                    )
                )
            end
            rebindInProgress = false
            pendingPhysicalCharacter = nil
            setRespawnPlaceholderActive(false)
            resetInFlight = false
            installResetBridge()

            local function observeRespawn(character)
                if respawnObserved then
                    return
                end
                if backend.Running
                    and not Reanimate.Stopping
                    and character
                    and character.Parent
                    and character ~= rig
                    and character ~= originalCharacter
                then
                    respawnObserved = true
                    queuedRespawnCharacter = character
                    resetInFlight = false
                    rebindInProgress = true
                    pendingPhysicalCharacter = character
                    isolatePhysicalCharacter(character)
                    updatePoseMirror(rig)
                    setRespawnPlaceholderActive(true, rig)
                end
            end
            table.insert(respawnConnections, Player.CharacterAdded:Connect(observeRespawn))
            table.insert(
                respawnConnections,
                Player:GetPropertyChangedSignal("Character"):Connect(function()
                    observeRespawn(Player.Character)
                end)
            )
            Reanimate.Starting = false
            while not Reanimate.Stopping and rig.Parent and not respawnObserved and not controllerDiedObserved do
                if Reanimate.Character ~= rig then
                    Reanimate.Character = rig
                    Bridge.Character = rig
                end
                ensureVisibleHead(rig)
                task.wait(0.1)
            end

            disconnectRespawnObservers()
            local continueRespawn = not Reanimate.Stopping and (respawnObserved or controllerDiedObserved)
            if controllerDiedObserved then
                -- FakeHum.Died is already inside Gelatek's serialized Death path.
                -- Let that call finish instead of invoking Death a second time.
                local deathDeadline = os.clock() + 2
                repeat
                    task.wait()
                until not rig.Parent or os.clock() >= deathDeadline
                controllerPreserved = false
            elseif (Reanimate.Stopping or continueRespawn) and rig.Parent then
                -- Reusing the same controller Instance leaves animation module,
                -- Humanoid, and track state alive across an instant respawn.
                -- A manual deanimate/reanimate fixes that exact condition, so
                -- automate the same clean controller rebuild here. The static
                -- root and mirrored placeholder remain alive and preserve place.
                controllerPreserved = requestInternalStop(false)
            end
        end, debug.traceback)

        disconnectRespawnObservers()

        local cleanupGlobal = environment()
        if cleanupGlobal.UhhhhhhTBZGelatekRunToken == generationRunToken then
            cleanupGlobal.UhhhhhhTBZGelatekRunToken = nil
        end

        if not ok then
            backend.LastError = tostring(reason)
            warn("Gelatek: " .. backend.LastError)
            Util.Notify("Gelatek failed")
            if backend.Rig and backend.Rig.Parent then
                requestInternalStop(false)
            end
            controllerPreserved = false
        end

        Reanimate.Starting = false
        local restartCause = respawnObserved or controllerDiedObserved
        local continueRespawn = ok and restartCause and not Reanimate.Stopping
        local excludedRig = backend.Rig
        local retiredPhysicalCharacter = originalCharacter
        fallbackCleanup(queuedRespawnCharacter, continueRespawn, controllerPreserved)
        local recovered, recoveryError, recoveredCharacter, recoveredPermanentDeathFallback = recoverAfterStop(
            excludedRig,
            queuedRespawnCharacter,
            continueRespawn,
            continueRespawn,
            retiredPhysicalCharacter
        )
        if not recovered then
            backend.LastError = backend.LastError and (backend.LastError .. " | recovery: " .. recoveryError) or recoveryError
            warn("Gelatek recovery: " .. tostring(recoveryError))
            Util.Notify("Respawn failed")
            if continueRespawn then
                fallbackCleanup(nil, false, false)
            end
        else
            destroyRetiredPhysicalCharacter(
                retiredPhysicalCharacter,
                Player.Character,
                queuedRespawnCharacter
            )
        end
        originalCharacter = nil
        if continueRespawn and recovered and recoveredCharacter and not Reanimate.Stopping then
            -- This is a loop continuation, never a recursive Start/task.spawn.
            -- The old generation has fully stopped; only the static tracker is
            -- retained for the clean controller that the next iteration builds.
            pendingReturnCFrame = staticRootCFrame
            pendingPermanentDeathFallback = recoveredPermanentDeathFallback == true
            restartRequested = true
            backend.LastError = nil
            task.wait()
        end
        end
        if type(Lifecycle.Complete) == "function" then
            Lifecycle.Complete(backend)
        else
            Reanimate.Stopping = false
        end
    end

    function backend.Teleport(target)
        local rig = backend.Rig
        if not backend.Running or not rig or not rig.Parent then
            return false
        end
        local root = rig:FindFirstChild("HumanoidRootPart")
        if not root or not root:IsA("BasePart") then
            return false
        end

        local targetRootCFrame
        if typeof(target) == "Vector3" then
            targetRootCFrame = root.CFrame.Rotation + target
        elseif typeof(target) == "CFrame" then
            targetRootCFrame = target
        else
            return false
        end

        local currentRootCFrame = root.CFrame
        local delta = targetRootCFrame * currentRootCFrame:Inverse()
        local currentPivot = rig:GetPivot()
        local moved = pcall(function()
            -- Gelatek parents the physical character below FakeRig. Pivoting the
            -- whole model keeps physical limbs next to the controller during a
            -- large teleport instead of asking CFrameAlign to recover afterward.
            rig:PivotTo(delta * currentPivot)
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)
        if not moved then
            return false
        end

        staticRootCFrame = targetRootCFrame
        if staticRootPart and staticRootPart.Parent then
            staticRootPart.CFrame = targetRootCFrame
        end
        environment().UhhhhhhTBZGelatekStaticRootCFrame = targetRootCFrame
        return true
    end

    function backend.Fling(target, duration)
        if not backend.Running or not target or target == backend.Rig or target == backend.RealCharacter then
            return false
        end
        local now = os.clock()
        if typeof(target) == "Instance" then
            local last = recentFlingTargets[target]
            if last and now - last < 1 then
                return false
            end
            recentFlingTargets[target] = now
            task.delay(1, function()
                if recentFlingTargets[target] == now then
                    recentFlingTargets[target] = nil
                end
            end)
        end
        activeFling = {
            Target = target,
            Deadline = now
                + math.max(
                    tonumber(duration)
                        or (Reanimate.UsePhysicsRepRootPart and Reanimate.PhysicsRepRootPartFling)
                        or 2,
                    0.05
                ),
        }
        environment().UhhhhhhTBZGelatekFlingActive = true
        return true
    end

    function backend.ShowHitboxes()
        local rig = backend.Rig
        if rig and rig.Parent then
            updatePoseMirror(rig)
        elseif staticRootPart and staticRootPart.Parent then
            backend.StaticRoot = staticRootPart
        end
    end
    return backend
end


end
factories["core/compat"] = function()
-- Small compatibility and capability layer for Uhhhhhh Reanimate Modded.
-- It detects capabilities; it deliberately does not fake hidden-property functions.
local M = {}

local function isFunction(value) return type(value) == "function" end

M.request = request or http_request or (http and http.request) or (syn and syn.request)
M.getcustomasset = getcustomasset or getsynasset
M.gethiddenproperty = gethiddenproperty or gethiddenprop or get_hidden_property
M.sethiddenproperty = sethiddenproperty or sethiddenprop or set_hidden_property
M.identifyexecutor = identifyexecutor or getexecutorname

function M.httpGet(url)
    if isFunction(M.request) then
        local response = M.request({ Url = url, Method = "GET" })
        if type(response) == "table" and type(response.Body) == "string" then
            local status = tonumber(response.StatusCode)
            if response.Success == false or (status and (status < 200 or status >= 300)) then
                error("HTTP request failed: " .. tostring(response.StatusCode) .. " " .. tostring(response.StatusMessage))
            end
            return response.Body
        end
    end
    return game:HttpGet(url)
end

function M.compile(source, chunkname)
    assert(isFunction(loadstring), "loadstring is required")
    local chunk, err = loadstring(source)
    assert(chunk, err)
    return chunk
end

function M.loadLocal(path)
    assert(isfile(path), "missing local file: " .. path)
    return M.compile(readfile(path), path)
end

function M.report()
    local rows = {
        {"loadstring", loadstring, "required"},
        {"request/http.request", M.request, "preferred; game:HttpGet fallback exists"},
        {"readfile", readfile, "required"}, {"writefile", writefile, "required"},
        {"isfile", isfile, "required"}, {"isfolder", isfolder, "required"},
        {"makefolder", makefolder, "required"}, {"listfiles", listfiles, "required by Uhhhhhh"},
        {"delfile", delfile, "required by Uhhhhhh"},
        {"getcustomasset/getsynasset", M.getcustomasset, "required by Uhhhhhh music/assets"},
        {"firetouchinterest", firetouchinterest, "required by current Uhhhhhh startup check"},
        {"gethiddenproperty", M.gethiddenproperty, "required by current Uhhhhhh"},
        {"sethiddenproperty", M.sethiddenproperty, "required by current Uhhhhhh and Gelatek"},
        {"setscriptable", setscriptable, "Gelatek fallback path"},
        {"isnetworkowner", isnetworkowner, "Gelatek legacy diagnostic/ownership path"},
        {"identifyexecutor", M.identifyexecutor, "diagnostics"},
    }
    print("===== Uhhhhhh Reanimate Modded 1.0.9 BETA capability report =====")
    for _, row in ipairs(rows) do
        print((isFunction(row[2]) and "[OK] " or "[--] ") .. row[1] .. " - " .. row[3])
    end
    print("Hidden-property functions are never emulated with setscriptable by this bridge.")
    return rows
end

return M

end
factories["core/joints"] = function()
local Util = {}
Util.Notify = function(message) warn("[Gelatek] " .. tostring(message)) end
local setters = {}
local function register(name, fn)
    if type(fn)=="function" then table.insert(setters, {Name=name, Set=fn}) end
end
register("sethiddenproperty", sethiddenproperty)
register("sethiddenprop", sethiddenprop)
register("set_hidden_property", set_hidden_property)
if #setters==0 and type(setscriptable)=="function" then
    register("setscriptable fallback", function(instance, property, value)
        local previous=setscriptable(instance, property, true)
        local ok, err=pcall(function() instance[property]=value end)
        setscriptable(instance, property, previous)
        if not ok then error(err) end
    end)
end
Util.HiddenPropertySetterSource=setters[1] and setters[1].Name or "none"
function Util.TrySetHiddenProperty(instance, property, value)
    local lastError="no hidden-property setter is available"
    for _,candidate in ipairs(setters) do
        local ok, result=pcall(candidate.Set, instance, property, value)
        if ok and result~=false then return true, candidate.Name end
        lastError=ok and (candidate.Name.." returned false") or tostring(result)
    end
    return false, lastError
end
Util.IsCharacterJoint = function(joint)
	return typeof(joint) == "Instance"
		and (joint:IsA("Motor6D") or joint.ClassName == "AnimationConstraint")
end
Util.GetCharacterJointParts = function(joint)
	local success, part0, part1 = pcall(function()
		return joint.Part0, joint.Part1
	end)
	if success then
		return part0, part1
	end
	return nil, nil
end
Util.GetCharacterJointFrames = function(joint)
	local success, c0, c1 = pcall(function()
		return joint.C0, joint.C1
	end)
	if success and typeof(c0) == "CFrame" and typeof(c1) == "CFrame" then
		return c0, c1
	end
	return nil, nil
end
Util.CharacterJointReplicationStats = {
	State = "waiting",
	Source = Util.HiddenPropertySetterSource,
	Path = "original R6 writer",
	LastError = nil,
	Attempts = 0,
	Successes = 0,
	Failures = 0,
}
Util.IsR15CharacterJoint = function(joint)
	if typeof(joint) ~= "Instance" then
		return false
	end
	local character = joint:FindFirstAncestorOfClass("Model")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R15
end
Util.SetCharacterJointTransform = function(joint, transform, _legacyMotorReplication)
	if not Util.IsCharacterJoint(joint) or typeof(transform) ~= "CFrame" then
		return false
	end
	local applied = false
	if joint:IsA("Motor6D") then
		-- R6 is intentionally frozen to STEVE's original writer. R15 support must
		-- never insert a client-only Transform assignment into the R6 path again.
		-- Only a Motor6D proven to belong to an R15 Humanoid receives Transform;
		-- missing/custom rig metadata takes the conservative original R6 path.
		local r15Path = Util.IsR15CharacterJoint(joint)
		if r15Path then
			applied = pcall(function()
				joint.Transform = transform
			end)
		end
		local desiredApplied = pcall(function()
			joint.MaxVelocity = 9e9
			local _, _, desiredAngle = transform:ToEulerAngles(Enum.RotationOrder.ZYX)
			joint.DesiredAngle = desiredAngle
			joint:SetDesiredAngle(desiredAngle)
		end)
		applied = applied or desiredApplied
		local axis, angle = transform:ToAxisAngle()
		local offsetSuccess, offsetResult =
			Util.TrySetHiddenProperty(joint, "ReplicateCurrentOffset6D", transform.Position)
		local angleSuccess, angleResult =
			Util.TrySetHiddenProperty(joint, "ReplicateCurrentAngle6D", axis * angle)
		local stats = Util.CharacterJointReplicationStats
		stats.Path = r15Path and "R15 Transform + hidden writes" or "original R6 writer"
		stats.Attempts += 1
		if offsetSuccess and angleSuccess then
			stats.State = "accepted"
			stats.Source = angleResult or offsetResult or stats.Source
			stats.LastError = nil
			stats.Successes += 1
		else
			stats.State = "failed"
			stats.LastError = tostring(not offsetSuccess and offsetResult or angleResult)
			stats.Failures += 1
		end
	else
		applied = pcall(function()
			joint.Transform = transform
			joint.IsKinematic = true
		end)
	end
	return applied
end
Util.SetCharacterJointOffset = function(joint, offset, legacyMotorReplication)
	local c0, c1 = Util.GetCharacterJointFrames(joint)
	if not c0 or not c1 then
		return false
	end
	return Util.SetCharacterJointTransform(joint, c0:Inverse() * offset * c1, legacyMotorReplication)
end
-- Backward-compatible aliases for community modules written before R15's
-- AnimationConstraint-based Avatar Joint Upgrade.
Util.SetMotor6DTransform = Util.SetCharacterJointTransform
Util.SetMotor6DOffset = Util.SetCharacterJointOffset


return Util

end
factories["core/runtime"] = function()
return [=[local Global = (getgenv and getgenv()) or shared
-- [[ Services ]] --
local Speed = tick()
local Players = game:FindFirstChildOfClass("Players")
local UserInputService = game:FindFirstChildOfClass("UserInputService")
local TestService = game:FindFirstChildOfClass("TestService")
local RunService = game:FindFirstChildOfClass("RunService")
local StarterGui = game:FindFirstChildOfClass("StarterGui")
local CoreGui = game:FindFirstChildOfClass("CoreGui")
local Player = Players.LocalPlayer
local HubMode = Global.HubMode or false

-- [[ Variables ]] --
local Events = {}
local BodyVels = {}
local UhhhhhhTBZCreatedObjects = {}
-- This patch runs before Gelatek declares its local Config table.
local UhhhhhhTBZRunToken = (Global.GelatekReanimateConfig or {}).RunToken
local function UhhhhhhTBZRunActive()
	return UhhhhhhTBZRunToken ~= nil
		and Global.UhhhhhhTBZGelatekRunToken == UhhhhhhTBZRunToken
		and Global.Stopped ~= true
end
local function UhhhhhhTBZTrack(Object)
	table.insert(UhhhhhhTBZCreatedObjects, Object)
	return Object
end
local Root_Offset = 0.02
local Velocity = Vector3.new(0,0,-25.8)
local SpawnPoint = workspace:FindFirstChildOfClass("SpawnLocation",true) and workspace:FindFirstChildOfClass("SpawnLocation",true) or CFrame.new(0,20,0)

-- [[ Functions ]] --
local setfflag = setfflag or function(flag,bool) game:DefineFastFlag(flag,bool) end
local isnetworkowner = isnetworkowner or function(Part) return Part.ReceiveAge == 0 end
local sethiddenproperty = sethiddenproperty or set_hidden_property or function() end 
	
-- [[ Checking Settings ]] --
local Config = Global.GelatekReanimateConfig or {}
Global.TableOfEvents = {}

--[[ Ownership ]] --
local DisableTweaks = Config.DisableTweaks or false -- Disables Net-Boosting Tweaks
local DynamicalVelocity = Config.DynamicalVelocity or false -- Enables Dynamical/Movement Velocity

-- [[ Details ]] --
local DetailedCredits = Config.DetailedCredits or false -- Detailed Credits lol

-- [[ Rig Settings ]] --
local AreAnimationsDisabled = Config.AnimationsDisabled or false -- Disable Anims
local IsPermaDeath = Config.PermanentDeath or false -- Permanent Death

-- [[ R15 Stuff ]] --
local R15ToR6 = Config.R15ToR6 or false -- Convert R15 To R6

-- [[ Align Reanimate ]] --
local AlignReanimate = Config.AlignReanimate or false -- Align Reanimate
local MaxAlignReanimate = Config.FullForceAlign or false -- Maximazes Align Position Force by making another one, might be less stable but no longer wacky

local FasterHeartbeat = Config.FasterHeartbeat or false
-- Uses Newer Runservices, which makes artifical event x2 times faster than heartbeat, can affect fps. 

-- [[ Extra ]] --
local DontBreakHairWelds = Config.DontBreakHairWelds or false -- Keeps Hair to head (Non Perma Only)
local IsLoadLibraryEnabled = Config.LoadLibrary or false -- LoadLibrary
local TeleportBackWhenVoided = Config.TeleportBackWhenVoided or false -- Teleports back to surface whenever you fall into void
local OldVelocityMethod = Config.OldVelocityMethod or false -- Self Explainatory

-- [[ Flinging Methods ]] --
local IsTorsoFling = Config.TorsoFling or false -- Torso/Collision Fling
local IsBulletEnabled = Config.BulletEnabled or false -- Enable Bullet
local BulletConfig = Config.BulletConfig or {}
local BulletAfterReanim = BulletConfig.RunAfterReanimate or false -- Run After Reanimate
local LockBulletOnTorso = BulletConfig.LockBulletOnTorso or false -- Lock Bullet On Torso
if IsTorsoFling == true and IsBulletEnabled == true then
	IsTorsoFling = false
end

task.spawn(function()
-- [[ Custom Functions ]] --
local UhhhhhhTBZGelatekBodyHideTargets = setmetatable({}, {__mode = "k"})
local UhhhhhhTBZGelatekBodyHideTargetFolder = Instance.new("Folder")
UhhhhhhTBZGelatekBodyHideTargetFolder.Name = "GelatekBodyHideTargets"
UhhhhhhTBZGelatekBodyHideTargetFolder.Parent = workspace
Global.UhhhhhhTBZGelatekBodyHideTargetFolder = UhhhhhhTBZGelatekBodyHideTargetFolder
local function UhhhhhhGetGelatekBodyHideTarget(Part1, PartName)
	local Target = UhhhhhhTBZGelatekBodyHideTargets[Part1]
	if not Target or not Target.Parent then
		Target = Instance.new("Part")
		Target.Name = tostring(PartName or Part1.Name) .. " Gelatek Hide Target"
		Target.Transparency = 1
		Target.Anchored = true
		Target.CanCollide = false
		Target.CanQuery = false
		Target.CanTouch = false
		Target.CastShadow = false
		Target.Archivable = false
		Target.Parent = UhhhhhhTBZGelatekBodyHideTargetFolder
		UhhhhhhTBZGelatekBodyHideTargets[Part1] = Target
	end
	Target.Size = Part1.Size
	local HiddenY = tonumber(Global.UhhhhhhTBZGelatekHiddenPartsY) or -495
	local Position = Part1.Position
	local X = Position.X == Position.X and Position.X or 0
	local Z = Position.Z == Position.Z and Position.Z or 0
	Target.CFrame = CFrame.new(X, HiddenY, Z) * Part1.CFrame.Rotation
	return Target
end
local function UhhhhhhResolveBodyHideTarget(Part0, Part1)
	local Resolver = Global.UhhhhhhTBZGetBodyHideTargetInfo
	if type(Resolver) == "function" then
		local Success, ShouldHide, PartName = pcall(Resolver, Part0, Part1)
		if Success and ShouldHide == true then
			return UhhhhhhGetGelatekBodyHideTarget(Part1, PartName)
		end
	end
	return Part1
end
local CFrameAlign = function(Part0, Part1, Position, Angle)
	Part1 = UhhhhhhResolveBodyHideTarget(Part0, Part1)
	local CFrame_Position = Position or CFrame.new()

	Global.UhhhhhhTBZGelatekAlignStats =
		Global.UhhhhhhTBZGelatekAlignStats or setmetatable({}, {__mode = "k"})
	local UhhhhhhAlignStat = Global.UhhhhhhTBZGelatekAlignStats[Part0]
	if not UhhhhhhAlignStat then
		UhhhhhhAlignStat = {Calls = 0, OwnedCalls = 0, UnownedCalls = 0}
		Global.UhhhhhhTBZGelatekAlignStats[Part0] = UhhhhhhAlignStat
	end
	UhhhhhhAlignStat.Calls += 1
	UhhhhhhAlignStat.Part0Name = Part0.Name
	UhhhhhhAlignStat.Part1Name = Part1.Name
	UhhhhhhAlignStat.LastTime = os.clock()
	local UhhhhhhOwnerOk, UhhhhhhOwned = pcall(isnetworkowner, Part0)
	UhhhhhhOwned = UhhhhhhOwnerOk and UhhhhhhOwned == true
	UhhhhhhAlignStat.NetworkOwned = UhhhhhhOwned
	if UhhhhhhOwned then
		UhhhhhhAlignStat.OwnedCalls += 1
	else
		UhhhhhhAlignStat.UnownedCalls += 1
	end
	local CFrame_Angle = Angle or CFrame.Angles(0,0,0)
	if isnetworkowner(Part0) == true then
		local CharacterSpacingScale = tonumber(Global.UhhhhhhTBZGelatekCharacterSpacingScale) or 1
		CFrame_Position = CFrame_Position.Rotation + CFrame_Position.Position * CharacterSpacingScale
		local TargetCFrame = Part1.CFrame * CFrame_Position * CFrame_Angle
		-- Body hiding already resolves a dedicated target. Per-part clamping
		-- distorted body/accessory spacing during void falls.
		if Global.UhhhhhhTBZGelatekAntiSleep == true then
			TargetCFrame += Vector3.new(0, math.sin(os.clock() * 15) * 0.0015, 0)
		end
		UhhhhhhAlignStat.TargetCFrame = TargetCFrame
		UhhhhhhAlignStat.ErrorBefore =
			(Part0.Position - TargetCFrame.Position).Magnitude
		if Config.DirectPositionCorrection == true then
			local PositionError = (Part0.Position - TargetCFrame.Position).Magnitude
			if PositionError > 0.01 then
				Part0.Position = TargetCFrame.Position
			end
		end
		Part0.CFrame = TargetCFrame
		UhhhhhhAlignStat.ErrorAfter =
			(Part0.Position - TargetCFrame.Position).Magnitude
		if Part0:FindFirstChild("OwnershipCheck") then
			Part0:FindFirstChild("OwnershipCheck").Transparency = 1
		end
	elseif isnetworkowner(Part0) == false then
		if Part0:FindFirstChild("OwnershipCheck") then
			Part0:FindFirstChild("OwnershipCheck").Transparency = 0
		end
	end
end
local Align = function(Part0, Part1, Position, Orientation)
	local NormalPart1 = Part1
	Part1 = UhhhhhhResolveBodyHideTarget(Part0, NormalPart1)
	local AlignPosition = UhhhhhhTBZTrack(Instance.new("AlignPosition")); do
		AlignPosition.MaxForce = 66666666666
		AlignPosition.RigidityEnabled = true
		AlignPosition.Responsiveness = 200
		AlignPosition.Name = "AlignPosition_1"
		AlignPosition.Parent = Part0
	end

	local AlignOrientation = UhhhhhhTBZTrack(Instance.new("AlignOrientation")); do
		AlignOrientation.MaxTorque = 9e9 -- Better To Decrease this to avoid weird movement on R15.
		AlignOrientation.Responsiveness = 200
		AlignOrientation.Name = "AlignOrientation"
		AlignOrientation.Parent = Part0
	end

	local Attachment1 = UhhhhhhTBZTrack(Instance.new("Attachment")); do
		local BasePosition
		if typeof(Position) == "Vector3" then
			BasePosition = Position
		elseif typeof(Position) == "CFrame" then
			BasePosition = Position.Position
		elseif type(Position) == "number" then
			BasePosition = Vector3.new(0, Position, 0)
		else
			BasePosition = Vector3.new(0,0,0)
		end
		Attachment1:SetAttribute("UhhhhhhCharacterSpacingBasePosition", BasePosition)
		Attachment1.Position = BasePosition * (tonumber(Global.UhhhhhhTBZGelatekCharacterSpacingScale) or 1)
		local BaseOrientation
		if typeof(Orientation) == "Vector3" then
			BaseOrientation = Orientation
		elseif typeof(Orientation) == "CFrame" then
			local X, Y, Z = Orientation:ToOrientation()
			BaseOrientation = Vector3.new(math.deg(X), math.deg(Y), math.deg(Z))
		elseif type(Orientation) == "number" then
			BaseOrientation = Vector3.new(0, 0, Orientation)
		else
			BaseOrientation = Vector3.new(0,0,0)
		end
		Attachment1.Orientation = BaseOrientation
		Attachment1.Name = "Attachment_1"
		Attachment1.Parent = Part0
	end

	local Attachment2 = UhhhhhhTBZTrack(Instance.new("Attachment")); do
		Attachment2.Name = "GelatekATT2"
		Attachment2.Parent = Part1
	end
	table.insert(Events, RunService.PreSimulation:Connect(function()
		local Target = UhhhhhhResolveBodyHideTarget(Part0, NormalPart1)
		if Target and Target.Parent and Attachment2.Parent ~= Target then
			Attachment2.Parent = Target
		end
		local AntiSleep = Global.UhhhhhhTBZGelatekAntiSleep == true
			and math.sin(os.clock() * 15) * 0.0015 or 0
		Attachment2.Position = Vector3.new(0, AntiSleep, 0)
	end))

	AlignPosition.Attachment0 = Attachment1
	AlignPosition.Attachment1 = Attachment2
	AlignOrientation.Attachment0 = Attachment1
	AlignOrientation.Attachment1 = Attachment2

	if MaxAlignReanimate == true then
		task.spawn(function()
			repeat task.wait() until not UhhhhhhTBZRunActive() or not Part0.Parent or isnetworkowner(Part0) == true
			if not UhhhhhhTBZRunActive() or not Part0.Parent then return end
			task.wait(0.05) -- Avoiding Bugs
			if not UhhhhhhTBZRunActive() or not Part0.Parent or not Attachment1.Parent or not Attachment2.Parent then return end
			local AlignPosition2 = UhhhhhhTBZTrack(Instance.new("AlignPosition")); do
				AlignPosition2.Name = "GelatekAP2"
				AlignPosition2.RigidityEnabled = true
				AlignPosition2.Parent = Part0
			end
			AlignPosition2.Attachment0 = Attachment1
			AlignPosition2.Attachment1 = Attachment2
		end)
	end
end
local Notification = function(Title, Text, Duration)
	StarterGui:SetCore("SendNotification", {
		Title = Title or "Unknown",
		Text = Text or "Unknown",
		Duration = Duration or 3
	})
end
local ReCreateWelds = function(Model, Accessory) 
	-- [[ Inspiration from DevForum Post made by admin. ]] --
	local Handle = Accessory:FindFirstChild("Handle")
	pcall(function() Handle:FindFirstChildOfClass("Weld"):Destroy() end)
	local NewWeld = Instance.new("Weld")
	NewWeld.Name = "AccessoryWeld"
	NewWeld.Part0 = Handle
	local Attachment = Handle:FindFirstChildOfClass("Attachment")
	if Attachment then
		NewWeld.C0 = Attachment.CFrame
		NewWeld.C1 = Model:FindFirstChild(tostring(Attachment), true).CFrame
		NewWeld.Part1 = Model:FindFirstChild(tostring(Attachment), true).Parent
	else
		NewWeld.Part1 = Model:FindFirstChild("Head")
		NewWeld.C1 = CFrame.new(0,Model:FindFirstChild("Head").Size.Y / 2,0) * Accessory.AttachmentPoint:Inverse()
	end
	Handle.CFrame = NewWeld.Part1.CFrame * NewWeld.C1 * NewWeld.C0:Inverse()
	NewWeld.Parent = Accessory.Handle
end

local ArtificalEvent; do
	-- [[ Artifical Event; original by 4eyedfool; "Borrowing" From One.]] --
	local EventList = {"PreRender","PreAnimation","PreSimulation","PostSimulation"}
	if FasterHeartbeat == false or IsPermaDeath == false then
		EventList = {"PostSimulation"}
	end
	if not ArtificalEvent then
		local BindEvent = Instance.new("BindableEvent")
		local Tick = tick()
		for _,RunEvent in pairs(EventList) do
			table.insert(Events, RunService[RunEvent]:Connect(function()
				Tick = tick()
				BindEvent:Fire(tick()-Tick)
			end))
		end 
		ArtificalEvent = BindEvent.Event
	end
end
local R6Animate = function()
    local a=game.Players.LocalPlayer.Character;local b=a:WaitForChild("Torso")local c=b:WaitForChild("Right Shoulder")local d=b:WaitForChild("Left Shoulder")local e=b:WaitForChild("Right Hip")local f=b:WaitForChild("Left Hip")local g=b:WaitForChild("Neck")local h=a:WaitForChild("Humanoid")local i="Standing"local j=""local k=nil;local l=nil;local m=nil;local n=1.0;local o={}local p={idle={{id="http://www.roblox.com/asset/?id=180435571",weight=9},{id="http://www.roblox.com/asset/?id=180435792",weight=1}},walk={{id="http://www.roblox.com/asset/?id=180426354",weight=10}},run={{id="run.xml",weight=10}},jump={{id="http://www.roblox.com/asset/?id=125750702",weight=10}},fall={{id="http://www.roblox.com/asset/?id=180436148",weight=10}},climb={{id="http://www.roblox.com/asset/?id=180436334",weight=10}},sit={{id="http://www.roblox.com/asset/?id=178130996",weight=10}},toolnone={{id="http://www.roblox.com/asset/?id=182393478",weight=10}},toolslash={{id="http://www.roblox.com/asset/?id=129967390",weight=10}},toollunge={{id="http://www.roblox.com/asset/?id=129967478",weight=10}},wave={{id="http://www.roblox.com/asset/?id=128777973",weight=10}},point={{id="http://www.roblox.com/asset/?id=128853357",weight=10}},dance1={{id="http://www.roblox.com/asset/?id=182435998",weight=10},{id="http://www.roblox.com/asset/?id=182491037",weight=10},{id="http://www.roblox.com/asset/?id=182491065",weight=10}},dance2={{id="http://www.roblox.com/asset/?id=182436842",weight=10},{id="http://www.roblox.com/asset/?id=182491248",weight=10},{id="http://www.roblox.com/asset/?id=182491277",weight=10}},dance3={{id="http://www.roblox.com/asset/?id=182436935",weight=10},{id="http://www.roblox.com/asset/?id=182491368",weight=10},{id="http://www.roblox.com/asset/?id=182491423",weight=10}},laugh={{id="http://www.roblox.com/asset/?id=129423131",weight=10}},cheer={{id="http://www.roblox.com/asset/?id=129423030",weight=10}}}local q={"dance1","dance2","dance3"}local r={wave=false,point=false,dance1=true,dance2=true,dance3=true,laugh=false,cheer=false}function configureAnimationSet(s,t)if o[s]~=nil then for u,v in pairs(o[s].connections)do v:disconnect()end end;o[s]={}o[s].count=0;o[s].totalWeight=0;o[s].connections={}local w=script:FindFirstChild(s)if w~=nil then table.insert(o[s].connections,w.ChildAdded:connect(function(x)configureAnimationSet(s,t)end))table.insert(o[s].connections,w.ChildRemoved:connect(function(x)configureAnimationSet(s,t)end))local y=1;for u,z in pairs(w:GetChildren())do if z:IsA("Animation")then table.insert(o[s].connections,z.Changed:connect(function(A)configureAnimationSet(s,t)end))o[s][y]={}o[s][y].anim=z;local B=z:FindFirstChild("Weight")if B==nil then o[s][y].weight=1 else o[s][y].weight=B.Value end;o[s].count=o[s].count+1;o[s].totalWeight=o[s].totalWeight+o[s][y].weight;y=y+1 end end end;if o[s].count<=0 then for y,C in pairs(t)do o[s][y]={}o[s][y].anim=Instance.new("Animation")o[s][y].anim.Name=s;o[s][y].anim.AnimationId=C.id;o[s][y].weight=C.weight;o[s].count=o[s].count+1;o[s].totalWeight=o[s].totalWeight+C.weight end end end;function scriptChildModified(x)local t=p[x.Name]if t~=nil then configureAnimationSet(x.Name,t)end end;script.ChildAdded:connect(scriptChildModified)script.ChildRemoved:connect(scriptChildModified)for s,t in pairs(p)do configureAnimationSet(s,t)end;local D="None"local E=0;local F=0;local G=0.3;local H=0.1;local I=0.3;local J=0.75;function stopAllAnimations()local K=j;if r[K]~=nil and r[K]==false then K="idle"end;j=""k=nil;if m~=nil then m:disconnect()end;if l~=nil then l:Stop()l:Destroy()l=nil end;return K end;function setAnimationSpeed(L)if L~=n then n=L;l:AdjustSpeed(n)end end;function keyFrameReachedFunc(M)if M=="End"then local N=j;if r[N]~=nil and r[N]==false then N="idle"end;local O=n;playAnimation(N,0.0,h)setAnimationSpeed(O)end end;function playAnimation(P,Q,R)pcall(function()local S=math.random(1,o[P].totalWeight)local T=S;local y=1;while S>o[P][y].weight do S=S-o[P][y].weight;y=y+1 end;local C=o[P][y].anim;if C~=k then if l~=nil then l:Stop(Q)l:Destroy()end;n=1.0;l=R:LoadAnimation(C)l.Priority=Enum.AnimationPriority.Core;l:Play(Q)j=P;k=C;if m~=nil then m:disconnect()end;m=l.KeyframeReached:connect(keyFrameReachedFunc)end end)end;local U=""local V=nil;local W=nil;local X=nil;function toolKeyFrameReachedFunc(M)if M=="End"then playToolAnimation(U,0.0,h)end end;function playToolAnimation(P,Q,R,Y)local S=math.random(1,o[P].totalWeight)local T=S;local y=1;while S>o[P][y].weight do S=S-o[P][y].weight;y=y+1 end;local C=o[P][y].anim;if W~=C then if V~=nil then V:Stop()V:Destroy()Q=0 end;V=R:LoadAnimation(C)if Y then V.Priority=Y end;V:Play(Q)U=P;W=C;X=V.KeyframeReached:connect(toolKeyFrameReachedFunc)end end;function stopToolAnimations()local K=U;if X~=nil then X:disconnect()end;U=""W=nil;if V~=nil then V:Stop()V:Destroy()V=nil end;return K end;function onRunning(L)pcall(function()if L>0.01 then playAnimation("walk",0.1,h)if k and k.AnimationId=="http://www.roblox.com/asset/?id=180426354"then setAnimationSpeed(L/14.5)end;i="Running"else if r[j]==nil then playAnimation("idle",0.1,h)i="Standing"end end end)end;function onDied()i="Dead"end;function onJumping()playAnimation("jump",0.1,h)F=G;i="Jumping"end;function onClimbing(L)playAnimation("climb",0.1,h)setAnimationSpeed(L/12.0)i="Climbing"end;function onGettingUp()i="GettingUp"end;function onFreeFall()if F<=0 then playAnimation("fall",I,h)end;i="FreeFall"end;function onFallingDown()i="FallingDown"end;function onSeated()i="Seated"end;function onPlatformStanding()i="PlatformStanding"end;function onSwimming(L)if L>0 then i="Running"else i="Standing"end end;function getTool()for u,Z in ipairs(a:GetChildren())do if Z.className=="Tool"then return Z end end;return nil end;function getToolAnim(_)for u,a0 in ipairs(_:GetChildren())do if a0.Name=="toolanim"and a0.className=="StringValue"then return a0 end end;return nil end;function animateTool()if D=="None"then playToolAnimation("toolnone",H,h,Enum.AnimationPriority.Idle)return end;if D=="Slash"then playToolAnimation("toolslash",0,h,Enum.AnimationPriority.Action)return end;if D=="Lunge"then playToolAnimation("toollunge",0,h,Enum.AnimationPriority.Action)return end end;function moveSit()c.MaxVelocity=0.15;d.MaxVelocity=0.15;c:SetDesiredAngle(3.14/2)d:SetDesiredAngle(-3.14/2)e:SetDesiredAngle(3.14/2)f:SetDesiredAngle(-3.14/2)end;local a1=0;function move(a2)local a3=1;local a4=1;local a5=a2-a1;a1=a2;local a6=0;local a7=false;if F>0 then F=F-a5 end;if i=="FreeFall"and F<=0 then playAnimation("fall",I,h)elseif i=="Seated"then playAnimation("sit",0.5,h)return elseif i=="Running"then playAnimation("walk",0.1,h)elseif i=="Dead"or i=="GettingUp"or i=="FallingDown"or i=="Seated"or i=="PlatformStanding"then stopAllAnimations()a3=0.1;a4=1;a7=true end;if a7 then local a8=a3*math.sin(a2*a4)c:SetDesiredAngle(a8+a6)d:SetDesiredAngle(a8-a6)e:SetDesiredAngle(-a8)f:SetDesiredAngle(-a8)end;local _=getTool()if _ and _:FindFirstChild("Handle")then local a9=getToolAnim(_)if a9 then D=a9.Value;a9.Parent=nil;E=a2+.3 end;if a2>E then E=0;D="None"end;animateTool()else stopToolAnimations()D="None"W=nil;E=0 end end;table.insert(Events,h.Died:connect(onDied))table.insert(Events,h.Running:connect(onRunning))table.insert(Events,h.Jumping:connect(onJumping))table.insert(Events,h.Climbing:connect(onClimbing))table.insert(Events,h.GettingUp:connect(onGettingUp))table.insert(Events,h.FreeFalling:connect(onFreeFall))table.insert(Events,h.FallingDown:connect(onFallingDown))table.insert(Events,h.Seated:connect(onSeated))table.insert(Events,h.PlatformStanding:connect(onPlatformStanding))table.insert(Events,h.Swimming:connect(onSwimming))table.insert(Events, game:GetService("Players").LocalPlayer.Chatted:Connect(function(aa)local ab=""if aa=="/e dance"then ab=q[math.random(1,#q)]elseif string.sub(aa,1,3)=="/e "then ab=string.sub(aa,4)elseif string.sub(aa,1,7)=="/emote "then ab=string.sub(aa,8)end;if i=="Standing"and r[ab]~=nil then playAnimation(ab,0.1,h)end end))playAnimation("idle",0.1,h)i="Standing"table.insert(Events,game:GetService("RunService").Stepped:Connect(function()local u,a2=wait(0.1)move(a2)end))
end
do -- [[ Checking ]] --
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	if Player.Character.Name == "GelatekReanimate" then
		Notification("Error!", "Reanimate Is Already Running!", 3)
		return nil
	end
	if Player.Character:FindFirstChildWhichIsA("Humanoid").Health == 0 then
		Notification("Error!", "You are currently dead, wait until you will respawn.", 3)
		return nil
	end
	if not TestService:FindFirstChild("GelatekReanimateData") then
		local Folder = Instance.new("Folder")
		Folder.Name = "GelatekReanimateData"
		local FakeRig = Instance.new("Model"); do
			local Limbs = {}
			local Attachments = {}
			local function CreateJoint(Name,Part0,Part1,C0,C1)
				local Joint = Instance.new("Motor6D")
				Joint.Name = Name
				Joint.Part0 = Part0
				Joint.Part1 = Part1
				Joint.C0 = C0
				Joint.C1 = C1
				Joint.Parent = Part0
			end

			for i = 0,18 do
				local Attachment = Instance.new("Attachment")
				Attachment.Axis = Vector3.new(1,0,0)
				Attachment.SecondaryAxis = Vector3.new(0,1,0)
				table.insert(Attachments, Attachment)
			end
			for i = 0,3 do
				local Limb = Instance.new("Part")
				Limb.Size = Vector3.new(1, 2, 1)
				Limb.BottomSurface = Enum.SurfaceType.Smooth
				Limb.FormFactor = Enum.FormFactor.Symmetric
				Limb.Locked = true
				Limb.CanCollide = false
				Limb.Parent = FakeRig
				table.insert(Limbs, Limb)
			end

			Limbs[1].Name = "Right Arm"
			Limbs[2].Name = "Left Arm"
			Limbs[3].Name = "Right Leg"
			Limbs[4].Name = "Left Leg"

			local Head = Instance.new("Part"); do
				Head.Size = Vector3.new(2,1,1)
				Head.TopSurface = Enum.SurfaceType.Smooth
				Head.FormFactor = Enum.FormFactor.Symmetric
				Head.Locked = true
				Head.CanCollide = false
				Head.Name = "Head"
				Head.Parent = FakeRig
			end
			local Torso = Instance.new("Part"); do
				Torso.Size = Vector3.new(2, 2, 1)
				Torso.BottomSurface = Enum.SurfaceType.Smooth
				Torso.FormFactor = Enum.FormFactor.Symmetric
				Torso.Locked = true
				Torso.CanCollide = false
				Torso.Name = "Torso"
				Torso.Parent = FakeRig
			end
			local Root = Torso:Clone(); do
				Root.Transparency = 1
				Root.Name = "HumanoidRootPart"
				Root.Parent = FakeRig
			end

			CreateJoint("Neck", Torso, Head, CFrame.new(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0), CFrame.new(0, -0.5, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0))
			CreateJoint("RootJoint", Root, Torso, CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0), CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0))
			CreateJoint("Right Shoulder", Torso, Limbs[1], CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, -0, -1, 0, 0), CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, -0, -1, 0, 0))
			CreateJoint("Left Shoulder", Torso, Limbs[2], CFrame.new(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CFrame.new(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0))
			CreateJoint("Right Hip", Torso, Limbs[3], CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, -0, -1, 0, 0), CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, -0, -1, 0, 0))
			CreateJoint("Left Hip", Torso, Limbs[4], CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0))

			local Humanoid = Instance.new("Humanoid"); do
				Humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
				Humanoid.Parent = FakeRig
			end
			local Animator = Instance.new("Animator"); do
				Animator.Parent = Humanoid
			end
			local HumanoidDescription = Instance.new("HumanoidDescription"); do
				HumanoidDescription.Parent = Humanoid
			end
			local HeadMesh = Instance.new("SpecialMesh") do
				HeadMesh.Scale = Vector3.new(1.25, 1.25, 1.25)
				HeadMesh.Parent = Head
			end
			local Face = Instance.new("Decal"); do
				Face.Name = "face"
				Face.Texture = "http://www.roblox.com/asset/?id=158044781"
				Face.Parent = Head
			end
			local Animate = Instance.new("LocalScript"); do
				Animate.Name = "Animate" -- Template placeholder only
				Animate.Disabled = true
				Animate.Parent = FakeRig
			end
			local Health = Instance.new("Script"); do -- not neccessary to fill
				Health.Name = "Health"
				Health.Parent = FakeRig
			end
			FakeRig.Name = "Rig"
			FakeRig.PrimaryPart = Root
			FakeRig.Parent = Folder
			-- Attachments (Oh Boy..)
			Attachments[1].Name = "FaceCenterAttachment"
			Attachments[1].Position = Vector3.new(0, 0, 0)
			
			Attachments[2].Name = "FaceFrontAttachment"
			Attachments[2].Position = Vector3.new(0, 0, -0.6)
			
			Attachments[3].Name = "HairAttachment"	
			Attachments[3].Position = Vector3.new(0, 0.6, 0)
			
			Attachments[4].Name = "HatAttachment"
			Attachments[4].Position = Vector3.new(0, 0.6, 0)
			
			Attachments[5].Name = "RootAttachment"
			Attachments[5].Position = Vector3.new(0, 0, 0)
			
			Attachments[6].Name = "RightGripAttachment"
			Attachments[6].Position = Vector3.new(0, -1, 0)
			
			Attachments[7].Name = "RightShoulderAttachment"
			Attachments[7].Position = Vector3.new(0, 1, 0)
			
			Attachments[8].Name = "LeftGripAttachment"
			Attachments[8].Position = Vector3.new(0, -1, 0)
			
			Attachments[9].Name = "LeftShoulderAttachment"
			Attachments[9].Position = Vector3.new(0, 1, 0)
			
			Attachments[10].Name = "RightFootAttachment"
			Attachments[10].Position = Vector3.new(0, -1, 0)
			
			Attachments[11].Name = "LeftFootAttachment"
			Attachments[11].Position = Vector3.new(0, -1, 0)
			
			Attachments[12].Name = "BodyBackAttachment"
			Attachments[12].Position = Vector3.new(0, 0, 0.5)
			
			Attachments[13].Name = "BodyFrontAttachment"
			Attachments[13].Position = Vector3.new(0, 0, -0.5)
			
			Attachments[14].Name = "LeftCollarAttachment"
			Attachments[14].Position = Vector3.new(-1, 1, 0)
			
			Attachments[15].Name = "NeckAttachment"
			Attachments[15].Position = Vector3.new(0, 1, 0)
			
			Attachments[16].Name = "RightCollarAttachment"
			Attachments[16].Position = Vector3.new(1, 1, 0)
			
			Attachments[17].Name = "WaistBackAttachment"
			Attachments[17].Position = Vector3.new(0, -1, 0.5)
			
			Attachments[18].Name = "WaistCenterAttachment"
			Attachments[18].Position = Vector3.new(0, -1, 0)
			
			Attachments[19].Name = "WaistFrontAttachment"
			Attachments[19].Position = Vector3.new(0, -1, -0.5)
	

			Attachments[1].Parent = Head
			Attachments[2].Parent = Head
			Attachments[3].Parent = Head
			Attachments[4].Parent = Head

			Attachments[5].Parent = Root

			Attachments[6].Parent = Limbs[1]
			Attachments[7].Parent = Limbs[1]

			Attachments[8].Parent = Limbs[2]
			Attachments[9].Parent = Limbs[2]

			Attachments[10].Parent = Limbs[3]

			Attachments[11].Parent = Limbs[4]

			for i = 0,7 do
				Attachments[12 + i].Parent = Torso
			end
		end
		local R6FakeHat = Instance.new("Accessory"); do
			R6FakeHat.Name = "R6FakeHat"
			local Handle = Instance.new("Part")
			Handle.Name = "Handle"
			Handle.Transparency = 0.5
			Handle.Size = Vector3.new(2,1,1)
			Handle.Parent = R6FakeHat
		end
		local R15FakeHat = Instance.new("Accessory"); do
			R15FakeHat.Name = "R15FakeHat"
			local Handle = Instance.new("Part")
			Handle.Name = "Handle"
			Handle.Size = Vector3.new(1,1,1)
			Handle.Transparency = 0.5
			Handle.Color = Color3.fromRGB(163, 162, 165)
			local SpecialMesh = Instance.new("SpecialMesh")
			SpecialMesh.MeshId = "rbxassetid://5972856435"
			SpecialMesh.Parent = Handle
			Handle.Parent = R15FakeHat
		end
		R15FakeHat.Parent = Folder
		R6FakeHat.Parent = Folder
		FakeRig.Parent = Folder
		Folder.Parent = TestService
	end
end
Global.PartDisconnected = false
-- [[ Start ]] --
local Character = Player["Character"] or Player.CharacterAdded:Wait()
local Humanoid = Character:FindFirstChildWhichIsA("Humanoid")
local RootPart = Character:WaitForChild("HumanoidRootPart")
local CharacterDescendants = Character:GetDescendants()
local CharacterChildren = Character:GetChildren()
local CameraCFrame = workspace.CurrentCamera.CFrame
local FakeHats = Instance.new("Folder"); do
	FakeHats.Name = "FakeHats"
	FakeHats.Parent = Character
end
local RigType = Humanoid.RigType.Name
Global.RealChar = Character
Character.Archivable = true
if Character:FindFirstChild("Animate") then -- [[ Disable Animations ]] --
	Character:FindFirstChild("Animate").Disabled = true
	for _, Track in next, Humanoid:GetPlayingAnimationTracks() do
		Track:Stop();
	end
end
if IsTorsoFling == false then
	Humanoid:ChangeState("Physics")
end
do -- [[ Tweaks ]] --
	if DisableTweaks == false then
		Player.ReplicationFocus = workspace
		settings()["Physics"].PhysicsEnvironmentalThrottle = Enum.EnviromentalPhysicsThrottle.Disabled
		settings()["Physics"].AllowSleep = false
		settings()["Physics"].ForceCSGv2 = false
		settings()["Physics"].DisableCSGv2 = true
		settings()["Physics"].UseCSGv2 = false
		sethiddenproperty(workspace, "PhysicsSteppingMethod", Enum.PhysicsSteppingMethod.Fixed)
		sethiddenproperty(workspace, "InterpolationThrottling", Enum.InterpolationThrottlingMode.Disabled)
	end
end

local FakeRig; do -- [[ Rig Maker ]] --
	local PreservedController = Global.UhhhhhhTBZGelatekPreservedController
	Global.UhhhhhhTBZGelatekPreservedController = nil
	local PreservedHumanoid = typeof(PreservedController) == "Instance"
		and PreservedController:IsA("Model")
		and PreservedController:FindFirstChildOfClass("Humanoid")
	local ReusedController = PreservedHumanoid
		and PreservedHumanoid.Health > 0
		and PreservedController.Parent ~= nil
		and PreservedController:FindFirstChild("HumanoidRootPart") ~= nil
	if not ReusedController and typeof(PreservedController) == "Instance" and PreservedController.Parent then
		PreservedController:Destroy()
	end
	if ReusedController then
		FakeRig = PreservedController
		FakeRig.Name = "GelatekReanimate"
		local ControllerAnimate = FakeRig:FindFirstChild("Animate")
		if ControllerAnimate and ControllerAnimate:IsA("LocalScript") then
			-- The generated template script is empty. Uhhhhhh owns controller
			-- animation, and Gelatek's optional classic animator is a Lua closure.
			ControllerAnimate:Destroy()
		end
		FakeRig.Parent = workspace
	elseif RigType == "R6" or (RigType == "R15" and R15ToR6 == true) then
		FakeRig = TestService.GelatekReanimateData:FindFirstChild("Rig"):Clone()
		FakeRig.Name = "GelatekReanimate"
		for Index, Misc in ipairs(FakeRig:GetDescendants()) do
			if Misc:IsA("BasePart") or Misc:IsA("Decal") then
				Misc.Transparency = 1
			end
		end
		local ControllerAnimate = FakeRig:FindFirstChild("Animate")
		if ControllerAnimate and ControllerAnimate:IsA("LocalScript") then
			-- The generated template script is empty. Uhhhhhh owns controller
			-- animation, and Gelatek's optional classic animator is a Lua closure.
			ControllerAnimate:Destroy()
		end
		FakeRig.Parent = workspace
	else
		FakeRig = Character:Clone() 
		FakeRig.Name = "GelatekReanimate"
		for Index, Misc in ipairs(FakeRig:GetDescendants()) do
			if Misc:IsA("BasePart") or Misc:IsA("Decal") then
				Misc.Transparency = 1
			elseif Misc:IsA("Accessory") then
				Misc:Destroy()
			end
		end
		FakeRig:FindFirstChildWhichIsA("Humanoid").DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		local ControllerAnimate = FakeRig:FindFirstChild("Animate")
		if ControllerAnimate and ControllerAnimate:IsA("LocalScript") then
			-- The generated template script is empty. Uhhhhhh owns controller
			-- animation, and Gelatek's optional classic animator is a Lua closure.
			ControllerAnimate:Destroy()
		end
		FakeRig.Parent = workspace
	end
	if not ReusedController then
		-- Build exactly like a manual reanimation at the fresh Roblox spawn.
		-- The bridge returns the finished controller to its persistent tracker
		-- only after Gelatek signals that assignment is complete.
		FakeRig.HumanoidRootPart.CFrame = RootPart.CFrame
	end
end
local FakeHum = FakeRig:FindFirstChildOfClass("Humanoid")
Character.Parent = workspace -- keep the physical shell outside the scalable controller
local UhhhhhhTBZAccessoryTargets = {}
Global.UhhhhhhTBZGelatekAccessoryTargets = UhhhhhhTBZAccessoryTargets
local UhhhhhhTBZAccessoryTargetFolder = Instance.new("Folder")
UhhhhhhTBZAccessoryTargetFolder.Name = "GelatekAccessoryTargets"
UhhhhhhTBZAccessoryTargetFolder.Parent = workspace
Global.UhhhhhhTBZGelatekAccessoryTargetFolder = UhhhhhhTBZAccessoryTargetFolder
do --[[ Rename Hats (By Mizt) / AccessoryWeld Recreation (Fix Offsets) ]] --
	local HatsNames = {}
	for Index, Accessory in ipairs(CharacterDescendants) do
		if Accessory:IsA("Accessory") then
			if HatsNames[Accessory.Name] then
				if HatsNames[Accessory.Name] == "Unknown" then
					HatsNames[Accessory.Name] = {}
				end
				table.insert(HatsNames[Accessory.Name], Accessory)
			else
				HatsNames[Accessory.Name] = "Unknown"
			end	
		end
	end
	for Index, Tables in ipairs(HatsNames) do
		if type(Tables) == "table" then
			local Number = 1
			for Index2, Names in ipairs(Tables) do
				Names.Name = Names.Name .. Number
				Number = Number + 1
			end
		end
	end
	table.clear(HatsNames)
	---------------------------------------------------
	for _, v in pairs(Character:GetChildren()) do
		if v:IsA("Accessory") and v:FindFirstChild("Handle") then
			local FakeHats1 = v:Clone()
			local FakeHandle = FakeHats1:FindFirstChild("Handle")
			FakeHandle.Transparency = 1
			FakeHandle.CanCollide = false
			FakeHandle.CanQuery = false
			FakeHandle.CanTouch = false
			FakeHandle.CastShadow = false
			FakeHandle.Massless = true
			ReCreateWelds(FakeRig, FakeHats1)
			FakeHats1.Parent = UhhhhhhTBZAccessoryTargetFolder
			UhhhhhhTBZAccessoryTargets[v] = FakeHats1
		end
	end
end
local FakeRigDescendants = FakeRig:GetDescendants()
Global.UhhhhhhTBZGelatekPhysicalRoot = RootPart
Global.UhhhhhhTBZGelatekControllerRoot = FakeRig:FindFirstChild("HumanoidRootPart")
local function FollowPhysicalRoot(Position)
	if Global.UhhhhhhTBZGelatekFlingActive then
		return
	end
	local PhysicalTorso =
		Character:FindFirstChild("UpperTorso")
		or Character:FindFirstChild("Torso")
	if RootPart and RootPart.Parent and PhysicalTorso and PhysicalTorso.Parent then
		-- A connected root already follows its assembly. Moving it again
		-- would move the torso/head too and feed the offset back each frame.
		if RootPart.AssemblyRootPart == PhysicalTorso.AssemblyRootPart then
			return
		end
		if IsPermaDeath == false then
			local RigTorso = FakeRig:FindFirstChild("Torso")
				or FakeRig:FindFirstChild("UpperTorso")
			local Offset = RigType == "R15" and R15ToR6 == true
				and CFrame.new(0, 0.194, 0) or CFrame.new()
			if RigTorso then
				CFrameAlign(RootPart, RigTorso, Offset)
			end
		else
			CFrameAlign(RootPart, PhysicalTorso, Position)
		end
	end
end

-- Bullet System
local BulletHatInfo
local BulletPartInfo
local CollideFlingPart
local ExtraThing	
do
	local OldNetworkMarker = workspace:FindFirstChild("GELATEKOWNERSHIP")
	if OldNetworkMarker then
		OldNetworkMarker:Destroy()
	end
	local Network = Instance.new("Folder")
	Network.Name = "GELATEKOWNERSHIP"
	Network.Parent = workspace
	table.insert(Events, game:GetService("RunService").Stepped:Connect(function()
		if Global.UhhhhhhTBZGelatekRunToken == nil or Global.Stopped == true then
			return
		end
		pcall(sethiddenproperty, Player, "MaximumSimulationRadius", 10000000*2)
		pcall(sethiddenproperty, Player, "SimulationRadius", 10000000*2)
	end))
end
do --[[ Bullet/TorsoFling Checking ]]--
	if IsBulletEnabled == true and RigType == "R6" and IsPermaDeath == false then
		if not Character:FindFirstChild("Robloxclassicred") then -- [[ Hat Check ]] -- 
			local FakeHat = TestService:FindFirstChild("GelatekReanimateData"):FindFirstChild("R6FakeHat"):Clone()
			FakeHat.Parent = Character
			BulletHatInfo = {FakeHat, FakeRig:FindFirstChild("Left Arm"), CFrame.Angles(0,0,math.rad(90)), CFrame.new(), Vector3.new(), Vector3.new(0, 0, 90)}
		else
			BulletHatInfo = {Character:FindFirstChild("Robloxclassicred"), FakeRig:FindFirstChild("Left Arm"), CFrame.Angles(0,0,math.rad(90)), Vector3.new(), Vector3.new()}
		end
		BulletPartInfo = {Character:FindFirstChild("Left Arm"), FakeRig:FindFirstChild("Left Arm")}
	elseif IsBulletEnabled == true and RigType == "R6" and IsPermaDeath == true then
		BulletPartInfo = {Character:FindFirstChild("HumanoidRootPart"), FakeRig:FindFirstChild("HumanoidRootPart"), CFrame.new(), Vector3.new(), Vector3.new(), "yes"}
	elseif IsBulletEnabled == true and RigType == "R15" then
		local funnyoffseto = {0, 0}
		if R15ToR6 == true then
			funnyoffseto = {0.5, -0.5}
		end
		if not Character:FindFirstChild("SniperShoulderL") then -- [[ Hat Check ]] -- 
			local FakeHat = TestService:FindFirstChild("GelatekReanimateData"):FindFirstChild("R15FakeHat"):Clone()
			FakeHat.Parent = Character
			BulletHatInfo = {FakeHat, FakeRig:FindFirstChild("Left Arm") or FakeRig:FindFirstChild("LeftUpperArm"), CFrame.new(0, funnyoffseto[1], 0), Vector3.new(0, funnyoffseto[2], 0), Vector3.new()}
		else
			BulletHatInfo = {Character:FindFirstChild("SniperShoulderL"), FakeRig:FindFirstChild("Left Arm") or FakeRig:FindFirstChild("LeftUpperArm"), CFrame.new(0, funnyoffseto[1], 0), Vector3.new(0, funnyoffseto[2], 0), Vector3.new()}
		end
		if R15ToR6 == true then
			BulletPartInfo = {Character:FindFirstChild("LeftUpperArm"), FakeRig:FindFirstChild("Left Arm") or FakeRig:FindFirstChild("LeftUpperArm"), CFrame.new(0, 0.4085, 0), Vector3.new(0, -0.4085, 0), Vector3.new()}	
		else
			BulletPartInfo = {Character:FindFirstChild("LeftUpperArm"), FakeRig:FindFirstChild("Left Arm") or FakeRig:FindFirstChild("LeftUpperArm"), CFrame.new(0, 0, 0), Vector3.new(0, -0, 0), Vector3.new()}	
		end
	end
	if IsTorsoFling == true then
		CollideFlingPart = Character:FindFirstChild("Torso") or Character:FindFirstChild("UpperTorso")
		local Highlight = Instance.new("SelectionBox")
		Highlight.Adornee = CollideFlingPart
		Highlight.Name = "BulletHightlight"
		Highlight.Parent = CollideFlingPart 
		task.spawn(function()
			task.wait(1)
			if CollideFlingPart:FindFirstChild("AntiRotation") then
				CollideFlingPart:FindFirstChild("AntiRotation")
			end
		end)
		if RigType == "R6" then
			CollideFlingInfo = {CollideFlingPart, FakeRig:FindFirstChild("Torso"), CFrame.new()}
		elseif RigType == "R15" and R15ToR6 == true then
			CollideFlingInfo = {CollideFlingPart, FakeRig:FindFirstChild("Torso"), CFrame.new(0, 0.194, 0)}
		elseif RigType == "R15" and R15ToR6 == false then
			CollideFlingInfo = {CollideFlingPart, FakeRig:FindFirstChild("UpperTorso"), CFrame.new()}
		end
	else
		CollideFlingInfo = nil
		CollideFlingPart = nil
	end
	if BulletPartInfo then
		local Highlight = Instance.new("SelectionBox")
		Highlight.Adornee = BulletPartInfo[1]
		Highlight.Name = "BulletHightlight"
		Highlight.LineThickness = 0.05
		if BulletPartInfo[1].Name == "HumanoidRootPart" then
			Highlight.Transparency = 0.75
		end
		BulletPartInfo[1].Name = 'Bullet'
		BulletPartInfo[1].Transparency = 0.5
		Highlight.Parent = BulletPartInfo[1]
	end
end

Character:MoveTo(FakeRig.HumanoidRootPart.Position)

local Offsets --[[ Offsets For R15 ]] --
if RigType == "R15" then
	Offsets = {
		["UpperTorso"] = {FakeRig:FindFirstChild("Torso"), CFrame.new(0, 0.194, 0), Vector3.new(0, -0.194, 0)},
		["LowerTorso"] = {FakeRig:FindFirstChild("Torso"), CFrame.new(0, -0.79, 0), Vector3.new(0, 0.79, 0)},

		["RightUpperArm"] = {FakeRig:FindFirstChild("Right Arm"), CFrame.new(0, 0.4085, 0), Vector3.new(0, -0.4085, 0)},
		["RightLowerArm"] = {FakeRig:FindFirstChild("Right Arm"), CFrame.new(0, -0.184, 0), Vector3.new(0, 0.184, 0)},
		["RightHand"] = {FakeRig:FindFirstChild("Right Arm"), CFrame.new(0, -0.83, 0), Vector3.new(0, 0.83, 0)},

		["LeftUpperArm"] = {FakeRig:FindFirstChild("Left Arm"), CFrame.new(0, 0.4085, 0), Vector3.new(0, -0.4085, 0)},
		["LeftLowerArm"] = {FakeRig:FindFirstChild("Left Arm"), CFrame.new(0, -0.184, 0), Vector3.new(0, 0.184, 0)},
		["LeftHand"] = {FakeRig:FindFirstChild("Left Arm"), CFrame.new(0, -0.83, 0), Vector3.new(0, 0.83, 0)},

		["RightUpperLeg"] = {FakeRig:FindFirstChild("Right Leg"), CFrame.new(0, 0.575, 0), Vector3.new(0, -0.575, 0)},
		["RightLowerLeg"] = {FakeRig:FindFirstChild("Right Leg"), CFrame.new(0, -0.199, 0), Vector3.new(0, 0.199, 0)},
		["RightFoot"] = {FakeRig:FindFirstChild("Right Leg"), CFrame.new(0, -0.849, 0), Vector3.new(0, 0.849, 0)},

		["LeftUpperLeg"] = {FakeRig:FindFirstChild("Left Leg"), CFrame.new(0, 0.575, 0), Vector3.new(0, -0.575, 0)},
		["LeftLowerLeg"] = {FakeRig:FindFirstChild("Left Leg"), CFrame.new(0, -0.199, 0), Vector3.new(0, 0.199, 0)},
		["LeftFoot"] = {FakeRig:FindFirstChild("Left Leg"), CFrame.new(0, -0.849, 0), Vector3.new(0, 0.849, 0)}
	}
elseif RigType == "R6" then
	Offsets = {
		["Torso"] = {FakeRig:FindFirstChild("Torso"), CFrame.new()},
		["Right Arm"] = {FakeRig:FindFirstChild("Right Arm"), CFrame.new()},
		["Left Arm"] = {FakeRig:FindFirstChild("Left Arm"), CFrame.new()},
		["Right Leg"] = {FakeRig:FindFirstChild("Right Leg"), CFrame.new()},
		["Left Leg"] = {FakeRig:FindFirstChild("Left Leg"), CFrame.new()},
	}
end

if Config.CurrentAngleBodyChain == true and IsPermaDeath == false then
	if RigType == "R15" then
		Offsets["UpperTorso"] = nil
		Offsets["LowerTorso"] = nil
	else
		Offsets["Torso"] = nil
	end
end

if IsPermaDeath == true then
	task.spawn(function()
		Global.UhhhhhhTBZGelatekPermaError = nil
		local PermaOk, PermaReason = xpcall(function()
			FakeHum.BreakJointsOnDeath = false
			pcall(game:GetService("StarterGui").SetCore, game:GetService("StarterGui"), "ResetButtonCallback", false)
			local NetworkDelay = 0
			pcall(function()
				local Ping = game:GetService("Stats").Network.ServerStatsItem:FindFirstChild("Data Ping")
				NetworkDelay = Ping and math.max((tonumber(Ping:GetValue()) or 0) / 750, 0) or 0
			end)
			if Config.ServerPermanentDeathReady ~= true then
				task.wait(math.max(tonumber(Players.RespawnTime) or 0, 0) + NetworkDelay)
			end
			if not UhhhhhhTBZRunActive() then
				return
			end
			local Head = Character:FindFirstChild("Head")
			local TargetHead = FakeRig and FakeRig:FindFirstChild("Head")
			assert(Head and Head:IsA("BasePart"), "physical Head disappeared before the PD break")
			assert(TargetHead and TargetHead:IsA("BasePart"), "controller Head is missing")
			-- Server readiness is not evidence that local neck joints are gone.
			-- Detach the local Head in both preparation paths before registering
			-- its independent physical follower. Leave arm/leg joints untouched.
			local Broke, BreakReason = pcall(Head.BreakJoints, Head)
			assert(Broke, "head joint break failed: " .. tostring(BreakReason))
			Offsets["Head"] = {TargetHead, CFrame.new()}
			if AlignReanimate == true then
				Align(Head, TargetHead)
			end
			Global.UhhhhhhTBZGelatekPermaReady = true
		end, debug.traceback)
		pcall(game:GetService("StarterGui").SetCore, game:GetService("StarterGui"), "ResetButtonCallback", true)
		if not PermaOk then
			Global.UhhhhhhTBZGelatekPermaError = tostring(PermaReason)
			warn("Gelatek permanent death failed: " .. tostring(PermaReason))
		elseif Global.UhhhhhhTBZGelatekPermaReady then
			warn("Godmoded in: " .. string.sub(tostring(tick()-Speed),1,string.find(tostring(tick()-Speed),".")+5))
		end
	end)
end


do -- [[ Boosting Tweaks/Claims ]] --
	for _, v in pairs(CharacterDescendants) do
		if v:IsA("BasePart") then
			v:ApplyAngularImpulse(Vector3.new())
			v:ApplyImpulse(Velocity)
			local UhhhhhhCurrentAngleChain =
				Config.CurrentAngleBodyChain == true and IsPermaDeath == false
			local UhhhhhhCurrentAngleHeadOnly =
				Config.CurrentAngleHeadOnly == true and IsPermaDeath == false
			local UhhhhhhConnectedNonPDHead =
				(UhhhhhhCurrentAngleChain or UhhhhhhCurrentAngleHeadOnly)
				and v.Name == "Head"
			local UhhhhhhConnectedNonPDRoot =
				UhhhhhhCurrentAngleChain and v.Name == "HumanoidRootPart"
			local UhhhhhhConnectedNonPDLowerTorso =
				UhhhhhhCurrentAngleChain and v.Name == "LowerTorso"
			local UhhhhhhConnectedNonPDTorso =
				(UhhhhhhCurrentAngleChain or UhhhhhhCurrentAngleHeadOnly) and (
					v.Name == "Torso"
					or v.Name == "UpperTorso"
				)
			local UhhhhhhConnectedBodyChainPart =
				UhhhhhhConnectedNonPDHead
				or UhhhhhhConnectedNonPDRoot
				or UhhhhhhConnectedNonPDLowerTorso
				or UhhhhhhConnectedNonPDTorso

			if UhhhhhhConnectedNonPDRoot then
				v.RootPriority = 127
				v.Massless = false
				v.CustomPhysicalProperties = nil
			elseif UhhhhhhConnectedNonPDHead then
				v.RootPriority = -127
				v.Massless = true
				if HubMode == false then
					v.CustomPhysicalProperties = PhysicalProperties.new(0,0,0,0,0)
				end
			elseif UhhhhhhConnectedNonPDTorso
				or UhhhhhhConnectedNonPDLowerTorso
			then
				v.RootPriority = UhhhhhhCurrentAngleHeadOnly and 127 or 0
				v.Massless = not UhhhhhhCurrentAngleHeadOnly
				if HubMode == false then
					v.CustomPhysicalProperties = PhysicalProperties.new(0,0,0,0,0)
				end
			else
				v.RootPriority = 127
				if HubMode == false then
					v.CustomPhysicalProperties = PhysicalProperties.new(0,0,0,0,0)
					v.Massless = true
				end
			end

			if AlignReanimate == false
				and (
					UhhhhhhConnectedNonPDRoot
					or not UhhhhhhConnectedBodyChainPart
				)
			then -- causes weird ass movement
				local UhhhhhhPDHeadOrTorso = IsPermaDeath == true
					and (v.Name == "Head" or v.Name == "Torso"
						or v.Name == "UpperTorso" or v.Name == "LowerTorso")
				-- Pose-driven PD head/torso must not also be held at zero spin
				-- by infinite torque. Preserve the original arm/leg stabilizers.
				if not UhhhhhhConnectedNonPDRoot and not UhhhhhhPDHeadOrTorso then
					local ABV = Instance.new("BodyAngularVelocity")
					ABV.P = 1/0
					ABV.MaxTorque = Vector3.new(1/0,1/0,1/0)
					ABV.AngularVelocity = Vector3.new(0,0,0)
					ABV.Name = "AntiRotation"
					ABV.Parent = v
				end
				local BV = Instance.new("BodyVelocity")
				BV.P = 1/0
				BV.MaxForce = Vector3.new(1/0,1/0,1/0)
				BV.Velocity = Vector3.new(0,0,0)
				BV.Name =
					UhhhhhhConnectedNonPDRoot
						and "UhhhhhhRootClaim"
						or "Stabilition"
				BV.Parent = v
				table.insert(BodyVels, BV)
			end
			local HG = Instance.new("SelectionBox")
			HG.Adornee = v
			HG.Name = "OwnershipCheck"
			HG.LineThickness = 0.4
			HG.Transparency = 1
			HG.Color3 = Color3.fromRGB(125,240,125)
			HG.Parent = v
		end
	end
	coroutine.wrap(function() --// Delayless Method; Used for root Y cframing.
		while UhhhhhhTBZRunActive() and task.wait(0.05) do
			Root_Offset = Root_Offset * -1
		end
	end)()
end
table.insert(Events, RunService.PreSimulation:Connect(function()
	for _, v in pairs(CharacterDescendants) do -- [[ Detached physical shell ]] --
		if v:IsA("BasePart") and v.Parent then
			v.CanCollide = false
			v.CanQuery = false
			v.CanTouch = false
		end
	end
end))

local function Death()
	if Global.UhhhhhhTBZGelatekDeathRunning == true then return end
	Global.UhhhhhhTBZGelatekDeathRunning = true
	Global.Stopped = true
	if Global.UhhhhhhTBZGelatekRunToken == UhhhhhhTBZRunToken then Global.UhhhhhhTBZGelatekRunToken = nil end
	for _, Object in ipairs(UhhhhhhTBZCreatedObjects) do
		if Object and Object.Parent then pcall(function() Object:Destroy() end) end
	end
	table.clear(UhhhhhhTBZCreatedObjects)
	Global.UhhhhhhTBZGelatekPreservedController = Global.UhhhhhhTBZGelatekPreserveController == true and FakeRig or nil
	if UhhhhhhTBZAccessoryTargetFolder and UhhhhhhTBZAccessoryTargetFolder.Parent then
		UhhhhhhTBZAccessoryTargetFolder:Destroy()
	end
	if UhhhhhhTBZGelatekBodyHideTargetFolder and UhhhhhhTBZGelatekBodyHideTargetFolder.Parent then
		UhhhhhhTBZGelatekBodyHideTargetFolder:Destroy()
	end
	Global.UhhhhhhTBZGelatekAccessoryTargetFolder = nil
	Global.UhhhhhhTBZGelatekBodyHideTargetFolder = nil
	Global.UhhhhhhTBZGelatekPhysicalRoot = nil
	Global.UhhhhhhTBZGelatekControllerRoot = nil
	Global.UhhhhhhTBZGelatekFlingActive = nil
	Character.Parent = workspace
	Player.Character = Character -- restore the exact physical shell, even when two generations share its name
	Humanoid:ChangeState(15)
	if FakeRig and Global.UhhhhhhTBZGelatekPreserveController ~= true then FakeRig:Destroy() end
	for i,v in pairs(Events) do
		v:Disconnect()
	end
	for i,v in pairs(Global.TableOfEvents) do
		v:Disconnect()
	end
	if FakeRig and Global.UhhhhhhTBZGelatekPreserveController ~= true then FakeRig:Destroy() end
	FakeRig = nil
	task.wait(0.15)
	if game:FindFirstChildOfClass("TestService"):FindFirstChild("ScriptCheck") then
		game:FindFirstChildOfClass("TestService"):FindFirstChild("ScriptCheck"):Destroy()
	end
	Global.Stopped = false
	Global.RealChar = nil
end
	
Global.UhhhhhhTBZGelatekStop = Death

table.insert(Events, ArtificalEvent:Connect(function()
	if Global.UhhhhhhTBZGelatekPermaReady and FakeRig.HumanoidRootPart.Position.Y <= (Global.UhhhhhhTBZGelatekDestroyHeight or -500) + 70 then
		if TeleportBackWhenVoided == false then
            pcall(function()
                Death()
            end)
		else
			FakeRig:MoveTo(SpawnPoint.Position)
		end
	end
	if not CollideFlingInfo then
		local Torso = Character:FindFirstChild("Torso") or Character:FindFirstChild("UpperTorso")
		Torso.AssemblyLinearVelocity = Velocity	
	end
	for _, v in pairs(BodyVels) do
		v.Velocity = Velocity
	end

	for _, v in pairs(CharacterDescendants) do -- [[ Main Things ]] --
		if v:IsA("BasePart") then
			if v and v.Parent then
				if (CollideFlingInfo and v.Name ~= CollideFlingInfo[1].Name) or not CollideFlingInfo then
					v.AssemblyLinearVelocity = Velocity
				end
			end
		end
	end
	if AlignReanimate == true and IsTorsoFling == true then
		CFrameAlign(CollideFlingInfo[1], CollideFlingInfo[2], CollideFlingInfo[3]) 
	end
	if IsTorsoFling == true then
		if RigType == "R6" then
			if FakeHum.MoveDirection.Magnitude < 0.1 then
				CollideFlingPart.AssemblyLinearVelocity = Velocity
			elseif FakeHum.MoveDirection.Magnitude > 0.1 then
				CollideFlingPart.AssemblyLinearVelocity = Vector3.new(1000,1000,1000)
			end
		else
			CollideFlingPart.AssemblyLinearVelocity = Velocity
			if FakeHum.MoveDirection.Magnitude < 0.1 then
				CollideFlingPart.RotVelocity = Vector3.new()
			elseif FakeHum.MoveDirection.Magnitude > 0.1 then
				CollideFlingPart.RotVelocity = Vector3.new(2500,2500,2500)
			end
		end
	else

	end
	if AlignReanimate == false then
		for _, v in pairs(CharacterDescendants) do -- [[ Main Things ]] --
			if v:IsA("Accessory") and v.Parent then
				local Target = UhhhhhhTBZAccessoryTargets[v]
				local Handle0 = v:FindFirstChild("Handle")
				local Handle1 = Target and Target:FindFirstChild("Handle")
				if Handle0 and Handle1 and Global.UhhhhhhTBZGelatekAccessoryWriterActive ~= true then
					CFrameAlign(Handle0, Handle1)
				end
			end
		end
		for i, v in pairs(Offsets) do
			if RigType == "R15" and R15ToR6 == true and Character:FindFirstChild(i) then
				CFrameAlign(Character:FindFirstChild(i), v[1], v[2])
			elseif RigType == "R15" and R15ToR6 == false and Character:FindFirstChild(i) then
				CFrameAlign(Character:FindFirstChild(i), FakeRig:FindFirstChild(i))
			elseif RigType == "R6" and Character:FindFirstChild(i) then
				CFrameAlign(Character:FindFirstChild(i), v[1])
			end
		end
		if BulletHatInfo then
			CFrameAlign(BulletHatInfo[1].Handle, BulletHatInfo[2], BulletHatInfo[3])
		end
		if BulletPartInfo and Global.PartDisconnected == false then
			if BulletPartInfo[6] and BulletPartInfo[6] == "yes" then
				FollowPhysicalRoot(CFrame.new(0,Root_Offset,0))
			else
				CFrameAlign(BulletPartInfo[1], BulletPartInfo[2], BulletPartInfo[3])
			end
		end
	end
	if not (Config.CurrentAngleBodyChain == true and IsPermaDeath == false)
		and (RigType == "R15" or (RigType == "R6" and IsPermaDeath == false) or (RigType == "R6" and IsPermaDeath == true and IsBulletEnabled == false))
	then
		FollowPhysicalRoot(CFrame.new(0,Root_Offset,0))
	end
end))

if DynamicalVelocity == true then
	local Y_Vel = Vector3.new(0, 25.45, 0) -- stability hlfdsajkladfjkladfs
	table.insert(Events, RunService.PreSimulation:Connect(function()
		if OldVelocityMethod == true then
			Velocity = Vector3.new(FakeRig["HumanoidRootPart"].CFrame.LookVector.X * 85, FakeRig["Head"].Velocity.Y * 4, FakeRig["HumanoidRootPart"].CFrame.LookVector.Z * 85)
		else
			if FakeRig.HumanoidRootPart.Velocity.Y > 0 and FakeRig.HumanoidRootPart.Velocity.Y < 3 then
				Y_Vel = Vector3.new(0,25.45,0)
			else
				Y_Vel = Vector3.new(0,28 + (FakeHum.JumpPower/12.5) + FakeRig.HumanoidRootPart.Velocity.Y/15, 0)
			end
			if FakeHum.MoveDirection.Magnitude < 0.1 then
				Velocity = Y_Vel
			elseif FakeHum.MoveDirection.Magnitude > 0.1 then
				Velocity = FakeHum.MoveDirection * 125 + Y_Vel
			end
		end
	end))
end
if AlignReanimate == true then
	for _, v in pairs(CharacterDescendants) do
		if v:IsA("Accessory") and v.Parent then
			local Target = UhhhhhhTBZAccessoryTargets[v]
			local Handle0 = v:FindFirstChild("Handle")
			local Handle1 = Target and Target:FindFirstChild("Handle")
			if Handle0 and Handle1 then
				Align(Handle0, Handle1)
			end
		end
	end
	for i, v in pairs(Offsets) do
		if RigType == "R15" and R15ToR6 == true and Character:FindFirstChild(i) then
			Align(Character:FindFirstChild(i), v[1], v[3])
		elseif RigType == "R15" and R15ToR6 == false and Character:FindFirstChild(i) and i ~= "HumanoidRootPart" then
			Align(Character:FindFirstChild(i), FakeRig:FindFirstChild(i))
			FollowPhysicalRoot()
		elseif RigType == "R6" and Character:FindFirstChild(i) then
			Align(Character:FindFirstChild(i), v[1])
		end
	end
	if BulletHatInfo then
		Align(BulletHatInfo[1].Handle, BulletHatInfo[2], BulletHatInfo[4], BulletPartInfo[5])
		BulletHatInfo[1].Handle.AlignOrientation.RigidityEnabled = true
	end
	if BulletPartInfo then
		Align(BulletPartInfo[1], BulletPartInfo[2], BulletPartInfo[4], BulletPartInfo[5])
	end
end
-- [[ Break Joints ]] --
for Index, Joint in ipairs(CharacterDescendants) do
	if Joint:IsA("Motor6D") then
		local PreserveForCurrentAngleChain = false
		if Config.CurrentAngleBodyChain == true and IsPermaDeath == false then
			local P0, P1 = Joint.Part0, Joint.Part1
			local N0 = P0 and P0.Name
			local N1 = P1 and P1.Name
			PreserveForCurrentAngleChain =
				(N0 == "HumanoidRootPart" and (N1 == "Torso" or N1 == "LowerTorso"))
				or (N0 == "LowerTorso" and N1 == "UpperTorso")
				or ((N0 == "Torso" or N0 == "UpperTorso") and N1 == "Head")
		end
		if Joint.Name ~= "Neck" and not PreserveForCurrentAngleChain then
			Joint:Destroy()
		end
	elseif Joint.Name == "AccessoryWeld" then
		if IsPermaDeath == true then
			Joint:Destroy()
		elseif IsPermaDeath == false then
			local Attachment = Joint.Parent:FindFirstChildOfClass("Attachment")
			if DontBreakHairWelds == true then
				if Attachment.Name ~= "HatAttachment" and Attachment.Name ~= "FaceFrontAttachment" and Attachment.Name ~= "HairAttachment" and Attachment.Name ~= "FaceCenterAttachment" then
					Joint:Destroy()
				end
			else
				Joint:Destroy()
			end
		end	
	end
end
local CurCameraOffset = workspace.CurrentCamera.CFrame
workspace.CurrentCamera.CFrame = CurCameraOffset
Player.Character = FakeRig
workspace.CurrentCamera.CFrame = CurCameraOffset
workspace.CurrentCamera.CameraSubject = FakeHum
workspace.CurrentCamera.CFrame = CurCameraOffset
Global.UhhhhhhTBZGelatekControllerReady = true

-- "Disable Gelatek's Own Animator" means do not start Gelatek's legacy
-- DesiredAngle animator. It must not remove the Roblox Animator used by generic
-- animation-based movesets.
if not FakeHum:FindFirstChildOfClass("Animator") then
	Instance.new("Animator", FakeHum)
end

if AreAnimationsDisabled == false then
	if (RigType == "R15" and R15ToR6 == true) or RigType == "R6" then
		R6Animate()
	elseif RigType == "R15" and R15ToR6 == false then
		local SourceAnimate = Character:FindFirstChild("Animate")
		local TargetAnimate = FakeRig:FindFirstChild("Animate")
		if SourceAnimate and SourceAnimate:IsA("LocalScript") then
			local Anim = SourceAnimate:Clone()
			if TargetAnimate then
				TargetAnimate:Destroy()
			end
			Anim.Parent = FakeRig
			Anim.Disabled = false
		elseif TargetAnimate and TargetAnimate:IsA("LocalScript") then
			TargetAnimate.Disabled = false
		else
			warn("Gelatek controller has no usable Animate LocalScript")
		end
	end
end
if IsLoadLibraryEnabled == true and (not RunService:IsStudio()) then
	loadstring(game:HttpGet("https://raw.githubusercontent.com/Gelatekussy/GelatekReanimate/e776bcda907bcabade98d0ef671fce0c72e237e7/Addons/LoadLibrary.lua"))()
end
table.insert(Events,FakeHum.Died:Connect(function()
	if Global.UhhhhhhTBZGelatekBridgeStopping == true then
		return
	end
	local ControllerDied = Global.UhhhhhhTBZGelatekControllerDied
	if type(ControllerDied) == "function" then
		pcall(ControllerDied, FakeRig)
	end
	Death()
end))
-- The bridge owns Character reassignment and calls Death explicitly.

task.spawn(function()
	if IsBulletEnabled == true and BulletAfterReanim == true then
		task.wait(2.5)
		Global.PartDisconnected = true
		local Held = false
		local Players = game:GetService("Players")
		local Bullet = Character:FindFirstChild("Bullet")
		local Highlight = FakeRig:FindFirstChild("FlingerHighlighter")
		if not Bullet or not Bullet:IsA("BasePart") then
			warn("Gelatek bullet addon skipped: mapped Bullet part is missing")
			return
		end
		local function DestroyBulletObject(Name)
			local Object = Bullet:FindFirstChild(Name)
			if Object then
				Object:Destroy()
			end
		end
		DestroyBulletObject("AntiRotation")
		if AlignReanimate == true then
			DestroyBulletObject("GelatekAP2")
			DestroyBulletObject("AlignPosition_1")
			DestroyBulletObject("AlignOrientation")
		end
		Bullet.Transparency = 1
		local Mouse = Players.LocalPlayer:GetMouse()
		local Power = Instance.new("BodyAngularVelocity")
		local Position = Instance.new("BodyPosition")
		Position.Position = Bullet.Position
		Position.MaxForce = Vector3.new(math.huge,math.huge,math.huge)
		Position.P = 25000
		Position.D = 200
		Power.MaxTorque = Vector3.new(math.huge,math.huge,math.huge)
		Power.P = math.huge
		Power.AngularVelocity = Vector3.new(20000,20000,20000)
		table.insert(Global.TableOfEvents, Mouse.Button1Down:Connect(function()
			Held = true
		end))
		table.insert(Global.TableOfEvents, Mouse.Button1Up:Connect(function()
			Held = false
		end))
		
		Power.Parent = Bullet
		Position.Parent = Bullet
		coroutine.wrap(function()
			while true do
				Position.P = 25000
				task.wait(5)
				Position.P = 50000
				task.wait(1)
			end
		end)()
		table.insert(Global.TableOfEvents, game:GetService("RunService").Heartbeat:Connect(function()
			local Hue = tick() % 5/5
			pcall(function()
				if Held then
					if LockBulletOnTorso == true then
						if Mouse.Target:IsA("BasePart") then
							if Players:GetPlayerFromCharacter(Mouse.Target.Parent) then
								if Mouse.Target.Parent.Name ~= Players.LocalPlayer.Name then
									local Target = Mouse.Target.Parent:FindFirstChild("Torso") or Mouse.Target.Parent:FindFirstChild("Head") or Mouse.Target.Parent:FindFirstChildWhichIsA("BasePart")
									Position.Position = Target.Position
								end
							elseif Players:GetPlayerFromCharacter(Mouse.Target.Parent.Parent) then
								if Mouse.Target.Parent.Parent.Name ~= Players.LocalPlayer.Name then
									local Target = Mouse.Target.Parent.Parent:FindFirstChild("Torso") or Mouse.Target.Parent.Parent:FindFirstChild("Head") or Mouse.Target.Parent.Parent:FindFirstChildWhichIsA("BasePart")
									Position.Position = Target.Position
								end
							else
								Position.Position = Mouse.Hit.Position
							end
						end
					else
						if Mouse.Target:IsA("BasePart") then
							Position.Position = Mouse.Hit.Position
						end
					end
				else
					Position.Position = FakeRig["HumanoidRootPart"].Position
				end
				Highlight.Color3 = Color3.fromHSV(Hue, 1, 1)
			end)
		end))
	end
end)
if DetailedCredits == true then
	task.spawn(function()
		local ScreenGui = Instance.new("ScreenGui")
		local DefaultSample = Instance.new("Frame")
		local TextLabel = Instance.new("TextLabel")
		local UITextSizeConstraint = Instance.new("UITextSizeConstraint")
		local TextLabel_2 = Instance.new("TextLabel")
		local UITextSizeConstraint_2 = Instance.new("UITextSizeConstraint")
		local Cat = Instance.new("Frame")
		local UIAspectRatioConstraint = Instance.new("UIAspectRatioConstraint")
		local UIStroke = Instance.new("UIStroke")
		local Sound = Instance.new("Sound")
		--Properties:
		if not RunService:IsStudio() then
			ScreenGui.Parent = game.CoreGui
		else
			ScreenGui.Parent = Player.PlayerGui
		end
		DefaultSample.Name = "DefaultSample"
		DefaultSample.Parent = ScreenGui
		DefaultSample.AnchorPoint = Vector2.new(0.5, 0.5)
		DefaultSample.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		DefaultSample.BackgroundTransparency = 0.700
		DefaultSample.BorderSizePixel = 0
		DefaultSample.Position = UDim2.new(0.5, 0, -1.5, 0)
		DefaultSample.Size = UDim2.new(0.363999993, 0, 1.5, 0)

		UIStroke.Parent = DefaultSample
		UIStroke.ApplyStrokeMode = 1
		UIStroke.Thickness = 4
		UIStroke.Color = Color3.fromRGB(172, 172, 172)
		
		TextLabel.Parent = DefaultSample
		TextLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TextLabel.BackgroundTransparency = 1.000
		TextLabel.AnchorPoint = Vector2.new(0.5,0.5)
		TextLabel.Position = UDim2.new(0.5, 0, 0.190133557, 0)
		TextLabel.Size = UDim2.new(1, 0, 0.0285421945, 0)
		TextLabel.Font = Enum.Font.Arcade
		TextLabel.Text = "CREDITS (V1.5.5)"
		TextLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		TextLabel.TextScaled = true
		TextLabel.TextSize = 14.000
		TextLabel.TextStrokeTransparency = 0.000
		TextLabel.TextWrapped = true

		UITextSizeConstraint.Parent = TextLabel
		UITextSizeConstraint.MaxTextSize = 30

		Sound.Parent = DefaultSample
		Sound.SoundId = "rbxassetid://3216912628"
		Sound.Volume = 0.25
		
		TextLabel_2.Parent = DefaultSample
		TextLabel_2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TextLabel_2.BackgroundTransparency = 1.000
		TextLabel_2.Position = UDim2.new(0.0301664975, 0, 0.225778505, 0)
		TextLabel_2.Size = UDim2.new(0.943056703, 0, 0.3, 0)
		TextLabel_2.Font = Enum.Font.Arcade
		TextLabel_2.Text = [[GELATEK
		Reanimate Itself, New Low Jitter and more, 



		PRODUCTIONTAKEONE
		Optimization, Helpful with tweaks and some stuff.



		MYWORLD
		Delayless Method, Inspiration



		MIZT
		Hat Renamer, Inspiration
		
		
		4EYEDFOOL
		Artifical Heartbeat


		FNF SONIC.EXE TEAM
		Inspiration for the Credit GUI
		]]
		TextLabel_2.TextColor3 = Color3.fromRGB(255, 255, 255)
		TextLabel_2.TextScaled = true
		TextLabel_2.TextSize = 14.000
		TextLabel_2.TextStrokeTransparency = 0.000
		TextLabel_2.TextWrapped = true
		TextLabel_2.TextYAlignment = Enum.TextYAlignment.Top

		UITextSizeConstraint_2.Parent = TextLabel_2
		UITextSizeConstraint_2.MaxTextSize = 35

		Cat.Name = "Cat"
		Cat.Parent = DefaultSample
		Cat.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Cat.BackgroundTransparency = 1.000
		Cat.AnchorPoint = Vector2.new(0.5,0.5)
		Cat.Position = UDim2.new(0.5,0,0.7, 0)
		Cat.Size = UDim2.new(0.289978415, 0, 0.139616504, 0)

		UIAspectRatioConstraint.Parent = Cat

		if not RunService:IsStudio() then
			local getsynasset = getsynasset or getcustomasset or function() end 
			local request = syn and syn.request or http and http.request or request or function() end
			local isfile = isfile or readfile and function(filename) local succ,a = pcall(function() local b = readfile(filename) end) return succ end or function() end
				
			local Video = Instance.new("VideoFrame"); do
				Video.Size = UDim2.new(1,0,1,0)
				Video.Position = UDim2.new(0,0,0,0)
				Video.Looped = true
				Video.Parent = Cat
			end
			if false then -- legacy cat.webm promo disabled; it breaks sandboxed mobile filesystems
				if not isfile("cat.webm") then
					local Response, TempFile = request({Url = "https://cdn.discordapp.com/attachments/971520525736218766/1008731543298117692/cat.webm",Method = 'GET'})
					if Response.StatusCode == 200 then
						writefile("cat.webm",Response.Body)
					end
				end
				Video.Video = getsynasset("cat.webm")
				Video:Play()
				Sound:Play()
				DefaultSample:TweenPosition(UDim2.new(0.5,0,0.5,0), Enum.EasingDirection.InOut, Enum.EasingStyle.Quart, 1, false)
				task.wait(3.5)
				DefaultSample:TweenPosition(UDim2.new(0.5,0,2.5,0), Enum.EasingDirection.InOut, Enum.EasingStyle.Quart, 1, false)
				task.wait(2.5)
				ScreenGui:Destroy()
			else
				Video.Visible = false
			end
		end
	end)
else

end
-- legacy promo hooks removed

end)
warn("Reanimated in " .. string.sub(tostring(tick()-Speed),1,string.find(tostring(tick()-Speed),".")+5))


]=]
end
factories["core/visibility"] = function()
-- One visibility policy for hosted and URL-loader use. No physics writes.
local Visibility={}
Visibility.__index=Visibility
function Visibility.new(settings)
    return setmetatable({Settings=settings,Parts={},Connections={}},Visibility)
end
local function headPart(part)
    if part.Name=="Head" then return true end
    local weld=part:FindFirstChild("AccessoryWeld")
    if weld and weld:IsA("JointInstance") and weld.Part1 and weld.Part1.Name=="Head" then return true end
    for _,name in ipairs({"HatAttachment","HairAttachment","FaceFrontAttachment","FaceCenterAttachment"}) do
        if part:FindFirstChild(name) then return true end
    end
    return false
end
function Visibility:Restore()
    for _,connection in ipairs(self.Connections) do connection:Disconnect() end
    table.clear(self.Connections)
    for part,record in pairs(self.Parts) do
        if part.Parent and part.LocalTransparencyModifier==record.Last then
            part.LocalTransparencyModifier=record.Before
        end
    end
    table.clear(self.Parts)
end
function Visibility:Track(rig,physical)
    if self.Rig==rig and self.Physical==physical then return end
    self:Restore();self.Rig=rig;self.Physical=physical
    local function add(part)
        if part:IsA("BasePart") and not self.Parts[part] then
            self.Parts[part]={Before=part.LocalTransparencyModifier}
        end
    end
    for _,model in pairs({Rig=rig,Physical=physical}) do
        for _,part in ipairs(model:GetDescendants()) do add(part) end
        table.insert(self.Connections,model.DescendantAdded:Connect(add))
    end
end
function Visibility:Step(camera)
    if not camera then return end
    local settings=self.Settings
    local hostCamera=settings.Camera
    local firstPerson
    if hostCamera and type(hostCamera.IsFirstPerson)=="function" then
        firstPerson=hostCamera:IsFirstPerson()
    else firstPerson=(camera.Focus.Position-camera.CFrame.Position).Magnitude<1 end
    if hostCamera and hostCamera.Scriptable then firstPerson=false end
    for part,record in pairs(self.Parts) do
        if part.Parent then
            -- Match Uhhhhhh Limb: tools stay visible; body-on still hides the head.
            local hide=firstPerson and not part:FindFirstAncestorWhichIsA("Tool")
                and (not settings.FirstPersonBody or headPart(part))
            local value=hide and 1 or record.Before
            part.LocalTransparencyModifier=value;record.Last=value
        end
    end
end
function Visibility:Stop()
    self:Restore();self.Rig=nil;self.Physical=nil
end
return Visibility

end
factories["defaults"] = function()
return {["Gelatek"]={["BulletLockTorso"]=false,["PermanentDeath"]=false,["DirectPositionCorrection"]=true,["DetailedCredits"]=false,["FullForceAlign"]=false,["ShowMeHowILook"]=false,["DisableDirectionalWalking"]=true,["NonPDRecoveryRadiusPercent"]=5,["RagdollSelfCollision"]=true,["BulletEnabled"]=false,["DynamicalVelocity"]=true,["AlignReanimate"]=true,["DisableTweaks"]=false,["AnimationsDisabled"]=true,["BulletRunAfter"]=false,["RecoverBeforeVoid"]=true,["FasterHeartbeat"]=false,["DontBreakHairWelds"]=true,["LoadLibrary"]=false,["TorsoFling"]=false,["TeleportBackWhenVoided"]=true,["AntiSleep"]=true},["Character"]={["InfiniteJump"]=true,["Noclip"]=false,["SmoothCam"]=true,["FirstPersonBody"]=false,["ShiftlockEnabled"]=false,["SeatSit"]=true,["KeepSeatSitState"]=true,["ToolGrab"]=true,["ScaleGravity"]=true,["PatchmaVoidFloat"]=true,["CharacterScale"]=1,["PlaceholderTransparency"]=1,["ShowResetPlaceholder"]=true,["ShowControllerCharacter"]=false,["NetlessVelocity"]=30,["UseAngularVelocity"]=true,["UsePhysicsRepRootPart"]=true,["CameraFocusPart"]="Root",["WalkSpeed"]=16,["JumpPower"]=50},["Writers"]={["GelatekTorso"]="Gelatek Physics",["GelatekHead"]="CurrentAngle6D"}}

end
factories["init"] = function()
local Defaults = require("defaults")
local Backend = require("core/backend")
local Runtime = require("core/runtime")
local Compat = require("core/compat")
local Host = require("adapters/standalone")
local Module = {Version = "0.1.0-rc1"}
local live = {
    AntiSleep=true, DirectPositionCorrection=true, RagdollSelfCollision=true,
    RecoverBeforeVoid=true, DisableDirectionalWalking=true,
}
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function mergeMissing(target, defaults)
    for key,value in pairs(defaults) do
        if target[key] == nil then target[key] = copy(value) end
    end
end
function Module.GetDefaults() return copy(Defaults) end

function Module.Attach(context)
    assert(type(context) == "table" and context.Reanimate and context.SaveData,
        "Attach requires Uhhhhhh's backend context")
    local saved = context.SaveData
    saved.TheoBridge = saved.TheoBridge or {}
    saved.TheoBridge.Gelatek = saved.TheoBridge.Gelatek or {}
    mergeMissing(saved.TheoBridge.Gelatek, Defaults.Gelatek)
    saved.AnimLibOptions = saved.AnimLibOptions or {}
    saved.AnimLibOptions.ReplicationWriters = saved.AnimLibOptions.ReplicationWriters or {}
    mergeMissing(saved.AnimLibOptions.ReplicationWriters, Defaults.Writers)
    mergeMissing(context.Reanimate, Defaults.Character)
    context.GelatekSource = Runtime
    context.LoadCompat = context.LoadCompat or function() return Compat end
    local backend = Backend(context)
    if not context.Util.PredictionFling or not context.Util.PredictionFlingPart then
        backend.Fling = function() return false, "Fling requires a host prediction adapter" end
    end
    local api = {Version=Module.Version, Backend=backend, Context=context}
    local env = (getgenv and getgenv()) or shared or _G
    local thread
    local starting = false
    local lastError
    function api:GetState()
        return {Running=backend.Running == true, Starting=starting and not backend.Running,
            Stopping=context.Reanimate.Stopping == true, Error=lastError or backend.LastError,
            Rig=backend.Rig, RealCharacter=backend.RealCharacter}
    end
    function api:GetCharacter() return backend.Rig end
    function api:GetRealCharacter() return backend.RealCharacter end
    function api:GetSettings()
        local character = {}
        for key in pairs(Defaults.Character) do character[key] = context.Reanimate[key] end
        local gelatek, writers = {}, {}
        for key in pairs(Defaults.Gelatek) do gelatek[key]=saved.TheoBridge.Gelatek[key] end
        for key in pairs(Defaults.Writers) do writers[key]=saved.AnimLibOptions.ReplicationWriters[key] end
        return {Gelatek=gelatek, Character=character, Writers=writers}
    end
    function api:Configure(patch)
        assert(type(patch) == "table", "expected configuration table")
        -- Validate the whole update before changing the live context.
        for section, values in pairs(patch) do
            assert(Defaults[section] and type(values)=="table", "unknown section: "..tostring(section))
            for key,value in pairs(values) do
                local default = Defaults[section][key]
                assert(default ~= nil and type(value)==type(default), "invalid setting: "..tostring(key))
                if type(value)=="number" then
                    assert(value==value and math.abs(value)<math.huge and value>=0, "invalid numeric setting")
                    if key=="CharacterScale" then assert(value>=0.5 and value<=5, "scale must be 0.5..5") end
                    if key=="NonPDRecoveryRadiusPercent" then assert(value>=5 and value<=100, "recovery radius must be 5..100") end
                    if key=="PlaceholderTransparency" then assert(value<=1, "transparency must be 0..1") end
                end
                if section=="Writers" then
                    if key=="GelatekTorso" then
                        assert(value=="Gelatek Physics", "torso uses the native Gelatek physics writer")
                    else
                        assert(value=="CurrentAngle6D" or value=="WeldConstraint CFrame0", "unknown head writer")
                    end
                end
                if key=="CameraFocusPart" then
                    assert(table.find({"Root","Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg"},value), "unknown camera part")
                end
                if (starting or backend.Running) and section=="Gelatek" and not live[key] then
                    error(key.." requires Stop, then Configure, then Start", 2)
                end
            end
        end
        for section, values in pairs(patch) do
            local target = section=="Gelatek" and saved.TheoBridge.Gelatek
                or section=="Character" and context.Reanimate
                or saved.AnimLibOptions.ReplicationWriters
            for key,value in pairs(values) do target[key]=value end
        end
        if backend.Running and (not env.GelatekReanimateFork or env.GelatekReanimateFork==self) then
        env.UhhhhhhTBZGelatekAntiSleep = saved.TheoBridge.Gelatek.AntiSleep
        if env.GelatekReanimateConfig then
            env.GelatekReanimateConfig.DirectPositionCorrection = saved.TheoBridge.Gelatek.DirectPositionCorrection
        end
        end
        return self:GetSettings()
    end
    function api:Start()
        if starting or backend.Running then return self end
        local owner = env.GelatekReanimateFork
        assert(not owner or owner==self or not (owner:GetState().Running or owner:GetState().Starting),
            "another fork controller is active")
        env.GelatekReanimateFork = self
        starting, lastError = true, nil
        context.Reanimate.Stopping = false
        context.Reanimate.Starting = true
        thread = task.spawn(function()
            local ok, message = xpcall(function()
                if context.StartHost then context.StartHost(backend) end
                backend.Start()
            end, debug.traceback)
            starting = false
            context.Reanimate.Starting = false
            if not ok then lastError=tostring(message); warn(lastError) end
            if context.StopHost then context.StopHost() end
        end)
        return self
    end
    function api:WaitForReady(timeout)
        local deadline=os.clock()+(timeout or 45)
        repeat
            if backend.Running then return backend.Rig end
            if lastError or not starting then return nil, lastError or backend.LastError or "backend stopped before ready" end
            task.wait()
        until os.clock()>=deadline
        return nil, "controller readiness timed out; call Stop before retrying"
    end
    function api:Stop()
        context.Reanimate.Stopping = true
        return self -- cooperative: backend owns respawn/reset/physical cleanup
    end
    function api:Teleport(target) return backend.Teleport(target) end
    function api:GetDebugDump() return backend.GetDebugDump() end
    function api:MountConfig(parent)
        assert(context.UI, "MountConfig requires the host's UI adapter")
        return backend.Config(parent)
    end
    function api:CreateUI() return require("ui")(self) end
    return api
end
function Module.new(settings)
    local context = Host()
    local api = Module.Attach(context)
    if settings then api:Configure(settings) end
    return api
end
function Module.FromLegacy(config)
    local result = {Gelatek={}, Character={}}
    for key,value in pairs(config or {}) do
        if Defaults.Gelatek[key] ~= nil then result.Gelatek[key]=value
        elseif Defaults.Character[key] ~= nil then result.Character[key]=value
        elseif key=="BulletConfig" and type(value)=="table" then
            result.Gelatek.BulletRunAfter=value.RunAfterReanimate
            result.Gelatek.BulletLockTorso=value.LockBulletOnTorso
        else
            warn("[Gelatek Fork] Unsupported legacy option: "..tostring(key))
        end
    end
    return result
end
return Module

end
factories["ui"] = function()
return function(api)
    local player=game:GetService("Players").LocalPlayer
    local gui=Instance.new("ScreenGui")
    gui.Name="GelatekForkSettings"
    gui.ResetOnSpawn=false
    gui.Parent=player:WaitForChild("PlayerGui")
    local panel=Instance.new("ScrollingFrame")
    panel.Size=UDim2.new(1,-32,0.85,0)
    local bounds=Instance.new("UISizeConstraint")
    bounds.MaxSize=Vector2.new(330,460)
    bounds.Parent=panel
    panel.AnchorPoint=Vector2.new(0,0.5)
    panel.Position=UDim2.new(0,16,0.5,0)
    panel.BackgroundColor3=Color3.fromRGB(24,26,31)
    panel.AutomaticCanvasSize=Enum.AutomaticSize.Y
    panel.CanvasSize=UDim2.new()
    panel.Parent=gui
    local layout=Instance.new("UIListLayout")
    layout.Padding=UDim.new(0,5)
    layout.Parent=panel
    local function row(class,text)
        local item=Instance.new(class)
        item.Size=UDim2.new(1,-12,0,32)
        item.BackgroundColor3=Color3.fromRGB(39,43,51)
        item.TextColor3=Color3.fromRGB(235,238,245)
        item.TextSize=14
        item.Font=Enum.Font.Gotham
        item.Text=text
        item.Parent=panel
        return item
    end
    row("TextLabel","Gelatek Fork "..api.Version)
    local status=row("TextLabel","Ready")
    local function action(name,callback)
        row("TextButton",name).Activated:Connect(function()
            local ok,err=pcall(callback)
            status.Text=ok and name or tostring(err)
        end)
    end
    action("Start",function() api:Start() end)
    action("Stop",function() api:Stop() end)
    local defaults=api:GetSettings()
    for _,section in ipairs({"Gelatek","Character","Writers"}) do
        row("TextLabel",section=="Character" and "Reanimate Character Settings" or section)
        local keys={}
        for key in pairs(defaults[section]) do
            if key~="SchemaVersion" then table.insert(keys,key) end
        end
        table.sort(keys)
        for _,key in ipairs(keys) do
            local value=defaults[section][key]
            if type(value)=="boolean" then
                local button=row("TextButton",key..": "..tostring(value))
                button.Activated:Connect(function()
                    local nextValue=not api:GetSettings()[section][key]
                    local ok,err=pcall(api.Configure,api,{[section]={[key]=nextValue}})
                    if ok then button.Text=key..": "..tostring(nextValue) end
                    status.Text=ok and "Updated "..key or tostring(err)
                end)
            elseif section=="Writers" then
                local choices=key=="GelatekTorso" and {"Gelatek Physics"}
                    or {"CurrentAngle6D", "WeldConstraint CFrame0"}
                local button=row("TextButton",key..": "..tostring(value))
                button.Activated:Connect(function()
                    local index=table.find(choices,api:GetSettings().Writers[key]) or 1
                    local nextValue=choices[index % #choices + 1]
                    local ok,err=pcall(api.Configure,api,{Writers={[key]=nextValue}})
                    if ok then button.Text=key..": "..nextValue end
                    status.Text=ok and "Updated "..key or tostring(err)
                end)
            elseif type(value)=="number" or type(value)=="string" then
                row("TextLabel",key)
                local input=row("TextBox",tostring(value))
                input.ClearTextOnFocus=false
                input.FocusLost:Connect(function()
                    local update=type(value)=="number" and tonumber(input.Text) or input.Text
                    if update==nil then status.Text="Invalid number"; return end
                    local ok,err=pcall(api.Configure,api,{[section]={[key]=update}})
                    status.Text=ok and "Updated "..key or tostring(err)
                    input.Text=tostring(api:GetSettings()[section][key])
                end)
            end
        end
    end
    action("Close settings",function() gui:Destroy() end)
    return gui
end

end
local Fork = require("init")
local env = (getgenv and getgenv()) or shared or _G
local controller = env.GelatekReanimateFork
if not controller or not (controller:GetState().Running or controller:GetState().Starting) then
    controller = Fork.new(Fork.FromLegacy(env.GelatekReanimateConfig or {}))
    controller:Start()
end
local rig, reason = controller:WaitForReady(60)
if not rig then controller:Stop(); error(reason) end
if env.GelatekForkShowUI then controller:CreateUI() end
return controller
