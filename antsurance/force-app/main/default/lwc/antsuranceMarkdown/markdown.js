/**
 * A small Markdown-to-HTML renderer for chat replies.
 *
 * It covers what Claude writes in practice: paragraphs, headings, bold, italic, strikethrough,
 * inline code, fenced code, links, bullet and numbered lists (nested), tables, blockquotes and
 * horizontal rules. All source text is HTML-escaped before any tag is added, so the output only
 * ever contains the tags produced here. A paragraph that opens with a bold label gets the label
 * on a line of its own.
 *
 * Underscore emphasis (_x_, __x__) is deliberately not supported: Salesforce API names such as
 * My_Field__c would be mangled by it.
 */

const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
// Private-use characters that mark a protected span while inline formatting runs.
const HOLD_OPEN = '';
const HOLD_CLOSE = '';
const ESCAPED_PIPE = '';

const FENCE = /^\s*(```|~~~)/;
const HEADING = /^(#{1,6})\s+(.+?)\s*#*\s*$/;
const RULE = /^\s*([-*_])(?:\s*\1){2,}\s*$/;
const QUOTE = /^\s*>\s?/;
const LIST_ITEM = /^(\s*)([-*+]|(\d+)[.)])\s+(.*)$/;
const TABLE_DIVIDER_CELL = /^:?-+:?$/;
// /lightning/r/<Id>/view, /lightning/r/<Object>/<Id>/view, or /<Id>
const RECORD_PATH = /^\/(?:lightning\/r\/(?:[A-Za-z0-9_]+\/)?)?([A-Za-z0-9]{18}|[A-Za-z0-9]{15})(?:\/view)?$/;

// A paragraph that opens with a bold label, written **Label:** text or **Label**: text.
const LEAD_IN = /^<strong>([^<]{1,60}?)(:?)<\/strong>(:?)\s*([\s\S]+)$/;

/** Puts a paragraph's opening bold label on a line of its own, without its colon, and the text under it. */
function stackLeadIn(html) {
    const lead = html.match(LEAD_IN);
    if (!lead || !(lead[2] || lead[3])) {
        return html;
    }
    return `<strong class="c-md-lead">${lead[1]}</strong>${lead[4]}`;
}

const NO_BREAK_SPACE = '\u00a0';
// A sentence shorter than this many words is left alone: tied, its ending would be most of it.
const WORDS_BEFORE_TYING = 8;

/**
 * Ties the last three words of a longer line of source together, so a paragraph or a list item does
 * not end on one or two words by themselves ("are excluded."). Left alone when those words hold a
 * link or code, whose own text must not change.
 */
function tieEnding(text) {
    const words = text.split(' ');
    if (words.length < WORDS_BEFORE_TYING) {
        return text;
    }
    const ending = words.slice(-3);
    if (ending.some((word) => !word || /[`\]()|]/.test(word))) {
        return text;
    }
    return `${words.slice(0, -3).join(' ')} ${ending.join(NO_BREAK_SPACE)}`;
}

const escapeHtml = (text) => text.replace(/[&<>"']/g, (character) => HTML_ESCAPES[character]);

/** Applies inline formatting to text that has already been HTML-escaped. */
function renderInline(escaped) {
    const held = [];
    const hold = (html) => `${HOLD_OPEN}${held.push(html) - 1}${HOLD_CLOSE}`;

    let text = escaped
        // Code spans and backslash escapes come out first so nothing inside them is formatted.
        .replace(/`([^`]+)`/g, (match, code) => hold(`<code class="c-md-code">${code}</code>`))
        .replace(/\\([\\`*_{}[\]()#+\-.!|>~])/g, (match, character) => hold(character))
        .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (match, label, url) => {
            const opening = linkOpening(url);
            return opening ? `${hold(opening)}${label}${hold('</a>')}` : match;
        })
        .replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, '<strong>$1</strong>')
        .replace(/(^|[^*\w])\*(?=\S)([^*]*?\S)\*(?![*\w])/g, '$1<em>$2</em>')
        .replace(/~~(?=\S)([\s\S]*?\S)~~/g, '<del>$1</del>');

    const restore = new RegExp(`${HOLD_OPEN}(\\d+)${HOLD_CLOSE}`, 'g');
    while (restore.test(text)) {
        text = text.replace(restore, (match, index) => held[Number(index)]);
    }
    return text;
}

/** The opening anchor tag for an allowed URL, or null when the URL is not one we link to. */
function linkOpening(url) {
    const record = url.match(RECORD_PATH);
    if (record) {
        return `<a href="${url}" data-record-id="${record[1]}">`;
    }
    if (url.startsWith('/') && !url.startsWith('//')) {
        return `<a href="${url}" data-internal="true">`;
    }
    if (/^(https?:\/\/|mailto:)/i.test(url)) {
        return `<a href="${url}" target="_blank" rel="noopener noreferrer">`;
    }
    return null;
}

const splitRow = (line) => {
    let row = line.trim().replace(/\\\|/g, ESCAPED_PIPE);
    if (row.startsWith('|')) {
        row = row.slice(1);
    }
    if (row.endsWith('|')) {
        row = row.slice(0, -1);
    }
    return row.split('|').map((cell) => cell.trim().split(ESCAPED_PIPE).join('|'));
};

const isTableDivider = (line) => {
    if (!line || !line.includes('-')) {
        return false;
    }
    const cells = splitRow(line);
    return cells.length > 0 && cells.every((cell) => TABLE_DIVIDER_CELL.test(cell));
};

const startsTable = (lines, index) => lines[index].includes('|') && isTableDivider(lines[index + 1]);

