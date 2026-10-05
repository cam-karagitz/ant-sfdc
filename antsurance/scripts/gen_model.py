"""One-off generator, part 2: households, policy participants and coverages (not part of the project)."""
import os, sys, importlib.util
# Run with -I (as the docs say) and Python leaves this folder off its path, so it is put back for gen_shared.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_shared import OWN_TABS
ROOT = sys.argv[1]
spec = importlib.util.spec_from_file_location('gen', sys.argv[2]); gen = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0], ROOT]; spec.loader.exec_module(gen)   # re-runs part 1, which is idempotent
write, field, picklist, esc, NS, CURRENCY, DATE = gen.write, gen.field, gen.picklist, gen.esc, gen.NS, gen.CURRENCY, gen.DATE
rt_picklist, listview, flt = gen.rt_picklist, gen.listview, gen.flt

# ---------------- Account record types: Household, Business, Agency ----------------
def account_rt(name, label, desc, segment, compact, extra=()):
    write(f'objects/Account/recordTypes/{name}.recordType-meta.xml', f'<RecordType {NS}>\n    <fullName>{name}</fullName>\n    <active>true</active>\n'
          f'    <compactLayoutAssignment>{compact}</compactLayoutAssignment>\n    <description>{esc(desc)}</description>\n    <label>{label}</label>\n'
          + rt_picklist('Customer_Segment__c', [segment], segment) + ''.join(extra) + '</RecordType>')
INDUSTRIES = ['Construction', 'Food %26 Beverage', 'Healthcare', 'Hospitality', 'Manufacturing', 'Recreation', 'Retail', 'Transportation', 'Insurance', 'Other']
account_rt('Household', 'Household', 'A family or individual who holds personal lines policies. Its contacts are the household members.', 'Personal Lines', 'Household_Compact')
account_rt('Business', 'Business', 'A company that holds commercial lines policies.', 'Commercial Lines', 'Business_Compact', [rt_picklist('Industry', INDUSTRIES)])
account_rt('Agency', 'Agency', 'An independent agency or broker that places business with Antsurance.', 'Agency Partner', 'Agency_Compact', [rt_picklist('Industry', ['Insurance'], 'Insurance')])
def compact(obj, name, label, fields):
    write(f'objects/{obj}/compactLayouts/{name}.compactLayout-meta.xml', f'<CompactLayout {NS}>\n    <fullName>{name}</fullName>\n' + ''.join(f'    <fields>{f}</fields>\n' for f in fields) + f'    <label>{label}</label>\n</CompactLayout>')
compact('Account', 'Household_Compact', 'Household Compact Layout', ['Name', 'Active_Policies__c', 'Premium_in_Force__c', 'Customer_Since__c', 'Phone'])
compact('Account', 'Business_Compact', 'Business Compact Layout', ['Name', 'Industry', 'Active_Policies__c', 'Premium_in_Force__c', 'Customer_Since__c', 'Phone'])
# An agency holds no policies of its own, so its compact layout leaves out the policy count and premium, which would read as zero.
compact('Account', 'Agency_Compact', 'Agency Compact Layout', ['Name', 'Phone', 'Website'])
ACOLS = ['ACCOUNT.NAME', 'Active_Policies__c', 'Premium_in_Force__c', 'Customer_Since__c', 'ACCOUNT.ADDRESS1_CITY', 'ACCOUNT.PHONE1']
listview('Account', 'Households', 'Households', ACOLS, flt('ACCOUNT.RECORDTYPE', 'equals', 'Account.Household'))
listview('Account', 'Business_Customers', 'Businesses', ACOLS, flt('ACCOUNT.RECORDTYPE', 'equals', 'Account.Business'))
listview('Account', 'Agencies', 'Agencies', ['ACCOUNT.NAME', 'ACCOUNT.ADDRESS1_CITY', 'ACCOUNT.PHONE1'], flt('ACCOUNT.RECORDTYPE', 'equals', 'Account.Agency'))

# ---------------- Contact: household membership ----------------
field('Contact', 'Household_Role__c', 'Household Role', 'Picklist', picklist(['Head of Household', 'Spouse or Partner', 'Dependent', 'Other Household Member']),
      desc='This person\'s place in their household. Blank for business contacts.')
field('Contact', 'Primary_Member__c', 'Primary Member', 'Checkbox', '    <defaultValue>false</defaultValue>', desc='The main person Antsurance deals with for this household or business.')
field('Contact', 'Licensed_Driver__c', 'Licensed Driver', 'Checkbox', '    <defaultValue>false</defaultValue>', desc='Holds a driver license, so can be rated as a driver on an auto policy.')

# ---------------- Policy: agency as a real relationship ----------------
field('Policy__c', 'Producer__c', 'Producer', 'Lookup', '''    <deleteConstraint>SetNull</deleteConstraint>
    <referenceTo>Account</referenceTo>
    <relationshipLabel>Policies Produced</relationshipLabel>
    <relationshipName>Policies_Produced</relationshipName>
    <required>false</required>
    <trackHistory>false</trackHistory>''', desc='The agency that sold and services this policy. Blank when Antsurance sold it directly.')

# ---------------- Policy_Participant__c ----------------
def child_object(name, label, plural, desc, name_field):
    write(f'objects/{name}/{name}.object-meta.xml', f'''<CustomObject {NS}>
    <deploymentStatus>Deployed</deploymentStatus>
    <description>{esc(desc)}</description>
    <enableActivities>false</enableActivities>
    <enableBulkApi>true</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>false</enableSearch>
    <enableSharing>true</enableSharing>
    <enableStreamingApi>true</enableStreamingApi>
    <label>{label}</label>
{name_field}
    <pluralLabel>{plural}</pluralLabel>
    <sharingModel>ControlledByParent</sharingModel>
    <visibility>Public</visibility>
</CustomObject>''')
def master(obj, rel_label, rel_name, desc):
    field(obj, 'Policy__c', 'Policy', 'MasterDetail', f'''    <referenceTo>Policy__c</referenceTo>
    <relationshipLabel>{rel_label}</relationshipLabel>
    <relationshipName>{rel_name}</relationshipName>
    <relationshipOrder>0</relationshipOrder>
    <reparentableMasterDetail>false</reparentableMasterDetail>
    <writeRequiresMasterRead>false</writeRequiresMasterRead>''', desc=desc)
