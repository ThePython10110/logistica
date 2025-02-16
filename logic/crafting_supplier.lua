local INV_MAIN = "main"
local INV_CRAFT = "crf"
local INV_HOUT = "hout"

local function count_items_to_stack(list)
	local map = {}
	for _, stack in ipairs(list) do
		if not stack:is_empty() then
			local stName = stack:get_name()
      if not map[stName] then map[stName] = 0 end
			map[stName] = map[stName] + stack:get_count()
		end
	end
  local items = {}
  local i = 0
	for name, count in pairs(map) do
    i = i + 1
    local item = ItemStack(name) ; item:set_count(count)
    items[i] = item
  end
  return items
end

local function consume_from_network(craftItems, times, network, depth)
  if times <= 0 then return end
  local acceptItem = function (_) return 0 end
  for _, itemStack in ipairs(craftItems) do
    local consumeStack = ItemStack(itemStack) ; consumeStack:set_count(itemStack:get_count() * times)
    logistica.take_stack_from_network(consumeStack, network, acceptItem, true, false, false, depth + 1)
  end
end

-- returns 0 if craftItems could not be taken from network, returns 1 if they could
local function consume_for_craft(craftItems, craftItemsMult, network, depth, dryRun)
  local itemTaken = ItemStack("")
  local acceptItem = function(st) itemTaken:add_item(st) ; return 0 end
  for _, _itemStack in ipairs(craftItems) do
    itemTaken:clear()
    local itemStack = ItemStack(_itemStack)
    if dryRun then
      -- when doing a dryRun the actual items are not removed from the network, so we need to make sure
      -- we have enough in the network by accounting for how many have been "crafted" so far
      itemStack:set_count(itemStack:get_count() * craftItemsMult)
    end
    logistica.take_stack_from_network(itemStack, network, acceptItem, true, false, true, depth + 1)
    if itemTaken:get_count() < itemStack:get_count() then
      return 0
    end
  end
  if not dryRun then
    consume_from_network(craftItems, 1, network, depth)
  end
  return 1
end

function logistica.take_item_from_crafting_supplier(pos, _takeStack, network, collectorFunc, useMetadata, dryRun, _depth)
  local depth = _depth or 0
  local takeStack = ItemStack(_takeStack)
  local remaining = takeStack:get_count()
  local takeStackName = takeStack:get_name()
  local inv = minetest.get_meta(pos):get_inventory()

  -- first check existing supply, ignore the 1st slot (which is for the crafted item)
  remaining = logistica.take_item_from_supplier(pos, takeStack, network, collectorFunc, useMetadata, dryRun, 1)
  if remaining <= 0 then return 0 end -- we're done

  -- only craft if machine is on
  if not logistica.is_machine_on(pos) then return _takeStack:get_count() end

  -- if we still have a number of requested itsm to fulfil, try crafting them
  takeStack:set_count(remaining)
  local craftStack = inv:get_stack(INV_MAIN, 1)

  -- if names are different, we can't craft this request
  if inv:is_empty(INV_CRAFT) or  craftStack:get_name() ~= takeStack:get_name() then
    return remaining
  end

  inv:set_list(INV_HOUT, {})
  local numCrafted = 0
  local isEnough = false

  local craftItemMult = 0
  repeat
    logistica.autocrafting_produce_single_item(inv, INV_CRAFT, nil, INV_HOUT)
    craftItemMult = craftItemMult + 1
    -- if we can craft from network
    local items = count_items_to_stack(inv:get_list(INV_CRAFT))
    local numCanCraft = consume_for_craft(items, craftItemMult, network, depth, dryRun)
    numCrafted = numCrafted + numCanCraft

    isEnough = inv:contains_item(INV_HOUT, takeStack) or numCanCraft == 0 or numCrafted >= 99
  until (isEnough)

  if numCrafted == 0 then return remaining end -- nothing could be crafted
  remaining = math.max(0, remaining - numCrafted)

  -- give the item to the collector
  local taken = inv:remove_item(INV_HOUT, takeStack)
  local leftover = collectorFunc(taken)

  -- now move any extras from the hidden to the main inventory - deleting extras (TODO: maybe drop them)
  if not dryRun then
    local extraNotTaken = 0
    local toInsert = {}
    for _, st in ipairs(inv:get_list(INV_HOUT)) do
      if st:get_name() == takeStackName then
        extraNotTaken = extraNotTaken + st:get_count()
      else
        table.insert(toInsert, st)
      end
    end
    taken:set_count(leftover + extraNotTaken)

    if not taken:is_empty() then
      local main = inv:get_list(INV_MAIN) or {}
      for i = 2, #main do
        taken = main[i]:add_item(taken)
      end
      inv:set_list(INV_MAIN, main)
    end

    for _, insertStack in ipairs(toInsert) do
      inv:add_item(INV_MAIN, insertStack)
    end
    logistica.update_cache_at_pos(pos, LOG_CACHE_SUPPLIER, network)
  end

  return remaining
end
