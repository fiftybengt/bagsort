
                                  
                                  
                                  
bag sorting addon for 3.3.5 (build 12340)

Interface: 30300
Title: BagSorter
otes: Sorts your bags by item type, quality, and name using sequential item swaps
Version: 1.0
OptionalDeps: !!!ClassicAPI

-------------------------------------------------------------------------------
BagSorter.lua  v1.0
World of Warcraft – Wrath of the Lich King 3.3.5 (build 12340)

Sorts all bag contents by: item type → quality (desc) → equip slot →
ub-type → name.  Empty slots are pushed to the end.

Technique: selection-sort simulation produces a minimal list of (posA, posB)
swaps, then each physical swap is executed via PickupContainerItem with a
small timer delay between operations so the client can keep up.

Commands:
   /bagsort          – sort all bags
   /bagsort cancel   – cancel an in-progress sort
   /bagsort help     – show help
   /bsort            – shortcut for /bagsort
