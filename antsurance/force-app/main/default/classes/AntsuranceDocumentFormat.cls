/**
 * @description Formatting shared by the Antsurance document PDFs. The PDF engine cannot be trusted
 * to wrap, round or align, so every value is turned into finished text here: money with separators,
 * dates that name the month, cells shortened to fit, and paragraphs broken into lines by hand.
 */
public with sharing class AntsuranceDocumentFormat {
    public static final String NOT_RECORDED = 'Not recorded';
    private static final Map<String, String> STATE_NAMES = new Map<String, String>{
        'IL' => 'Illinois', 'WI' => 'Wisconsin', 'IN' => 'Indiana', 'MI' => 'Michigan', 'IA' => 'Iowa', 'MN' => 'Minnesota',
        'MO' => 'Missouri', 'OH' => 'Ohio', 'KY' => 'Kentucky', 'NY' => 'New York', 'CA' => 'California', 'TX' => 'Texas'
    };

    /**
     * @description Dollars with thousands separators and a fixed number of decimal places.
     * @param value The amount
     * @param scale Decimal places to show
     * @param whenBlank What to print when there is no amount
     * @return The amount as text, or the stand-in
     */
    public static String money(Decimal value, Integer scale, String whenBlank) {
        if (value == null) {
            return whenBlank;
        }
        Decimal rounded = value.setScale(scale, RoundingMode.HALF_UP);
        Decimal whole = rounded.setScale(0, RoundingMode.DOWN);
        String text = '$' + whole.format();
        if (scale > 0) {
            Integer cents = ((rounded - whole) * Math.pow(10, scale)).intValue();
            text += '.' + String.valueOf(cents).leftPad(scale, '0');
        }
        return text;
    }

    /**
     * @description A date that names its month, such as Jan 5, 2027, so it cannot be misread or split.
     * @param value The date
     * @return The date as text, or the stand-in for a blank
     */
    public static String longDate(Date value) {
        return value == null ? NOT_RECORDED : DateTime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    /**
     * @description A value for a table cell: a stand-in when blank, shortened when it would not fit on one line.
     * @param value The text
     * @param maxLength The longest text the cell holds on one line
     * @return Text that fits the cell
     */
    public static String cell(String value, Integer maxLength) {
        return String.isBlank(value) ? NOT_RECORDED : value.abbreviate(Math.max(maxLength, 4));
    }

    /**
     * @description The values that are not blank, in order.
     * @param values Any strings
     * @return Those with something in them
     */
    public static List<String> present(List<String> values) {
        List<String> kept = new List<String>();
        for (String value : values) {
            if (String.isNotBlank(value)) {
                kept.add(value);
            }
        }
        return kept;
    }

    /**
     * @description Breaks a paragraph into lines of at most maxChars, so the page prints each line as
     * written. The lines are evened out: the paragraph takes no more lines than it needs, and the
     * last one is never left with a word or two on its own.
     * @param text The paragraph
     * @param maxChars The longest line, in characters
     * @return The lines, or none for blank text
     */
    public static List<String> wrap(String text, Integer maxChars) {
        if (String.isBlank(text)) {
            return new List<String>();
        }
        List<String> words = text.normalizeSpace().split(' ');
        List<String> lines = fill(words, maxChars);
        // The narrowest width that needs no more lines gives lines of about the same length.
        Integer narrowest = (Integer) Math.ceil((Decimal) text.normalizeSpace().length() / lines.size());
        for (Integer width = narrowest; width < maxChars; width++) {
            List<String> evened = fill(words, width);
            if (evened.size() == lines.size()) {
                return evened;
            }
        }
        return lines;
    }

    private static List<String> fill(List<String> words, Integer maxChars) {
        List<String> lines = new List<String>();
        String current = '';
        for (String word : words) {
            if (current != '' && current.length() + 1 + word.length() > maxChars) {
                lines.add(current);
                current = word;
            } else {
                current = current == '' ? word : current + ' ' + word;
            }
        }
        lines.add(current);
        return lines;
    }

    /**
     * @description Markdown reduced to plain words: emphasis marks and list bullets are dropped.
     * @param markdown Text that may carry Markdown
     * @return The same words without the marks
     */
    public static String plain(String markdown) {
        return markdown == null ? '' : markdown.replace('**', '').replace('__', '').replaceAll('(?m)^\\s*[-*]\\s+', '').normalizeSpace();
    }

    /**
     * @description The name of a US state from its two-letter code.
     * @param code For example IL
     * @return The state's name, or the code itself when it is not one this demo uses
     */
    public static String stateName(String code) {
        return STATE_NAMES.containsKey(code) ? STATE_NAMES.get(code) : (String.isBlank(code) ? NOT_RECORDED : code);
    }

    /**
     * @description Text that is safe to use inside a file name.
     * @param text Any text
     * @return Letters, digits and hyphens only
     */
    public static String fileSafe(String text) {
        return text == null ? '' : text.replaceAll('[^A-Za-z0-9]+', '-').replaceAll('^-+|-+$', '');
    }
}
