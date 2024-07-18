package main

Debug :: #config(Debug, true)

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
creditsText := #load("./assets/credits.txt", cstring)
howtoText := #load("./assets/howto.txt", cstring)

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

TextureID :: int
texture_cnt: TextureID = 0
textures: [dynamic]rl.Texture2D

add_tex :: proc(path: cstring) -> TextureID {
	id := texture_cnt
	texture_cnt += 1
	inject_at(&textures, id, rl.LoadTexture(path))
	return id
}

get_tex :: proc(id: TextureID) -> rl.Texture2D {
	return textures[id]
}

Animation :: struct {
	tex:           TextureID,
	speed:         f32,
	frame_cnt:     i32,
	timer:         f32,
	current_frame: i32,
}

update_anim :: proc(anim: ^Animation, dt: f32) {
	anim.timer += dt
	if anim.timer > anim.speed {
		anim.current_frame += 1
		anim.timer = 0
		if anim.current_frame >= anim.frame_cnt {anim.current_frame = 0}
	}
}

reset_anim :: proc(anim: ^Animation) {
	anim.current_frame = 0
	anim.timer = 0
}

// :en
EntityProp :: enum {
	nil,
	collidable,
	ridable,
	plat,
}

EntityId :: enum {
	nil,
	chunk,
	dead_zone,
	moving_plat,
	plat,
	jump_coffee,
	check_coffee,
	player,
	trophy,
	// :id
}

Entity :: struct {
	pos:           rl.Vector2,
	vel:           rl.Vector2,
	remainder:     rl.Vector2,
	size:          rl.Vector2,
	aabb:          rl.Rectangle,
	flip:          bool,
	last_collided: ^Entity,
	is_collidable: bool,
	props:         [dynamic]EntityProp,
	grounded:      bool,
	id:            EntityId,
	respawn:       rl.Vector2,
	riding:        ^Entity,
	texId:         TextureID,
	is_valid:      bool,
	played_land:   bool,
	fall_time:     f32,
}

en_setup :: proc(en: ^Entity, x, y, w, h: f32) {
	en.pos = {x, y}
	en.size = {w, h}
	en.aabb = {x, y, w, h}
	en.is_valid = true
	en.played_land = true
}

en_add_props :: proc(en: ^Entity, props: ..EntityProp) {
	for p in props {append(&en.props, p)}
}

en_has_prop :: proc(en: ^Entity, prop: EntityProp) -> bool {
	return slice.count(en.props[:], prop) > 0
}

en_collides_with :: proc(en: ^Entity, collidables: []^Entity, at: rl.Vector2) -> bool {
	to_check := rl.Rectangle{at.x, at.y, en.aabb.width, en.aabb.height}
	for c in collidables {
		if rl.CheckCollisionRecs(c.aabb, to_check) {
			en.last_collided = c
			if en_has_prop(c, .ridable) {
				c.riding = en
			}
			return true
		}
	}
	return false
}

Action :: proc(e: ^Entity)
ActorMoveX :: proc(collidables: []^Entity, e: ^Entity, amount: f32, callback: Action) {

	e.remainder.x += amount
	move := math.round(e.remainder.x)
	if move != 0 {
		e.remainder.x -= move
		sign := math.sign(move)
		for move != 0 {
			if !en_collides_with(e, collidables, {e.pos.x + sign, e.pos.y}) {
				e.pos.x += sign
				move -= sign
			} else {
				if callback != nil {callback(e)}
				if e.last_collided != nil && !e.last_collided.is_collidable {
					e.pos.x += sign
					move -= sign
				} else {
					break
				}
			}
		}
	}
}

ActorMoveY :: proc(collidables: []^Entity, e: ^Entity, amount: f32, callback: Action) {
	e.remainder.y += amount
	move := math.round(e.remainder.y)
	if move != 0 {
		e.remainder.y -= move
		sign := math.sign(move)
		for move != 0 {
			if !en_collides_with(e, collidables, {e.pos.x, e.pos.y + sign}) {
				e.pos.y += sign
				move -= sign
			} else {
				if callback != nil {callback(e)}
				if e.last_collided != nil && !e.last_collided.is_collidable {
					e.pos.y += sign
					move -= sign
				} else {
					if e.vel.y > 0 {
						if !e.played_land {
							rl.PlaySound(land)
							e.played_land = true
						}
						e.grounded = true
						e.fall_time = 0
					}
					e.vel.y = 0
					break
				}
			}
		}
	}
}