PP = 'Policy_Participant__c'
child_object(PP, 'Policy Participant', 'Policy Participants',
    'A person with a role on a policy, such as the named insured, a rated driver or a lienholder contact. For drivers it holds the license, rating and three-year driving record that the premium is rated on. Adding a driver to an auto policy adds a participant.',
    '    <nameField>\n        <label>Participant</label>\n        <type>Text</type>\n    </nameField>')
master(PP, 'Participants', 'Participants', 'The policy this person has a role on.')
field(PP, 'Contact__c', 'Person', 'Lookup', '''    <deleteConstraint>SetNull</deleteConstraint>
    <referenceTo>Contact</referenceTo>
    <relationshipLabel>Policy Roles</relationshipLabel>
    <relationshipName>Policy_Roles</relationshipName>
    <required>false</required>''', desc='The person holding this role.')
# A business is the named insured on its own policy, through the policy's account. The person we deal with there is its policy contact.
ROLES = ['Named Insured', 'Additional Insured', 'Policy Contact', 'Driver', 'Excluded Driver', 'Beneficiary', 'Lienholder', 'Certificate Holder']
field(PP, 'Role__c', 'Role', 'Picklist', picklist(ROLES), desc='What this person is on the policy.')
field(PP, 'Is_Primary__c', 'Primary', 'Checkbox', '    <defaultValue>false</defaultValue>', desc='The primary person in this role, for example the first named insured.')
field(PP, 'Effective_Date__c', 'Effective Date', 'Date', DATE, desc='When this person was added to the policy.')

# ---------------- Policy_Coverage__c ----------------
PC = 'Policy_Coverage__c'
child_object(PC, 'Policy Coverage', 'Policy Coverages',
    'One coverage on a policy, such as collision on an auto policy or dwelling on a homeowners policy. It holds the limit and how it applies, the deductible, and the premium for that coverage with its share of the policy premium.',
    '    <nameField>\n        <label>Coverage Name</label>\n        <type>Text</type>\n    </nameField>')
master(PC, 'Coverages', 'Coverages', 'The policy this coverage belongs to.')
CATEGORIES = ['Liability', 'Collision', 'Comprehensive', 'Medical Payments', 'Uninsured Motorist', 'Dwelling', 'Personal Property', 'Loss of Use',
              'Business Property', 'Business Income', 'Workers Compensation', 'Other']
field(PC, 'Category__c', 'Category', 'Picklist', picklist(CATEGORIES), desc='The kind of protection this coverage gives.')
field(PC, 'Limit_Amount__c', 'Limit', 'Currency', CURRENCY, desc='The most this coverage pays for a covered loss.')
field(PC, 'Deductible_Amount__c', 'Deductible', 'Currency', CURRENCY, desc='What the policyholder pays before this coverage applies.')
field(PC, 'Premium_Amount__c', 'Premium', 'Currency', CURRENCY, desc='The part of the annual premium charged for this coverage.')

field('Case', 'Reported_Date__c', 'Received', 'Date', '    <defaultValue>TODAY()</defaultValue>\n    <required>false</required>', desc='When the claim or request was first reported to Antsurance. Defaults to today.')

field('Case', 'Coverage_Check__c', 'Policy in Force', 'Picklist', picklist(['In force on date of loss', 'Outside policy term', 'Policy not in force']),
      desc='Whether the policy covered the date of loss. Set automatically from the policy term and status when a claim is saved.')
write('objects/Case/validationRules/Paid_Within_Reserve.validationRule-meta.xml', f'''<ValidationRule {NS}>
    <fullName>Paid_Within_Reserve</fullName>
    <active>true</active>
    <description>A claim cannot be paid beyond what is reserved for it. The reserve has to be raised first.</description>
    <errorConditionFormula><![CDATA[AND(RecordType.DeveloperName = "Claim", BLANKVALUE(Paid_Amount__c, 0) > BLANKVALUE(Reserve_Amount__c, 0))]]></errorConditionFormula>
    <errorDisplayField>Paid_Amount__c</errorDisplayField>
    <errorMessage>Paid to date cannot be more than the reserve. Raise the reserve first.</errorMessage>
</ValidationRule>''')

# ---------------- Round 2: richer participants and coverages, notes, briefs ----------------
NUM = '    <precision>3</precision>\n    <required>false</required>\n    <scale>0</scale>\n    <unique>false</unique>'
def text(length): return f'    <length>{length}</length>\n    <required>false</required>\n    <unique>false</unique>'
def long_text(lines=6): return f'    <length>32768</length>\n    <visibleLines>{lines}</visibleLines>'
def lookup(to, label, name, required=False):
    return f"""    <deleteConstraint>SetNull</deleteConstraint>
    <referenceTo>{to}</referenceTo>
    <relationshipLabel>{label}</relationshipLabel>
    <relationshipName>{name}</relationshipName>
    <required>false</required>"""
def compact(obj, name, label, fields):
    write(f'objects/{obj}/compactLayouts/{name}.compactLayout-meta.xml', f'<CompactLayout {NS}>\n    <fullName>{name}</fullName>\n' + ''.join(f'    <fields>{f}</fields>\n' for f in fields) + f'    <label>{label}</label>\n</CompactLayout>')
def set_compact(obj, name):
    path = f'{ROOT}/objects/{obj}/{obj}.object-meta.xml'; body = open(path).read()
    if '<compactLayoutAssignment>' not in body:
        open(path, 'w').write(body.replace(f'<CustomObject {NS}>\n', f'<CustomObject {NS}>\n    <compactLayoutAssignment>{name}</compactLayoutAssignment>\n', 1))

