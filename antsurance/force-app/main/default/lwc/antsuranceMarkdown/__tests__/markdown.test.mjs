// Run with: node --test force-app/main/default/lwc/antsuranceMarkdown/__tests__/markdown.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderMarkdown } from '../markdown.js';

test('paragraphs keep single line breaks and separate on blank lines', () => {
    assert.equal(renderMarkdown('One\nTwo\n\nThree'), '<p>One<br>Two</p><p>Three</p>');
});

test('escapes HTML in the source', () => {
    assert.equal(
        renderMarkdown('<script>alert("x")</script> & more'),
        '<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; more</p>'
    );
});

test('bold, italic, strikethrough and inline code', () => {
    assert.equal(
        renderMarkdown('The **total** is *about* ~~$1M~~ `SELECT Id`'),
        '<p>The <strong>total</strong> is <em>about</em> <del>$1M</del> <code class="c-md-code">SELECT Id</code></p>'
    );
});

test('a paragraph that opens with a bold label gets the label on a line of its own', () => {
    assert.equal(renderMarkdown('**Total:** about $1M'), '<p><strong class="c-md-lead">Total</strong>about $1M</p>');
});

test('a longer paragraph or list item cannot end on one or two words', () => {
    assert.equal(
        renderMarkdown('Rebuilds the home after a covered loss. Flood and earth movement are excluded.'),
        '<p>Rebuilds the home after a covered loss. Flood and earth movement\u00a0are\u00a0excluded.</p>'
    );
    assert.equal(renderMarkdown('Short lines are left as they are.'), '<p>Short lines are left as they are.</p>');
    assert.equal(
        renderMarkdown('- See the full wording of this coverage in the [policy](/x/y) form'),
        '<ul class="c-md-list"><li>See the full wording of this coverage in the <a href="/x/y" data-internal="true">policy</a> form</li></ul>'
    );
});

test('leaves Salesforce API names and stray asterisks alone', () => {
    assert.equal(renderMarkdown('Policy_Number__c and Claim__c'), '<p>Policy_Number__c and Claim__c</p>');
    assert.equal(renderMarkdown('2 * 3 * 4 = 24'), '<p>2 * 3 * 4 = 24</p>');
});

test('does not format inside code spans or after a backslash', () => {
    assert.equal(renderMarkdown('`**not bold**` and \\*literal\\*'), '<p><code class="c-md-code">**not bold**</code> and *literal*</p>');
});

test('headings start at h3 and stop at h5', () => {
    assert.equal(renderMarkdown('# Top\n### Third\n###### Sixth'),
        '<h3 class="c-md-heading">Top</h3><h5 class="c-md-heading">Third</h5><h5 class="c-md-heading">Sixth</h5>');
});

test('bullet lists, including nesting and a continuation line', () => {
    assert.equal(
        renderMarkdown('- One\n  - Inner\n- Two\n  continued'),
        '<ul class="c-md-list"><li>One<ul class="c-md-list"><li>Inner</li></ul></li><li>Two continued</li></ul>'
    );
});

test('numbered lists keep their starting number', () => {
    assert.equal(renderMarkdown('3. Third\n4. Fourth'), '<ol class="c-md-list" start="3"><li>Third</li><li>Fourth</li></ol>');
    assert.equal(renderMarkdown('1. First'), '<ol class="c-md-list"><li>First</li></ol>');
});

test('a list directly after a paragraph starts a new block', () => {
    assert.equal(renderMarkdown('Deals:\n- A\n- B'), '<p>Deals:</p><ul class="c-md-list"><li>A</li><li>B</li></ul>');
});

test('loose lists with blank lines between items stay one list', () => {
    assert.equal(renderMarkdown('- A\n\n- B'), '<ul class="c-md-list"><li>A</li><li>B</li></ul>');
});

test('tables with alignment, inline formatting and missing cells', () => {
    assert.equal(
        renderMarkdown('| Deal | Amount |\n|---|---:|\n| **Big** | $675K |\n| Small |'),
        '<div class="c-md-table"><table class="slds-table slds-table_bordered slds-no-row-hover"><thead><tr>' +
            '<th scope="col">Deal</th><th scope="col" class="slds-text-align_right">Amount</th></tr></thead><tbody>' +
            '<tr><td><strong>Big</strong></td><td class="slds-text-align_right">$675K</td></tr>' +
            '<tr><td>Small</td><td class="slds-text-align_right"></td></tr></tbody></table></div>'
    );
});

test('a line with pipes but no divider row is just text', () => {
    assert.equal(renderMarkdown('a | b'), '<p>a | b</p>');
});

test('record links carry the record Id for in-app navigation', () => {
    assert.equal(
        renderMarkdown('[United Oil](/lightning/r/001aj00003z0XfKAAU/view)'),
        '<p><a href="/lightning/r/001aj00003z0XfKAAU/view" data-record-id="001aj00003z0XfKAAU">United Oil</a></p>'
    );
    assert.match(renderMarkdown('[Deal](/lightning/r/Opportunity/006aj000001AbCdEFG/view)'), /data-record-id="006aj000001AbCdEFG"/);
});

test('external links open in a new tab and other schemes are not linked', () => {
    assert.equal(
        renderMarkdown('[Docs](https://example.com/a?b=1&c=2)'),
        '<p><a href="https://example.com/a?b=1&amp;c=2" target="_blank" rel="noopener noreferrer">Docs</a></p>'
    );
    assert.equal(renderMarkdown('[x](javascript:alert(1))'), '<p>[x](javascript:alert(1))</p>');
    assert.equal(renderMarkdown('[x](//evil.example)'), '<p>[x](//evil.example)</p>');
});

test('fenced code is escaped and not formatted', () => {
    assert.equal(
        renderMarkdown('```sql\nSELECT Name FROM Account WHERE Name < \'B\'\n**x**\n```'),
        '<pre class="c-md-pre"><code>SELECT Name FROM Account WHERE Name &lt; &#39;B&#39;\n**x**</code></pre>'
    );
});

test('blockquotes and horizontal rules', () => {
    assert.equal(renderMarkdown('> Quoted\n> text\n\n---'), '<blockquote class="c-md-quote"><p>Quoted<br>text</p></blockquote><hr class="c-md-rule">');
});

test('empty and missing input render nothing', () => {
    assert.equal(renderMarkdown(''), '');
    assert.equal(renderMarkdown(undefined), '');
});
