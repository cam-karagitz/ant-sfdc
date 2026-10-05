@IsTest
private class AntsuranceTasksControllerTest {
    @TestSetup
    static void createTasks() {
        Account customer = new Account(Name = 'Harbor Household');
        insert customer;
        Contact person = new Contact(LastName = 'Harbor', FirstName = 'Mina', AccountId = customer.Id);
        insert person;
        Date today = Date.today();
        Policy__c policy = new Policy__c(
            Name = 'ANT-HO-1', Account__c = customer.Id, Status__c = 'Active', Line_of_Business__c = 'Homeowners', Annual_Premium__c = 1000,
            Effective_Date__c = today.addMonths(-6), Expiration_Date__c = today.addMonths(6)
        );
        insert policy;
        Opportunity sale = new Opportunity(Name = 'Harbor umbrella', AccountId = customer.Id, StageName = 'Quote Issued', CloseDate = today.addDays(20));
        insert sale;
        Quote option = new Quote(OpportunityId = sale.Id, Name = 'Standard limit', Status = 'Issued', Annual_Premium__c = 500, Issued_Date__c = today);
        insert option;
        Map<String, Schema.RecordTypeInfo> caseTypes = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName();
        Case claim = new Case(Subject = 'Burst pipe', AccountId = customer.Id, Status = 'Under Investigation', RecordTypeId = caseTypes.get('Claim').getRecordTypeId());
        Case request = new Case(Subject = 'Add a driver', AccountId = customer.Id, Status = 'New', RecordTypeId = caseTypes.get('Policy_Service').getRecordTypeId());
        insert new List<Case>{ claim, request };
        insert new List<Task>{
            new Task(Subject = 'Overdue call', ActivityDate = today.addDays(-2), Priority = 'Normal', Status = 'Not Started', WhatId = claim.Id, WhoId = person.Id),
            new Task(Subject = 'Due today', ActivityDate = today, Priority = 'High', Status = 'Not Started', WhatId = option.Id),
            new Task(Subject = 'Tomorrow, on a request', ActivityDate = today.addDays(1), Priority = 'Normal', Status = 'Not Started', WhatId = request.Id),
            new Task(Subject = 'Next week, on a policy', ActivityDate = today.addDays(7), Priority = 'Normal', Status = 'Not Started', WhatId = policy.Id),
            new Task(Subject = 'Later, on a sale', ActivityDate = today.addDays(20), Priority = 'Normal', Status = 'Not Started', WhatId = sale.Id),
            new Task(Subject = 'No date, about nothing', Priority = 'Normal', Status = 'Not Started'),
            new Task(Subject = 'Already done', ActivityDate = today.addDays(-5), Priority = 'Normal', Status = 'Completed', WhatId = claim.Id)
        };
    }

    @IsTest
    static void listsOpenTasksSoonestFirstAndCountsTheOverdue() {
        Test.startTest();
        AntsuranceTasksController.Board board = AntsuranceTasksController.getMyOpenTasks();
        Test.stopTest();

        Assert.areEqual(6, board.openCount, 'Completed tasks are not counted');
        Assert.areEqual(1, board.overdueCount, 'One task is past due');
        Assert.areEqual(6, board.tasks.size(), 'Every open task is listed');
        Assert.areEqual('Overdue call', board.tasks[0].subject, 'The overdue task comes first');
        Assert.areEqual('No date, about nothing', board.tasks[5].subject, 'A task with no date comes last');
        Assert.areEqual(Date.today(), board.today, 'The page is told which day the groups are measured from');
    }

    @IsTest
    static void namesWhatEachTaskIsAboutInWords() {
        Test.startTest();
        AntsuranceTasksController.Board board = AntsuranceTasksController.getMyOpenTasks();
        Test.stopTest();

        Map<String, AntsuranceTasksController.Row> bySubject = new Map<String, AntsuranceTasksController.Row>();
        for (AntsuranceTasksController.Row row : board.tasks) {
            bySubject.put(row.subject, row);
        }
        AntsuranceTasksController.Row onClaim = bySubject.get('Overdue call');
        Assert.areEqual('Burst pipe', onClaim.relatedName, 'A claim is named by its subject, not its number');
        Assert.areEqual('Claim', onClaim.relatedKind, 'A claim is called a claim');
        Assert.areEqual('Mina Harbor', onClaim.contactName, 'The person the task is with is named');
        Assert.areEqual('Service request', bySubject.get('Tomorrow, on a request').relatedKind, 'A service request is called one');
        Assert.areEqual('Harbor umbrella, Standard limit', bySubject.get('Due today').relatedName, 'A quote is named by its sale and option');
        Assert.areEqual('Quote', bySubject.get('Due today').relatedKind, 'A quote is called a quote');
        Assert.areEqual('ANT-HO-1, Harbor Household', bySubject.get('Next week, on a policy').relatedName, 'A policy carries its policyholder');
        Assert.areEqual('Policy sale', bySubject.get('Later, on a sale').relatedKind, 'A sale is called a policy sale');
        Assert.isNull(bySubject.get('No date, about nothing').relatedName, 'A task about nothing has no related name');
    }

    @IsTest
    static void aUserWithNoTasksGetsAnEmptyBoard() {
        delete [SELECT Id FROM Task];
        Test.startTest();
        AntsuranceTasksController.Board board = AntsuranceTasksController.getMyOpenTasks();
        Test.stopTest();

        Assert.areEqual(0, board.openCount, 'Nothing is open');
        Assert.isTrue(board.tasks.isEmpty(), 'Nothing is listed');
    }
}
