extends Node

## AUTOLOAD. The wallet and the wardrobe: coins carry between matches, so this is
## the only thing in the game that touches disk. Kept deliberately small and
## forgiving -- a corrupt or missing save just starts you at zero rather than
## erroring, because losing a save should never stop a kid playing.

const SAVE_PATH := "user://bellasgame.save"

const PAYOUT_PER_KO := 10
const PAYOUT_WIN := 150
const PAYOUT_TOP_TEN := 40
const PAYOUT_SURVIVAL := 1        # per squishy you outlasted

## Species and colours 0-2 are free so a new player has choices immediately;
## the rest are what coins are for.
const FREE_SPECIES := 3
const FREE_COLORS := 3
const SPECIES_COST := 250
const COLOR_COST := 150

## Mild by design: the answer to "can I buy a win?" has to stay no.
const PERKS := [
	{
		"id": "sturdy", "name": "Extra Padding", "cost": 400,
		"blurb": "+20 health. Soak one more bonk.",
	},
	{
		"id": "sharp", "name": "Better Bonker", "cost": 500,
		"blurb": "Land holding the Lollipop Hammer instead of the foam one.",
	},
	{
		"id": "whirl", "name": "Bigger Propeller", "cost": 350,
		"blurb": "Half again as much hover time from a spinny hat.",
	},
]

signal coins_changed
signal loadout_changed

var coins: int = 0
var unlocked_species: Array = []      # indices beyond the free ones
var unlocked_colors: Array = []
var owned_perks: Array = []
var chosen_species: int = 0
var chosen_color: int = 0


func _ready() -> void:
	load_game()


func has_species(index: int) -> bool:
	return index < FREE_SPECIES or unlocked_species.has(index)


func has_color(index: int) -> bool:
	return index < FREE_COLORS or unlocked_colors.has(index)


func has_perk(id: String) -> bool:
	return owned_perks.has(id)


func perk_by_id(id: String) -> Dictionary:
	for p in PERKS:
		if p.id == id:
			return p
	return {}


func add_coins(amount: int) -> void:
	coins = maxi(0, coins + amount)
	coins_changed.emit()
	save_game()


## Every purchase funnels through here so there is exactly one place that can
## take coins off you, and it always checks you had them first.
func buy(kind: String, key) -> bool:
	var cost := 0
	match kind:
		"species":
			if has_species(int(key)):
				return false
			cost = SPECIES_COST
		"color":
			if has_color(int(key)):
				return false
			cost = COLOR_COST
		"perk":
			if has_perk(str(key)):
				return false
			var perk := perk_by_id(str(key))
			if perk.is_empty():
				return false
			cost = int(perk.cost)
		_:
			return false

	if coins < cost:
		return false
	coins -= cost

	match kind:
		"species":
			unlocked_species.append(int(key))
		"color":
			unlocked_colors.append(int(key))
		"perk":
			owned_perks.append(str(key))

	coins_changed.emit()
	loadout_changed.emit()
	save_game()
	return true


func choose_species(index: int) -> void:
	if not has_species(index):
		return
	chosen_species = index
	loadout_changed.emit()
	save_game()


func choose_color(index: int) -> void:
	if not has_color(index):
		return
	chosen_color = index
	loadout_changed.emit()
	save_game()


## What one match was worth. Placement pays more than kills on purpose: hiding in
## a bush until second place is a completely legitimate way to play.
func payout_for(kos: int, placement: int, total: int) -> int:
	var reward := kos * PAYOUT_PER_KO
	reward += maxi(0, total - placement) * PAYOUT_SURVIVAL
	if placement == 1:
		reward += PAYOUT_WIN
	elif placement <= 10:
		reward += PAYOUT_TOP_TEN
	return reward


func save_game() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"coins": coins,
		"species": unlocked_species,
		"colors": unlocked_colors,
		"perks": owned_perks,
		"chosen_species": chosen_species,
		"chosen_color": chosen_color,
	}))
	file.close()


func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	coins = int(parsed.get("coins", 0))
	unlocked_species = parsed.get("species", [])
	unlocked_colors = parsed.get("colors", [])
	owned_perks = parsed.get("perks", [])
	chosen_species = int(parsed.get("chosen_species", 0))
	chosen_color = int(parsed.get("chosen_color", 0))
	# A save edited by hand (or by an older build) must never leave you wearing
	# something you cannot select in the shop.
	if not has_species(chosen_species):
		chosen_species = 0
	if not has_color(chosen_color):
		chosen_color = 0