field(PP, 'Status__c', 'Status', 'Picklist', picklist(['Active', 'Pending', 'Removed']), desc='Whether this person currently has this role on the policy.')
field(PP, 'Relationship_to_Insured__c', 'Relationship', 'Picklist', picklist(['Self', 'Spouse or Partner', 'Child', 'Other Relative', 'Employee', 'Other']), desc='How this person is related to the named insured.')
field(PP, 'Expiration_Date__c', 'End Date', 'Date', DATE, desc='When this person came off the policy, if they have.')
field(PP, 'License_Number__c', 'License Number', 'Text', text(30), desc='Driver license number. Drivers only.')
field(PP, 'License_State__c', 'License State', 'Text', text(2), desc='Two-letter state that issued the license.')
field(PP, 'Date_Licensed__c', 'Date Licensed', 'Date', DATE, desc='When the driver was first licensed.')
field(PP, 'Years_Licensed__c', 'Years Licensed', 'Number', """    <formula><![CDATA[IF(ISBLANK(Date_Licensed__c), NULL, FLOOR((TODAY() - Date_Licensed__c) / 365.25))]]></formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <unique>false</unique>""", desc='Whole years since the driver was first licensed.')
field(PP, 'Driver_Rating__c', 'Driver Rating', 'Picklist', picklist(['Preferred', 'Standard', 'Non-Standard', 'Inexperienced Operator']), desc='The rating tier this driver falls in, which drives the auto premium.')
field(PP, 'Violations_Past_3_Years__c', 'Violations (3 Years)', 'Number', NUM, desc='Moving violations on the driving record in the past three years.')
field(PP, 'Accidents_Past_3_Years__c', 'At-Fault Accidents (3 Years)', 'Number', NUM, desc='At-fault accidents in the past three years.')
field(PP, 'Good_Student_Discount__c', 'Good Student Discount', 'Checkbox', '    <defaultValue>false</defaultValue>', desc='A young driver with qualifying grades, which earns a discount.')
field(PP, 'Primary_Vehicle__c', 'Primary Vehicle', 'Text', text(120), desc='The vehicle this driver mainly drives.')
field(PP, 'Notes__c', 'Notes', 'LongTextArea', long_text(4), desc='Anything underwriting or service should know about this person on this policy. Markdown is rendered on the record page.')
compact(PP, 'Participant_Compact', 'Policy Participant Compact Layout', ['Name', 'Role__c', 'Status__c', 'Policy__c', 'Contact__c', 'Driver_Rating__c'])
set_compact(PP, 'Participant_Compact')

field(PC, 'Status__c', 'Status', 'Picklist', picklist(['Active', 'Pending', 'Removed']), desc='Whether this coverage is currently on the policy.')
field(PC, 'Limit_Type__c', 'Limit Applies', 'Picklist', picklist(['Per Occurrence', 'Per Person', 'Aggregate', 'Replacement Cost', 'Actual Cash Value', 'Statutory']), desc='How the limit is applied when a claim is paid.')
field(PC, 'Effective_Date__c', 'Effective Date', 'Date', DATE, desc='When this coverage started on the policy.')
field(PC, 'Premium_Share__c', 'Share of Premium', 'Percent', """    <formula><![CDATA[IF(BLANKVALUE(Policy__r.Annual_Premium__c, 0) = 0, 0, Premium_Amount__c / Policy__r.Annual_Premium__c)]]></formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>""", desc='This coverage premium as a share of the policy annual premium.')
field(PC, 'What_Is_Covered__c', 'What Is Covered', 'LongTextArea', long_text(4), desc='Plain-language description of what this coverage pays for and its main exclusions. Markdown is rendered on the record page.')
compact(PC, 'Coverage_Compact', 'Policy Coverage Compact Layout', ['Name', 'Category__c', 'Status__c', 'Limit_Amount__c', 'Deductible_Amount__c', 'Premium_Amount__c'])
set_compact(PC, 'Coverage_Compact')

field('Policy__c', 'Policy_Summary__c', 'Policy Summary', 'Text', """    <formula><![CDATA[Name & " " & TEXT(Line_of_Business__c) & IF(ISBLANK(Insured_Item__c), "", " (" & LEFT(Insured_Item__c, 60) & ")")]]></formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <required>false</required>
    <trackHistory>false</trackHistory>
    <unique>false</unique>""", desc='Policy number, line and insured item on one line, for pickers in flows.')
field('Policy__c', 'Underwriting_Notes__c', 'Underwriting Notes', 'LongTextArea', long_text(8) + '\n    <trackHistory>false</trackHistory>', desc='The underwriter view of the risk: what was considered, conditions and things to watch at renewal. Markdown is rendered on the record page.')
field('Account', 'Customer_Brief__c', 'Customer Brief', 'LongTextArea', long_text(8), desc='A short standing brief on the customer: who they are, how they like to be served and what to watch. Markdown is rendered on the record page.')

FN = 'File_Note__c'
write(f'objects/{FN}/{FN}.object-meta.xml', f"""<CustomObject {NS}>
    <compactLayoutAssignment>File_Note_Compact</compactLayoutAssignment>
    <deploymentStatus>Deployed</deploymentStatus>
    <description>A dated note on a claim, service request, policy or customer file, written by whoever handled it: a call with the insured, an investigation step, a coverage or reserve decision. A note on a case also shows on its policy and customer.</description>
    <enableActivities>false</enableActivities>
    <enableBulkApi>true</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>false</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <enableSharing>true</enableSharing>
    <enableStreamingApi>true</enableStreamingApi>
    <label>File Note</label>
    <nameField>
        <displayFormat>FN-{{00000}}</displayFormat>
        <label>Note Number</label>
        <type>AutoNumber</type>
    </nameField>
    <pluralLabel>File Notes</pluralLabel>
    <sharingModel>ReadWrite</sharingModel>
    <visibility>Public</visibility>
</CustomObject>""")
field(FN, 'Case__c', 'Claim or Request', 'Lookup', lookup('Case', 'File Notes', 'File_Notes'), desc='The claim or service request this note is about.')
field(FN, 'Policy__c', 'Policy', 'Lookup', lookup('Policy__c', 'File Notes', 'File_Notes'), desc='The policy this note is about, or the policy of its claim.')
field(FN, 'Account__c', 'Customer', 'Lookup', lookup('Account', 'File Notes', 'File_Notes'), desc='The customer this note is about, or the customer of its claim or policy.')
field(FN, 'Note_Type__c', 'Type', 'Picklist', picklist(['Contact', 'Investigation', 'Coverage', 'Reserve', 'Payment', 'Underwriting', 'Service', 'General']), desc='What kind of file activity the note records.')
field(FN, 'Body__c', 'Note', 'LongTextArea', long_text(10), desc='The note itself. Markdown is rendered in the File Notes timeline.')
field(FN, 'Note_Date__c', 'Note Date', 'DateTime', '    <defaultValue>NOW()</defaultValue>\n    <required>false</required>', desc='When the activity happened. Defaults to now.')
field(FN, 'Author_Name__c', 'Author', 'Text', text(80), desc='Who wrote the note, with their role. Blank means the user who created it.')
compact(FN, 'File_Note_Compact', 'File Note Compact Layout', ['Name', 'Note_Type__c', 'Note_Date__c', 'Author_Name__c', 'Case__c', 'Policy__c'])

