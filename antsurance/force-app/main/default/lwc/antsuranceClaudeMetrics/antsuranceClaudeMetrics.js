import { LightningElement, api } from 'lwc';

// In the panel, up to this many figures are rows; four make a two-by-two grid.
const MAX_ROWS = 3;

/** One to four headline figures as tiles. In the utility panel they are rows or a tight grid. */
export default class AntsuranceClaudeMetrics extends LightningElement {
    /** { tiles: [{ label, value, note, tone }] } */
    @api spec;
    /** True in the utility bar panel. */
    @api compact = false;

    get tiles() {
        return (this.spec?.tiles ?? []).map((tile, index) => ({
            ...tile,
            key: `tile-${index}`,
            className: `c-tile c-tile_${tile.tone}`,
            miniClassName: `c-figure c-figure_${tile.tone}`
        }));
    }

    get gridClass() {
        return `c-tiles c-tiles_${this.tiles.length}`;
    }

    get miniClass() {
        return this.tiles.length > MAX_ROWS ? 'c-figures c-figures_grid' : 'c-figures';
    }

    handleExpand() {
        this.dispatchEvent(new CustomEvent('blockexpand', { bubbles: true }));
    }
}
