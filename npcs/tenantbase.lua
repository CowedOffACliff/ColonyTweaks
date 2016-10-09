require "/scripts/behavior.lua"
require "/scripts/pathing.lua"
require "/scripts/util.lua"
require "/scripts/vec2.lua"
require "/scripts/quest/participant.lua"
require "/scripts/relationships.lua"
require "/scripts/actions/dialog.lua"
require "/scripts/drops.lua"
require "/scripts/statusText.lua"
require "/scripts/tenant.lua"
require "/scripts/companions/recruitable.lua"


-- Engine callback - called on initialization of entity
function init()
  restorePreservedStorage()

  if storage.tenantRep == nil then
    storage.tenantRep = clampRep(0)
  end
  self.repTickdown = 5400 -- 1:30 seconds @ 60 updates per second
  self.repTick = 0
  
  self.shouldDie = true
  self.forceDie = false
  self.pathing = {}

  self.notifications = {}
  if storage.spawnPosition == nil then
    local position = mcontroller.position()
    local groundPosition = findGroundPosition(position, -20, 3)
    storage.spawnPosition = groundPosition or position
  end
  BData:setPosition("spawn", storage.spawnPosition)

  local questOutbox = Outbox.new("questOutbox", ContactList.new("questContacts"))
  self.quest = QuestParticipant.new("quest", questOutbox)
  self.quest.onOfferedQuestStarted = offeredQuestStarted
  self.quest.onOfferedQuestFinished = offeredQuestFinished

  if config.getParameter("behavior") then
    self.behavior = BTree:new(config.getParameter("behavior"), config.getParameter("behaviorConfig", {}))
    self.behavior.topLevel = true
  end

  npc.setInteractive(true)
  script.setUpdateDelta(1)

  self.behaviorConfig = config.getParameter("behaviorConfig", {})
  if personality().behaviorConfig then
    self.behaviorConfig = parseArgs(personality().behaviorConfig, self.behaviorConfig)
  end

  self.primary = npc.getItemSlot("primary")
  self.alt = npc.getItemSlot("alt")
  self.sheathedPrimary = npc.getItemSlot("sheathedprimary")
  self.sheathedAlt = npc.getItemSlot("sheathedalt")
  self.delayedSetItemSlot = {}

  self.debug = false

  mcontroller.setAutoClearControls(false)
  self.behaviorTickRate = 10
  self.behaviorTick = math.random(1, self.behaviorTickRate)

  self.stuckCheckTime = config.getParameter("stuckCheckTime", 3.0)
  self.stuckCheckTimer = 0.1

  message.setHandler("notify", function (_, _, notification)
      return notify(notification)
    end)

  message.setHandler("suicide", function ()
      status.setResource("health", 0)
    end)

  self.uniqueId = config.getParameter("uniqueId")
  updateUniqueId()

  npc.setDamageOnTouch(true)
  npc.setAggressive(config.getParameter("aggressive", false))

  if (config.getParameter("facingDirection")) then
    mcontroller.controlFace(config.getParameter("facingDirection"))
  end

  recruitable.init()
end

function clampRep(n) 
  return math.min(math.max(-100, n), 100) 
end

function setRepBonus(n)
  
  if self.behavior.name == "merchanttenant" then
    n = n * 0.75
  end
  if self.behavior.name == "guard" then
    n = n * 0.75
  end

  if self.behavior.name == "merchant" then
    n = n * 1.25
  end

  storage.tenantRep = storage.tenantRep + n

  storage.tenantRep = math.floor(storage.tenantRep + 0.5)
  storage.tenantRep = clampRep(storage.tenantRep)
end

function getRepBonus()
  n = storage.tenantRep
  storage.tenantRep = 0
  return n
end

-- The colony and crew systems repeatedly kill and respawn the same NPCs.
-- Certain things about them that change during their lifetime (item slots,
-- etc.) need to be preserved between spawns.
function restorePreservedStorage()
  for k, v in pairs(config.getParameter("initialStorage", {})) do
    if storage[k] == nil then
      storage[k] = v
    end
  end
  for slot, item in pairs(storage.itemSlots or {}) do
    npc.setItemSlot(slot, item)
  end
end

function preservedStorage()
  return {
      itemSlots = storage.itemSlots,
      relationships = storage.relationships,
      criminal = storage.criminal,
      stolen = storage.stolen,
      extraMerchantItems = storage.extraMerchantItems
    }
end

function updateUniqueId()
  if self.uniqueId and not entity.uniqueId() then
    npc.setUniqueId(self.uniqueId)
  end
end

