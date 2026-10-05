/**
 * Map arithmetic for the Event response page: where a latitude and longitude fall on the web map's
 * tile grid, and back again. This is the standard "slippy map" projection the OpenStreetMap tiles
 * use; nothing here calls a service.
 */

/** The width and height of one map tile, in pixels. */
export const TILE_SIZE = 256;
export const MIN_ZOOM = 6;
export const MAX_ZOOM = 15;
const EARTH_CIRCUMFERENCE_MILES = 24901.461;

/** Where a point falls on the whole-world map at a zoom level, in pixels from its top left. */
export function worldPoint(latitude, longitude, zoom) {
    const size = TILE_SIZE * 2 ** zoom;
    const radians = (latitude * Math.PI) / 180;
    return {
        x: ((longitude + 180) / 360) * size,
        y: ((1 - Math.log(Math.tan(radians) + 1 / Math.cos(radians)) / Math.PI) / 2) * size
    };
}

/** The latitude and longitude at a spot on the whole-world map, the reverse of worldPoint. */
export function placeAt(x, y, zoom) {
    const size = TILE_SIZE * 2 ** zoom;
    const turn = Math.PI - (2 * Math.PI * y) / size;
    return {
        latitude: (180 / Math.PI) * Math.atan(0.5 * (Math.exp(turn) - Math.exp(-turn))),
        longitude: (x / size) * 360 - 180
    };
}

/** How many miles one pixel covers at a latitude and zoom level. */
export function milesPerPixel(latitude, zoom) {
    return (EARTH_CIRCUMFERENCE_MILES * Math.cos((latitude * Math.PI) / 180)) / (TILE_SIZE * 2 ** zoom);
}

/** The closest zoom level at which an area reaching `reachMiles` from its middle fits the frame with room to spare. */
export function zoomToFit(reachMiles, latitude, width, height) {
    const across = Math.max(1, Math.min(width, height));
    const wanted = (reachMiles * 2 * 1.3) / across;
    for (let zoom = MAX_ZOOM; zoom >= MIN_ZOOM; zoom--) {
        if (milesPerPixel(latitude, zoom) >= wanted) {
            return zoom;
        }
    }
    return MIN_ZOOM;
}

/** The tiles that cover a frame whose top left corner sits at (left, top) on the whole-world map. */
export function tilesFor(left, top, width, height, zoom) {
    const count = 2 ** zoom;
    const tiles = [];
    const firstColumn = Math.floor(left / TILE_SIZE);
    const lastColumn = Math.floor((left + width) / TILE_SIZE);
    const firstRow = Math.max(0, Math.floor(top / TILE_SIZE));
    const lastRow = Math.min(count - 1, Math.floor((top + height) / TILE_SIZE));
    for (let row = firstRow; row <= lastRow; row++) {
        for (let column = firstColumn; column <= lastColumn; column++) {
            const wrapped = ((column % count) + count) % count;
            tiles.push({
                key: `${zoom}-${column}-${row}`,
                url: `https://tile.openstreetmap.org/${zoom}/${wrapped}/${row}.png`,
                style: `left: ${Math.round(column * TILE_SIZE - left)}px; top: ${Math.round(row * TILE_SIZE - top)}px`
            });
        }
    }
    return tiles;
}
