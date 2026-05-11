-------------------------------------------------------------------------------
-- BagSorter.lua  v1.0
-- World of Warcraft – Wrath of the Lich King 3.3.5 (build 12340)
--
-- Sorts all bag contents by: item type → quality (desc) → equip slot →
-- sub-type → name.  Empty slots are pushed to the end.
--
-- Technique: selection-sort simulation produces a minimal list of (posA, posB)
-- swaps, then each physical swap is executed via PickupContainerItem with a
-- small timer delay between operations so the client can keep up.
--
-- Commands:
--   /bagsort          – sort all bags
--   /bagsort cancel   – cancel an in-progress sort
--   /bagsort help     – show help
--   /bsort            – shortcut for /bagsort
-------------------------------------------------------------------------------

local VERSION      = "1.1"
local SWAP_DELAY   = 0.05   -- seconds between successive swap operations
local MAX_RETRY    = 5      -- how many times to retry while waiting for item cache
local PASS_DELAY   = 0.4    -- seconds to wait between auto-iteration passes
local MAX_PASSES   = 15     -- safety cap on auto-iteration passes

-------------------------------------------------------------------------------
-- Sort-priority tables
-------------------------------------------------------------------------------

-- Lower number = appears earlier (closer to start of bag)
local TYPE_ORDER = {
    ["Weapon"]        = 1,
    ["Armor"]         = 2,
    ["Gem"]           = 3,
    ["Consumable"]    = 4,
    ["Reagent"]       = 5,
    ["Trade Goods"]   = 6,
    ["Recipe"]        = 7,
    ["Key"]           = 8,
    ["Projectile"]    = 9,
    ["Quest"]         = 10,
    ["Miscellaneous"] = 11,
    ["Container"]     = 12,
    ["Junk"]          = 13,
}

-- Equipment slot order used as a secondary key for Weapon/Armor items
local EQUIP_ORDER = {
    ["INVTYPE_HEAD"]      = 1,
    ["INVTYPE_NECK"]      = 2,
    ["INVTYPE_SHOULDER"]  = 3,
    ["INVTYPE_CLOAK"]     = 4,
    ["INVTYPE_CHEST"]     = 5,
    ["INVTYPE_ROBE"]      = 5,
    ["INVTYPE_BODY"]      = 6,   -- shirt
    ["INVTYPE_TABARD"]    = 7,
    ["INVTYPE_WRIST"]     = 8,
    ["INVTYPE_HAND"]      = 9,
    ["INVTYPE_WAIST"]     = 10,
    ["INVTYPE_LEGS"]      = 11,
    ["INVTYPE_FEET"]      = 12,
    ["INVTYPE_FINGER"]    = 13,
    ["INVTYPE_TRINKET"]   = 14,
    ["INVTYPE_WEAPON"]    = 15,
    ["INVTYPE_SHIELD"]    = 16,
    ["INVTYPE_2HWEAPON"]  = 17,
    ["INVTYPE_RANGED"]    = 18,
    ["INVTYPE_THROWN"]    = 19,
    ["INVTYPE_HOLDABLE"]  = 20,
    ["INVTYPE_BAG"]       = 21,
    ["INVTYPE_QUIVER"]    = 22,
    ["INVTYPE_RELIC"]     = 23,
    ["INVTYPE_NON_EQUIP"] = 50,
    [""]                  = 50,
}

-------------------------------------------------------------------------------
-- Comparison helpers
-------------------------------------------------------------------------------

-- Returns five comparison values for an item data table (or nil for empty slot).
local function GetSortKey(item)
    if not item then
        -- Empty slots always go to the very end
        return 999, 0, 999, "", ""
    end
    local typeOrd  = TYPE_ORDER[item.type] or 50
    -- Invert quality so higher quality (4=Epic) sorts before lower (1=Common)
    local qualOrd  = 8 - (item.quality or 1)
    local equipOrd = EQUIP_ORDER[item.equipSlot] or 50
    return typeOrd, qualOrd, equipOrd, (item.subType or ""), (item.name or "")
end

-- Returns true if item 'a' should appear before item 'b' in the sorted bag.
local function ItemSortsBefore(a, b)
    local aT, aQ, aE, aST, aN = GetSortKey(a)
    local bT, bQ, bE, bST, bN = GetSortKey(b)
    if aT ~= bT   then return aT  < bT  end
    if aQ ~= bQ   then return aQ  < bQ  end
    if aE ~= bE   then return aE  < bE  end
    if aST ~= bST then return aST < bST end
    return aN < bN
end

-------------------------------------------------------------------------------
-- Bag scanning
-------------------------------------------------------------------------------

-- Returns an ordered list of all {bag, slot} positions across bags 0–4.
local function GetAllBagSlots()
    local slots = {}
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            table.insert(slots, { bag = bag, slot = slot })
        end
    end
    return slots
end