-- Engine callback - called on each update
-- Update frequencey is dependent on update delta
function update(dt)
  self.stuckCheckTimer = math.max(0, self.stuckCheckTimer - dt)
  if self.stuckCheckTimer == 0 then
    checkStuck()
    self.stuckCheckTimer = self.stuckCheckTime
  end

  updateUniqueId()

  self.quest:update()

  recruitable.update(dt)

  for _,slot in pairs(self.delayedSetItemSlot) do
    setNpcItemSlot(slot.slotName, slot.item)
  end
  self.delayedSetItemSlot = {}

  if status.resourcePositive("stunned") then
    mcontroller.clearControls()
    self.stunned = true
    if self.primary and root.itemHasTag(self.primary.name, "ranged") then
      npc.endPrimaryFire()
    end
    return
  end

  if self.behaviorTick >= self.behaviorTickRate then
    self.behaviorTick = self.behaviorTick - self.behaviorTickRate
    mcontroller.clearControls()

    self.tradingEnabled = false
    self.setFacingDirection = false
    self.primaryFire = false
    self.altFire = false

    BData:setEntity("self", entity.id())
    BData:setPosition("self", mcontroller.position())
    BData:setNumber("facingDirection", mcontroller.facingDirection())

    if self.behavior then
      self.behavior:run(dt * self.behaviorTickRate)
    end
    BGroup:updateGroups()

    if self.primaryFire then
      npc.beginPrimaryFire()
    else
      npc.endPrimaryFire()
    end
    if self.altFire then
      npc.beginAltFire()
    else
      npc.endAltFire()
    end

    self.interacted = false
    self.damaged = false
    self.stunned = false
    if self.notifications[1] and self.notifications[1].type ~= "chatrequest" then
      sb.logInfo("ID: " .. sb.print(entity.uniqueId) .. " Type: " .. sb.print(npc.npcType()) .. " Notifications: " .. sb.print(self.notifications[1].type) .. " " .. sb.print(self.notifications[1].sourceId))
    end
    
    if self.notifications[1] and self.notifications[1].type == "monsterdeath" then
      setRepBonus(2)
    end
    
    self.notifications = {}
  end
  self.behaviorTick = self.behaviorTick + 1

  if self.repTick >= self.repTickdown then
    if storage.tenantRep <= 0 then 
      storage.tenantRep = storage.tenantRep + 1
    else
        storage.tenantRep = storage.tenantRep - 1
    end
    
    --sb.logInfo("Rep Changed :" .. "( ID: " .. sb.print(entity.uniqueId) .. " Type: " .. sb.print(npc.npcType()) .. ")")
    self.repTick = 0
  end
  self.repTick = self.repTick + 1

  runWorkers()

  self.die = (self.shouldDie and not status.resourcePositive("health")) or self.forceDie
end

-- Engine callback - called on interact
function interact(args)
  local recruitAction = recruitable.interact(args.sourceId)
  if recruitAction then
    return recruitAction
  end

  setInteracted(args)
  if self.tradingConfig ~= nil and self.tradingEnabled then
    setRepBonus(1)
    return { "OpenMerchantInterface", self.tradingConfig }
  end

  local interactAction = config.getParameter("interactAction")
  if interactAction then
    local data = config.getParameter("interactData", {})
    if type(data) == "string" then
      data = root.assetJson(data)
    end
    setRepBonus(1)
    return { interactAction, data }
  end
end

function setInteracted(args)
  self.quest:fireEvent("interaction", args.sourceId)
  self.interacted = true
  BData:setEntity("interactionSource", args.sourceId)
end

-- Engine callback - called on taking damage
function damage(args)
  self.damaged = true
  BData:setEntity("damageSource", args.sourceId)
  sb.logInfo("Entity Damaged: " .. sb.print(npc.npcType()) .. " : " .. sb.print(args))
  setRepBonus(-2)
end

function shouldDie()
  return self.die
end

function die()
  self.quest:die()
  recruitable.die()
  tenant.backup()
  spawnDrops()
end

function uninit()
  self.quest:uninit()
  BGroup:uninit()
end

function offeredQuestStarted(questArc)
  setRepBonus(10)

  if entity.damageTeam().type ~= "assistant" then
    storage.preQuestDamageTeam = entity.damageTeam()
    npc.setDamageTeam({
        type = "assistant",
        team = 1 -- Friendly NPCs always on team 1
      })
  end
end

function offeredQuestFinished(questArc, complete)
  setRepBonus(20)
  
  if storage.preQuestDamageTeam then
    npc.setDamageTeam(storage.preQuestDamageTeam)
    storage.preQuestDamageTeam = nil
  end
end

-- Personality and reactions
function personality()
  if not storage.personality then
    storage.personality = generatePersonality()
  end
  return storage.personality
end

function setPersonality(personality)
  storage.personality = personality
end

function personalityType()
  return personality().personality
end

function generatePersonality()
  return util.weightedRandom(config.getParameter("personalities"), npc.seed())
end

function participateInNewQuests()
  local enabled = config.getParameter("questGenerator.enableParticipation")
  return enabled and not self.quest:isQuestGiver()
end

function getHeldItems()
  local result = {}
  -- table.insert has no effect on the table when given a nil
  table.insert(result, self.primary)
  table.insert(result, self.sheathedPrimary)
  table.insert(result, self.alt)
  table.insert(result, self.sheathedAlt)
  return result
end

function setNpcItemSlot(slotName, item)
  npc.setItemSlot(slotName, item)
  storage.itemSlots = storage.itemSlots or {}
  storage.itemSlots[string.lower(slotName)] = item

  self.primary = npc.getItemSlot("primary")
  self.alt = npc.getItemSlot("alt")
  self.sheathedPrimary = npc.getItemSlot("sheathedprimary")
  self.sheathedAlt = npc.getItemSlot("sheathedalt")
end

function setItemSlotDelayed(slotName, item)
  table.insert(self.delayedSetItemSlot, {
      slotName = slotName,
      item = item
    })
end

function checkStuck()
  if mcontroller.isCollisionStuck() and not npc.isLounging() then
    -- sloppy catch-all correction for various cases of getting stuck in things
    -- due to bad spawn position, failure to exit loungeable (on ships), etc.
    local poly = mcontroller.collisionPoly()
    local pos = mcontroller.position()
    for maxDist = 2, 4 do
      local resolvePos = world.resolvePolyCollision(poly, pos, maxDist)
      if resolvePos then
        mcontroller.setPosition(resolvePos)
        break
      end
    end
  end
end