const startsBlock = (lines, index) => {
    const line = lines[index];
    return (
        FENCE.test(line) ||
        HEADING.test(line) ||
        RULE.test(line) ||
        QUOTE.test(line) ||
        LIST_ITEM.test(line) ||
        startsTable(lines, index)
    );
};

function renderTable(header, divider, rows) {
    const alignments = splitRow(divider).map((cell) => {
        if (cell.startsWith(':') && cell.endsWith(':')) {
            return ' class="slds-text-align_center"';
        }
        return cell.endsWith(':') ? ' class="slds-text-align_right"' : '';
    });
    const headings = splitRow(header);
    const cellsFor = (line) => {
        const cells = splitRow(line);
        return headings.map((heading, column) => cells[column] ?? '');
    };
    const head = headings
        .map((cell, column) => `<th scope="col"${alignments[column] ?? ''}>${renderInline(escapeHtml(cell))}</th>`)
        .join('');
    const body = rows
        .map((line) => {
            const cells = cellsFor(line)
                .map((cell, column) => `<td${alignments[column] ?? ''}>${renderInline(escapeHtml(cell))}</td>`)
                .join('');
            return `<tr>${cells}</tr>`;
        })
        .join('');
    return (
        '<div class="c-md-table"><table class="slds-table slds-table_bordered slds-no-row-hover">' +
        `<thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`
    );
}

/** Builds nested lists from items of the form {indent, ordered, start, text}. */
function renderList(items) {
    let html = '';
    const open = [];
    const openList = (item) => {
        const tag = item.ordered ? 'ol' : 'ul';
        const start = item.ordered && item.start !== 1 ? ` start="${item.start}"` : '';
        html += `<${tag} class="c-md-list"${start}>`;
        open.push({ indent: item.indent, tag });
    };
    const closeList = () => {
        html += `</li></${open.pop().tag}>`;
    };

    for (const item of items) {
        while (open.length && item.indent < open[open.length - 1].indent) {
            closeList();
        }
        const current = open[open.length - 1];
        if (!current || item.indent > current.indent) {
            openList(item);
        } else if (current.tag !== (item.ordered ? 'ol' : 'ul')) {
            closeList();
            openList(item);
        } else {
            html += '</li>';
        }
        html += `<li>${stackLeadIn(renderInline(escapeHtml(tieEnding(item.text))))}`;
    }
    while (open.length) {
        closeList();
    }
    return html;
}

/**
 * Renders Markdown as an HTML string that is safe to assign to innerHTML.
 * @param {string} source Markdown text
 * @returns {string} HTML
 */
export function renderMarkdown(source) {
    const lines = String(source ?? '')
        .replace(/\r\n?/g, '\n')
        .replace(/[-]/g, '')
        .replace(/\t/g, '    ')
        .split('\n');
    const html = [];
    let index = 0;

    while (index < lines.length) {
        const line = lines[index];
        const heading = line.match(HEADING);

        if (!line.trim()) {
            index += 1;
        } else if (FENCE.test(line)) {
            const marker = line.match(FENCE)[1];
            const code = [];
            index += 1;
            while (index < lines.length && !lines[index].trim().startsWith(marker)) {
                code.push(lines[index]);
                index += 1;
            }
            index += 1;
            html.push(`<pre class="c-md-pre"><code>${escapeHtml(code.join('\n'))}</code></pre>`);
        } else if (heading) {
            // The card title is an h2, so reply headings start at h3.
            const level = Math.min(heading[1].length + 2, 5);
            html.push(`<h${level} class="c-md-heading">${renderInline(escapeHtml(heading[2]))}</h${level}>`);
            index += 1;
        } else if (RULE.test(line)) {
            html.push('<hr class="c-md-rule">');
            index += 1;
        } else if (startsTable(lines, index)) {
            const rows = [];
            let next = index + 2;
            while (next < lines.length && lines[next].trim() && lines[next].includes('|')) {
                rows.push(lines[next]);
                next += 1;
            }
            html.push(renderTable(line, lines[index + 1], rows));
            index = next;
        } else if (QUOTE.test(line)) {
            const quoted = [];
            while (index < lines.length && QUOTE.test(lines[index])) {
                quoted.push(lines[index].replace(QUOTE, ''));
                index += 1;
            }
            html.push(`<blockquote class="c-md-quote">${renderMarkdown(quoted.join('\n'))}</blockquote>`);
        } else if (LIST_ITEM.test(line)) {
            const items = [];
            while (index < lines.length) {
                const item = lines[index].match(LIST_ITEM);
                if (item) {
                    items.push({
                        indent: item[1].length,
                        ordered: item[3] !== undefined,
                        start: Number(item[3] ?? 1),
                        text: item[4]
                    });
                } else if (lines[index].trim() && /^\s+/.test(lines[index])) {
                    // An indented line continues the item above it.
                    items[items.length - 1].text += ` ${lines[index].trim()}`;
                } else if (!lines[index].trim() && LIST_ITEM.test(lines[index + 1] ?? '')) {
                    // A blank line between items keeps the list going.
                } else {
                    break;
                }
                index += 1;
            }
            html.push(renderList(items));
        } else {
            const paragraph = [];
            while (index < lines.length && lines[index].trim() && (!paragraph.length || !startsBlock(lines, index))) {
                paragraph.push(renderInline(escapeHtml(tieEnding(lines[index].trim()))));
                index += 1;
            }
            html.push(`<p>${stackLeadIn(paragraph.join('<br>'))}</p>`);
        }
    }
    return html.join('');
}
