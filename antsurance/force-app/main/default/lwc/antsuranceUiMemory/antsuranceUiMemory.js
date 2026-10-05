/**
 * Remembers where a person was in a component (which tab, which page of a list, what was open) for as
 * long as the browser session lasts, so coming back to a record puts them where they left off.
 *
 *   import { recall, remember } from 'c/antsuranceUiMemory';
 *   this.tab = recall(`${this.recordId}:analysis-tab`, 'summary');
 *   remember(`${this.recordId}:analysis-tab`, this.tab);
 *
 * Values are small and plain (a string, a number, a boolean). Nothing here is saved to Salesforce.
 */

const PREFIX = 'antsurance-ui:';
// Used when the browser refuses session storage, so a page still remembers within one visit.
const held = new Map();

/**
 * @param {string} key What is being remembered, usually the record id and a name
 * @param {*} otherwise What to answer when nothing was remembered
 * @returns {*} The remembered value, or `otherwise`
 */
export function recall(key, otherwise) {
    try {
        const stored = window.sessionStorage.getItem(PREFIX + key);
        if (stored !== null) {
            return JSON.parse(stored);
        }
    } catch (error) {
        // Fall through to what this page has held.
    }
    return held.has(key) ? held.get(key) : otherwise;
}

/**
 * @param {string} key What is being remembered
 * @param {*} value A string, number or boolean
 */
export function remember(key, value) {
    held.set(key, value);
    try {
        window.sessionStorage.setItem(PREFIX + key, JSON.stringify(value));
    } catch (error) {
        // The copy in memory is enough for this visit.
    }
}

/**
 * The rows of one page of a list, for use with c-antsurance-step-pager.
 * @param {Array} rows Every row
 * @param {number} page The page, counted from 0
 * @param {number} pageSize Rows on a page
 * @returns {Array} The rows on that page; the last page when `page` is past the end
 */
export function pageOf(rows, page, pageSize) {
    const list = rows ?? [];
    const size = Math.max(1, Number(pageSize) || 1);
    const last = Math.max(0, Math.ceil(list.length / size) - 1);
    const at = Math.min(Math.max(0, Number(page) || 0), last);
    return list.slice(at * size, at * size + size);
}
