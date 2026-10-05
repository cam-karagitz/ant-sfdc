@IsTest
private class AntsuranceAiSettingsTest {
    @IsTest
    static void anOrgWithNoRecordGetsTheBuiltInValues() {
        AntsuranceAiSettings.hasNoRecord = true;

        Assert.areEqual(AntsuranceAiSettings.BUILT_IN_MODEL, AntsuranceAiSettings.model(), 'The built-in model');
        Assert.isTrue(AntsuranceAiSettings.useFastMode(), 'Fast mode stays on, as it was before the setting existed');
        Assert.areEqual(AntsuranceAiSettings.BUILT_IN_FAST_MODE_BETA, AntsuranceAiSettings.fastModeBeta(), 'The built-in beta header');
    }

    @IsTest
    static void theRecordDecidesTheModelAndFastMode() {
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Model__c = ' claude-sonnet-5 ', Fast_Mode__c = false, Fast_Mode_Beta__c = 'fast-mode-later');

        Assert.areEqual('claude-sonnet-5', AntsuranceAiSettings.model(), 'The configured model, trimmed');
        Assert.isFalse(AntsuranceAiSettings.useFastMode(), 'Fast mode is off when the record says so');
        Assert.areEqual('fast-mode-later', AntsuranceAiSettings.fastModeBeta(), 'The configured beta header');
    }

    @IsTest
    static void emptyFieldsFallBackOneByOne() {
        AntsuranceAiSettings.standIn = new Antsurance_AI_Setting__mdt(Model__c = '', Fast_Mode__c = true, Fast_Mode_Beta__c = null);

        Assert.areEqual(AntsuranceAiSettings.BUILT_IN_MODEL, AntsuranceAiSettings.model(), 'An empty model means the built-in one');
        Assert.isTrue(AntsuranceAiSettings.useFastMode(), 'Fast mode is on when ticked');
        Assert.areEqual(AntsuranceAiSettings.BUILT_IN_FAST_MODE_BETA, AntsuranceAiSettings.fastModeBeta(), 'An empty header means the built-in one');
    }

    @IsTest
    static void theDeployedDefaultRecordIsReadable() {
        // Whatever the org's record holds, the three answers are never empty.
        AntsuranceAiSettings.readStoredRecordInTests = true;
        Assert.isFalse(String.isBlank(AntsuranceAiSettings.model()), 'A model is always named');
        Assert.isNotNull(AntsuranceAiSettings.useFastMode(), 'Fast mode is always yes or no');
        Assert.isFalse(String.isBlank(AntsuranceAiSettings.fastModeBeta()), 'A beta header is always named');
    }
}
