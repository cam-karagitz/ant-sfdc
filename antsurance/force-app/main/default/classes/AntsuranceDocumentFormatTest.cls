@IsTest
private class AntsuranceDocumentFormatTest {
    @IsTest
    static void moneyAndDatesAreFinishedText() {
        Assert.areEqual('$1,234,567.05', AntsuranceDocumentFormat.money(1234567.049, 2, ''), 'Rounds to cents and pads them');
        Assert.areEqual('$1,000', AntsuranceDocumentFormat.money(999.5, 0, ''), 'Rounds whole dollars up');
        Assert.areEqual('None', AntsuranceDocumentFormat.money(null, 0, 'None'), 'Blank becomes the stand-in');
        Assert.areEqual('Jan 5, 2027', AntsuranceDocumentFormat.longDate(Date.newInstance(2027, 1, 5)), 'Dates name the month');
        Assert.areEqual('Not recorded', AntsuranceDocumentFormat.longDate(null), 'A missing date is a word');
    }

    @IsTest
    static void cellsAndListsAreTidied() {
        Assert.areEqual('Not recorded', AntsuranceDocumentFormat.cell(' ', 10), 'A blank cell gets a word');
        Assert.areEqual('A long...', AntsuranceDocumentFormat.cell('A long description', 9), 'A long value is shortened to fit');
        Assert.areEqual(new List<String>{ 'a', 'b' }, AntsuranceDocumentFormat.present(new List<String>{ 'a', null, ' ', 'b' }), 'Blanks are dropped');
        Assert.areEqual('Includes: towing and rental', AntsuranceDocumentFormat.plain('**Includes:**  towing\nand rental'), 'Markdown marks are dropped');
        Assert.areEqual('First point Second point', AntsuranceDocumentFormat.plain('- First point\n- Second point'), 'So are list bullets');
        Assert.areEqual('', AntsuranceDocumentFormat.plain(null), 'Nothing in, nothing out');
        Assert.areEqual('Illinois', AntsuranceDocumentFormat.stateName('IL'), 'A state code becomes its name');
        Assert.areEqual('ZZ', AntsuranceDocumentFormat.stateName('ZZ'), 'An unknown code is printed as it is');
        Assert.areEqual('Not recorded', AntsuranceDocumentFormat.stateName(null), 'A missing state is a word');
        Assert.areEqual('Ridgeline-Roofing-Solar', AntsuranceDocumentFormat.fileSafe('Ridgeline Roofing & Solar '), 'File names keep letters, digits and hyphens');
        Assert.areEqual('Dubois-Household-Personal-Auto', AntsuranceDocumentFormat.fileSafe('Dubois Household - Personal Auto'), 'Runs of spaces and marks become one hyphen');
        Assert.areEqual('ANT-PA-204517', AntsuranceDocumentFormat.fileSafe('ANT-PA-204517'), 'A policy number is kept as it is');
        Assert.areEqual('', AntsuranceDocumentFormat.fileSafe(null), 'No name, no text');
    }

    @IsTest
    static void paragraphsAreBrokenByHandIntoEvenLines() {
        Assert.areEqual(new List<String>(), AntsuranceDocumentFormat.wrap(' ', 20), 'Blank text has no lines');
        Assert.areEqual(new List<String>{ 'One short line' }, AntsuranceDocumentFormat.wrap('One  short line', 20), 'Text that fits stays on one line');
        Assert.areEqual(
            new List<String>{ 'alpha beta gamma', 'delta epsilon' },
            AntsuranceDocumentFormat.wrap('alpha beta gamma delta epsilon', 16),
            'Lines break between words at the width'
        );
        Assert.areEqual(
            new List<String>{ 'alpha beta', 'gamma delta' },
            AntsuranceDocumentFormat.wrap('alpha beta gamma delta', 18),
            'A last line of one word is evened out with the line above'
        );
        List<String> lines = AntsuranceDocumentFormat.wrap('Covers the building, the equipment inside it and income lost while repairs are made after a covered loss', 30);
        Assert.areEqual(4, lines.size(), 'No more lines than the width needs');
        for (String line : lines) {
            Assert.isTrue(line.length() <= 30, 'No line is longer than asked: ' + line);
            Assert.isTrue(line.length() >= 20, 'And none is left short: ' + line);
        }
        Assert.areEqual(new List<String>{ 'Supercalifragilistic', 'word' }, AntsuranceDocumentFormat.wrap('Supercalifragilistic word', 10), 'A word longer than the width keeps a line to itself');
    }