# ---------------- Round 3: endorsements, insured assets, and an icon per object ----------------
PE = 'Policy_Endorsement__c'
child_object(PE, 'Policy Endorsement', 'Policy Endorsements',
    'A form attached to a policy that changes it: an endorsement that adds or alters coverage, an exclusion, a benefit the policyholder is entitled to such as roadside assistance, a discount, or a lienholder interest. It carries the form number and any premium change.',
    '    <nameField>\n        <label>Form Title</label>\n        <type>Text</type>\n    </nameField>')
master(PE, 'Endorsements', 'Endorsements', 'The policy this form is attached to.')
field(PE, 'Form_Number__c', 'Form Number', 'Text', text(30), desc='The form reference printed on the declarations page, such as ANT HO 04 61.')
field(PE, 'Type__c', 'Type', 'Picklist', picklist(['Endorsement', 'Exclusion', 'Benefit', 'Discount', 'Lienholder or Mortgagee']), desc='What the form does to the policy.')
field(PE, 'Status__c', 'Status', 'Picklist', picklist(['Active', 'Pending', 'Removed']), desc='Whether the form currently applies.')
field(PE, 'Effective_Date__c', 'Effective Date', 'Date', DATE, desc='When the form took effect.')
# "Premium" rather than "Premium Change": a money column is narrow, and the longer label was cut off in the policy's list.
field(PE, 'Premium_Change__c', 'Premium', 'Currency', CURRENCY, desc='What the form adds to or takes off the annual premium. Negative for a discount.')
field(PE, 'Limit_Amount__c', 'Limit', 'Currency', CURRENCY, desc='The limit the form adds or changes, if any.')
field(PE, 'Description__c', 'Description', 'LongTextArea', long_text(4), desc='What the form does, in plain language. Markdown is rendered on the record page.')
compact(PE, 'Endorsement_Compact', 'Policy Endorsement Compact Layout', ['Name', 'Form_Number__c', 'Type__c', 'Status__c', 'Premium_Change__c', 'Effective_Date__c'])
set_compact(PE, 'Endorsement_Compact')

PA = 'Policy_Asset__c'
child_object(PA, 'Insured Asset', 'Insured Assets',
    'Something a policy insures: a vehicle with its VIN, a home or commercial building with its address and construction, a fleet or a business operation. A policy can insure several.',
    '    <nameField>\n        <label>Asset</label>\n        <type>Text</type>\n    </nameField>')
master(PA, 'What Is Insured', 'Assets', 'The policy that insures this asset.')
field(PA, 'Asset_Type__c', 'Asset Type', 'Picklist', picklist(['Vehicle', 'Dwelling', 'Rented Residence', 'Commercial Building', 'Business Property', 'Fleet', 'Workplace', 'Operations']), desc='What kind of thing is insured.')
field(PA, 'Identifier__c', 'Reference', 'Text', text(40), desc='The VIN for a vehicle, or a location or schedule number for property.')
field(PA, 'Model_Year__c', 'Model Year or Year Built', 'Text', text(4), desc='Model year of a vehicle, or year built for a building.')
field(PA, 'Location__c', 'Location', 'Text', text(255), desc='Where the vehicle is kept or where the property is.')
# Two plain numbers rather than a compound location field: record pages read these reliably.
COORDINATE = '    <precision>9</precision>\n    <required>false</required>\n    <scale>6</scale>\n    <unique>false</unique>'
field(PA, 'Latitude__c', 'Latitude', 'Number', COORDINATE, desc='Where the asset is, north or south, so it can be shown on a map without looking the address up.')
field(PA, 'Longitude__c', 'Longitude', 'Number', COORDINATE, desc='Where the asset is, east or west, so it can be shown on a map without looking the address up.')
field(PA, 'Use__c', 'Use', 'Text', text(80), desc='How it is used: commute, pleasure, primary residence, owner occupied and so on.')
field(PA, 'Details__c', 'Details', 'Text', text(255), desc='Rating details such as construction, square footage, roof age, annual mileage or safety features.')
# A currency column in a related list is narrow, so the label is one short word and is never cut off.
field(PA, 'Insured_Value__c', 'Value', 'Currency', CURRENCY, desc='The value the asset is insured for.')
field(PA, 'Lienholder__c', 'Lienholder or Mortgagee', 'Text', text(120), desc='The lender with an interest in the asset, if any.')
compact(PA, 'Asset_Compact', 'Insured Asset Compact Layout', ['Name', 'Asset_Type__c', 'Identifier__c', 'Insured_Value__c', 'Location__c'])
set_compact(PA, 'Asset_Compact')

# Each object gets its own icon, so related lists and pages are easy to tell apart. The tabs stay out of the navigation bar.
# Tab icons come with a fixed colour each. These are the warm ones nearest the brand's clay, so a record
# header does not add a green, a pink or a magenta to a page of clay cards (UI audit 4, A4-04).
for obj, motif in [(PC, 'Custom91: Safe'), (PP, 'Custom15: People'), (PE, 'Custom83: Pencil'), (PA, 'Custom16: Bank'), (FN, 'Custom75: PDA')]:
    write(f'tabs/{obj}.tab-meta.xml', f'<CustomTab {NS}>\n    <customObject>true</customObject>\n    <motif>{motif}</motif>\n</CustomTab>')

# ---------------- Round 4: quotes on the standard Quote object ----------------
# Standard Quote hangs off the opportunity already. Its Name is the option, ExpirationDate is "valid until"
# and Description is the coverage summary; these fields add the insurance terms.
# What the reports need to show loss ratio, claim age and who is handling a case.
field('Policy__c', 'Incurred_Losses__c', 'Incurred Losses', 'Currency', CURRENCY,
      desc="Reserves or payments on this policy's claims, whichever is higher for each claim. Kept up to date by AntsuranceCaseAutomation whenever a claim changes.")
