/**
 * Small text helpers shared by the cards.
 *
 * keepTogether stops a line breaking inside things a reader takes in as one item: a policy number
 * at its hyphens, a street address at its spaces, a figure and its unit. It swaps in non-breaking
 * characters, so use it only for text on screen. What is copied, emailed or saved keeps the plain text.
 */

const NO_BREAK_HYPHEN = '‑';
const NO_BREAK_SPACE = ' ';

// ANT-GL-205163, ANT-HO-204653: letters, then hyphenated groups of letters and digits.
const REFERENCE = /\b[A-Z]{2,5}(?:-[A-Z0-9]{2,}){1,3}\b/g;
// 316 N Lombard Ave, 9000 Harrison Ave, 524 W Spring Ave.
const STREET =
    /\b\d{1,6} (?:[NSEW]\.? |North |South |East |West )?(?:[A-Z][A-Za-z']+ ){1,3}(?:Ave|Avenue|St|Street|Rd|Road|Dr|Drive|Ln|Lane|Blvd|Boulevard|Ct|Court|Way|Pl|Place|Pkwy|Parkway|Hwy|Highway|Ter|Terrace|Cir|Circle)\b/g;
// 3 years, 12 months, 30 days, 2 claims: a figure stays with the word that says what it counts.
const FIGURE_AND_UNIT = /(\d) (years?|months?|weeks?|days?|hours?|claims?|percent|vehicles?|drivers?|employees|policies|policy)\b/g;
// Oct 2, Sep 28, Oct 31, 2026: a month stays with its day, and the day with its year.
const MONTH_AND_DAY = /\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)([a-z]*\.?) (\d{1,2})(?:(,) (\d{4}))?\b/g;
// "on Jul 23", "by Oct 31": the word that introduces a date stays with it, so a date never opens a line on its own.
const WORD_AND_DATE = /\b(on|by|from|until|since|before|after|of|dated) (?=(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.? \d)/g;
// "of $485,000", "to $45,000", "at least $1,000,000": a short word stays with the amount it introduces.
const WORD_AND_AMOUNT = /\b(of|to|at|by|is|a|least|most|over|under|about|than) (\$\d)/g;
// "at least", "up to", "no more than": the words that qualify an amount stay with each other.
const QUALIFIER = /\b(at) (least|most)\b|\b(up) (to)(?= \$)|\b(more|less) (than)(?= \$)/g;
// Marcus Lindahl, Lakeshore Restoration, Honda Accord: two capitalized words in a row are a name, and a name stays on one line.
// Not after a sentence end, so "claim. Marcus" is left alone, and each word is short enough to fit a narrow column.
// At most three words, so a run of capitals such as a title cannot grow into a line that will not fit.
const NAME = /(?<![.!?:] )\b[A-Z][a-z']{1,11}(?: [A-Z][a-z']{2,12}){1,2}\b/g;
// multi-line, owner-occupied, third-party: a short compound word does not break at its hyphen.
const COMPOUND = /\b([A-Za-z]{2,12})-([a-z]{2,12})\b/g;

/**
 * @param {string} text Text about to be shown
 * @returns {string} The same text, unable to break inside a reference number, a street address or a figure and its unit
 */
export function keepTogether(text) {
    if (typeof text !== 'string' || !text) {
        return text;
    }
    return text
        .replace(REFERENCE, (match) => match.replace(/-/g, NO_BREAK_HYPHEN))
        .replace(STREET, (match) => match.replace(/ /g, NO_BREAK_SPACE))
        .replace(FIGURE_AND_UNIT, `$1${NO_BREAK_SPACE}$2`)
        .replace(WORD_AND_DATE, `$1${NO_BREAK_SPACE}`)
        .replace(MONTH_AND_DAY, (match, month, rest, day, comma, year) => `${month}${rest}${NO_BREAK_SPACE}${day}${year ? `${comma}${NO_BREAK_SPACE}${year}` : ''}`)
        .replace(COMPOUND, `$1${NO_BREAK_HYPHEN}$2`)
        .replace(NAME, (match) => match.replace(/ /g, NO_BREAK_SPACE))
        .replace(QUALIFIER, (match) => match.replace(' ', NO_BREAK_SPACE))
        .replace(WORD_AND_AMOUNT, `$1${NO_BREAK_SPACE}$2`);
}

/**
 * A headline in its clauses: "Halsted Street Bistro has no reserve; set that first." comes back as two
 * pieces. Draw each piece as an inline block and a headline too long for one line breaks after the
 * semicolon or the full stop, where a reader would pause, and not in the middle of a clause. A clause
 * wider than the card still wraps inside itself. Each piece has had keepTogether applied.
 * @param {string} text A headline about to be shown
 * @returns {{key: number, text: string}[]} Its clauses, in order; one piece when it has no such break
 */
export function clauses(text) {
    const kept = keepTogether(text);
    if (typeof kept !== 'string' || !kept) {
        return [];
    }
    const pieces = [];
    kept.split(/(?<=[;.!?]) +(?=\S)/).forEach((piece) => {
        // A piece of one or two words ("No.", "See below.") is not a clause to stand by itself.
        if (pieces.length > 0 && piece.split(' ').length < 3) {
            pieces[pieces.length - 1] += ` ${piece}`;
        } else {
            pieces.push(piece);
        }
    });
    return pieces.map((piece, index) => ({ key: index, text: piece }));
}

/**
 * keepTogether, and the last three words of a longer sentence stay on one line, so a paragraph in a
 * narrow column does not end on a word or a date by itself.
 * @param {string} text Text about to be shown
 * @returns {string} The same text, unable to end on a short last line
 */
export function tidyEnding(text) {
    const kept = keepTogether(text);
    if (typeof kept !== 'string') {
        return kept;
    }
    const words = kept.split(' ');
    if (words.length < 8) {
        return kept;
    }
    return `${words.slice(0, -3).join(' ')} ${words.slice(-3).join(NO_BREAK_SPACE)}`;
}
