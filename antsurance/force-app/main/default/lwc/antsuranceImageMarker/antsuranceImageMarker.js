import { LightningElement, api } from 'lwc';

// A box narrower or shorter than this share of the image is noise, not an area.
const MIN_SIDE = 0.02;
// Arrow keys move or resize a box by this share of the image; with Alt, by the fine step.
const KEY_STEP = 0.01;
const FINE_STEP = 0.0025;
// A new box added from the keyboard starts this size, in the middle of the image.
const STARTER = { x: 0.375, y: 0.375, width: 0.25, height: 0.25 };
const HANDLES = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];
const ARROWS = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
const PERCENT = 100;
const CROP_PAD = 0.12;
const CROP_ATTEMPTS = 6;
const BASE64_RATIO = 0.75;
// A box's number or letter is a disc this many pixels across, kept this far from the next one, inside a box border this thick.
const TAG_PX = 20;
const TAG_GAP_PX = 4;
const BOX_BORDER_PX = 2;
const TAG_TRIES = 12;
const MEASURE_EVERY_MS = 1000;

const round = (value) => Math.round(value * 1000) / 1000;
const clamp = (value, low, high) => Math.min(Math.max(value, low), high);
const percent = (value) => `${Math.round(value * PERCENT)}%`;

/**
 * Keeps a box inside the image and no smaller than the smallest box worth drawing.
 * @param {{x: number, y: number, width: number, height: number}} box Fractions of the image from the top left
 * @returns {{x: number, y: number, width: number, height: number}} The same box, tidied, to three places
 */
export function tidyBox(box) {
    const width = clamp(box.width, MIN_SIDE, 1);
    const height = clamp(box.height, MIN_SIDE, 1);
    return { x: round(clamp(box.x, 0, 1 - width)), y: round(clamp(box.y, 0, 1 - height)), width: round(width), height: round(height) };
}

/**
 * Cuts one area out of an image as a JPEG, with a little of its surroundings, small enough to send.
 * The image must be one the page may read the pixels of (a data: or blob: address, or same origin).
 * @param {HTMLImageElement} image A loaded image
 * @param {{x: number, y: number, width: number, height: number}} box The area, as fractions of the image
 * @param {{maxEdge?: number, maxBytes?: number}} [limits] The longest side in pixels and the largest size in bytes
 * @returns {string} The crop, base64 encoded, or undefined when it cannot be made small enough
 */
export function cropToJpeg(image, box, limits = {}) {
    const maxBytes = limits.maxBytes ?? 90000;
    let edge = limits.maxEdge ?? 640;
    let quality = 0.82;
    const padX = box.width * CROP_PAD;
    const padY = box.height * CROP_PAD;
    const left = clamp(box.x - padX, 0, 1) * image.naturalWidth;
    const top = clamp(box.y - padY, 0, 1) * image.naturalHeight;
    const right = clamp(box.x + box.width + padX, 0, 1) * image.naturalWidth;
    const bottom = clamp(box.y + box.height + padY, 0, 1) * image.naturalHeight;
    const width = Math.max(1, right - left);
    const height = Math.max(1, bottom - top);
    for (let attempt = 0; attempt < CROP_ATTEMPTS; attempt++) {
        // A small area is drawn larger, up to twice its size, so fine detail is not lost to the encoder.
        const scale = Math.min(2, edge / Math.max(width, height));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(width * scale));
        canvas.height = Math.max(1, Math.round(height * scale));
        const context = canvas.getContext('2d');
        context.fillStyle = '#fff';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.drawImage(image, left, top, width, height, 0, 0, canvas.width, canvas.height);
        const data = canvas.toDataURL('image/jpeg', quality).split(',')[1];
        if (data.length * BASE64_RATIO <= maxBytes) {
            return data;
        }
        // Give up some quality first, then some size.
        if (quality > 0.62) {
            quality -= 0.1;
        } else {
            edge = Math.round(edge * 0.8);
        }
    }
    return undefined;
}

