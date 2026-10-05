import { LightningElement, api } from 'lwc';
import { worldPoint, placeAt, milesPerPixel, zoomToFit, tilesFor, MIN_ZOOM, MAX_ZOOM } from 'c/antsuranceEventGeo';

// How far one arrow key press slides the map, in pixels.
const KEY_STEP = 64;
// The frame's size before it has been measured.
const FIRST_WIDTH = 640;
const FIRST_HEIGHT = 440;
// A background browser tab draws no frames, so the frame is also measured on a slow timer.
const MEASURE_EVERY_MS = 1200;
// A drag shorter than this is a click.
const DRAG_SLACK = 4;

/** What each kind of location is called, and the icon inside its marker. The marker's shape differs too. */
const KINDS = {
    Home: { word: 'Home', icon: 'utility:home', shape: 'round' },
    Business: { word: 'Business premises', icon: 'utility:company', shape: 'square' },
    Vehicle: { word: 'Vehicle garaged here', icon: 'utility:transport_light_truck', shape: 'pill' },
    Workplace: { word: 'Workplace', icon: 'utility:identity', shape: 'diamond' }
};

/**
 * A street map of an event: the area it crossed, shaded, with a marker for each insured location.
 * The map slides by dragging or the arrow keys and zooms with its buttons or the plus and minus keys.
 * It draws OpenStreetMap tiles itself from coordinates; nothing is geocoded.
 */
export default class AntsuranceEventMap extends LightningElement {
    /** What the map shows, for screen readers. */
    @api label = 'Map of the event';
    @api centerLatitude;
    @api centerLongitude;
    /** How far the area reaches from its middle, in miles. */
    @api reachMiles;
    /** The circle's radius in miles; empty when the area is an outline. */
    @api radiusMiles;
    /** The key of the chosen location. */
    @api selectedKey;

    width = FIRST_WIDTH;
    height = FIRST_HEIGHT;
    zoom;
    // The middle of the frame on the whole-world map at the current zoom, in pixels.
    middleX;
    middleY;
    drag;
    timer;
    resizer;
    _places = [];
    _points = [];
    // The area the map was last fitted to, and whether it has been fitted to a measured frame yet.
    _areaKey;
    _fitted = false;
    _justDragged = false;

    /** The locations to mark: { key, latitude, longitude, inside, kind, name, what }. */
    @api
    get places() {
        return this._places;
    }
    set places(value) {
        this._places = Array.isArray(value) ? value : [];
    }

    /** An outline's corners as [latitude, longitude] pairs; empty for a circle. */
    @api
    get points() {
        return this._points;
    }
    set points(value) {
        this._points = Array.isArray(value) ? value : [];
    }

    /** Slides the map so one location sits in the middle. */
    @api
    showPlace(key) {
        const place = this._places.find((one) => one.key === key);
        if (place && this.zoom !== undefined) {
            const point = worldPoint(place.latitude, place.longitude, this.zoom);
            this.middleX = point.x;
            this.middleY = point.y;
        }
    }

