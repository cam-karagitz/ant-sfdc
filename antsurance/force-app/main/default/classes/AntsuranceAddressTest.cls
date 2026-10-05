/**
 * @description Tests for AntsuranceAddress: one way to read and write a state and country, in an org with
 * state and country picklists and in one without.
 */
@IsTest
private class AntsuranceAddressTest {
    @IsTest
    static void aStateWrittenIsTheStateReadBack() {
        Account household = new Account(Name = 'Address Household', BillingCity = 'Naperville');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        Assert.areEqual('IL', AntsuranceAddress.state(household, 'Billing'), 'A record built in memory gives its state back');

        insert household;
        Account saved = [SELECT BillingState FROM Account WHERE Id = :household.Id];
        Assert.areEqual('IL', AntsuranceAddress.state(saved, 'Billing'), 'A saved record read by its text field gives the two-letter state');

        Contact person = new Contact(LastName = 'Address', AccountId = household.Id);
        AntsuranceAddress.put(person, 'Mailing', AntsuranceAddress.state(household, 'Billing'), 'US');
        insert person;
        Assert.areEqual('IL', AntsuranceAddress.state([SELECT MailingState FROM Contact WHERE Id = :person.Id], 'Mailing'), 'A contact works the same way');

        Lead prospect = new Lead(LastName = 'Address', Company = 'Address Co');
        AntsuranceAddress.put(prospect, '', 'WI', 'US');
        insert prospect;
        Assert.areEqual('WI', AntsuranceAddress.state([SELECT State FROM Lead WHERE Id = :prospect.Id], ''), 'A lead has no prefix');
    }

    @IsTest
    static void anOrgWithoutThePicklistsUsesTheTextFields() {
        AntsuranceAddress.picklists = false;
        Assert.areEqual('BillingState', AntsuranceAddress.stateField('Billing'), 'The text field holds the state');
        Assert.areEqual('MailingCountry', AntsuranceAddress.countryField('Mailing'), 'The text field holds the country');
        Assert.areEqual('State', AntsuranceAddress.stateField(null), 'A lead has no prefix');

        // Not saved: this org may have the picklists on, and then the text field would want the state's name.
        Account household = new Account(Name = 'Text Household');
        AntsuranceAddress.put(household, 'Billing', 'IL', 'US');
        Assert.areEqual('IL', household.BillingState, 'The state is stored as text');
        Assert.areEqual('US', household.BillingCountry, 'The country is stored as text');
        Assert.areEqual('IL', AntsuranceAddress.state(household, 'Billing'), 'And read back from the text field');
    }

    @IsTest
    static void anOrgWithThePicklistsUsesTheCodeFields() {
        AntsuranceAddress.picklists = true;
        Assert.areEqual('BillingStateCode', AntsuranceAddress.stateField('Billing'), 'The code field holds the state');
        Assert.areEqual('CountryCode', AntsuranceAddress.countryField(''), 'The code field holds the country');
    }

    @IsTest
    static void aNameOrACodeBecomesACode() {
        Assert.areEqual('IL', AntsuranceAddress.code('Illinois'), 'A name becomes its code');
        Assert.areEqual('NY', AntsuranceAddress.code(' new york '), 'Case and spaces do not matter');
        Assert.areEqual('WI', AntsuranceAddress.code('wi'), 'A code is put in capitals');
        Assert.areEqual('Ontario', AntsuranceAddress.code('Ontario'), 'A name it does not know is left alone');
        Assert.isNull(AntsuranceAddress.code('  '), 'Nothing gives nothing');
        Assert.isNull(AntsuranceAddress.state(null, 'Billing'), 'No record gives nothing');
        Assert.isNull(AntsuranceAddress.state(new Account(Name = 'No address'), 'Billing'), 'No state gives nothing');
        AntsuranceAddress.put(null, 'Billing', 'IL', 'US');
    }
}
