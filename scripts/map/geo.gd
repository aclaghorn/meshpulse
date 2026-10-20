class_name Geo
extends RefCounted
## Web Mercator helpers and the mapping into world space.
##
## World space: 1 unit = 1 km at the origin's latitude, +X east, -Z north, +Y up.
## Elevation is multiplied by vertical_scale (the exaggeration) on its way into Y.

const EARTH_RADIUS_M := 6378137.0
## Half the width of the Mercator plane, in metres.
const ORIGIN_SHIFT := PI * EARTH_RADIUS_M
const MAX_LAT := 85.05112878

static var origin_lat := 0.0
static var origin_lon := 0.0
static var origin_mx := 0.0
static var origin_my := 0.0
## Mercator metres are stretched by 1/cos(lat); this brings them back to true km at the origin.
static var km_per_mercator_m := 0.001
static var vertical_scale := 2.0


static func set_origin(lat: float, lon: float) -> void:
	origin_lat = lat
	origin_lon = lon
	origin_mx = lon_to_mx(lon)
	origin_my = lat_to_my(lat)
	km_per_mercator_m = cos(deg_to_rad(lat)) / 1000.0


static func lon_to_mx(lon: float) -> float:
	return deg_to_rad(lon) * EARTH_RADIUS_M


static func lat_to_my(lat: float) -> float:
	var clamped := clampf(lat, -MAX_LAT, MAX_LAT)
	return log(tan(PI / 4.0 + deg_to_rad(clamped) / 2.0)) * EARTH_RADIUS_M


static func mx_to_lon(mx: float) -> float:
	return rad_to_deg(mx / EARTH_RADIUS_M)


static func my_to_lat(my: float) -> float:
	return rad_to_deg(2.0 * atan(exp(my / EARTH_RADIUS_M)) - PI / 2.0)


## Mercator metres -> world (x, z).
static func mercator_to_world(mx: float, my: float) -> Vector2:
	return Vector2((mx - origin_mx) * km_per_mercator_m, -(my - origin_my) * km_per_mercator_m)


## World (x, z) -> Mercator metres.
static func world_to_mercator(x: float, z: float) -> Vector2:
	return Vector2(x / km_per_mercator_m + origin_mx, -z / km_per_mercator_m + origin_my)


static func latlon_to_world(lat: float, lon: float, elevation_km := 0.0) -> Vector3:
	var xz := mercator_to_world(lon_to_mx(lon), lat_to_my(lat))
	return Vector3(xz.x, elevation_km * vertical_scale, xz.y)


## Returns Vector2(lat, lon).
static func world_to_latlon(p: Vector3) -> Vector2:
	var m := world_to_mercator(p.x, p.z)
	return Vector2(my_to_lat(m.y), mx_to_lon(m.x))


static func tile_size_m(zoom: int) -> float:
	return 2.0 * ORIGIN_SHIFT / float(1 << zoom)


## Fractional XYZ tile coordinates of a Mercator point (y grows southward).
static func mercator_to_tile(mx: float, my: float, zoom: int) -> Vector2:
	var size := tile_size_m(zoom)
	return Vector2((mx + ORIGIN_SHIFT) / size, (ORIGIN_SHIFT - my) / size)


## Mercator metres of a tile's north-west corner.
static func tile_nw_mercator(zoom: int, tx: int, ty: int) -> Vector2:
	var size := tile_size_m(zoom)
	return Vector2(-ORIGIN_SHIFT + tx * size, ORIGIN_SHIFT - ty * size)


## Great-circle distance in km.
static func distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dp := p2 - p1
	var dl := deg_to_rad(lon2 - lon1)
	var a := sin(dp / 2.0) ** 2 + cos(p1) * cos(p2) * sin(dl / 2.0) ** 2
	return 2.0 * 6371.0 * asin(minf(1.0, sqrt(a)))