    connectedCallback() {
        this.resizer = () => this.measure();
        window.addEventListener('resize', this.resizer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setInterval(() => this.measure(), MEASURE_EVERY_MS);
    }

    disconnectedCallback() {
        window.removeEventListener('resize', this.resizer);
        clearInterval(this.timer);
    }

    renderedCallback() {
        this.measure();
    }

    /** Reads the frame's size, and fits the map to the area the first time or when the event changes. */
    measure() {
        const frame = this.template.querySelector('.c-map__frame');
        if (frame) {
            const box = frame.getBoundingClientRect();
            if (box.width > 0 && box.height > 0 && (Math.abs(box.width - this.width) > 1 || Math.abs(box.height - this.height) > 1)) {
                this.width = box.width;
                this.height = box.height;
                if (this._fitted) {
                    return;
                }
            }
        }
        const areaKey = `${this.centerLatitude}|${this.centerLongitude}|${this.reachMiles}`;
        if (this.hasArea && (areaKey !== this._areaKey || !this._fitted)) {
            this._areaKey = areaKey;
            this._fitted = Boolean(frame);
            this.fit();
        }
    }

    get hasArea() {
        return Number.isFinite(this.centerLatitude) && Number.isFinite(this.centerLongitude) && Number.isFinite(this.reachMiles);
    }

    /** Shows the whole area, centered. */
    fit() {
        this.zoom = zoomToFit(this.reachMiles, this.centerLatitude, this.width, this.height);
        const middle = worldPoint(this.centerLatitude, this.centerLongitude, this.zoom);
        this.middleX = middle.x;
        this.middleY = middle.y;
    }

    get isReady() {
        return this.hasArea && this.zoom !== undefined;
    }

    get left() {
        return this.middleX - this.width / 2;
    }

    get top() {
        return this.middleY - this.height / 2;
    }

    get tiles() {
        return this.isReady ? tilesFor(this.left, this.top, this.width, this.height, this.zoom) : [];
    }

    get viewBox() {
        return `0 0 ${Math.round(this.width)} ${Math.round(this.height)}`;
    }

    /** The area as a circle on the frame, when it is one. */
    get circle() {
        if (!this.isReady || this._points.length >= 3 || !Number.isFinite(this.radiusMiles)) {
            return undefined;
        }
        const center = worldPoint(this.centerLatitude, this.centerLongitude, this.zoom);
        return {
            x: center.x - this.left,
            y: center.y - this.top,
            radius: this.radiusMiles / milesPerPixel(this.centerLatitude, this.zoom)
        };
    }

    /** The area as an outline on the frame, when it is one. */
    get outline() {
        if (!this.isReady || this._points.length < 3) {
            return undefined;
        }
        return this._points
            .map((point) => {
                const spot = worldPoint(point[0], point[1], this.zoom);
                return `${(spot.x - this.left).toFixed(1)},${(spot.y - this.top).toFixed(1)}`;
            })
            .join(' ');
    }

    /** One marker for each location in view. Inside ones are drawn last so they sit on top. */
    get pins() {
        if (!this.isReady) {
            return [];
        }
        const pins = [];
        for (const place of this._places) {
            const spot = worldPoint(place.latitude, place.longitude, this.zoom);
            const x = spot.x - this.left;
            const y = spot.y - this.top;
            if (x < -16 || y < -16 || x > this.width + 16 || y > this.height + 16) {
                continue;
            }
            const kind = KINDS[place.kind] ?? KINDS.Workplace;
            const isSelected = place.key === this.selectedKey;
            pins.push({
                key: place.key,
                icon: kind.icon,
                inside: place.inside,
                label: `${kind.word}: ${place.name}, ${place.what}${place.inside ? '' : ', just outside the area'}`,
                name: place.name,
                isSelected,
                pressed: isSelected ? 'true' : 'false',
                className: `c-pin c-pin_${kind.shape} ${place.inside ? 'c-pin_inside' : 'c-pin_near'}${isSelected ? ' c-pin_chosen' : ''}`,
                style: `left: ${x.toFixed(1)}px; top: ${y.toFixed(1)}px`
            });
        }
        return pins.sort((first, second) => Number(first.isSelected) - Number(second.isSelected) || Number(first.inside) - Number(second.inside));
    }

    get legend() {
        const present = new Set(this._places.map((place) => place.kind));
        return Object.keys(KINDS)
            .filter((kind) => present.has(kind))
            .map((kind) => ({ kind, word: KINDS[kind].word, icon: KINDS[kind].icon, className: `c-pin c-pin_key c-pin_inside c-pin_${KINDS[kind].shape}` }));
    }

    get hasNearby() {
        return this._places.some((place) => !place.inside);
    }

    get cannotZoomIn() {
        return !this.isReady || this.zoom >= MAX_ZOOM;
    }

    get cannotZoomOut() {
        return !this.isReady || this.zoom <= MIN_ZOOM;
    }

    get surfaceClass() {
        return `c-map__surface${this.drag?.moved ? ' c-map__surface_dragging' : ''}`;
    }

    /** Changes the zoom level, keeping the same spot in the middle of the frame. */
    zoomTo(level) {
        const next = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, level));
        if (!this.isReady || next === this.zoom) {
            return;
        }
        const middle = placeAt(this.middleX, this.middleY, this.zoom);
        this.zoom = next;
        const point = worldPoint(middle.latitude, middle.longitude, next);
        this.middleX = point.x;
        this.middleY = point.y;
    }

    handleZoomIn() {
        this.zoomTo(this.zoom + 1);
    }

    handleZoomOut() {
        this.zoomTo(this.zoom - 1);
    }

    handleFit() {
        if (this.hasArea) {
            this.fit();
        }
    }

    handleKey(event) {
        if (!this.isReady) {
            return;
        }
        const moves = { ArrowLeft: [-KEY_STEP, 0], ArrowRight: [KEY_STEP, 0], ArrowUp: [0, -KEY_STEP], ArrowDown: [0, KEY_STEP] };
        if (moves[event.key]) {
            this.middleX += moves[event.key][0];
            this.middleY += moves[event.key][1];
        } else if (event.key === '+' || event.key === '=') {
            this.zoomTo(this.zoom + 1);
        } else if (event.key === '-' || event.key === '_') {
            this.zoomTo(this.zoom - 1);
        } else if (event.key === '0') {
            this.fit();
        } else {
            return;
        }
        event.preventDefault();
    }

    handlePointerDown(event) {
        if (!this.isReady || event.button > 0) {
            return;
        }
        this.drag = { x: event.clientX, y: event.clientY, middleX: this.middleX, middleY: this.middleY, moved: false };
    }

    handlePointerMove(event) {
        if (!this.drag) {
            return;
        }
        const acrossX = event.clientX - this.drag.x;
        const acrossY = event.clientY - this.drag.y;
        if (!this.drag.moved && Math.abs(acrossX) < DRAG_SLACK && Math.abs(acrossY) < DRAG_SLACK) {
            return;
        }
        if (!this.drag.moved) {
            this.drag = { ...this.drag, moved: true };
            event.currentTarget.setPointerCapture?.(event.pointerId);
        }
        this.middleX = this.drag.middleX - acrossX;
        this.middleY = this.drag.middleY - acrossY;
    }

    handlePointerUp(event) {
        if (this.drag?.moved) {
            event.currentTarget.releasePointerCapture?.(event.pointerId);
            // The click that ends a drag must not choose the marker under it.
            this._justDragged = true;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this._justDragged = false;
            }, 0);
        }
        this.drag = undefined;
    }

    handleDoubleClick(event) {
        if (!this.isReady) {
            return;
        }
        const frame = this.template.querySelector('.c-map__frame').getBoundingClientRect();
        const spot = placeAt(this.left + event.clientX - frame.left, this.top + event.clientY - frame.top, this.zoom);
        const next = Math.min(MAX_ZOOM, this.zoom + 1);
        const point = worldPoint(spot.latitude, spot.longitude, next);
        this.zoom = next;
        this.middleX = point.x;
        this.middleY = point.y;
    }

    handlePin(event) {
        event.stopPropagation();
        if (this._justDragged) {
            return;
        }
        this.dispatchEvent(new CustomEvent('placeselect', { detail: { key: event.currentTarget.dataset.key } }));
    }

    /** A press on a marker starts no drag, so a click on it is always a choice. */
    handlePinDown(event) {
        event.stopPropagation();
    }
}
