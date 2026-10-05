# Giving your customers access to the portal

The portal phase installs the site, its screens and code, one profile and one permission set. It creates no portal users and changes none of your customers' records. Who your customers are, how they sign in and which of them may use the site are your decisions. This page is what Claude Code works through with you after the portal is installed. Every step that changes the org gets a yes first.

## What the install gave you

1. **The site**, named Antsurance, with sign-in required. Self-registration is off. Its sign-in and forgotten-password pages are Salesforce's stock ones.
2. **A profile, "Antsurance Customer"**, on the Customer Community license. It is a member of the site. It gives no access to any object or field.
3. **A permission set, "Antsurance Portal Customer"** (`Antsurance_Portal`): the five portal Apex classes and use of the stored Claude key. Nothing else.
4. **How a customer sees only their own records.** They have no object access at all. Every read and write goes through the portal's Apex, which works out the customer from the signed-in user's own contact and account, never from anything the browser sends, and checks every record against that account. So there is no sharing rule or sharing set to configure for the portal, and none should be added to make it work.

## What is yours to set up

Ask these with AskUserQuestion, one decision at a time, and say what each changes.

1. **Which license your customers are on.** Check what the org has free: `SELECT Name, TotalLicenses, UsedLicenses FROM UserLicense WHERE Name LIKE 'Customer Community%' OR Name LIKE 'External%'`. The shipped profile is for Customer Community. If your customers are on another license (Customer Community Plus, Customer Community Login, External Apps), the profile to use is one of yours on that license, or a copy of ours made for it. Say which licenses are free and recommend the one they already use for customers.
2. **Our profile, or one you already have.** If the org has no customer site yet, use "Antsurance Customer". If it already has a customer profile, keep it: do not edit it. Give those users the "Antsurance Portal Customer" permission set, which carries everything the portal needs, and add their profile to the site's members (Setup, Digital Experiences, All Sites, Workspaces, Administration, Members). Adding a profile to a site's members is a change to the site, not to the profile; it still gets its own yes.
3. **Which customers.** A portal user is a contact under an account. Start with one, a test contact of your own, before any real customer. A real customer gets a sign-in only when the person says so by name or by a rule they state ("every primary insured on an active policy"); never enable a list on your own.
4. **The account's owner needs a role.** Salesforce refuses to make a portal user under an account whose owner has no role. Check the owner of each account first and say so before changing anyone's role.
5. **Making the user.** Either press "Enable Customer User" on the contact (it is in the page's action menu), or create the user with that contact, the profile, a username, and the welcome email switched off until the person wants customers told. Then assign "Antsurance Portal Customer".
6. **How they sign in.** With a username and password by default. If the org has single sign-on or its own registration page for customers, that is configured on the site, by them; point to Setup, Digital Experiences, All Sites, Workspaces, Administration, Login and Registration. Do not switch self-registration on unless they ask for it and name the profile and account new people land in.
7. **Publishing.** A change to the site's pages or to a portal component shows to customers only after the site is published again.
8. **What it costs.** Each question a customer asks Claude is a call on the stored API key. Say so before many customers are enabled.

## See it as a customer, with no password

On a contact that has a portal user, "Log in to Experience as User" opens the site as that customer. Use it to check, with the person watching: the home page shows only that customer's policies and claims; another customer's record cannot be opened; a claim or a request sent from the portal arrives in the internal app as that customer's.

## If you fitted the portal to your own objects

The rule in item 4 of the first list is the one that must survive: the adapted Apex still works out the customer from the signed-in user and still checks every record against that customer's account. The portal's tests prove it with two customers in different households; the adapted tests must prove the same on your objects. Never replace that check with object access on a customer profile.

## Taking it away again

1. To stop one customer using the site, deactivate their user. A contact with a portal user cannot be deleted until the user is deactivated.
2. Before the portal is removed (`uninstall.py --capability portal`), deactivate the portal users or move them to another profile. The removal has been proven on a site with no portal users; with users on the "Antsurance Customer" profile, Salesforce will not delete the profile, and the removal stops and says so.
3. Digital Experiences stays on afterwards. Salesforce does not let it be switched off.