SolidMove :: proc(collidables: []^Entity, e: ^Entity, xAmount, yAmount: f32) {
	e.remainder.x += xAmount
	e.remainder.y += yAmount
	moveX := math.round(e.remainder.x)
	moveY := math.round(e.remainder.y)
	if moveX != 0 || moveY != 0 {
		e.is_collidable = false
		if moveX != 0 {
			e.remainder.x -= moveX
			e.pos.x += moveX
			if moveX > 0 {
				if e.riding != nil && rl.FloatEquals(e.riding.pos.y + e.riding.aabb.height, e.pos.y) {
					e.riding.pos.x += moveX
				} else {
					e.riding = nil
				}
			} else {
				if e.riding != nil && rl.FloatEquals(e.riding.pos.y + e.riding.aabb.height, e.pos.y) {
					e.riding.pos.x -= moveX
				} else {
					e.riding = nil
				}
			}
		}
		e.is_collidable = true
	}
}

// :player
PlayerState :: enum {
	idle,
	walk,
}

Player :: struct {
	using en:                    Entity,
	animation:                   ^Animation,
	state, prevState:            PlayerState,
	jump_power, jump_boost_time: f32,
}

player_init :: proc() -> ^Player {
	e := new(Player)
	en_setup(e, 0, -24, 18, 24)
	e.state = .idle
	e.jump_power = -5
	e.id = .player
	return e
}

player_update :: proc(player: ^Player, walk, idle: ^Animation) {
	using rl, player
	riding = nil
	aabb.x = player.pos.x + 4
	aabb.y = player.pos.y

	if vel.y > 0 {
		fall_time += GetFrameTime()
	}

	if fall_time > 3 {
		vel.y += 2
	}

	if IsKeyDown(.A) {
		walk.speed = Approach(walk.speed, .1, 4 * GetFrameTime())
		player.vel.x = Approach(player.vel.x, -2.0, 22 * GetFrameTime())
		player.flip = true
		player.state = .walk
	} else if IsKeyDown(.D) {
		walk.speed = Approach(walk.speed, .1, 4 * GetFrameTime())
		player.vel.x = Approach(player.vel.x, 2.0, 22 * GetFrameTime())
		player.flip = false
		player.state = .walk
	} else {
		player.state = .idle
	}

	if IsKeyPressed(.SPACE) && player.grounded {
		player.grounded = false
		player.played_land = false
		player.vel.y = jump_power
		PlaySound(jump)
	}

	if player.prevState != player.state {
		switch player.state {
		case .idle:
			player.animation = idle
			reset_anim(walk)
			walk.speed = .25
		case .walk:
			player.animation = walk
			reset_anim(idle)
		}
		player.prevState = player.state
	}

	if !IsKeyDown(.A) && !IsKeyDown(.D) {
		if player.grounded {
			player.vel.x = Approach(player.vel.x, 0.0, 10 * GetFrameTime())
		} else {
			player.vel.x = Approach(player.vel.x, 0.0, 12 * GetFrameTime())
		}
	}

	onCollide :: proc(self: ^Entity) {
		player: ^Player = auto_cast self
		if self.last_collided != nil {
			if self.last_collided.id == .dead_zone {
				if player.jump_boost_time <= 0 {
					game.screen = .lost
				} else {
					self.pos = self.respawn
				}
			} else if self.last_collided.id == .jump_coffee {
				self.last_collided.is_valid = false
				player.jump_power = -10
				player.jump_boost_time = clamp(player.jump_boost_time, player.jump_boost_time + 4, 20)
				rl.PlaySound(pickup)
			} else if self.last_collided.id == .check_coffee {
				player.respawn = {self.pos.x, (self.pos.y + self.aabb.height - player.aabb.height)}
				self.last_collided.is_valid = false
				rl.PlaySound(pickup)
			} else if self.last_collided.id == .trophy {
				game.screen = .won
			}
		}
	}

	ActorMoveX(game_get_all_en_with_prop(&game, .collidable)[:], player, player.vel.x, onCollide)
	player.vel.y = Approach(player.vel.y, 3.6, 13 * GetFrameTime())
	ActorMoveY(game_get_all_en_with_prop(&game, .collidable)[:], player, player.vel.y, onCollide)

	update_anim(player.animation, GetFrameTime())

	if jump_boost_time > 0 {
		jump_boost_time -= GetFrameTime()
	} else if jump_boost_time <= 0 && jump_power == -10 {
		jump_power /= 2
	}
}

