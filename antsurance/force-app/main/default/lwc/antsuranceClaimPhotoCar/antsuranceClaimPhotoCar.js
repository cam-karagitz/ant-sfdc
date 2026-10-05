import { LightningElement, api } from 'lwc';

// The panels of a car seen from above, front at the top, as rectangles in a 120 by 260 drawing.
// Left on the page is the driver's side.
const PANELS = [
    { key: 'front_bumper', label: 'Front bumper', x: 22, y: 4, width: 76, height: 14, radius: 7 },
    { key: 'hood', label: 'Hood', x: 26, y: 21, width: 68, height: 44, radius: 4 },
    { key: 'front_left_fender', label: 'Left front fender', x: 8, y: 21, width: 15, height: 44, radius: 4 },
    { key: 'front_right_fender', label: 'Right front fender', x: 97, y: 21, width: 15, height: 44, radius: 4 },
    { key: 'windshield', label: 'Windshield', x: 30, y: 68, width: 60, height: 20, radius: 4 },
    { key: 'front_left_door', label: 'Left front door', x: 8, y: 68, width: 19, height: 44, radius: 4 },
    { key: 'front_right_door', label: 'Right front door', x: 93, y: 68, width: 19, height: 44, radius: 4 },
    { key: 'roof', label: 'Roof', x: 30, y: 91, width: 60, height: 64, radius: 4 },
    { key: 'rear_left_door', label: 'Left rear door', x: 8, y: 115, width: 19, height: 44, radius: 4 },
    { key: 'rear_right_door', label: 'Right rear door', x: 93, y: 115, width: 19, height: 44, radius: 4 },
    { key: 'rear_window', label: 'Rear window', x: 30, y: 158, width: 60, height: 18, radius: 4 },
    { key: 'rear_left_quarter', label: 'Left rear quarter', x: 8, y: 162, width: 15, height: 60, radius: 4 },
    { key: 'rear_right_quarter', label: 'Right rear quarter', x: 97, y: 162, width: 15, height: 60, radius: 4 },
    { key: 'trunk', label: 'Trunk', x: 26, y: 179, width: 68, height: 43, radius: 4 },
    { key: 'rear_bumper', label: 'Rear bumper', x: 22, y: 225, width: 76, height: 14, radius: 7 }
];
const SEVERITY_WORD = { minor: 'minor', moderate: 'moderate', severe: 'severe' };

/**
 * A car from above with its damaged panels tinted: sand for minor, amber for moderate, deep clay for
 * severe. It says in words what it shows, for people who cannot see the colours.
 */
export default class AntsuranceClaimPhotoCar extends LightningElement {
    /** The worst severity seen on each panel, as { panel key: 'minor' | 'moderate' | 'severe' }. */
    @api panels = {};

    get shapes() {
        return PANELS.map((panel) => {
            const severity = SEVERITY_WORD[this.panels?.[panel.key]];
            return { ...panel, className: severity ? `c-panel c-panel_${severity}` : 'c-panel' };
        });
    }

    get description() {
        const damaged = PANELS.filter((panel) => SEVERITY_WORD[this.panels?.[panel.key]]).map((panel) => `${panel.label}, ${this.panels[panel.key]}`);
        return damaged.length ? `Damaged panels: ${damaged.join('; ')}.` : 'No damaged panels marked.';
    }
}
