```
██████╗  █████╗  ██████╗ ███████╗ ██████╗ ██████╗ ████████╗███████╗██████╗
██╔══██╗██╔══██╗██╔════╝ ██╔════╝██╔═══██╗██╔══██╗╚══██╔══╝██╔════╝██╔══██╗
██████╔╝███████║██║  ███╗███████╗██║   ██║██████╔╝   ██║   █████╗  ██████╔╝
██╔══██╗██╔══██║██║   ██║╚════██║██║   ██║██╔══██╗   ██║   ██╔══╝  ██╔══██╗
██████╔╝██║  ██║╚██████╔╝███████║╚██████╔╝██║  ██║   ██║   ███████╗██║  ██║
╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝
```
> *Bag sorting addon for World of Warcraft **3.3.5** (build 12340)*

---

## Overview

**BagSorter** automatically organizes all your bag contents using a smart, multi-pass sorting algorithm so you spend less time managing inventory and more time playing.

Items are sorted in the following priority order:

| Priority | Criteria |
|----------|----------|
| 1st | Item Type |
| 2nd | Quality *(descending — best first)* |
| 3rd | Equip Slot |
| 4th | Sub-type |
| 5th | Name |

> Empty slots are always pushed to the **end** of your bags.

---

## Dependencies

| Dependency | Required |
|------------|----------|
| `!!!ClassicAPI` | Optional |

---

## Commands

| Command | Description |
|---------|-------------|
| `/bagsort` | Sort all bags |
| `/bagsort cancel` | Cancel an in-progress sort |
| `/bagsort help` | Show in-game help |
| `/bsort` | Shortcut for `/bagsort` |

---

## Installation

1. Download the addon folder
2. Place it inside your `Interface/AddOns/` directory
3. Restart the game
4. Confirm it appears in your **AddOns** list at the character select screen

---

*Compatible with WoW **3.3.5** (build 12340) — Wrath of the Lich King*