-- Reads item data from a single bag slot.
-- Returns:
--   nil   – slot is empty
--   false – slot is locked (item being traded / in loot window)
--   table – item data { link, count, quality, type, subType, equipSlot,
--                       iLevel, name, cached }
local function ReadSlot(bag, slot)
    local _, count, locked, quality, _, _, itemLink = GetContainerItemInfo(bag, slot)

    if not itemLink then return nil   end  -- empty
    if locked        then return false end  -- locked; abort sort

    local name, _, q, iLevel, _, itemType, subType, _, equipSlot = GetItemInfo(itemLink)
    return {
        link      = itemLink,
        count     = count     or 1,
        quality   = q         or quality or 1,
        type      = itemType  or "Miscellaneous",
        subType   = subType   or "",
        equipSlot = equipSlot or "",
        iLevel    = iLevel    or 0,
        -- Fall back to the item link if the name is not yet in the cache
        name      = name      or itemLink,
        cached    = (name ~= nil),
    }
end

-------------------------------------------------------------------------------
-- Physical swap execution
--
-- A bag-slot swap requires the following sequence because WoW has no direct
-- "swap slot A with slot B" API:
--
--   PickupContainerItem(b1, s1)  → item A goes to cursor; slot1 is now empty
--   PickupContainerItem(b2, s2)  → item A lands in slot2; item B (if any)
--                                   goes to cursor
--   PickupContainerItem(b1, s1)  → item B lands in slot1; cursor is clear
--
-- All three calls happen within a single script execution frame, so the
-- client processes them atomically before the next C_Timer tick.
-------------------------------------------------------------------------------
local function ExecuteSwap(pos1, pos2)
    local b1, s1 = pos1.bag, pos1.slot
    local b2, s2 = pos2.bag, pos2.slot

    local _, _, _, _, _, _, link1 = GetContainerItemInfo(b1, s1)
    local _, _, _, _, _, _, link2 = GetContainerItemInfo(b2, s2)

    if link1 and link2 then
        -- Both slots filled: 3-step swap
        PickupContainerItem(b1, s1)  -- A → cursor,  slot1 empty
        PickupContainerItem(b2, s2)  -- A → slot2,   B → cursor
        PickupContainerItem(b1, s1)  -- B → slot1,   cursor clear
    elseif link1 then
        -- Only pos1 has an item: move it into empty pos2
        PickupContainerItem(b1, s1)
        PickupContainerItem(b2, s2)
    elseif link2 then
        -- Only pos2 has an item: move it into empty pos1
        PickupContainerItem(b2, s2)
        PickupContainerItem(b1, s1)
    end
    -- Both empty: nothing to do (shouldn't happen after selection sort pruning)
end

-------------------------------------------------------------------------------
-- State flags
-------------------------------------------------------------------------------
local isSorting    = false  -- true while swap queue is being executed
local isPending    = false  -- true while waiting for a cache-retry timer
-- Incremented on every cancel so that stale C_Timer callbacks become no-ops
local sortGen      = 0
-- Current auto-iteration pass number (reset to 0 on each user-initiated sort)
local sortPass     = 0

-------------------------------------------------------------------------------
-- Core sort routine
--   retries:     number of times we have already retried due to uncached items
--   autoIterate: true when called automatically between passes (not by user)
-------------------------------------------------------------------------------
local function DoSort(retries, autoIterate)
    -- Reset pass counter on a fresh user-initiated sort
    if not autoIterate then
        sortPass = 0
    end

    -- Safety cap: stop after MAX_PASSES auto-iterations
    sortPass = sortPass + 1
    if sortPass > MAX_PASSES then
        isSorting = false
        print("|cffff6600[BagSorter]|r Sort stopped after " .. MAX_PASSES ..
              " passes. Your bags may not be fully sorted (unusual item layout?).")
        return
    end

    -- Guard: only one sort at a time
    if isSorting or isPending then
        print("|cffff6600[BagSorter]|r A sort is already in progress. " ..
              "Type /bagsort cancel to stop it.")
        return
    end
    if InCombatLockdown() then
        print("|cffff6600[BagSorter]|r Cannot sort bags while in combat.")
        return
    end
    if CursorHasItem() then
        print("|cffff6600[BagSorter]|r Please clear your cursor before sorting.")
        return
    end

    -- ── 1. Scan all bag slots ────────────────────────────────────────────────
    local allSlots = GetAllBagSlots()
    local n        = #allSlots
    local contents = {}

    for i, pos in ipairs(allSlots) do
        local data = ReadSlot(pos.bag, pos.slot)
        if data == false then
            print("|cffff6600[BagSorter]|r A bag item is locked. " ..
                  "Please wait and try again.")
            return
        end
        contents[i] = data  -- nil if empty, table if item present
    end

    -- ── 2. Handle uncached item data ─────────────────────────────────────────
    local uncached = 0
    for i = 1, n do
        if contents[i] and not contents[i].cached then
            uncached = uncached + 1
        end
    end

    if uncached > 0 then
        if retries >= MAX_RETRY then
            -- Give up waiting and sort with link strings as fallback names
            print(string.format(
                "|cffff6600[BagSorter]|r %d item(s) could not be loaded from cache. " ..
                "Sorting with partial data.", uncached))
        else
            print(string.format(
                "|cff88ff88[BagSorter]|r Waiting for %d item(s) to load... " ..
                "(attempt %d/%d)", uncached, retries + 1, MAX_RETRY))
            isPending = true
            local myGen = sortGen  -- capture current generation
            C_Timer.After(1.0, function()
                if sortGen ~= myGen then return end  -- cancelled while waiting
                isPending = false
                DoSort(retries + 1, autoIterate)
            end)
            return
        end
    end

    -- ── 3. Build swap list via selection sort simulation ────────────────────
    --
    -- We simulate the bag state in `working[]`.  For each position i we find
    -- the item with the best sort key among positions i..n, then record the
    -- swap and update `working[]` to reflect the new state.  The resulting
    -- swap list, when executed in order, produces a fully sorted bag.
    --
    -- Selection sort is ideal here because it generates at most (n-1) swaps —
    -- the theoretical minimum for a comparison-based sort with swaps.
    local working = {}
    for i = 1, n do working[i] = contents[i] end

    local swaps = {}
    for i = 1, n do
        local bestJ = i
        for j = i + 1, n do
            if ItemSortsBefore(working[j], working[bestJ]) then
                bestJ = j
            end
        end
        if bestJ ~= i then
            table.insert(swaps, { allSlots[i], allSlots[bestJ] })
            working[i], working[bestJ] = working[bestJ], working[i]
        end
    end

    if #swaps == 0 then
        -- No more work to do on this pass — bags are fully sorted
        print("|cff88ff88[BagSorter]|r Done! Bags are fully sorted.")
        return
    end

    if sortPass == 1 then
        print(string.format("|cff88ff88[BagSorter]|r Sorting... (%d swap(s))", #swaps))
    else
        print(string.format("|cff88ff88[BagSorter]|r Pass %d... (%d swap(s))", sortPass, #swaps))
    end
    isSorting = true

    -- ── 4. Execute swaps sequentially, one per timer tick ───────────────────
    local idx = 1
    local myGen = sortGen
    local function DoNext()
        if not isSorting then return end  -- cancelled by user
        if sortGen ~= myGen then return end  -- cancelled via generation

        -- A prior swap left an item on the cursor (simulated vs actual state
        -- divergence). Clear it and let the next auto-iteration pass re-sort.
        if CursorHasItem() then
            ClearCursor()
            isSorting = false
            C_Timer.After(PASS_DELAY, function()
                if sortGen ~= myGen then return end
                DoSort(0, true)
            end)
            return
        end

        if idx > #swaps then
            -- This pass is done; wait for items to settle then run another pass
            isSorting = false
            C_Timer.After(PASS_DELAY, function()
                if sortGen ~= myGen then return end
                DoSort(0, true)
            end)
            return
        end

        local swap = swaps[idx]
        ExecuteSwap(swap[1], swap[2])
        idx = idx + 1

        C_Timer.After(SWAP_DELAY, DoNext)
    end

    DoNext()  -- kick off the first swap immediately
end

-------------------------------------------------------------------------------
-- Public API table
-------------------------------------------------------------------------------
local BagSorter = {}

function BagSorter:Sort()
    DoSort(0)
end

function BagSorter:Cancel()
    if isSorting or isPending then
        isSorting = false
        isPending = false
        sortGen   = sortGen + 1  -- invalidate any pending C_Timer callbacks
        ClearCursor()
        print("|cffff6600[BagSorter]|r Sort cancelled.")
    else
        print("|cff88ff88[BagSorter]|r No sort currently in progress.")
    end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_BAGSORT1 = "/bagsort"
SLASH_BAGSORT2 = "/bsort"

SlashCmdList["BAGSORT"] = function(msg)
    local cmd = strtrim(msg or ""):lower()

    if cmd == "" or cmd == "sort" then
        BagSorter:Sort()
    elseif cmd == "cancel" then
        BagSorter:Cancel()
    elseif cmd == "help" then
        print("|cff88ff88[BagSorter]|r v" .. VERSION .. " – Commands:")
        print("  /bagsort           Sort all bags by type, quality and name")
        print("  /bagsort cancel    Stop an in-progress sort")
        print("  /bagsort help      Show this message")
        print("  /bsort             Shortcut for /bagsort")
        print("Sort order: Weapons → Armor → Gems → Consumables → Reagents →")
        print("  Trade Goods → Recipes → Keys → Projectiles → Quest →")
        print("  Misc → Containers → Junk → Empty slots")
        print("Within each category: quality (high→low) → equip slot → name")
    else
        print("|cffff6600[BagSorter]|r Unknown command '" .. cmd ..
              "'. Type /bagsort help for help.")
    end
end

-------------------------------------------------------------------------------
-- Addon load notification
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        print("|cff88ff88[BagSorter]|r v" .. VERSION ..
              " loaded. Type /bagsort to sort your bags.")
    end
end)