field('Policy__c', 'Loss_Ratio__c', 'Loss Ratio', 'Percent', '''    <formula><![CDATA[IF(BLANKVALUE(Annual_Premium__c, 0) = 0, NULL, BLANKVALUE(Incurred_Losses__c, 0) / Annual_Premium__c)]]></formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>1</scale>
    <unique>false</unique>''', desc='Incurred losses as a share of a year of premium. Over 100% means the policy has cost more in claims than it brings in.')
field('Case', 'Kind__c', 'Kind', 'Text', '''    <formula><![CDATA[IF(RecordType.DeveloperName = "Claim", "Claim", "Service request")]]></formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>''', desc='Whether this is a claim or a service request, in words, for lists that show both.')
field('Case', 'Days_Open__c', 'Days Open', 'Number', '''    <formula><![CDATA[IF(ISBLANK(Reported_Date__c), NULL, BLANKVALUE(Closed_On__c, IF(IsClosed, DATEVALUE(ClosedDate), TODAY())) - Reported_Date__c)]]></formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <unique>false</unique>''', desc='Days from when the claim or request was reported until it closed, or until today while it is open.')
field('Case', 'Handled_By__c', 'Handled By', 'Text', text(80), desc='The adjuster working the claim, or the service representative working the request.')
field('Case', 'Closed_On__c', 'Closed On', 'Date', '    <required>false</required>', desc='The day the claim or request was closed. Set when the status moves to a closed one and cleared if it is reopened, so days open stops counting at the close.')
# Search finds a record by its own text fields, not by the name of a record it looks up to, so the policyholder's
# name is kept on the policy as text. AntsurancePolicyTrigger fills it in.
field('Policy__c', 'Policyholder_Name__c', 'Policyholder Name', 'Text', text(255), desc="The policyholder's name as text, so searching for a customer's name also finds their policies. Set when the policy is saved; do not edit.")
field('Policy__c', 'Sold_Through__c', 'Sold Through', 'Text', '''    <formula>IF(ISBLANK(Producer__c), 'Direct', Producer__r.Name)</formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <required>false</required>
    <unique>false</unique>''', desc='The agency that produced the policy, or Direct when Antsurance sold it itself. For grouping reports without a blank bucket.')
field('Case', 'Claude_Brief__c', 'Claude Brief', 'LongTextArea', long_text(8), desc="Claude's written read of the claim: where it stands, coverage, the money, anything to watch and what to do next. Markdown. Written by the claim brief component; regenerate it there rather than editing here.")
field('Case', 'Claude_Brief_At__c', 'Claude Brief Written', 'DateTime', '    <required>false</required>', desc='When the Claude brief was last written, so the page can tell when the claim has changed since.')
# The photo assessment on a claim: what Claude saw in the claim's photographs.
field('Case', 'Photo_Assessment__c', 'Photo Assessment', 'LongTextArea', long_text(6), desc="Claude's assessment of the claim's photographs: the damage in each, whether it fits the reported loss, and what to do next. JSON, written by the claim photos component; assess again there rather than editing here.")
field('Case', 'Photo_Assessment_At__c', 'Photos Assessed', 'DateTime', '    <required>false</required>', desc='When the photo assessment was last made, so the page can tell when photographs have been added since.')
field('Case', 'Photo_Marks__c', 'Photo Marks', 'LongTextArea', long_text(6), desc="Areas a person marked on the claim's photographs, with Claude's answer about each, and a person's changes to the boxes Claude drew. JSON, written by the claim photo viewer; change it there rather than editing here.")
# The coverage check on a claim: Claude's read of whether the policy responds, and the adjuster's confirmation of it.
field('Case', 'Coverage_Read__c', 'Coverage Read', 'LongTextArea', long_text(6), desc="Claude's read of whether the policy responds to this loss, with the records each finding rests on. JSON, written by the coverage check component; check again there rather than editing here.")
field('Case', 'Coverage_Read_At__c', 'Coverage Read Written', 'DateTime', '    <required>false</required>', desc='When the coverage read was last written, so the page can tell when the claim or policy has changed since.')
field('Case', 'Coverage_Verdict__c', 'Coverage Verdict', 'Text', text(20), desc="The coverage read's verdict: Covered, Not covered or Needs review. Advice from Claude until an adjuster confirms it.")
field('Case', 'Coverage_Confirmed_By__c', 'Coverage Confirmed By', 'Text', text(80), desc='The adjuster who read the coverage check and confirmed it. Cleared when coverage is checked again.')
field('Case', 'Coverage_Confirmed_At__c', 'Coverage Confirmed On', 'DateTime', '    <required>false</required>', desc='When the adjuster confirmed the coverage check.')
# The claim analysis: one report over the whole evidence docket, with the readings it was built from.
field('Case', 'Claude_Analysis__c', 'Claude Analysis', 'LongTextArea', '    <length>131072</length>\n    <visibleLines>6</visibleLines>', desc="Claude's analysis of the claim's evidence: the adjuster's report, what each document and video showed, and what the report depended on. JSON, written by the claim analysis component; run it again there rather than editing here.")
field('Case', 'Claude_Analysis_At__c', 'Claude Analysis Written', 'DateTime', '    <required>false</required>', desc='When the claim analysis report was last written.')
# Home's briefing is each person's own, so it is kept on their user record. AntsuranceCockpitController writes it.
field('User', 'Claude_Briefing__c', 'Claude Briefing', 'LongTextArea', long_text(6), desc="Claude's briefing for this person on the Home page, stored as JSON by the Home cockpit. Written again there rather than edited here.")
field('User', 'Claude_Briefing_At__c', 'Claude Briefing Written', 'DateTime', '    <required>false</required>', desc='When the Home briefing was last written, so Home can say how fresh it is.')

