import { loadStyle } from 'lightning/platformResourceLoader';
import FONTS from '@salesforce/resourceUrl/antsuranceFonts';

let loading;

/**
 * Loads the Antsurance display font (Poppins) once per page. Body text uses the system sans.
 * Components fall back to system fonts until, or unless, this resolves.
 * @param {LightningElement} component The component asking for the fonts
 * @returns {Promise<void>}
 */
export function loadBrandFonts(component) {
    if (!loading) {
        loading = loadStyle(component, `${FONTS}/fonts.css`).catch(() => {
            // Leave system fonts in place and allow a later retry.
            loading = undefined;
        });
    }
    return loading;
}
