@IsTest
private class AntsuranceDemoAddressesTest {
    @IsTest
    static void theSwitchIsOffUnlessAsked() {
        Assert.areEqual('1 Given St', AntsuranceDemoAddresses.street('reyes', '1 Given St'), 'The street given is kept');
    }

    @IsTest
    static void withTheSwitchOnAHouseholdGetsItsInventedStreet() {
        AntsuranceDemoAddresses.useSample = true;

        String sample = AntsuranceDemoAddresses.street('reyes', '1 Given St');
        Assert.areEqual(AntsuranceDemoAddresses.SAMPLE_STREETS.get('reyes'), sample, 'The invented street for that household');
        Assert.areNotEqual('1 Given St', sample, 'Not the one given');
        Assert.areEqual('9 Trade Rd', AntsuranceDemoAddresses.street('some-business', '9 Trade Rd'), 'A key with no invented street keeps its own');
        Assert.isNull(AntsuranceDemoAddresses.street('reyes', null), 'An agency with no street stays without one');
    }

    @IsTest
    static void noTwoHouseholdsShareAnInventedStreet() {
        Set<String> streets = new Set<String>(AntsuranceDemoAddresses.SAMPLE_STREETS.values());
        Assert.areEqual(AntsuranceDemoAddresses.SAMPLE_STREETS.size(), streets.size(), 'Every invented street is used once');
    }
}