QT = 'Quote'
field(QT, 'Annual_Premium__c', 'Annual Premium', 'Currency', CURRENCY, desc='The premium offered for a full policy year.')
field(QT, 'Coverage_Limit__c', 'Coverage Limit', 'Currency', CURRENCY, desc='The limit offered.')
field(QT, 'Deductible__c', 'Deductible', 'Currency', CURRENCY, desc='The deductible offered.')
field(QT, 'Issued_Date__c', 'Issued Date', 'Date', DATE, desc='When the quote went to the customer or their agent.')
field(QT, 'Days_Since_Issued__c', 'Days Since Issued', 'Number', """    <formula><![CDATA[IF(ISBLANK(Issued_Date__c), NULL, TODAY() - Issued_Date__c)]]></formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <unique>false</unique>""", desc='How long the quote has been out. Blank until it is issued.')
field(QT, 'Underwriter__c', 'Underwriter', 'Text', text(80), desc='Who priced the quote.')
field(QT, 'Submission_Channel__c', 'Channel', 'Picklist', picklist(['Phone', 'Online', 'Agent', 'In Person']), desc='How the quote request reached Antsurance.')
field(QT, 'Needs_Underwriting_Review__c', 'Needs Underwriting Review', 'Checkbox', '    <defaultValue>false</defaultValue>', desc='One or more answers call for an underwriter to look at the quote before it is offered.')
field(QT, 'Underwriting_Memo__c', 'Underwriting Memo', 'LongTextArea', long_text(8), desc="Claude's memo for the underwriter on a referred quote, stored as JSON by the underwriting review component. Redraft it there rather than editing here.")
field(QT, 'Underwriting_Decision__c', 'Underwriting Decision', 'Picklist', picklist(['Approved', 'Approved with Conditions', 'Declined']), desc='What the underwriter decided on a quote that was referred for review.')
field(QT, 'Configuration__c', 'Configuration', 'LongTextArea', long_text(4), desc='The answers given in the quote configurator and the price they came to, as JSON. Written by AntsuranceQuoteConfigurator; read it on the quote page rather than here.')
# The option and its price on one line, for pickers in flows: "Standard deductible, $1,560 a year".
field(QT, 'Option_Summary__c', 'Option Summary', 'Text', '''    <formula><![CDATA[IF(ISBLANK(Annual_Premium__c), Name, Name & ", $" & IF(Annual_Premium__c >= 1000, TEXT(FLOOR(Annual_Premium__c / 1000)) & "," & LPAD(TEXT(MOD(FLOOR(Annual_Premium__c), 1000)), 3, "0"), TEXT(FLOOR(Annual_Premium__c))) & " a year")]]></formula>
    <formulaTreatBlanksAs>BlankAsBlank</formulaTreatBlanksAs>
    <required>false</required>
    <unique>false</unique>''', desc='The option name and its annual premium on one line, for pickers in flows.')
gen.svs('QuoteStatus', [{'fullName': v, 'default': str(v == 'Draft').lower(), 'label': v} for v in ['Draft', 'Issued', 'Presented', 'Accepted', 'Bound', 'Declined', 'Expired']])
# Option names repeat from sale to sale ("Guaranteed cost"), so each list leads with the sale the quote belongs to.
QCOLS = ['OPPORTUNITY.NAME', 'QUOTE.NAME', 'QUOTE.STATUS', 'Annual_Premium__c', 'Issued_Date__c', 'QUOTE.EXPIRATIONDATE']
listview(QT, 'Open_Quotes', 'Open Quotes', QCOLS, flt('QUOTE.STATUS', 'equals', 'Draft,Issued,Presented,Accepted'))
listview(QT, 'Waiting_15_Days', 'Waiting 15 Days or More', QCOLS, flt('QUOTE.STATUS', 'equals', 'Issued,Presented') + flt('Days_Since_Issued__c', 'greaterOrEqual', '15'))

# ---------------- Standard objects: names, search results and list views ----------------
def rename(obj, singular, plural, starts_with='Consonant'):
    """Renames a standard object and its tab. Standard field labels cannot be changed this way:
    the platform answers "Cannot translate standard field", so those are renamed in Setup, Rename Tabs and Labels."""
    write(f'objectTranslations/{obj}-en_US/{obj}-en_US.objectTranslation-meta.xml', f'<CustomObjectTranslation {NS}>\n'
          f'    <caseValues>\n        <plural>false</plural>\n        <value>{singular}</value>\n    </caseValues>\n'
          f'    <caseValues>\n        <plural>true</plural>\n        <value>{plural}</value>\n    </caseValues>\n'
          f'    <startsWith>{starts_with}</startsWith>\n</CustomObjectTranslation>')
rename('Account', 'Customer', 'Customers')
rename('Opportunity', 'Policy Sale', 'Policy Sales')

def search_layout(obj, results, recent=None, lookup=None):
    """What a standard object shows in search results, in its tab's recent list and in lookups. No owner alias: one person owns everything here."""
    rows = ''.join(f'        <customTabListAdditionalFields>{f}</customTabListAdditionalFields>\n' for f in (recent or results[:4]))
    rows += ''.join(f'        <lookupDialogsAdditionalFields>{f}</lookupDialogsAdditionalFields>\n' for f in (lookup or results[:3]))
    rows += ''.join(f'        <searchResultsAdditionalFields>{f}</searchResultsAdditionalFields>\n' for f in results)
    write(f'objects/{obj}/{obj}.object-meta.xml', f'<CustomObject {NS}>\n    <searchLayouts>\n{rows}    </searchLayouts>\n</CustomObject>')
search_layout('Account', ['ACCOUNT.NAME', 'Customer_Segment__c', 'Active_Policies__c', 'Premium_in_Force__c', 'ACCOUNT.ADDRESS1_CITY', 'ACCOUNT.PHONE1'],
              recent=['ACCOUNT.NAME', 'Customer_Segment__c', 'ACCOUNT.ADDRESS1_CITY', 'ACCOUNT.PHONE1'])