// ;player

en_collidable :: proc(x, y, w, h: f32) -> ^Entity {
	e := new(Entity)
	e.is_collidable = true
	en_setup(e, x, y, w, h)
	en_add_props(e, .collidable)
	return e
}

en_move_y :: proc(en: ^Entity, y: f32) {
	en.pos.y = y
	en.aabb.y = y
}

Game :: struct {
	ens:    [dynamic]^Entity,
	screen: Screen,
	quit:   bool,
}

game: Game

game_add_en :: proc(g: ^Game, en: ^Entity) {
	append(&g.ens, en)
}

game_get_all_en_with_prop :: proc(game: ^Game, prop: EntityProp) -> [dynamic]^Entity {
	res: [dynamic]^Entity
	for e in game.ens {
		if !e.is_valid {continue}
		if slice.count(e.props[:], prop) > 0 {
			append(&res, e)
		}
	}
	return res
}

Screen :: enum {
	menu,
	game,
	lost,
	won,
	credits,
	difficulty,
	howto,
}

jump, land, pickup: rl.Sound

main :: proc() {
	using rl
	SetTraceLogLevel(.WARNING)
	InitAudioDevice()
	InitWindow(1280, 720, "I'm drinking black coffee!")
	SetTargetFPS(60)

	when Debug {SetExitKey(.Q)} else {SetExitKey(.KEY_NULL)}

	cam := Camera2D{}
	cam.offset = {f32(GetScreenWidth()), f32(GetScreenHeight())} / 2
	cam.zoom = 2.0

	minimapCam := cam

	//:load
	boyIdle := add_tex("./assets/Boy_idle.png")
	boyWalk := add_tex("./assets/Boy_walk.png")
	tileset := add_tex("./assets/tileset_forest.png")
	coffee := add_tex("./assets/coffee.png")
	trophy := add_tex("./assets/gold.png")

	jump = LoadSound("./assets/jump.wav")
	land = LoadSound("./assets/land.wav")
	pickup = LoadSound("./assets/pop1.wav")

	idle := Animation {
		tex       = boyIdle,
		speed     = 0.25,
		frame_cnt = 4,
		timer     = 0,
	}

	walk := Animation {
		tex       = boyWalk,
		speed     = 0.25,
		frame_cnt = 6,
		timer     = 0,
	}

	//:init

	player := player_init()
	player.respawn = {0, -25}
	player.animation = &idle
	player.jump_boost_time = 20

	game = Game{}
	game.screen = .menu

	game_map: []int
	game_map_sz: int

	Tile :: struct {
		src, dst: rl.Vector2,
	}

	tile_data: []Tile

	dead_zone := en_collidable(-1000, 10, 2000, 16)
	dead_zone.is_collidable = false
	dead_zone.id = .dead_zone
	en_move_y(dead_zone, player.respawn.y + player.aabb.height + 16)
	game_add_en(&game, dead_zone)

	PlatType :: enum {
		one_wide,
		two_wide,
		three_wide,
		final = 5,
	}

	gen_plat :: proc(x, y: f32, type: PlatType, textId: TextureID) -> ^Entity {
		e := new(Entity)
		switch type {
		case .one_wide:
			en_setup(e, x, y, 16, 16)
		case .two_wide:
			en_setup(e, x, y, 16 * 2, 16)
		case .three_wide:
			en_setup(e, x, y, 16 * 3, 16)
		case .final:
			en_setup(e, x, y, 16 * 6, 16 * 3)
		}
		en_add_props(e, .collidable, .plat)
		e.id = .plat
		e.texId = textId
		e.is_collidable = true
		return e
	}

	plat_render :: proc(using self: ^Entity) {
		using rl
		type := (aabb.width / 16) - 1
		plat_type := cast(PlatType)type
		switch plat_type {
		case .one_wide:
			DrawTextureRec(get_tex(self.texId), {8 * 16, 16, 16, 16}, {pos.x, pos.y}, WHITE)
		case .two_wide:
			DrawTextureRec(get_tex(self.texId), {8 * 16, 16 * 3, 16, 16}, {pos.x, pos.y}, WHITE)
			DrawTextureRec(get_tex(self.texId), {10 * 16, 16 * 3, 16, 16}, {pos.x + 16, pos.y}, WHITE)
		case .three_wide:
			DrawTextureRec(get_tex(self.texId), {8 * 16, 16 * 3, 16, 16}, {pos.x, pos.y}, WHITE)
			DrawTextureRec(get_tex(self.texId), {9 * 16, 16 * 3, 16, 16}, {pos.x + 16, pos.y}, WHITE)
			DrawTextureRec(get_tex(self.texId), {10 * 16, 16 * 3, 16, 16}, {pos.x + 32, pos.y}, WHITE)
		case .final:
			for x in 0 ..< f32(6) {
				for y in 0 ..< f32(3) {
					DrawTextureRec(get_tex(self.texId), {(1 + x) * 16, (2 + y) * 16, 16, 16}, {pos.x + (x * 16), pos.y + (y * 16)}, WHITE)
				}
			}
		}
	}

	gen_pickup :: proc(x, y: f32, type: EntityId) -> ^Entity {
		e := new(Entity)
		en_setup(e, x, y, 16, 16)
		e.id = type
		en_add_props(e, .collidable)
		return e
	}


	plats := game_get_all_en_with_prop(&game, .plat)

	lastPlayerY: f32 = 0.0
	minimap := LoadRenderTexture(GetScreenWidth(), GetScreenHeight())
	score := 0

	inited := false
	diff := i32(0)


	for !WindowShouldClose() && !game.quit {

		switch game.screen {
		case .howto:
			if IsKeyPressed(.ESCAPE) {
				game.screen = .menu
			}
		case .difficulty:
			if IsKeyPressed(.ESCAPE) {
				game.screen = .menu
			}
		case .menu:
		case .game:
			when Debug {
				if IsKeyPressed(.C) {
					player.jump_boost_time = 20
				} else if IsKeyPressed(.K) {
					en_move_y(player, -10300)
					cam.target = player.pos
				}
			}

			if IsKeyPressed(.ESCAPE) {
				game.screen = .menu
			}

			player_update(player, &walk, &idle)

			if player.vel.y < 0 {
				score += 1
			}

			cam.target = linalg.lerp(cam.target, player.pos, abs(player.vel.y) * GetFrameTime())

			zoom := clamp(cam.zoom - math.floor(-player.vel.y) * 100 / 100, 1.0, 2.0)
			cam.zoom = linalg.lerp(cam.zoom, zoom, 1 * GetFrameTime())
			en_move_y(dead_zone, player.respawn.y + player.aabb.height + 32)

			minimapCam = cam

			for en in game.ens {
				if en.pos.y > dead_zone.pos.y {
					en.is_valid = false
				}
				if !en.is_valid {continue}
				if en.id == .trophy {
					en_move_y(en, en.pos.y - f32(math.sin(GetTime() * 3)))
				}
			}

			BeginTextureMode(minimap)
			{
				ClearBackground(BLANK)
				minimapCam.zoom = 1
				BeginMode2D(minimapCam)
				{
					for en in game.ens {
						if !en.is_valid {continue}
						#partial switch en.id {
						case .plat:
							plat_render(en)
						case .jump_coffee:
							DrawRectangleRec(en.aabb, WHITE)
						case .check_coffee:
							DrawRectangleRec(en.aabb, GREEN)
						}
					}
					DrawRectangleRec(player.aabb, RED)

				}
				EndMode2D()
			}
			EndTextureMode()

		case .lost:
			if IsKeyPressed(.ESCAPE) {
				game.screen = .menu
			}
		case .won:
			if IsKeyPressed(.ESCAPE) {
				game.screen = .menu
			}
		case .credits:
			if IsKeyPressed(.ESCAPE) {
				game.screen = .menu
			}
		}


		BeginDrawing()
		{
			btn :: proc(play: Rectangle, text: cstring) -> bool {
				clicked := false
				color := WHITE
				textColor := BLACK
				if CheckCollisionPointRec(GetMousePosition(), play) {
					color = BLUE
					textColor = WHITE
					if IsMouseButtonPressed(.LEFT) {
						clicked = true
					}
				}
				DrawRectangleRounded(play, .2, 10, color)
				DrawText(text, i32(play.x + play.width / 2) - i32(MeasureText(text, 20) / 2), i32(play.y + play.height / 2 - 10), 20, textColor)
				return clicked
			}
			switch game.screen {
			case .howto:
				ClearBackground(BLACK)
				cnt := i32(0)
				splited := TextSplit(howtoText, '\n', &cnt)
				y := GetScreenHeight() / 2 - cnt * 20
				for i in 0 ..< cnt {
					color := WHITE
					size := MeasureText(splited[i], 20)
					DrawText(splited[i], i32((f32(GetScreenWidth() - size)) * 0.5), y + i * 20, 20, color)
				}

				DrawRectangleRounded({12, 12, 35, 35}, .2, 10, BEIGE)
				DrawRectangleRounded({10, 10, 35, 35}, .2, 10, WHITE)
				DrawText("ESC", 12, 12, 10, BLACK)

			case .difficulty:
				ClearBackground(BLACK)

				xyMid := Vector2{f32(GetScreenWidth()), f32(GetScreenHeight())} / 2

				if !inited {xyMid.x -= 140
					xyMid.y -= 200
					DrawRectangleRounded({xyMid.x + 2, xyMid.y + 2, 35, 35}, .2, 10, BEIGE)
					DrawRectangleRounded({xyMid.x, xyMid.y, 35, 35}, .2, 10, WHITE)
					DrawText("A", i32(xyMid.x) + 2, i32(xyMid.y) + 2, 10, BLACK)
					DrawText("Move left", i32(xyMid.x) + 2 + 45, i32(xyMid.y) + 2, 10, RAYWHITE)
					DrawRectangleRounded({xyMid.x + 2, xyMid.y + 2 + 45, 35, 35}, .2, 10, BEIGE)
					DrawRectangleRounded({xyMid.x, xyMid.y + 45, 35, 35}, .2, 10, WHITE)
					DrawText("S", i32(xyMid.x) + 2, i32(xyMid.y) + 2 + 45, 10, BLACK)
					DrawText("Move right", i32(xyMid.x) + 2 + 45, i32(xyMid.y) + 2 + 45, 10, RAYWHITE)
					DrawRectangleRounded({xyMid.x + 2, xyMid.y + 2 + 45 + 45, 85, 35}, .2, 10, BEIGE)
					DrawRectangleRounded({xyMid.x, xyMid.y + 45 + 45, 85, 35}, .2, 10, WHITE)
					DrawText("SPACE", i32(xyMid.x) + 2, i32(xyMid.y) + 2 + 45 + 45, 10, BLACK)
					DrawText("Jump", i32(xyMid.x) + 2 + 95, i32(xyMid.y) + 2 + 45 + 45, 10, RAYWHITE)

					DrawTexture(get_tex(coffee), i32(xyMid.x) + 2 + 95 + 45, i32(xyMid.y), WHITE)
					DrawText("+ jump boost", i32(xyMid.x) + 2 + 95 + 45 + 16 + 10, i32(xyMid.y) + 4, 10, RAYWHITE)
					DrawTexture(get_tex(coffee), i32(xyMid.x) + 2 + 95 + 45, i32(xyMid.y) + 45, GREEN)
					DrawText("checkpoint", i32(xyMid.x) + 2 + 95 + 45 + 16 + 10, i32(xyMid.y) + 4 + 45, 10, RAYWHITE)
					DrawTexture(get_tex(trophy), i32(xyMid.x) + 2 + 95 + 45, i32(xyMid.y) + 45 + 45, WHITE)
					DrawText("final objective", i32(xyMid.x) + 2 + 95 + 45 + 16 + 10 + 10, i32(xyMid.y) + 4 + 45 + 45, 10, RAYWHITE)

					xyMid += {140, 200}

					how_to_play := Rectangle{xyMid.x - 200, xyMid.y, 400, 35}
					if btn(how_to_play, "Continue") {
						inited = true
						xyMid = Vector2{f32(GetScreenWidth()), f32(GetScreenHeight())} / 2
					}
				} else {


					easy := Rectangle{xyMid.x - f32(GetScreenWidth()) * .2 / 2, xyMid.y, f32(GetScreenWidth()) * .2, 45}
					if (btn(easy, "Easy")) {
						diff = -2000
						game_add_en(&game, gen_plat(0, 0, .three_wide, tileset))
						game_add_en(&game, gen_plat(-100, 0, .three_wide, tileset))
						game_add_en(&game, gen_pickup(-100, -16, .jump_coffee))
						y := f32(-2000)
						game_add_en(&game, gen_plat(0, y - 100, .final, tileset))
						game_add_en(&game, gen_pickup(38, y - 160, .trophy))
						for y < -100 {
							rnd := GetRandomValue(0, 2)
							rndX := f32(GetRandomValue(-200, 200))
							game_add_en(&game, gen_plat(rndX, y, cast(PlatType)rnd, tileset))

							if int(y) % 3 == 0 {
								game_add_en(&game, gen_plat(-rndX, y, cast(PlatType)rnd, tileset))
							} else if int(y) % 5 == 0 {
								game_add_en(&game, gen_pickup(rndX, y - 16, .jump_coffee))
							} else if int(y) % 11 == 0 {
								game_add_en(&game, gen_pickup(rndX, y - 16, .check_coffee))
							}
							y += 16 * 4
						}

						game.screen = .game
					}
					medium := Rectangle{xyMid.x - f32(GetScreenWidth()) * .2 / 2, xyMid.y + 55, f32(GetScreenWidth()) * .2, 45}
					if (btn(medium, "Medium")) {
						diff = -5000
						game_add_en(&game, gen_plat(0, 0, .three_wide, tileset))
						game_add_en(&game, gen_plat(-100, 0, .three_wide, tileset))
						game_add_en(&game, gen_pickup(-100, -16, .jump_coffee))
						y := f32(-5000)
						game_add_en(&game, gen_plat(0, y - 100, .final, tileset))
						game_add_en(&game, gen_pickup(38, y - 160, .trophy))
						for y < -100 {
							rnd := GetRandomValue(0, 2)
							rndX := f32(GetRandomValue(-200, 200))
							game_add_en(&game, gen_plat(rndX, y, cast(PlatType)rnd, tileset))

							if int(y) % 3 == 0 {
								game_add_en(&game, gen_plat(-rndX, y, cast(PlatType)rnd, tileset))
							} else if int(y) % 5 == 0 {
								game_add_en(&game, gen_pickup(rndX, y - 16, .jump_coffee))
							} else if int(y) % 11 == 0 {
								game_add_en(&game, gen_pickup(rndX, y - 16, .check_coffee))
							}
							y += 16 * 4
						}

						game.screen = .game
					}
					hard := Rectangle{xyMid.x - f32(GetScreenWidth()) * .2 / 2, xyMid.y + 110, f32(GetScreenWidth()) * .2, 45}
					if (btn(hard, "Hard")) {
						diff = -10000
						game_add_en(&game, gen_plat(0, 0, .three_wide, tileset))
						game_add_en(&game, gen_plat(-100, 0, .three_wide, tileset))
						game_add_en(&game, gen_pickup(-100, -16, .jump_coffee))
						y := f32(-10000)
						game_add_en(&game, gen_plat(0, y - 100, .final, tileset))
						game_add_en(&game, gen_pickup(38, y - 160, .trophy))
						for y < -100 {
							rnd := GetRandomValue(0, 2)
							rndX := f32(GetRandomValue(-200, 200))
							game_add_en(&game, gen_plat(rndX, y, cast(PlatType)rnd, tileset))

							if int(y) % 3 == 0 {
								game_add_en(&game, gen_plat(-rndX, y, cast(PlatType)rnd, tileset))
							} else if int(y) % 5 == 0 {
								game_add_en(&game, gen_pickup(rndX, y - 16, .jump_coffee))
							} else if int(y) % 11 == 0 {
								game_add_en(&game, gen_pickup(rndX, y - 16, .check_coffee))
							}
							y += 16 * 4
						}

						game.screen = .game
					}
				}

				DrawRectangleRounded({12, 12, 35, 35}, .2, 10, BEIGE)
				DrawRectangleRounded({10, 10, 35, 35}, .2, 10, WHITE)
				DrawText("ESC", 12, 12, 10, BLACK)
			case .menu:
				ClearBackground(BLACK)
				xyMid := Vector2{f32(GetScreenWidth()), f32(GetScreenHeight())} / 2
				play := Rectangle{xyMid.x - f32(GetScreenWidth()) * .2 / 2, xyMid.y, f32(GetScreenWidth()) * .2, 45}

				if btn(play, "START GAME") {
					game.screen = .difficulty
				}
				credits := Rectangle{play.x, play.y + play.height + 10, play.width, play.height}
				if btn(credits, "CREDITS") {
					game.screen = .credits
				}
				how_to_play := Rectangle{credits.x, credits.y + credits.height + 10, credits.width, credits.height}
				if btn(how_to_play, "HOW TO") {
					game.screen = .howto
				}
			case .game:
				ClearBackground(BLACK)

				BeginMode2D(cam)
				{
					DrawRectangleGradientV(-GetScreenWidth(), diff, GetScreenWidth() * 2, abs(diff) + 2000, BLACK, BLUE)
					tex := get_tex(tileset)
					for tile in tile_data {
						DrawTextureRec(tex, {tile.src.x, tile.src.y, 16, 16}, {tile.dst.x, tile.dst.y}, WHITE)
					}

					DrawTexturePro(
						get_tex(player.animation.tex),
						{f32(player.animation.current_frame) * 48, 0, player.flip ? -24 : 24, 48},
						{player.pos.x, player.pos.y - 24, 24, 48},
						{},
						0,
						WHITE,
					)
					when Debug {
						DrawRectangleLinesEx(player.aabb, 1.0, GREEN)
					}

					for en in game.ens {
						if !en.is_valid {continue}
						#partial switch en.id {
						case .plat:
							if en.pos.y > dead_zone.pos.y {en.is_valid = false}
							plat_render(en)
						case .jump_coffee:
							DrawTextureV(get_tex(coffee), en.pos, WHITE)
						case .check_coffee:
							DrawTextureV(get_tex(coffee), en.pos, GREEN)
						case .trophy:
							DrawTextureV(get_tex(trophy), en.pos, WHITE)
						case .dead_zone:
							DrawRectangleV(en.pos, en.size, RED)
						}
						for prop in en.props {
							#partial switch prop {
							case .collidable:
								when Debug {
									DrawRectangleLinesEx(en.aabb, 1.0, RED)
								}
							}
						}}
				}
				EndMode2D()

				MAX_JUMP_BOOST :: 20
				yStart := f32(GetScreenHeight() - 100)
				xStart := f32(GetScreenWidth() - 400) * 0.5
				DrawRectangleV({xStart, yStart}, {400, 25}, BROWN)
				current_width := 400 * player.jump_boost_time / MAX_JUMP_BOOST
				DrawRectangleV({xStart, yStart}, {current_width, 25}, DARKBROWN)
				DrawRectangleLinesEx({xStart, yStart, 400, 25}, 2, DARKBROWN)
				DrawText(
					"Jump Boost",
					(GetScreenWidth() / 2 - MeasureText("Jump Boost", GetFontDefault().baseSize * 2) / 2) - 2,
					(i32(yStart) - GetFontDefault().baseSize * 2) - 2,
					GetFontDefault().baseSize * 2,
					GRAY,
				)
				DrawText(
					"Jump Boost",
					GetScreenWidth() / 2 - MeasureText("Jump Boost", GetFontDefault().baseSize * 2) / 2,
					i32(yStart) - GetFontDefault().baseSize * 2,
					GetFontDefault().baseSize * 2,
					WHITE,
				)

				// Score
				//fontSize := i32(30)
				//DrawText("Score", GetScreenWidth() / 2 - MeasureText("Score", fontSize) / 2, i32(40) - fontSize, fontSize, WHITE)
				//DrawText(TextFormat("%010d", score), GetScreenWidth() / 2 - MeasureText(TextFormat("%010d", score), fontSize) / 2, i32(80) - fontSize, fontSize, WHITE)


				//DrawText(TextFormat("PlayerPos: %f %f", player.pos.x, player.vel.y), 10, 10, GetFontDefault().baseSize, WHITE)
				//DrawText(TextFormat("PlayerJumpPower: %f", player.jump_power), 10, 10 + GetFontDefault().baseSize + 2, GetFontDefault().baseSize, WHITE)
				//DrawText(
				//	TextFormat("PlayerJumptimer: %f", player.jump_boost_time),
				//	10,
				//	10 + GetFontDefault().baseSize + 2 + 10 + GetFontDefault().baseSize + 2,
				//	GetFontDefault().baseSize,
				//	WHITE,
				//)
				DrawTexturePro(
					minimap.texture,
					{0, 0, f32(minimap.texture.width), f32(-minimap.texture.height)},
					{10, f32(GetScreenHeight() - GetScreenHeight() / 4 - 10), f32(GetScreenWidth() / 4), f32(GetScreenHeight() / 4)},
					{},
					0,
					WHITE,
				)
				DrawRectangleLinesEx({10, f32(GetScreenHeight() - GetScreenHeight() / 4 - 10), f32(GetScreenWidth() / 4), f32(GetScreenHeight() / 4)}, 2.0, BLACK)

				DrawFPS(10, 55)

				DrawRectangleRounded({12, 12, 35, 35}, .2, 10, BEIGE)
				DrawRectangleRounded({10, 10, 35, 35}, .2, 10, WHITE)
				DrawText("ESC", 12, 12, 10, BLACK)

			case .lost:
				ClearBackground(BLACK)
				DrawRectangleRounded({12, 12, 35, 35}, .2, 10, BEIGE)
				DrawRectangleRounded({10, 10, 35, 35}, .2, 10, WHITE)
				DrawText("ESC", 12, 12, 10, BLACK)
			case .won:
				ClearBackground(BLACK)

				xyMid := Vector2{f32(GetScreenWidth()), f32(GetScreenHeight())} / 2
				easy := Rectangle{xyMid.x - f32(GetScreenWidth()) * .2 / 2, xyMid.y, f32(GetScreenWidth()) * .2, 45}

				DrawText("WON!", i32(easy.x), i32(easy.y), 30, WHITE)

				DrawRectangleRounded({12, 12, 35, 35}, .2, 10, BEIGE)
				DrawRectangleRounded({10, 10, 35, 35}, .2, 10, WHITE)
				DrawText("ESC", 12, 12, 10, BLACK)
			case .credits:
				ClearBackground(BLACK)
				cnt := i32(0)
				splited := TextSplit(creditsText, '\n', &cnt)
				y := GetScreenHeight() / 2 - cnt * 20
				for i in 0 ..< cnt {
					color := WHITE
					if i % 2 == 0 {
						color = RED}
					size := MeasureText(splited[i], 20)
					DrawText(splited[i], i32((f32(GetScreenWidth() - size)) * 0.5), y + i * 20, 20, color)
				}

				DrawRectangleRounded({12, 12, 35, 35}, .2, 10, BEIGE)
				DrawRectangleRounded({10, 10, 35, 35}, .2, 10, WHITE)
				DrawText("ESC", 12, 12, 10, BLACK)
			}
		}
		EndDrawing()
	}

	defer CloseWindow()
}

Approach :: proc(current, target, increase: f32) -> f32 {
	if current < target {
		return min(current + increase, target)
	}
	return max(current - increase, target)
}