/**
 * An image with boxes over it that a person can draw, move, resize and remove.
 *
 * It knows nothing about what the boxes mean. Give it an image address and a list of boxes; it draws
 * them and, when `editing` is on, raises an event for each thing the person does. The parent owns
 * the list: it applies the change and passes the new list back.
 *
 * A box is `{ id, x, y, width, height, tag, tone, kind, label, editable }`. x, y, width and height
 * are fractions of the image from the top left. `tag` is the short text in the box's corner (a number
 * or a letter). `tone` picks the line colour: minor, moderate, severe or mark. `kind` is `person` for
 * a dashed box with a square tag; anything else is a solid box with a round tag. `label` is read out
 * to a screen reader. `editable` false keeps a box still even while editing.
 *
 * With `selectable` on, a box can also be chosen while not editing: by a click, or by Tab and the
 * keyboard's focus. The chosen box is ringed and the others step back, so a list beside the image
 * can point at one box. `highlightId` does the same more lightly, for a hover.
 *
 * Events, all with `detail`:
 * - `boxadd` `{ box }`: the person drew a box, or added one from the keyboard with `addBox()`.
 * - `boxchange` `{ id, box }`: the person moved or resized a box. Raised once when a drag ends and
 *   once for each key press.
 * - `boxremove` `{ id }`: Delete or Backspace on a box.
 * - `boxselect` `{ id }`: a box was chosen, or `id` undefined when nothing is.
 * - `boxopen` `{ id }`: Enter on a box, for a parent that wants to move to its details.
 * - `boxhover` `{ id }`: the pointer is over a box, or `id` undefined when it has left.
 * - `imageload` `{ width, height }`: the image's own size in pixels, once it has loaded.
 *
 * Mouse and touch: drag on the image to draw; drag a box to move it; drag a corner or an edge to
 * resize it. Keyboard: Tab to a box, arrow keys move it, Shift with arrow keys resizes it, Alt makes
 * either step finer, Delete removes it, Escape lets go of it.
 */
export default class AntsuranceImageMarker extends LightningElement {
    /** The image's address. */
    @api src;
    // The address of the picture that has finished loading; boxes wait for it.
    loadedSrc;
    /** What the image shows, for a screen reader. */
    @api alt = '';
    /** True to let the person move, resize and remove the boxes marked editable. */
    @api editing = false;
    /** True to let the person draw new boxes while editing. */
    @api drawing = false;
    /** How the box being drawn looks: `person` (dashed) unless told otherwise. */
    @api drawKind = 'person';
    /** True to let a box be chosen, by pointer or keyboard, while not editing. */
    @api selectable = false;
    /** A box to bring forward lightly, for example while its row in a list is hovered. */
    @api highlightId;

    given = [];
    chosen;
    // How large the picture is drawn, in pixels: where each box's number goes depends on it.
    frameSize;
    // The box under the pointer or the keys right now, shown in place of the one the parent gave.
    live;
    draft;
    drag;
    announcement = '';

    /** The boxes to draw. */
    @api
    get boxes() {
        return this.given;
    }
    set boxes(value) {
        this.given = Array.isArray(value) ? value : [];
        // The parent has answered the last change, so its list is the truth again.
        if (!this.drag) {
            this.live = undefined;
        }
        if (this.chosen && !this.given.some((box) => box.id === this.chosen)) {
            this.chosen = undefined;
        }
    }

    /** The chosen box's id. Set it to choose a box from outside, for example from a list beside the image. */
    @api
    get selectedId() {
        return this.chosen;
    }
    set selectedId(value) {
        this.chosen = value;
    }

    /** The image's own size in pixels, once it has loaded. */
    @api
    get naturalSize() {
        const image = this.refs.image;
        return image?.naturalWidth ? { width: image.naturalWidth, height: image.naturalHeight } : undefined;
    }