search_layout('Contact', ['FULL_NAME', 'ACCOUNT.NAME', 'Household_Role__c', 'CONTACT.PHONE1', 'CONTACT.EMAIL'])
search_layout('Case', ['CASES.CASE_NUMBER', 'CASES.SUBJECT', 'ACCOUNT.NAME', 'Policy__c', 'CASES.STATUS'])
search_layout('Opportunity', ['OPPORTUNITY.NAME', 'ACCOUNT.NAME', 'Line_of_Business__c', 'OPPORTUNITY.STAGE_NAME', 'OPPORTUNITY.AMOUNT', 'OPPORTUNITY.CLOSE_DATE'])
search_layout('Lead', ['FULL_NAME', 'LEAD.COMPANY', 'Product_Interest__c', 'LEAD.STATUS', 'LEAD.PHONE'])
search_layout('Quote', ['QUOTE.NAME', 'OPPORTUNITY.NAME', 'QUOTE.STATUS', 'Annual_Premium__c', 'QUOTE.EXPIRATIONDATE'])

# Each tab needs one good list to open on. These reuse Salesforce's own "all" views where it has one,
# so the list is not doubled up, and give them useful columns.
listview('Account', 'AllAccounts', 'All Customers', ['ACCOUNT.NAME', 'Customer_Segment__c', 'Active_Policies__c', 'Premium_in_Force__c', 'ACCOUNT.ADDRESS1_CITY', 'ACCOUNT.PHONE1'])
listview('Contact', 'AllContacts', 'All Contacts', ['FULL_NAME', 'ACCOUNT.NAME', 'Household_Role__c', 'CONTACT.PHONE1', 'CONTACT.EMAIL'])
OCOLS = ['OPPORTUNITY.NAME', 'ACCOUNT.NAME', 'Line_of_Business__c', 'OPPORTUNITY.STAGE_NAME', 'OPPORTUNITY.AMOUNT', 'OPPORTUNITY.CLOSE_DATE']
listview('Opportunity', 'AllOpportunities', 'All Policy Sales', OCOLS)
listview('Opportunity', 'Open_Policy_Sales', 'Open Policy Sales', OCOLS, flt('OPPORTUNITY.CLOSED', 'equals', '0'))
listview('Opportunity', 'Bound_Policy_Sales', 'Bound', OCOLS, flt('OPPORTUNITY.WON', 'equals', '1'))
listview('Lead', 'AllOpenLeads', 'Open Leads', ['FULL_NAME', 'LEAD.COMPANY', 'Product_Interest__c', 'LEAD.STATUS', 'LEAD.RATING', 'LEAD.PHONE'], flt('LEAD.STATUS', 'notContain', 'closed'))
listview('Task', 'OpenTasks', 'Open Tasks', ['SUBJECT', 'WHO_NAME', 'WHAT_NAME', 'DUE_DATE', 'PRIORITY'],
         flt('IS_CLOSED', 'equals', '0') + flt('IS_RECURRENCE', 'equals', '0') + flt('DUE_DATE', 'greaterOrEqual', 'LAST_N_DAYS:30'), scope='Mine')

# ---------------- Permission set additions ----------------
import re
p = ROOT + '/permissionsets/Antsurance_CRM.permissionset-meta.xml'; t = open(p).read()
EXTRA_FLS = {**{f'Policy_Participant__c.{f}': True for f in ['Status__c', 'Relationship_to_Insured__c', 'Expiration_Date__c', 'License_Number__c', 'License_State__c', 'Date_Licensed__c',
                  'Driver_Rating__c', 'Violations_Past_3_Years__c', 'Accidents_Past_3_Years__c', 'Good_Student_Discount__c', 'Primary_Vehicle__c', 'Notes__c']},
             **{f'Policy_Coverage__c.{f}': True for f in ['Status__c', 'Limit_Type__c', 'Effective_Date__c', 'What_Is_Covered__c']},
             **{f'File_Note__c.{f}': True for f in ['Case__c', 'Policy__c', 'Account__c', 'Note_Type__c', 'Body__c', 'Note_Date__c', 'Author_Name__c']},
             **{f'Policy_Endorsement__c.{f}': True for f in ['Form_Number__c', 'Type__c', 'Status__c', 'Effective_Date__c', 'Premium_Change__c', 'Limit_Amount__c', 'Description__c']},
             **{f'Policy_Asset__c.{f}': True for f in ['Asset_Type__c', 'Identifier__c', 'Model_Year__c', 'Location__c', 'Latitude__c', 'Longitude__c', 'Use__c', 'Details__c', 'Insured_Value__c', 'Lienholder__c']},
             **{f'Quote.{f}': True for f in ['Annual_Premium__c', 'Coverage_Limit__c', 'Deductible__c', 'Issued_Date__c', 'Underwriter__c', 'Submission_Channel__c', 'Needs_Underwriting_Review__c', 'Configuration__c', 'Underwriting_Memo__c', 'Underwriting_Decision__c']},
             'Policy__c.Underwriting_Notes__c': True, 'Account.Customer_Brief__c': True, 'User.Claude_Briefing__c': True, 'User.Claude_Briefing_At__c': True,
             'Case.Coverage_Check__c': True, 'Case.Handled_By__c': True, 'Case.Claude_Brief__c': True, 'Case.Claude_Brief_At__c': True, 'Case.Photo_Assessment__c': True, 'Case.Photo_Assessment_At__c': True, 'Case.Photo_Marks__c': True, 'Case.Coverage_Read__c': True, 'Case.Coverage_Read_At__c': True, 'Case.Coverage_Verdict__c': True, 'Case.Coverage_Confirmed_By__c': True, 'Case.Coverage_Confirmed_At__c': True, 'Case.Claude_Analysis__c': True, 'Case.Claude_Analysis_At__c': True, 'Case.Closed_On__c': True, 'Case.Reported_Date__c': True, 'Contact.Household_Role__c': True, 'Contact.Primary_Member__c': True, 'Contact.Licensed_Driver__c': True, 'Policy__c.Producer__c': True,
             'Policy_Participant__c.Contact__c': True, 'Policy_Participant__c.Role__c': True, 'Policy_Participant__c.Is_Primary__c': True, 'Policy_Participant__c.Effective_Date__c': True,
             'Policy_Coverage__c.Category__c': True, 'Policy_Coverage__c.Limit_Amount__c': True, 'Policy_Coverage__c.Deductible_Amount__c': True, 'Policy_Coverage__c.Premium_Amount__c': True}
