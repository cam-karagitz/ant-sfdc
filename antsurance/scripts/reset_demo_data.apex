// Reloads the demo data and prints everything needed to check it, in one run, so a reload costs the
// org as few API requests as possible (a Developer Edition org allows 15,000 in any 24 hours).
AntsuranceDemoData.reset();
Integer flagged = AntsuranceRenewalJob.flagUpcomingRenewals();
// Attach the sample claim documents (an invoice, an estimate, a crash report, a photo) for Claude to read.
AntsuranceClaimsAssistantDemo.attachSampleDocuments();
// Attach the sample damage photos to the two claims that show the photo assessment.
AntsuranceClaimsAssistantPhotos.attachSamplePhotos();
System.debug(LoggingLevel.ERROR, 'RESET flagged=' + flagged + ' cpu=' + Limits.getCpuTime() + ' dml=' + Limits.getDmlStatements() + ' rows=' + Limits.getDmlRows() + ' soql=' + Limits.getQueries());

// Record counts, and their total against the storage budget of about 2,150.
String counts = '';
Integer total = 0;
for (String name : new List<String>{
    'Account', 'Contact', 'Policy__c', 'Policy_Coverage__c', 'Policy_Participant__c', 'Policy_Asset__c', 'Policy_Endorsement__c',
    'Case', 'File_Note__c', 'Opportunity', 'Quote', 'Task', 'Lead'
}) {
    Integer found = Database.countQuery('SELECT COUNT() FROM ' + name);
    counts += name.removeEnd('__c') + '=' + found + ' ';
    total += found;
}
System.debug(LoggingLevel.ERROR, 'COUNTS total=' + total + ' ' + counts.trim());

// Loss ratio by line for policies in force: incurred losses over a year of premium.
String ratios = '';
Decimal premium = 0;
Decimal incurred = 0;
for (AggregateResult line : [
    SELECT Line_of_Business__c line, SUM(Annual_Premium__c) premium, SUM(Incurred_Losses__c) incurred
    FROM Policy__c
    WHERE Status__c IN ('Active', 'Pending Renewal')
    GROUP BY Line_of_Business__c
    ORDER BY Line_of_Business__c
]) {
    Decimal linePremium = (Decimal) line.get('premium');
    Decimal lineIncurred = line.get('incurred') == null ? 0 : (Decimal) line.get('incurred');
    ratios += line.get('line') + '=' + (lineIncurred / linePremium * 100).setScale(0) + '% ';
    premium += linePremium;
    incurred += lineIncurred;
}
System.debug(LoggingLevel.ERROR, 'LOSS book=' + (incurred / premium * 100).setScale(0) + '% premium=' + premium.setScale(0) + ' incurred=' + incurred.setScale(0) + ' | ' + ratios.trim());
// The two claims that carry sample documents. Files can only be counted for a known set of records.
Set<Id> documentClaims = new Map<Id, Case>(
    [SELECT Id FROM Case WHERE Subject IN ('Burst pipe flooded finished basement', 'Rear-ended at a red light on Harlem Ave')]
).keySet();
System.debug(LoggingLevel.ERROR, 'CHECKS policiesInForce=' + [SELECT COUNT() FROM Policy__c WHERE Status__c IN ('Active', 'Pending Renewal')] +
    ' openClaims=' + [SELECT COUNT() FROM Case WHERE RecordType.DeveloperName = 'Claim' AND IsClosed = FALSE] +
    ' quotesForUnderwriter=' + [SELECT COUNT() FROM Quote WHERE Needs_Underwriting_Review__c = TRUE] +
    ' claimFiles=' + [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId IN :documentClaims]);
