# A worked example: fitting a part to another data model

Acme is an invented customer. It keeps policies in an object of its own, `Acme_Policy__c`, which is not ours and not shaped like ours. This folder shows both kinds of fitting on it. Nothing here is installed by the kit: it is for reading, and for trying in a scratch org.

| Folder or file | What it is |
|---|---|
| `model/` | Acme's own model: `Acme_Policy__c`, a lookup from Case to it, and the permission set `Acme_Policies`. It stands in for an org's own objects. |
| `mapping.json` | The mapping from our policy trigger to Acme's object. |
| `mapping-flow.json` | The mapping for one flow: the task a policy's owner gets when its premium is past due. |
| `mapping-component.json` | The mapping for one screen component with its Apex: the customer summary card. It uses every kind of answer a mapping can give. |
| `ask-claude-model/` | `AcmeClaudeModel`, the smallest class that teaches the Ask Claude chat about Acme's policies, with its test and the one-file setting that names it. |

## How Acme's policy differs from ours

1. **Other names.** `Customer__c` for our `Account__c`, `Customer_Name__c` for `Policyholder_Name__c`, `Policy_Status__c`, `Start_Date__c`, `End_Date__c`.
2. **A lookup where ours is a master-detail.** An Acme policy can have no customer.
3. **Another picklist value.** "In Force" where ours says "Active".
4. **A shorter text field.** 120 characters where ours holds 255.
5. **A policy number that is an auto number.** Ours is text a test can set.
6. **A required field we have nothing like.** `Region__c`.

## Fitting our policy trigger to it

Our trigger copies the policyholder's name onto the policy as text, so that a search finds the policy by it.

```
python3 scripts/setup/describe_capability.py --capability automation --only ApexTrigger:AntsurancePolicyTrigger
python3 scripts/setup/adapt_capability.py --capability automation --mapping examples/acme/mapping.json --out adapted/ --org-metadata examples/acme/model
```

The adapter writes six files (`AcmePolicyTrigger`, `AcmePolicyAutomation`, `AcmePolicyAutomationTest` and their meta files) and `adapted/ADAPT-REPORT.md`. The trigger and its class need nothing more. The test does, and the report says where and why: it gives a policy a name, which Acme numbers itself; it finds policies by that name afterwards; and it never sets `Region__c`. Those three are finished by hand, keeping every assertion.

## Fitting a flow to it

```
python3 scripts/setup/adapt_capability.py --capability automation --mapping examples/acme/mapping-flow.json --out adapted-flow/ --org-metadata examples/acme/model
```

Our flow gives the customer's owner a task to call when a policy's payment status becomes "Past Due". Acme calls that field `Billing_State__c` and the value "Overdue", and its policy's customer is `Customer__c`. The adapter writes one file, `Acme_Policy_Past_Due_Follow_Up`, with all six names changed, and flags one place: the task's owner comes from the policy's customer, and an Acme policy can have none. By hand, one condition is added to the flow's start (the customer is not empty), and a test class is written that saves an overdue policy and reads the task back.

## Fitting a screen component and its Apex to it

```
python3 scripts/setup/describe_capability.py --capability components --only LightningComponentBundle:antsuranceCustomerSummary
python3 scripts/setup/adapt_capability.py --capability components --mapping examples/acme/mapping-component.json --out adapted-component/ --org-metadata examples/acme/model
```

The customer summary card shows a customer's policies, premium, open claims and loss ratio. It leans on much more of our model than the trigger or the flow, and its mapping shows each kind of answer:

1. **This is that of theirs.** Eight policy fields, and `Case.Policy__c`, which is Acme's `Case.Acme_Policy__c`. Two lookups also name the list of children Acme's lookup gives (`"childRelationship"`), which the component opens.
2. **Create ours beside theirs.** `Case.Reserve_Amount__c` and `Case.Paid_Amount__c`: Acme has nothing like them and wants the loss figures.
3. **Leave it out.** The customer-since date, the household role, four claim fields.
4. **A record type that is a field value there.** Acme tells a claim by `Case.Type` and a broker by `Account.Type`.
5. **A picklist value with no match.** Acme has no "Pending Renewal".

The adapter writes 22 files with 102 names changed and flags 34 places. What is finished by hand, and why the report sends you to each:

1. **The class** (10 edits): the two record type checks become checks of `Type`; the lines for what was left out come out; the value with no match leaves the list of statuses that count as in force; a policy with no customer is allowed for.
2. **The script** (4 edits): the colors by status are keyed by Acme's values, which the adapter never changes in a script; one object name it could not tell from a field; the component's own class name and a comment.
3. **The test**: ours loads our sample records. Acme has none of that, so the test builds Acme's own customers, policies and claims, keeps every assertion that still has a meaning, turns around the two about the customer-since date that was left out, and gains one for a policy with no customer.
4. **Access**: the two new fields are added to `Acme_Policies`.

## Teaching the chat about Acme's policies

The chat reads Acme's schema by itself. `AcmeClaudeModel` adds what a schema cannot say: that the record is called a policy, whether it is in force today and how many days it still runs, and two starting points about policies. It extends `AntsuranceClaudeModel` and calls `super` for everything else.

The chat finds it through one setting: `Chat_Model_Class__c` on the `Default` record of Antsurance AI Setting. `ask-claude-model/main/default/customMetadata/` holds that record with the value set, as one file to deploy.

Salesforce lets a class of ours be deleted from under a class like this one, and `AcmeClaudeModel` then stops compiling. The kit's removal asks the org first and stops, naming it. Take the class and its setting out before removing the chat, or keep the chat.

To try it in a scratch org that has Ask Claude (`deploy_phase.py --only ask-claude`), from this folder, which is a small Salesforce project of its own:

```
cd examples/acme
sf project deploy start --source-dir model --target-org <alias>
sf org assign permset --name Acme_Policies --target-org <alias>
sf project deploy start --source-dir ask-claude-model --target-org <alias> --ignore-conflicts --test-level RunSpecifiedTests --tests AcmeClaudeModelTest
```

`--ignore-conflicts` is for a scratch org, which tracks changes: the setting record is already in the org from the install, and without the flag the deploy stops at "1 conflicts detected".

The last command also deploys the setting that names the class, so from then on the chat in that org uses `AcmeClaudeModel`.