READ_ONLY_FLS = ['Case.Kind__c', 'Policy__c.Policyholder_Name__c', 'Quote.Option_Summary__c', 'Policy__c.Sold_Through__c', 'Policy__c.Incurred_Losses__c', 'Policy__c.Loss_Ratio__c', 'Case.Days_Open__c', 'Quote.Days_Since_Issued__c', 'Policy_Participant__c.Years_Licensed__c', 'Policy_Coverage__c.Premium_Share__c', 'Policy__c.Policy_Summary__c']
fls_ro = ''.join(f'    <fieldPermissions>\n        <editable>false</editable>\n        <field>{f}</field>\n        <readable>true</readable>\n    </fieldPermissions>\n' for f in READ_ONLY_FLS)
fls = fls_ro + ''.join(f'    <fieldPermissions>\n        <editable>true</editable>\n        <field>{f}</field>\n        <readable>true</readable>\n    </fieldPermissions>\n' for f in sorted(EXTRA_FLS))
objs = ''.join(f'''    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>{o}</object>
        <viewAllFields>false</viewAllFields>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
''' for o in ['File_Note__c', 'Policy_Asset__c', 'Policy_Coverage__c', 'Policy_Endorsement__c', 'Policy_Participant__c', 'Quote'])
rts = ''.join(f'    <recordTypeVisibilities>\n        <recordType>Account.{r}</recordType>\n        <visible>true</visible>\n    </recordTypeVisibilities>\n' for r in ['Agency', 'Business', 'Household'])
tabs = ''.join(f'    <tabSettings>\n        <tab>{o}</tab>\n        <visibility>Available</visibility>\n    </tabSettings>\n' for o in ['File_Note__c', 'Policy_Asset__c', 'Policy_Coverage__c', 'Policy_Endorsement__c', 'Policy_Participant__c'])
tabs += '    <tabSettings>\n        <tab>standard-Quote</tab>\n        <visibility>Visible</visibility>\n    </tabSettings>\n'
# Our own Tasks tab stands in for the stock one in the app's navigation (see gen_pages.py).
if os.path.exists(os.path.join(ROOT, 'lwc', 'antsuranceTasks')):
    tabs = '    <tabSettings>\n        <tab>Antsurance_Tasks</tab>\n        <visibility>Visible</visibility>\n    </tabSettings>\n' + tabs
# Pages of our own that are tabs: each is granted once its tab file exists.
for own_tab in OWN_TABS:
    if os.path.exists(os.path.join(ROOT, 'tabs', own_tab + '.tab-meta.xml')):
        tabs = f'    <tabSettings>\n        <tab>{own_tab}</tab>\n        <visibility>Visible</visibility>\n    </tabSettings>\n' + tabs
t = t.replace('    <tabSettings>', tabs + '    <tabSettings>', 1)
t = t.replace('    <hasActivationRequired>', fls + '    <hasActivationRequired>', 1).replace('    <recordTypeVisibilities>', objs + rts + '    <recordTypeVisibilities>', 1)
# metadata wants each element type grouped and sorted; re-sort the blocks
blocks = re.findall(r'    <(fieldPermissions|objectPermissions|recordTypeVisibilities)>.*?</\1>\n', t, re.S)
def sort_blocks(tag, key):
    global t
    items = re.findall(rf'    <{tag}>.*?</{tag}>\n', t, re.S)
    if not items: return
    first = t.index(items[0])
    for i in items: t = t.replace(i, '', 1)
    t = t[:first] + ''.join(sorted(items, key=lambda b: re.search(rf'<{key}>(.*?)</{key}>', b).group(1))) + t[first:]
# Controllers from other workstreams: any class with an @AuraEnabled method that the permission set
# does not already name gets access, so a new component works for non-admin users without an edit here.
import os
_named = ['AntsuranceAssetController', 'AntsuranceQuoteConfigurator', 'AntsuranceDecPageController', 'AntsuranceInsightsController', 'AntsuranceNotesController', 'AntsuranceWorkController']
OTHER_STREAM_CLASSES = sorted(
    f[:-4] for f in os.listdir(os.path.join(ROOT, 'classes'))
    if f.endswith('.cls') and f[:-4] not in _named and f'<apexClass>{f[:-4]}</apexClass>' not in t
    and '@AuraEnabled' in open(os.path.join(ROOT, 'classes', f)).read())
# A Visualforce page's controller needs access too, or the page fails for anyone who is not an administrator.
_page_text = ''.join(open(os.path.join(ROOT, 'pages', f)).read() for f in os.listdir(os.path.join(ROOT, 'pages')) if f.endswith('.page'))
OTHER_STREAM_CLASSES = sorted(set(OTHER_STREAM_CLASSES) | {
    c for c in re.findall(r'controller="(\w+)"', _page_text)
    if c not in _named and f'<apexClass>{c}</apexClass>' not in t})
classes = ''.join(f'    <classAccesses>\n        <apexClass>{c}</apexClass>\n        <enabled>true</enabled>\n    </classAccesses>\n'
                  for c in ['AntsuranceAssetController', 'AntsuranceQuoteConfigurator', 'AntsuranceDecPageController', 'AntsuranceInsightsController', 'AntsuranceNotesController', 'AntsuranceWorkController'] + OTHER_STREAM_CLASSES)
t = t.replace('    <description>', classes + '    <description>', 1)
# The app itself. Access here comes from permission sets, never a profile, so without this nobody but someone
# whose own profile already shows the app would find Antsurance in the App Launcher after an install.
APP = '    <applicationVisibilities>\n        <application>Antsurance</application>\n        <visible>true</visible>\n    </applicationVisibilities>\n'
if '<application>Antsurance</application>' not in t:
    t = t.replace('">\n', '">\n' + APP, 1)
pages = ''.join(f'    <pageAccesses>\n        <apexPage>{f[:-5]}</apexPage>\n        <enabled>true</enabled>\n    </pageAccesses>\n'
                for f in sorted(os.listdir(os.path.join(ROOT, 'pages'))) if f.endswith('.page'))
t = t.replace('    <recordTypeVisibilities>', pages + '    <recordTypeVisibilities>', 1)
sort_blocks('fieldPermissions', 'field'); sort_blocks('objectPermissions', 'object'); sort_blocks('recordTypeVisibilities', 'recordType')
open(p, 'w').write(t)
print('part 2 generated')
