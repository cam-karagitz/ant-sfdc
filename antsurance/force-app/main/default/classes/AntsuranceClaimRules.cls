/**
 * @description The rules every Claude writer on a claim shares, so the claim brief, the coverage
 * check, the claim analysis and the Home briefing tell one story.
 *
 * Two rules live here. What a reserve is measured against: the reserve is what the insurer expects
 * to pay, so it is compared with the estimate less the deductible (and no more than the limit),
 * never with the gross estimate. And which file notes are Claude's own work: a note saved from the
 * claim analysis repeats what Claude already concluded, so it is not new evidence and does not
 * make an earlier brief or coverage check out of date.
 */
public with sharing class AntsuranceClaimRules {
    /** One line for every prompt: the demo is for US insurers. */
    public static final String AMERICAN_ENGLISH = 'Write in American English.';

    /**
     * How to read a reserve, in the words each prompt includes. Kept as one piece of text so no
     * writer can be told something different from the others.
     */
    public static final String RESERVE_RULE =
        'HOW TO READ THE RESERVE. The reserve is the total Antsurance expects to pay on the claim. ' +
        'It is measured against the payable amount, which is the estimate less the deductible and no more than the limit. It is never measured against the gross estimate. ' +
        'A reserve equal to the payable amount covers the claim: do not call it short, and never describe the deductible as a gap, a shortfall or a reason to raise the reserve. ' +
        'Say that in plain words, such as "the $45,000 reserve covers it"; do not write "the adequate reserve" or "adequately reserved". ' +
        'Call the reserve short only when it is below the payable amount, or below the payable amount plus costs the file documents beyond the estimate, and say by how much. ' +
        'A cost beyond the estimate is the amount by which what the documents show the whole loss costs is more than the estimate. ' +
        'It is not the amount by which one invoice or estimate is more than a line of an earlier reserve breakdown: ' +
        'add up the whole loss from the documents, using the latest breakdown for any part no document covers, and count only what is above the estimate. The deductible comes off once. ' +
        'For example, with a $30,000 estimate, a $1,000 deductible and documents that put the whole loss at $31,200, the payable amount is $29,000, the documented cost beyond the estimate is $1,200, ' +
        'and the reserve to hold is $30,200. ' +
        'A cost counts as documented when the file gives its amount, or gives what it takes to work the amount out: a rate and how long it runs, ' +
        'such as rental reimbursement at a daily amount that a note or the policy states, for the number of days a note states. Work it out, include it, and show the multiplication. ' +
        'When the file gives only one of the two (the days with no daily amount, or the reverse), leave it out of the figure and say which one is missing. ' +
        'When you recommend a different reserve, show the sum: the payable amount, then each addition by name with its figure and where it comes from, adding up to the figure you recommend. ' +
        'When the request gives a PAYABLE line, use its figures as given.';

    /**
     * What Claude writes here is stored and read again on later days, so every prompt that writes
     * something stored includes this. One piece of text, so no writer is told something different.
     */
    public static final String LASTING_WORDS =
        'What you write is read on later days too, so never write today, tonight, tomorrow or yesterday: give the date, like Sep 28, or leave the day out. ' +
        'For the same reason never say how many days ago something happened, how many days old it is, how long it has been open or how many days are left: give the date it happened or the date it is due. ';

    /** How a note saved from the claim analysis begins. */
    public static final String ANALYSIS_NOTE_OPENING = '**Claim analysis:**';
    /** Who a note saved from Claude's work is attributed to, ahead of the person who saved it. */
    public static final String CLAUDE_AUTHOR = 'Claude';

    public static final String ADEQUATE = 'adequate';
    public static final String SHORT_OF = 'short';
    public static final String ABOVE = 'above';
    public static final String UNKNOWN = 'unknown';

    /** The limit and deductible a claim's reserve is read against, and where they came from. */
    public class Terms {
        public Decimal deductible;
        public Decimal limitAmount;
        /** "the coverage check" when Claude's check named the coverage that responds, otherwise "the policy". */
        public String source;
    }

    /** Where a reserve stands against what is payable. */
    public class Position {
        @AuraEnabled
        public Decimal estimate;
        @AuraEnabled
        public Decimal deductible;
        @AuraEnabled
        public Decimal limitAmount;
        /** The estimate less the deductible, and no more than the limit. Null without an estimate. */
        @AuraEnabled
        public Decimal payable;
        @AuraEnabled
        public Decimal reserve;
        /** The reserve less the payable amount: negative when short. Null when payable is unknown. */
        @AuraEnabled
        public Decimal difference;
        /** adequate, short, above or unknown. */
        @AuraEnabled
        public String standing;
        @AuraEnabled
        public Boolean cappedByLimit = false;
    }

    /**
     * @description What a claim pays against an estimate: the estimate less the deductible, and no
     * more than the limit.
     * @param estimate The estimated loss
     * @param deductible The deductible that applies, or null for none
     * @param limitAmount The limit that applies, or null when there is none to cap it
     * @return The payable amount, or null when there is no estimate
     */
    public static Decimal payable(Decimal estimate, Decimal deductible, Decimal limitAmount) {
        if (estimate == null || estimate <= 0) {
            return null;
        }
        Decimal net = Math.max(0, estimate - (deductible == null ? 0 : deductible));
        return limitAmount != null && limitAmount > 0 ? Math.min(net, limitAmount) : net;
    }

    /**
     * @description Where the reserve stands against the payable amount.
     * @param reserve The reserve on the claim
     * @param estimate The estimated loss
     * @param deductible The deductible that applies
     * @param limitAmount The limit that applies
     * @return The position; standing is unknown when there is no estimate
     */
    public static Position position(Decimal reserve, Decimal estimate, Decimal deductible, Decimal limitAmount) {
        Position at = new Position();
        at.estimate = estimate;
        at.deductible = deductible == null ? 0 : deductible;
        at.limitAmount = limitAmount;
        at.reserve = reserve == null ? 0 : reserve;
        at.payable = payable(estimate, deductible, limitAmount);
        if (at.payable == null) {
            at.standing = UNKNOWN;
            return at;
        }
        at.cappedByLimit = limitAmount != null && limitAmount > 0 && estimate - at.deductible > limitAmount;
        at.difference = at.reserve - at.payable;
        // A dollar either way is rounding, not a shortfall.
        at.standing = at.difference < -1 ? SHORT_OF : at.difference > 1 ? ABOVE : ADEQUATE;
        return at;
    }

    /**
     * @description The position as the PAYABLE line a prompt carries, so every writer starts from
     * the same arithmetic instead of working it out again.
     * @param at The position
     * @return One or two plain sentences
     */
    public static String payableLine(Position at) {
        if (at == null || at.payable == null) {
            return 'PAYABLE: there is no estimate on the claim yet, so the reserve cannot be measured against one.';
        }
        String sum = 'the ' + money(at.estimate) + ' estimate';
        sum += at.deductible > 0 ? ' less the ' + money(at.deductible) + ' deductible' : ' with no deductible';
        if (at.cappedByLimit) {
            sum += ', capped by the ' + money(at.limitAmount) + ' limit';
        }
        String line = 'PAYABLE: ' + money(at.payable) + ' (' + sum + '). RESERVE: ' + money(at.reserve) + ', ';
        if (at.standing == ADEQUATE) {
            line += 'equal to the payable amount, so the reserve covers it.';
        } else if (at.standing == SHORT_OF) {
            line += 'which is ' + money(Math.abs(at.difference)) + ' below the payable amount.';
        } else {
            line += 'which is ' + money(at.difference) + ' above the payable amount; that is right only where the file documents costs beyond the estimate.';
        }
        return line;
    }

    /**
     * @description The limit and deductible to read a claim's reserve against. The coverage check,
     * when there is one, names the coverage that responds, so its terms are used; otherwise the
     * policy's own.
     * @param claim The claim, queried with Coverage_Read__c, Policy__r.Deductible__c and Policy__r.Coverage_Limit__c
     * @return The terms
     */
    public static Terms termsFor(Case claim) {
        Terms terms = new Terms();
        terms.source = 'the policy';
        terms.deductible = claim.Policy__r?.Deductible__c;
        terms.limitAmount = claim.Policy__r?.Coverage_Limit__c;
        if (String.isNotBlank(claim.Coverage_Read__c)) {
            try {
                Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(claim.Coverage_Read__c);
                Map<String, Object> check = (Map<String, Object>) data.get('check');
                if (check != null && String.isNotBlank((String) check.get('respondingLabel'))) {
                    terms.deductible = decimalOf(check.get('deductible'));
                    terms.limitAmount = decimalOf(check.get('limitAmount'));
                    terms.source = 'the coverage check';
                }
            } catch (Exception e) {
                // A check this card cannot read is the same as no check: the policy's terms stand.
                terms.source = 'the policy';
            }
        }
        return terms;
    }

    /**
     * @description True for a file note that was saved from Claude's own claim analysis.
     * @param note The note, with Body__c and Author_Name__c
     * @return Whether it is Claude's own work rather than new evidence
     */
    public static Boolean isClaudeNote(File_Note__c note) {
        if (note == null) {
            return false;
        }
        Boolean byAuthor = String.isNotBlank(note.Author_Name__c) && note.Author_Name__c.startsWith(CLAUDE_AUTHOR);
        Boolean byOpening = String.isNotBlank(note.Body__c) && note.Body__c.trim().startsWith(ANALYSIS_NOTE_OPENING);
        return byAuthor || byOpening;
    }

    /**
     * @description The notes a person wrote, leaving out those saved from Claude's own analysis,
     * which are not evidence and do not make an earlier brief or check out of date.
     * @param notes The claim's notes, in any order
     * @return The same notes in the same order, without Claude's own
     */
    public static List<File_Note__c> withoutClaudeNotes(List<File_Note__c> notes) {
        List<File_Note__c> kept = new List<File_Note__c>();
        if (notes != null) {
            for (File_Note__c note : notes) {
                if (!isClaudeNote(note)) {
                    kept.add(note);
                }
            }
        }
        return kept;
    }

    /**
     * @description Who a note saved from Claude's work is attributed to, so the file shows it was
     * Claude's analysis and who chose to keep it.
     * @return Such as "Claude, saved by Anjali Venkataraman"
     */
    public static String claudeAuthor() {
        return (CLAUDE_AUTHOR + ', saved by ' + UserInfo.getName()).abbreviate(80);
    }

    private static Decimal decimalOf(Object value) {
        if (value == null) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    private static String money(Decimal amount) {
        return amount == null ? 'not set' : '$' + amount.setScale(0, RoundingMode.HALF_UP).format();
    }
}
