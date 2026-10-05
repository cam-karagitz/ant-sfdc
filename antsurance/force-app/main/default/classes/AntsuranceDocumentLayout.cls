/**
 * @description A model of one document's pages, used to decide where page breaks go before the PDF
 * is drawn. The PDF engine will not repeat a table's column heads on the next page or keep a heading
 * with its rows, so a controller measures its blocks in points, asks this where each lands, and the
 * page prints explicit breaks. Heights are estimates on the generous side: a break may come a row
 * early, never late.
 */
public with sharing class AntsuranceDocumentLayout {
    /** Usable height of a US Letter page inside the documents' margins, in points. */
    public static final Decimal PAGE_HEIGHT = 694;
    // Room kept free at the foot of a page, so a small error in an estimate cannot push a block over.
    private static final Decimal SAFETY = 8;
    // A table is never left with fewer rows than this on either side of a page break.
    private static final Integer FEWEST_ROWS = 2;

    private Decimal used;

    /**
     * @description One run of a table's rows that prints on a single page under its own heading.
     */
    public class Chunk {
        /** Index of the chunk's first row. */
        public Integer first { get; set; }
        public Integer size { get; set; }
        public Boolean newPage { get; set; }
        public Boolean isFirst { get; set; }
        public Boolean isLast { get; set; }
    }

    /**
     * @description Starts a page model.
     * @param alreadyUsed Height of whatever is printed before the first measured block
     */
    public AntsuranceDocumentLayout(Decimal alreadyUsed) {
        used = alreadyUsed;
    }

    /**
     * @description Room left on the current page.
     * @return Points still free
     */
    public Decimal remaining() {
        return PAGE_HEIGHT - SAFETY - used;
    }

    /**
     * @description Places a block that must stay whole.
     * @param height The block's height in points
     * @return True when the block has to start a new page
     */
    public Boolean place(Decimal height) {
        Boolean newPage = used > 0 && height > remaining();
        if (newPage) {
            used = 0;
        }
        used += height;
        return newPage;
    }

    /**
     * @description Starts a new page, whatever room is left on this one.
     */
    public void newPage() {
        used = 0;
    }

    /**
     * @description Places a block only if it fits on the current page, for content that is worth
     * printing but not worth a page of its own.
     * @param height The block's height in points
     * @return True when the block fits and was placed
     */
    public Boolean placeIfRoom(Decimal height) {
        if (height > remaining()) {
            return false;
        }
        used += height;
        return true;
    }

    /**
     * @description Places a table. A table that fits on one page is kept whole: when the room left on
     * this page is too little for it, it starts the next page instead of being cut. Only a table taller
     * than a page is split, and then every chunk prints the heading and column heads again, no chunk is
     * a single stranded row, and whatever follows the last row (a total, a note) stays with at least two rows.
     * @param rowHeights Height of each row in points
     * @param headingHeight Height of the section heading and column heads, printed above every chunk
     * @param tailHeight Height of what follows the last row
     * @return The chunks, in order
     */
    public List<Chunk> split(List<Decimal> rowHeights, Decimal headingHeight, Decimal tailHeight) {
        List<Chunk> chunks = new List<Chunk>();
        Integer total = rowHeights.size();
        Integer index = 0;
        Boolean newPage = false;
        Decimal whole = headingHeight + tailHeight;
        for (Decimal rowHeight : rowHeights) {
            whole += rowHeight;
        }
        if (total > 0 && used > 0 && whole > remaining() && whole <= PAGE_HEIGHT - SAFETY) {
            // It fits on a page of its own, so it is not cut in two for the sake of the room left here.
            used = 0;
            newPage = true;
        }
        while (index < total) {
            Integer left = total - index;
            Decimal height = headingHeight;
            Integer count = 0;
            while (count < left && height + rowHeights[index + count] <= remaining()) {
                height += rowHeights[index + count];
                count++;
            }
            // The tail has to fit under the last row, with company.
            if (count == left && height + tailHeight > remaining()) {
                count = Math.max(left - FEWEST_ROWS, 0);
            }
            // Never leave one row to go over on its own.
            if (left - count == 1 && count > FEWEST_ROWS) {
                count--;
            }
            Boolean tooFew = count < Math.min(FEWEST_ROWS, left);
            if (tooFew && used > 0) {
                // Not worth starting here: begin the table, or its next chunk, on a fresh page.
                used = 0;
                newPage = true;
                continue;
            }
            if (tooFew) {
                // A fresh page and it still does not fit: print what the estimate says cannot be helped.
                count = left;
            }

            Chunk chunk = new Chunk();
            chunk.first = index;
            chunk.size = count;
            chunk.newPage = newPage;
            chunk.isFirst = index == 0;
            chunk.isLast = index + count == total;
            chunks.add(chunk);

            height = headingHeight;
            for (Integer row = index; row < index + count; row++) {
                height += rowHeights[row];
            }
            index += count;
            if (chunk.isLast) {
                used += height + tailHeight;
            } else {
                used = 0;
                newPage = true;
            }
        }
        return chunks;
    }

    /**
     * @description The same height for every row.
     * @param rowCount How many rows
     * @param rowHeight Height of each
     * @return A list to pass to split
     */
    public static List<Decimal> uniform(Integer rowCount, Decimal rowHeight) {
        List<Decimal> heights = new List<Decimal>();
        for (Integer row = 0; row < rowCount; row++) {
            heights.add(rowHeight);
        }
        return heights;
    }
}
