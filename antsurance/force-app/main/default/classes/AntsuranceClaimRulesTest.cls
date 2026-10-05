/**
 * @description The shared claim rules: what a reserve is measured against, and which file notes
 * are Claude's own work.
 */
@IsTest
private class AntsuranceClaimRulesTest {
    @IsTest
    static void reserveEqualToEstimateLessDeductibleIsAdequate() {
        // The burst pipe claim: a $47,500 estimate, a $2,500 deductible and a $45,000 reserve.
        AntsuranceClaimRules.Position at = AntsuranceClaimRules.position(45000, 47500, 2500, 485000);
        Assert.areEqual(45000, at.payable, 'The estimate less the deductible');
        Assert.areEqual(AntsuranceClaimRules.ADEQUATE, at.standing, 'A reserve equal to the payable amount is adequate');
        Assert.areEqual(0, at.difference, 'Nothing short');
        String line = AntsuranceClaimRules.payableLine(at);
        Assert.isTrue(line.contains('$45,000 (the $47,500 estimate less the $2,500 deductible)'), line);
        Assert.isTrue(line.contains('so the reserve covers it'), line);
        Assert.isFalse(line.contains('below'), 'The deductible is never called a gap: ' + line);
    }

    @IsTest
    static void shortAndAboveAreMeasuredFromThePayableAmount() {
        AntsuranceClaimRules.Position isShort = AntsuranceClaimRules.position(40000, 47500, 2500, null);
        Assert.areEqual(AntsuranceClaimRules.SHORT_OF, isShort.standing, 'Below the payable amount');
        Assert.areEqual(-5000, isShort.difference, 'Short by the payable amount less the reserve, not by the gross estimate');
        Assert.isTrue(AntsuranceClaimRules.payableLine(isShort).contains('$5,000 below the payable amount'), 'Says by how much');

        AntsuranceClaimRules.Position isAbove = AntsuranceClaimRules.position(48921, 47500, 2500, null);
        Assert.areEqual(AntsuranceClaimRules.ABOVE, isAbove.standing, 'Above the payable amount');
        Assert.isTrue(AntsuranceClaimRules.payableLine(isAbove).contains('$3,921 above'), 'Says by how much');
    }

    @IsTest
    static void theLimitCapsWhatIsPayable() {
        AntsuranceClaimRules.Position at = AntsuranceClaimRules.position(100000, 150000, 1000, 100000);
        Assert.areEqual(100000, at.payable, 'No more than the limit');
        Assert.isTrue(at.cappedByLimit, 'Capped');
        Assert.areEqual(AntsuranceClaimRules.ADEQUATE, at.standing, 'A reserve at the limit is adequate');
        Assert.isTrue(AntsuranceClaimRules.payableLine(at).contains('capped by the $100,000 limit'), 'Says the limit caps it');
    }

    @IsTest
    static void noEstimateIsUnknownAndNoDeductibleIsSaid() {
        AntsuranceClaimRules.Position none = AntsuranceClaimRules.position(5000, null, 500, null);
        Assert.areEqual(AntsuranceClaimRules.UNKNOWN, none.standing, 'Nothing to measure against');
        Assert.isTrue(AntsuranceClaimRules.payableLine(none).contains('no estimate'), 'Says so');
        Assert.isNull(AntsuranceClaimRules.payable(0, 500, null), 'A zero estimate is no estimate');

        AntsuranceClaimRules.Position workersComp = AntsuranceClaimRules.position(285000, 285000, null, null);
        Assert.areEqual(AntsuranceClaimRules.ADEQUATE, workersComp.standing, 'No deductible: the estimate is payable in full');
        Assert.isTrue(AntsuranceClaimRules.payableLine(workersComp).contains('with no deductible'), 'Says there is none');
        Assert.areEqual(0, AntsuranceClaimRules.payable(400, 500, null), 'An estimate under the deductible pays nothing');
    }

