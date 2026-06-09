local M = {}

M.game_name = "mhwilds"

M.extensions = {
	scn = ".21",
	pfb = ".18",
	user = ".3",
	mdf2 = ".45",
	mesh = ".241111606",
	tex = ".241106027",
	motbank = ".4",
	motlist = ".992",
	mot = ".932",
	chain2 = ".13",
	rcol = ".28",
	mcol = ".24022",
	ccbk = ".3",
	clsp = ".3",
	cfil = ".7",
	cdef = ".7",
	def = ".6",
	skeleton = ".7",
	fbxskel = ".7",
}

M.cog_names = {
	"Cog",
	"COG",
	"Hip",
	"Waist_00",
	"root",
	"Root",
}

M.collision_definition = "collision/sagcollision.cdef.3"
M.dynamics_definition = "dynamics/sagdynamics.def.5"

M.ray_layers = {
	0, 1, 3, 4, 5, 6, 8, 9, 10, 13, 14, 15,
	17, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
}

M.resource_roots = {
	character = "art/model/character",
	enemy = "gamedesign/enemy",
	motion = "motion",
	player_motion = "motion/player",
	npc_motion = "motion/npc",
}

return M
