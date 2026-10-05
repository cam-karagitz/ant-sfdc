const MONTHS = 'Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec';

/**
 * Keeps a date ("May 15, 2027"), an amount with what it counts ("$76 a year") and a policy number
 * ("ANT-HO-204534") in one piece, so none is split across two lines.
 * @param {string} text A paragraph
 * @returns {string} The same paragraph with those pieces tied by non-breaking spaces
 */
export function keepFiguresTogether(text) {
    if (!text) {
        return text;
    }
    return text
        .replace(new RegExp(`\\b(${MONTHS}) (\\d{1,2}),? (\\d{4})`, 'g'), '$1\u00A0$2,\u00A0$3')
        .replace(new RegExp(`\\b(${MONTHS}) (\\d{1,2})\\b(?!,?\u00A0)`, 'g'), '$1\u00A0$2')
        .replace(/([+-]?\$[\d,]+(?:\.\d\d)?) a (year|month)\b/g, '$1\u00A0a\u00A0$2')
        .replace(/\b([A-Z]{2,4})-([A-Z]{2,3})-(\d{4,})\b/g, '$1\u2011$2\u2011$3');
}

/**
 * Keeps the last two words of a paragraph on one line. Text in the portal fills its measure and wraps where
 * it falls, but never ends on a single stranded word. Only two words are tied: tying three left the line
 * before the last visibly short. Dates and amounts are kept whole as well.
 * @param {string} text A paragraph
 * @returns {string} The same paragraph with its last two words tied by a non-breaking space
 */
export function keepLastWordsTogether(text) {
    if (!text) {
        return text;
    }
    const words = keepFiguresTogether(text).split(' ');
    if (words.length < 4) {
        return words.join(' ');
    }
    const tail = words.splice(-2).join('\u00A0');
    return [...words, tail].join(' ');
}

/**
 * Keeps the end of a paragraph together as a phrase: its last two words, or its last three where two would
 * still be a stub ("auto policy.", "is reported."). For text in a narrow column, such as the conversation,
 * where a two-word last line reads as a leftover.
 * @param {string} text A paragraph
 * @returns {string} The same paragraph with its last words tied by non-breaking spaces
 */
export function keepEndTogether(text) {
    if (!text) {
        return text;
    }
    const words = keepFiguresTogether(text).split(' ');
    if (words.length < 5) {
        return words.join(' ');
    }
    const count = words.slice(-2).join(' ').length < 16 ? 3 : 2;
    const tail = words.splice(-count).join('\u00A0');
    return [...words, tail].join(' ');
}

/**
 * Whether a paragraph, as it is drawn now, ends on a short last line: more than one line, with the last one
 * under a third of the paragraph's width. Used to tie the last words only where the wrap needs it, so every
 * other line still fills its measure.
 * @param {HTMLElement} element A drawn paragraph holding plain text
 * @returns {boolean} True when the last line is short
 */
export function endsOnShortLine(element) {
    const width = element.clientWidth;
    if (!width || !element.firstChild) {
        return false;
    }
    const range = document.createRange();
    range.selectNodeContents(element);
    const lines = new Map();
    Array.from(range.getClientRects()).forEach((rect) => {
        const top = Math.round(rect.top);
        lines.set(top, (lines.get(top) ?? 0) + rect.width);
    });
    if (lines.size < 2) {
        return false;
    }
    const last = lines.get(Math.max(...lines.keys()));
    return last < width * 0.33;
}
