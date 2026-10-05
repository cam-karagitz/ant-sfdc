AntsuranceDemoData.clear();
// Claude's desk rows point at the records just cleared, so they go too.
delete [SELECT Id FROM Claude_Work__c];