    @IsTest
    static void termsComeFromTheCoverageCheckWhenThereIsOne() {
        Policy__c policy = new Policy__c(Deductible__c = 2500, Coverage_Limit__c = 485000);
        Case claim = new Case(Policy__r = policy);
        AntsuranceClaimRules.Terms fromPolicy = AntsuranceClaimRules.termsFor(claim);
        Assert.areEqual(2500, fromPolicy.deductible, 'The policy deductible');
        Assert.areEqual('the policy', fromPolicy.source, 'From the policy');

        claim.Coverage_Read__c = '{"check":{"respondingLabel":"Collision","deductible":500,"limitAmount":38000},"facts":{}}';
        AntsuranceClaimRules.Terms fromCheck = AntsuranceClaimRules.termsFor(claim);
        Assert.areEqual(500, fromCheck.deductible, 'The responding coverage\'s deductible');
        Assert.areEqual(38000, fromCheck.limitAmount, 'And its limit');
        Assert.areEqual('the coverage check', fromCheck.source, 'From the check');

        claim.Coverage_Read__c = 'not json';
        Assert.areEqual(2500, AntsuranceClaimRules.termsFor(claim).deductible, 'An unreadable check falls back to the policy');
        claim.Coverage_Read__c = '{"check":{"respondingLabel":"","deductible":1},"facts":{}}';
        Assert.areEqual(2500, AntsuranceClaimRules.termsFor(claim).deductible, 'A check with no responding coverage does too');
    }

    @IsTest
    static void notesSavedFromTheAnalysisAreClaudesOwn() {
        File_Note__c byPerson = new File_Note__c(Body__c = '**First notice:** Chinedu called on returning from a weekend away.', Author_Name__c = 'Anjali Venkataraman');
        File_Note__c byOpening = new File_Note__c(Body__c = '  **Claim analysis:** Coverage hinges on the water source.');
        File_Note__c byAuthor = new File_Note__c(Body__c = 'Something else', Author_Name__c = AntsuranceClaimRules.claudeAuthor());
        Assert.isFalse(AntsuranceClaimRules.isClaudeNote(byPerson), 'A person wrote it');
        Assert.isTrue(AntsuranceClaimRules.isClaudeNote(byOpening), 'It opens the way the analysis note does');
        Assert.isTrue(AntsuranceClaimRules.isClaudeNote(byAuthor), 'It is attributed to Claude');
        Assert.isFalse(AntsuranceClaimRules.isClaudeNote(null), 'Nothing is not a note');
        Assert.isTrue(AntsuranceClaimRules.claudeAuthor().startsWith('Claude, saved by '), 'Says who kept it');

        List<File_Note__c> kept = AntsuranceClaimRules.withoutClaudeNotes(new List<File_Note__c>{ byPerson, byOpening, byAuthor });
        Assert.areEqual(1, kept.size(), 'Only the person\'s note is evidence');
        Assert.areEqual(byPerson.Body__c, kept[0].Body__c, 'In place');
        Assert.isTrue(AntsuranceClaimRules.withoutClaudeNotes(null).isEmpty(), 'No notes, none kept');
    }

    @IsTest
    static void theRuleSaysTheDeductibleIsNotAGap() {
        Assert.isTrue(AntsuranceClaimRules.RESERVE_RULE.contains('estimate less the deductible'), 'What the reserve is measured against');
        Assert.isTrue(AntsuranceClaimRules.RESERVE_RULE.contains('never describe the deductible as a gap'), 'The deductible is not a shortfall');
        Assert.isTrue(AntsuranceClaimRules.RESERVE_RULE.contains('show the sum'), 'A recommendation shows its sum');
        Assert.isTrue(AntsuranceClaimRules.LASTING_WORDS.contains('never write today, tonight, tomorrow or yesterday: give the date'), 'What is stored names the date, not the day');
        Assert.isTrue(AntsuranceClaimRules.LASTING_WORDS.contains('how long it has been open'), 'And never an age, which is only true on the day it was written');
        Assert.isTrue(AntsuranceClaimRules.RESERVE_RULE.contains('a rate and how long it runs'), 'A cost given as a rate and a duration is documented, so every writer counts rental the same way');
        Assert.isTrue(AntsuranceClaimRules.RESERVE_RULE.contains('say which one is missing'), 'And half of that is not');
        Assert.isTrue(AntsuranceClaimRules.RESERVE_RULE.contains('the $45,000 reserve covers it'), 'And says it in plain words');
        Assert.isTrue(AntsuranceClaimRules.RESERVE_RULE.contains('The deductible comes off once'), 'A cost beyond the estimate is measured against the estimate, not a reserve line');
        Assert.areEqual('Write in American English.', AntsuranceClaimRules.AMERICAN_ENGLISH, 'One line, plain');
    }
}
