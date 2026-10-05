// Gives the demo customer Maria Reyes (Reyes Household) a sign-in to the customer portal, or repairs it.
// Run after the demo data is loaded: sf apex run --file scripts/portal_user.apex --target-org "$SF_TARGET_ORG"
// A portal account's owner must have a role, so the owner is given one if they have none.
// No email is sent. Sign in as her from Setup, or with the "log in to experience as user" link the script prints.
Contact maria = [SELECT Id, AccountId, Account.OwnerId, FirstName, LastName, Email FROM Contact WHERE Account.Name = 'Reyes Household' AND FirstName = 'Maria' AND LastName = 'Reyes' LIMIT 1];
User owner = [SELECT Id, UserRoleId FROM User WHERE Id = :maria.Account.OwnerId];
if (owner.UserRoleId == null) {
    owner.UserRoleId = [SELECT Id FROM UserRole WHERE Name = 'CEO' LIMIT 1].Id;
    update owner;
}
Id profileId = [SELECT Id FROM Profile WHERE Name = 'Antsurance Customer'].Id;
String username = 'maria.reyes@portal.antsurance.demo';
List<User> existing = [SELECT Id, ContactId, IsActive FROM User WHERE Username = :username];
User customer;
if (existing.isEmpty()) {
    customer = new User(
        ContactId = maria.Id, ProfileId = profileId, Username = username, Email = 'maria.reyes@example.com',
        FirstName = 'Maria', LastName = 'Reyes', Alias = 'mreyes', CommunityNickname = 'maria.reyes',
        EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', TimeZoneSidKey = 'America/Chicago'
    );
    Database.DMLOptions quiet = new Database.DMLOptions();
    quiet.EmailHeader.triggerUserEmail = false;
    quiet.EmailHeader.triggerAutoResponseEmail = false;
    Database.insert(customer, quiet);
} else {
    customer = existing[0];
}
Id permissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Antsurance_Portal'].Id;
if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :customer.Id AND PermissionSetId = :permissionSetId] == 0) {
    insert new PermissionSetAssignment(AssigneeId = customer.Id, PermissionSetId = permissionSetId);
}
Network site = [SELECT Id, Name, Status, UrlPathPrefix FROM Network WHERE Name = 'Antsurance' LIMIT 1];
System.debug(LoggingLevel.ERROR, '\nPORTALUSER user=' + customer.Id + ' contact=' + maria.Id + ' account=' + maria.AccountId + ' network=' + site.Id + ' status=' + site.Status + ' prefix=' + site.UrlPathPrefix + ' org=' + UserInfo.getOrganizationId() +
    '\nLOGINAS ' + URL.getOrgDomainUrl().toExternalForm() + '/servlet/servlet.su?oid=' + UserInfo.getOrganizationId() + '&retURL=%2F' + maria.Id + '&sunetworkid=' + String.valueOf(site.Id).left(15) + '&sunetworkuserid=' + String.valueOf(customer.Id).left(15) +
    '\nSITE ' + Network.getLoginUrl(site.Id) + '\nPORTALEND');