    @IsTest
    static void blocksThatDoNotFitStartANewPage() {
        AntsuranceDocumentLayout layout = new AntsuranceDocumentLayout(600);
        Assert.isFalse(layout.place(50), 'A block that fits stays on the page');
        Assert.isTrue(layout.place(100), 'One that does not starts the next page');
        Assert.isFalse(layout.placeIfRoom(700), 'Optional content is left out when there is no room');
        Assert.isTrue(layout.placeIfRoom(100), 'And printed when there is');
        Assert.areEqual(AntsuranceDocumentLayout.PAGE_HEIGHT - 8 - 200, layout.remaining(), 'Room left after both blocks');
        layout.newPage();
        Assert.isFalse(layout.place(600), 'A page started on purpose has all its room');
        Assert.isFalse(new AntsuranceDocumentLayout(0).place(2000), 'A block taller than a page still prints, without a blank page before it');
    }

    @IsTest
    static void aTableThatFitsOnAPageIsKeptWhole() {
        // 300 points are free: a 50 point heading and five 50 point rows. Eight rows and the total need 470.
        AntsuranceDocumentLayout layout = new AntsuranceDocumentLayout(AntsuranceDocumentLayout.PAGE_HEIGHT - 8 - 300);
        List<AntsuranceDocumentLayout.Chunk> chunks = layout.split(AntsuranceDocumentLayout.uniform(8, 50), 50, 20);
        Assert.areEqual(1, chunks.size(), 'Eight rows fit on a page, so they are not cut after five');
        Assert.areEqual(8, chunks[0].size, 'Every row is in the one part');
        Assert.isTrue(chunks[0].newPage && chunks[0].isFirst && chunks[0].isLast, 'Which starts the next page, whole, under its heading');
        Assert.areEqual(AntsuranceDocumentLayout.PAGE_HEIGHT - 8 - 470, layout.remaining(), 'And what follows prints under it');

        layout = new AntsuranceDocumentLayout(AntsuranceDocumentLayout.PAGE_HEIGHT - 8 - 500);
        chunks = layout.split(AntsuranceDocumentLayout.uniform(8, 50), 50, 20);
        Assert.areEqual(1, chunks.size(), 'With room for all of it, it stays where it is');
        Assert.isFalse(chunks[0].newPage, 'On the same page');

        layout = new AntsuranceDocumentLayout(AntsuranceDocumentLayout.PAGE_HEIGHT - 8 - 120);
        chunks = layout.split(AntsuranceDocumentLayout.uniform(4, 50), 50, 20);
        Assert.areEqual(1, chunks.size(), 'A table with room for only one row starts on the next page instead');
        Assert.isTrue(chunks[0].newPage && chunks[0].isFirst && chunks[0].isLast, 'Whole, under its heading');
    }

    @IsTest
    static void aTableTallerThanAPageIsCutWherePagesEnd() {
        // 300 points are free: a 50 point heading and five 50 point rows. Sixteen rows cannot fit on any one page.
        AntsuranceDocumentLayout layout = new AntsuranceDocumentLayout(AntsuranceDocumentLayout.PAGE_HEIGHT - 8 - 300);
        List<AntsuranceDocumentLayout.Chunk> chunks = layout.split(AntsuranceDocumentLayout.uniform(16, 50), 50, 20);
        Assert.areEqual(2, chunks.size(), 'Sixteen rows take two pages');
        Assert.areEqual(5, chunks[0].size, 'The first page is filled');
        Assert.isTrue(chunks[0].isFirst && !chunks[0].isLast && !chunks[0].newPage, 'And follows what came before');
        Assert.areEqual(5, chunks[1].first, 'The second part carries on where the first stopped');
        Assert.areEqual(11, chunks[1].size, 'With the rest');
        Assert.isTrue(chunks[1].newPage && chunks[1].isLast, 'On a new page, with the tail');

        // A fresh page holds the heading and twelve rows.
        chunks = new AntsuranceDocumentLayout(0).split(AntsuranceDocumentLayout.uniform(13, 50), 50, 20);
        Assert.areEqual(11, chunks[0].size, 'One row is never left to go over on its own');
        Assert.areEqual(2, chunks[1].size, 'It takes a second row with it');

        chunks = new AntsuranceDocumentLayout(0).split(AntsuranceDocumentLayout.uniform(12, 50), 50, 40);
        Assert.areEqual(10, chunks[0].size, 'When the tail does not fit under the last row, two rows go over with it');
        Assert.areEqual(2, chunks[1].size, 'So the total is never alone at the top of a page');

        Assert.isTrue(new AntsuranceDocumentLayout(0).split(new List<Decimal>(), 50, 20).isEmpty(), 'No rows, no parts');
        chunks = new AntsuranceDocumentLayout(0).split(new List<Decimal>{ 900 }, 50, 20);
        Assert.areEqual(1, chunks[0].size, 'A row taller than a page is printed anyway');
    }
}