    /**
     * Adds a box in the middle of the image, for someone who cannot drag. Raises `boxadd`; the parent
     * adds it and can then call `focusBox` with its id.
     */
    @api
    addBox() {
        this.dispatchEvent(new CustomEvent('boxadd', { detail: { box: { ...STARTER } } }));
    }

    /** Puts the keyboard on a box. */
    @api
    focusBox(id) {
        this.chosen = id;
        // Wait for the box to be drawn: it may have been added in this same turn. A timer, not the
        // next frame: a tab that is not in front draws no frames.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.template.querySelector(`[data-id="${id}"]`)?.focus();
        }, 0);
    }

    get isEditing() {
        return this.editing === true || this.editing === 'true';
    }

    get canDraw() {
        return this.isEditing && (this.drawing === true || this.drawing === 'true');
    }

    get canChoose() {
        return this.isEditing || this.selectable === true || this.selectable === 'true';
    }

    get frameClass() {
        const has = (id) => id !== undefined && this.given.some((box) => box.id === id);
        return [
            'c-marker',
            this.isEditing ? 'c-marker_editing' : '',
            this.canDraw ? 'c-marker_drawing' : '',
            this.drag ? 'c-marker_dragging' : '',
            // Until the picture arrives the frame holds its place, so the card does not jump and no box is drawn on nothing.
            this.isLoaded ? '' : 'c-marker_loading',
            // One box is pointed at, so the others step back.
            !this.isEditing && has(this.chosen) ? 'c-marker_chosen' : '',
            !this.isEditing && has(this.highlightId) ? 'c-marker_lit' : ''
        ]
            .filter(Boolean)
            .join(' ');
    }

    /** True once the picture now asked for has arrived. */
    get isLoaded() {
        return Boolean(this.src) && this.loadedSrc === this.src;
    }

    renderedCallback() {
        // After every draw, so the numbers are placed by the picture's real size the moment it has one.
        // It changes nothing unless the size has changed, so it cannot draw in a loop.
        this.measureFrame();
        if (this.remeasure) {
            return;
        }
        // The frame is also measured whenever its size may have changed. A tab that is
        // not in front draws no frames, so an observer alone can miss a change: the window's resize and
        // a slow timer measure it as well.
        this.remeasure = () => this.measureFrame();
        if (typeof ResizeObserver !== 'undefined') {
            this.watcher = new ResizeObserver(this.remeasure);
            this.watcher.observe(this.refs.frame);
        }
        window.addEventListener('resize', this.remeasure);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setInterval(this.remeasure, MEASURE_EVERY_MS);
    }

    disconnectedCallback() {
        this.watcher?.disconnect();
        this.watcher = undefined;
        window.removeEventListener('resize', this.remeasure);
        clearInterval(this.timer);
        this.remeasure = undefined;
    }

    measureFrame() {
        const rect = this.refs.frame?.getBoundingClientRect();
        // Hidden, or not laid out yet: keep what was last known.
        if (!rect || rect.width === 0 || rect.height === 0) {
            return;
        }
        const known = this.frameSize;
        if (!known || Math.abs(known.width - rect.width) > 1 || Math.abs(known.height - rect.height) > 1) {
            this.frameSize = { width: rect.width, height: rect.height };
        }
    }

    /**
     * Where each box's number sits, as a style for its tag, by box id. A number belongs on its box's
     * top left corner. It is kept whole inside the picture, so a box against an edge does not hang its
     * number off it, and when two boxes start at the same corner the later number steps along its
     * box's top edge (then down its side) until it is clear, so every number can be seen and reached.
     */
    tagStyles(boxes) {
        const styles = new Map();
        const size = this.frameSize;
        if (!size) {
            return styles;
        }
        const half = TAG_PX / 2;
        const apart = TAG_PX + TAG_GAP_PX;
        const placed = [];
        boxes.forEach(({ id, box }) => {
            const left = box.x * size.width;
            const top = box.y * size.height;
            const startX = clamp(left, half, size.width - half);
            let x = startX;
            let y = clamp(top, half, size.height - half);
            const rightmost = Math.min(size.width - half, (box.x + box.width) * size.width);
            const collides = () => placed.some((other) => Math.abs(other.x - x) < apart && Math.abs(other.y - y) < apart);
            for (let tries = 0; tries < TAG_TRIES && collides(); tries++) {
                if (x + apart <= rightmost) {
                    x += apart;
                } else {
                    x = startX;
                    y = Math.min(size.height - half, y + apart);
                }
            }
            placed.push({ x, y });
            styles.set(id, `left:${(x - left - half - BOX_BORDER_PX).toFixed(1)}px;top:${(y - top - half - BOX_BORDER_PX).toFixed(1)}px`);
        });
        return styles;
    }

    get shapes() {
        if (!this.isLoaded) {
            return [];
        }
        const drawn = this.given.map((given) => ({ id: given.id, box: this.live?.id === given.id ? this.live.box : given }));
        const tagStyles = this.tagStyles(drawn);
        return this.given.map((given) => {
            const box = this.live?.id === given.id ? this.live.box : given;
            const editable = this.isEditing && given.editable !== false;
            const reachable = editable || (!this.isEditing && this.canChoose);
            const selected = reachable && given.id === this.chosen;
            const person = given.kind === 'person';
            let role = 'img';
            if (editable) {
                role = 'group';
            } else if (reachable) {
                role = 'button';
            }
            return {
                id: given.id,
                tag: given.tag,
                label: editable ? `${given.label}. Arrow keys move it, Shift with arrow keys resizes it, Delete removes it.` : given.label,
                role,
                tabindex: reachable ? '0' : undefined,
                pressed: role === 'button' ? String(selected) : undefined,
                className: [
                    'c-marker__box',
                    `c-marker__box_${given.tone ?? 'mark'}`,
                    person ? 'c-marker__box_person' : '',
                    editable ? 'c-marker__box_editable' : '',
                    reachable && !editable ? 'c-marker__box_choosable' : '',
                    selected ? 'c-marker__box_selected' : '',
                    selected && editable ? 'c-marker__box_handles' : '',
                    given.id === this.highlightId ? 'c-marker__box_lit' : ''
                ]
                    .filter(Boolean)
                    .join(' '),
                tagClass: ['c-marker__tag', `c-marker__tag_${given.tone ?? 'mark'}`, person ? 'c-marker__tag_person' : ''].filter(Boolean).join(' '),
                style: this.styleFor(box),
                // A box with handles on it carries its tag above the corner, clear of them: the stylesheet places that one.
                tagStyle: selected && editable ? undefined : tagStyles.get(given.id),
                handles: selected && editable ? HANDLES.map((handle) => ({ handle, className: `c-marker__handle c-marker__handle_${handle}` })) : undefined
            };
        });
    }

    get draftClass() {
        return this.drawKind === 'person' ? 'c-marker__box c-marker__box_mark c-marker__box_person c-marker__box_draft' : 'c-marker__box c-marker__box_draft';
    }

    get draftStyle() {
        return this.draft ? this.styleFor(this.draft) : undefined;
    }

    styleFor(box) {
        return `left:${box.x * PERCENT}%;top:${box.y * PERCENT}%;width:${box.width * PERCENT}%;height:${box.height * PERCENT}%`;
    }

    boxFor(id) {
        const given = this.given.find((box) => box.id === id);
        if (!given) {
            return undefined;
        }
        const box = this.live?.id === id ? this.live.box : given;
        return { x: box.x, y: box.y, width: box.width, height: box.height };
    }

    /** Where the pointer is, as fractions of the image. */
    pointFor(event) {
        const rect = this.refs.frame.getBoundingClientRect();
        return {
            x: clamp((event.clientX - rect.left) / rect.width, 0, 1),
            y: clamp((event.clientY - rect.top) / rect.height, 0, 1)
        };
    }

    choose(id) {
        if (this.chosen !== id) {
            this.chosen = id;
            this.dispatchEvent(new CustomEvent('boxselect', { detail: { id } }));
        }
    }

    handlePointerDown(event) {
        if (!this.isEditing || this.drag || (event.pointerType === 'mouse' && event.button !== 0)) {
            return;
        }
        const point = this.pointFor(event);
        const handle = event.target.dataset?.handle;
        // Only a box of this marker counts: whatever holds the marker may carry a data-id of its own.
        const boxElement = event.target.closest?.('.c-marker__box');
        const id = boxElement?.dataset.id;
        const given = id === undefined ? undefined : this.given.find((box) => box.id === id);
        const editable = Boolean(given) && given.editable !== false;
        if (editable) {
            this.choose(id);
            this.drag = { kind: handle ? 'resize' : 'move', handle, id, start: point, origin: this.boxFor(id), moved: false };
        } else if (this.canDraw) {
            this.choose(undefined);
            this.drag = { kind: 'draw', start: point, moved: false };
        } else {
            return;
        }
        // The frame keeps the pointer, so a drag that leaves the image still ends here.
        this.refs.frame.setPointerCapture?.(event.pointerId);
        event.preventDefault();
        if (editable) {
            boxElement.focus({ preventScroll: true });
        }
    }

    handlePointerMove(event) {
        if (!this.drag) {
            return;
        }
        const point = this.pointFor(event);
        const drag = this.drag;
        const dx = point.x - drag.start.x;
        const dy = point.y - drag.start.y;
        if (!drag.moved && Math.abs(dx) < 0.004 && Math.abs(dy) < 0.004) {
            return;
        }
        drag.moved = true;
        if (drag.kind === 'draw') {
            this.draft = {
                x: Math.min(drag.start.x, point.x),
                y: Math.min(drag.start.y, point.y),
                width: Math.abs(dx),
                height: Math.abs(dy)
            };
        } else if (drag.kind === 'move') {
            const origin = drag.origin;
            this.live = {
                id: drag.id,
                box: { ...origin, x: clamp(origin.x + dx, 0, 1 - origin.width), y: clamp(origin.y + dy, 0, 1 - origin.height) }
            };
        } else {
            this.live = { id: drag.id, box: this.resized(drag.origin, drag.handle, dx, dy) };
        }
    }

    /** A box with one corner or edge dragged, the opposite side held where it was. */
    resized(origin, handle, dx, dy) {
        let left = origin.x;
        let top = origin.y;
        let right = origin.x + origin.width;
        let bottom = origin.y + origin.height;
        if (handle.includes('w')) {
            left = clamp(left + dx, 0, right - MIN_SIDE);
        }
        if (handle.includes('e')) {
            right = clamp(right + dx, left + MIN_SIDE, 1);
        }
        if (handle.includes('n')) {
            top = clamp(top + dy, 0, bottom - MIN_SIDE);
        }
        if (handle.includes('s')) {
            bottom = clamp(bottom + dy, top + MIN_SIDE, 1);
        }
        return { x: left, y: top, width: right - left, height: bottom - top };
    }

    handlePointerUp(event) {
        const drag = this.drag;
        if (!drag) {
            return;
        }
        this.drag = undefined;
        this.refs.frame.releasePointerCapture?.(event.pointerId);
        if (drag.kind === 'draw') {
            const draft = this.draft;
            this.draft = undefined;
            // A click or a sliver is not a box.
            if (drag.moved && draft && draft.width >= MIN_SIDE && draft.height >= MIN_SIDE) {
                this.dispatchEvent(new CustomEvent('boxadd', { detail: { box: tidyBox(draft) } }));
            }
            return;
        }
        if (drag.moved && this.live?.id === drag.id) {
            this.live = { id: drag.id, box: tidyBox(this.live.box) };
            this.dispatchEvent(new CustomEvent('boxchange', { detail: { id: drag.id, box: this.live.box } }));
        }
    }

    handlePointerCancel(event) {
        if (this.drag) {
            this.refs.frame.releasePointerCapture?.(event.pointerId);
            this.drag = undefined;
            this.draft = undefined;
            this.live = undefined;
        }
    }

    handleFocus(event) {
        if (this.canChoose) {
            this.choose(event.currentTarget.dataset.id);
        }
    }

    /** While not editing, a click on a box chooses it and a click on the bare image lets go of it. */
    handleClick(event) {
        if (this.isEditing || !this.canChoose) {
            return;
        }
        this.choose(event.target.closest?.('.c-marker__box')?.dataset.id);
    }

    handleEnter(event) {
        this.dispatchEvent(new CustomEvent('boxhover', { detail: { id: event.currentTarget.dataset.id } }));
    }

    handleLeave() {
        this.dispatchEvent(new CustomEvent('boxhover', { detail: { id: undefined } }));
    }

    handleImageLoad(event) {
        this.loadedSrc = this.src;
        // The frame takes the picture's shape once this render is done.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this.measureFrame(), 0);
        this.dispatchEvent(new CustomEvent('imageload', { detail: { width: event.target.naturalWidth, height: event.target.naturalHeight } }));
    }

    handleKeyDown(event) {
        const id = event.currentTarget.dataset.id;
        const given = this.given.find((box) => box.id === id);
        if (!given) {
            return;
        }
        if (!this.isEditing || given.editable === false) {
            // Not editing: Enter or Space goes to the box's details, Escape lets go of it, and the
            // arrow keys are left for whatever the image sits in.
            if (this.canChoose && (event.key === 'Enter' || event.key === ' ')) {
                event.preventDefault();
                event.stopPropagation();
                this.choose(id);
                this.dispatchEvent(new CustomEvent('boxopen', { detail: { id } }));
            } else if (this.canChoose && event.key === 'Escape') {
                this.choose(undefined);
            }
            return;
        }
        if (event.key === 'Delete' || event.key === 'Backspace') {
            event.preventDefault();
            event.stopPropagation();
            this.dispatchEvent(new CustomEvent('boxremove', { detail: { id } }));
            return;
        }
        if (event.key === 'Escape') {
            event.currentTarget.blur();
            this.choose(undefined);
            return;
        }
        if (event.key === 'Enter') {
            event.preventDefault();
            event.stopPropagation();
            this.dispatchEvent(new CustomEvent('boxopen', { detail: { id } }));
            return;
        }
        const arrow = ARROWS[event.key];
        if (!arrow) {
            return;
        }
        // The arrow keys belong to the box while it has the keyboard, not to the page's scrolling or to
        // a carousel the image sits in.
        event.preventDefault();
        event.stopPropagation();
        const step = event.altKey ? FINE_STEP : KEY_STEP;
        const box = this.boxFor(id);
        const next = event.shiftKey
            ? {
                  ...box,
                  width: clamp(box.width + arrow[0] * step, MIN_SIDE, 1 - box.x),
                  height: clamp(box.height + arrow[1] * step, MIN_SIDE, 1 - box.y)
              }
            : { ...box, x: clamp(box.x + arrow[0] * step, 0, 1 - box.width), y: clamp(box.y + arrow[1] * step, 0, 1 - box.height) };
        const tidy = tidyBox(next);
        this.live = { id, box: tidy };
        this.announcement = `${given.tag ? `Box ${given.tag}` : 'Box'}: ${percent(tidy.x)} from the left, ${percent(tidy.y)} from the top, ${percent(tidy.width)} wide, ${percent(tidy.height)} high.`;
        this.dispatchEvent(new CustomEvent('boxchange', { detail: { id, box: tidy } }));
    }
}
