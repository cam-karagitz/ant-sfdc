"""One-off generator for the insurance data model metadata (not part of the project)."""
import os, sys
ROOT = sys.argv[1]
NS = 'xmlns="http://soap.sforce.com/2006/04/metadata"'
HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'

def write(path, body):
    full = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'w').write(HEAD + body.strip('\n') + '\n')

def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

def field(obj, name, label, ftype, extra='', desc=None, help_text=None):
    parts = [f'    <fullName>{name}</fullName>']
    if desc: parts.append(f'    <description>{esc(desc)}</description>')
    if help_text: parts.append(f'    <inlineHelpText>{esc(help_text)}</inlineHelpText>')
    parts.append(f'    <label>{esc(label)}</label>')
    if extra: parts.append(extra.strip('\n'))
    parts.append(f'    <type>{ftype}</type>')
    write(f'objects/{obj}/fields/{name}.field-meta.xml', f'<CustomField {NS}>\n' + '\n'.join(parts) + '\n</CustomField>')

def picklist(values, restricted=True):
    vals = ''.join(f'            <value>\n                <fullName>{esc(v)}</fullName>\n                <default>false</default>\n                <label>{esc(v)}</label>\n            </value>\n' for v in values)
    return f'''    <required>false</required>
    <valueSet>
        <restricted>{'true' if restricted else 'false'}</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
{vals}        </valueSetDefinition>
    </valueSet>'''

GLOBAL_LOB = '''    <required>false</required>
    <valueSet>
        <restricted>true</restricted>
        <valueSetName>Line_of_Business</valueSetName>
    </valueSet>'''
# Money is shown in whole dollars, the way the cards show it.
CURRENCY = '    <precision>14</precision>\n    <required>false</required>\n    <scale>0</scale>'
DATE = '    <required>false</required>'

LOBS = ['Personal Auto', 'Homeowners', 'Renters', 'Umbrella', 'Commercial Property', 'General Liability', 'Workers Compensation', 'Commercial Auto']
write('globalValueSets/Line_of_Business.globalValueSet-meta.xml', f'<GlobalValueSet {NS}>\n' + ''.join(
    f'    <customValue>\n        <fullName>{v}</fullName>\n        <default>false</default>\n        <label>{v}</label>\n    </customValue>\n' for v in LOBS) +
    '    <description>Insurance lines Antsurance writes. Shared by policies, opportunities and leads.</description>\n    <masterLabel>Line of Business</masterLabel>\n    <sorted>false</sorted>\n</GlobalValueSet>')

# ---------------- Policy__c ----------------
write('objects/Policy__c/Policy__c.object-meta.xml', f'''<CustomObject {NS}>
    <compactLayoutAssignment>Policy_Compact</compactLayoutAssignment>
    <deploymentStatus>Deployed</deploymentStatus>
    <description>An insurance policy Antsurance has quoted or issued to a policyholder account. It records the line of business, term dates, premium, limit and deductible, plus billing and renewal status. Claims and service requests are cases that point at a policy. Expiration must fall after the effective date.</description>
    <enableActivities>true</enableActivities>
    <enableBulkApi>true</enableBulkApi>
    <enableFeeds>false</enableFeeds>
    <enableHistory>true</enableHistory>
    <enableReports>true</enableReports>
    <enableSearch>true</enableSearch>
    <enableSharing>true</enableSharing>
    <enableStreamingApi>true</enableStreamingApi>
    <label>Policy</label>
    <nameField>
        <label>Policy Number</label>
        <trackHistory>false</trackHistory>
        <type>Text</type>
    </nameField>
    <pluralLabel>Policies</pluralLabel>
    <searchLayouts>
        <customTabListAdditionalFields>Account__c</customTabListAdditionalFields>
        <customTabListAdditionalFields>Line_of_Business__c</customTabListAdditionalFields>
        <customTabListAdditionalFields>Status__c</customTabListAdditionalFields>
        <customTabListAdditionalFields>Annual_Premium__c</customTabListAdditionalFields>
        <customTabListAdditionalFields>Expiration_Date__c</customTabListAdditionalFields>
        <lookupDialogsAdditionalFields>Account__c</lookupDialogsAdditionalFields>
        <lookupDialogsAdditionalFields>Line_of_Business__c</lookupDialogsAdditionalFields>
        <lookupDialogsAdditionalFields>Status__c</lookupDialogsAdditionalFields>
        <searchResultsAdditionalFields>Account__c</searchResultsAdditionalFields>
        <searchResultsAdditionalFields>Line_of_Business__c</searchResultsAdditionalFields>
        <searchResultsAdditionalFields>Status__c</searchResultsAdditionalFields>
        <searchResultsAdditionalFields>Annual_Premium__c</searchResultsAdditionalFields>
        <searchResultsAdditionalFields>Expiration_Date__c</searchResultsAdditionalFields>
    </searchLayouts>
    <sharingModel>ControlledByParent</sharingModel>
    <visibility>Public</visibility>
</CustomObject>''')
P = 'Policy__c'
field(P, 'Account__c', 'Policyholder', 'MasterDetail', '''    <referenceTo>Account</referenceTo>
    <relationshipLabel>Policies</relationshipLabel>
    <relationshipName>Policies</relationshipName>
    <relationshipOrder>0</relationshipOrder>
    <reparentableMasterDetail>false</reparentableMasterDetail>
    <trackHistory>false</trackHistory>
    <writeRequiresMasterRead>false</writeRequiresMasterRead>''', desc='The account that holds this policy.')
field(P, 'Primary_Insured__c', 'Policy Contact', 'Lookup', '''    <deleteConstraint>SetNull</deleteConstraint>
    <referenceTo>Contact</referenceTo>
    <relationshipLabel>Policies</relationshipLabel>
    <relationshipName>Policies</relationshipName>
    <required>false</required>
    <trackHistory>false</trackHistory>''', desc='The person to deal with on this policy: the named insured on a personal policy, or the contact at the business on a commercial one, where the named insured is the business itself.')
field(P, 'Line_of_Business__c', 'Line of Business', 'Picklist', GLOBAL_LOB + '\n    <trackHistory>false</trackHistory>', desc='The kind of coverage this policy provides.')
field(P, 'Status__c', 'Status', 'Picklist', picklist(['Quoted', 'Active', 'Pending Renewal', 'Lapsed', 'Cancelled', 'Expired']) + '\n    <trackHistory>true</trackHistory>', desc='Where the policy is in its life, from quote to expiry.')
field(P, 'Effective_Date__c', 'Effective Date', 'Date', DATE + '\n    <trackHistory>false</trackHistory>', desc='First day of coverage for the current term.')
field(P, 'Expiration_Date__c', 'Expiration Date', 'Date', DATE + '\n    <trackHistory>true</trackHistory>', desc='Last day of coverage for the current term. Renewal is due by this date.')
field(P, 'Annual_Premium__c', 'Annual Premium', 'Currency', CURRENCY + '\n    <trackHistory>true</trackHistory>', desc='Premium for a full policy year.')
field(P, 'Coverage_Limit__c', 'Coverage Limit', 'Currency', CURRENCY + '\n    <trackHistory>false</trackHistory>', desc='The most the policy pays for a covered loss.')
field(P, 'Deductible__c', 'Deductible', 'Currency', CURRENCY + '\n    <trackHistory>false</trackHistory>', desc='What the policyholder pays on a claim before coverage applies.')
field(P, 'Billing_Frequency__c', 'Billing Frequency', 'Picklist', picklist(['Monthly', 'Quarterly', 'Semi-Annual', 'Annual']) + '\n    <trackHistory>false</trackHistory>', desc='How often the policyholder is billed.')
field(P, 'Payment_Status__c', 'Payment Status', 'Picklist', picklist(['Current', 'Past Due', 'Paid in Full']) + '\n    <trackHistory>true</trackHistory>', desc='Whether premium payments are up to date.')
field(P, 'Insured_Item__c', 'Insured Item', 'Text', '    <length>255</length>\n    <required>false</required>\n    <trackHistory>false</trackHistory>\n    <unique>false</unique>', desc='What is covered: the vehicle, property address or business operation.')
field(P, 'Agency__c', 'Agency', 'Text', '    <length>80</length>\n    <required>false</required>\n    <trackHistory>false</trackHistory>\n    <unique>false</unique>', desc='The agency or producer that placed the policy. Blank for direct business.')
field(P, 'Days_to_Renewal__c', 'Days Left', 'Number', '''    <formula><![CDATA[Expiration_Date__c - TODAY()]]></formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>18</precision>
    <required>false</required>
    <scale>0</scale>
    <trackHistory>false</trackHistory>
    <unique>false</unique>''', desc='Days until the current term expires. Negative once it has passed.')
write(f'objects/{P}/validationRules/Expiration_After_Effective.validationRule-meta.xml', f'''<ValidationRule {NS}>
    <fullName>Expiration_After_Effective</fullName>
    <active>true</active>
    <description>A policy term cannot end on or before the day it starts.</description>
    <errorConditionFormula><![CDATA[AND(NOT(ISBLANK(Effective_Date__c)), NOT(ISBLANK(Expiration_Date__c)), Expiration_Date__c <= Effective_Date__c)]]></errorConditionFormula>
    <errorDisplayField>Expiration_Date__c</errorDisplayField>
    <errorMessage>The expiration date must be after the effective date.</errorMessage>
</ValidationRule>''')
write(f'objects/{P}/compactLayouts/Policy_Compact.compactLayout-meta.xml', f'''<CompactLayout {NS}>
    <fullName>Policy_Compact</fullName>
    <fields>Name</fields>
    <fields>Status__c</fields>
    <fields>Line_of_Business__c</fields>
    <fields>Annual_Premium__c</fields>
    <fields>Expiration_Date__c</fields>
    <fields>Payment_Status__c</fields>
    <label>Policy Compact Layout</label>
</CompactLayout>''')
def listview(obj, name, label, cols, filters='', scope='Everything'):
    write(f'objects/{obj}/listViews/{name}.listView-meta.xml', f'<ListView {NS}>\n    <fullName>{name}</fullName>\n' + ''.join(f'    <columns>{c}</columns>\n' for c in cols) + f'    <filterScope>{scope}</filterScope>\n' + filters + f'    <label>{label}</label>\n</ListView>')
def flt(fieldname, op, value):
    return f'    <filters>\n        <field>{fieldname}</field>\n        <operation>{op}</operation>\n        <value>{value}</value>\n    </filters>\n'
# List view names leave out "Policies": the tab already says it. Six columns at most, so no header is cut short.
PCOLS = ['NAME', 'Account__c', 'Line_of_Business__c', 'Status__c', 'Annual_Premium__c', 'Expiration_Date__c']
listview(P, 'All', 'All Policies', PCOLS)
listview(P, 'Active_Policies', 'Active', PCOLS, flt('Status__c', 'equals', 'Active'))
listview(P, 'Renewals_Next_60_Days', 'Renewals, Next 60 Days', ['NAME', 'Account__c', 'Line_of_Business__c', 'Annual_Premium__c', 'Expiration_Date__c', 'Days_to_Renewal__c'],
         flt('Status__c', 'equals', 'Active,Pending Renewal') + flt('Expiration_Date__c', 'equals', 'NEXT_N_DAYS:60'))
listview(P, 'Past_Due', 'Past Due', ['NAME', 'Account__c', 'Line_of_Business__c', 'Annual_Premium__c', 'Payment_Status__c', 'Expiration_Date__c'], flt('Payment_Status__c', 'equals', 'Past Due'))
# By line of business, so the list can be narrowed to one kind of policy.
LCOLS = ['NAME', 'Account__c', 'Line_of_Business__c', 'Status__c', 'Annual_Premium__c', 'Expiration_Date__c']
listview(P, 'Personal_Lines', 'Personal Lines', LCOLS, flt('Line_of_Business__c', 'equals', 'Personal Auto,Homeowners,Renters,Umbrella'))
listview(P, 'Commercial_Lines', 'Commercial Lines', LCOLS, flt('Line_of_Business__c', 'equals', 'Commercial Property,General Liability,Workers Compensation,Commercial Auto'))
for line in LOBS:
    listview(P, 'Line_' + line.replace(' ', '_'), line, ['NAME', 'Account__c', 'Insured_Item__c', 'Status__c', 'Annual_Premium__c', 'Expiration_Date__c'], flt('Line_of_Business__c', 'equals', line))
write('tabs/Policy__c.tab-meta.xml', f'<CustomTab {NS}>\n    <customObject>true</customObject>\n    <motif>Custom77: Shield</motif>\n</CustomTab>')

# ---------------- Case ----------------
C = 'Case'
field(C, 'Policy__c', 'Policy', 'Lookup', '''    <deleteConstraint>SetNull</deleteConstraint>
    <referenceTo>Policy__c</referenceTo>
    <relationshipLabel>Claims and Service Requests</relationshipLabel>
    <relationshipName>Cases</relationshipName>
    <required>false</required>''', desc='The policy this claim or service request is about.')
field(C, 'Date_of_Loss__c', 'Date of Loss', 'Date', DATE, desc='When the loss happened. Claims only.')
LOSS = ['Collision', 'Animal Strike', 'Theft', 'Vandalism', 'Water Damage', 'Fire', 'Wind or Hail', 'Liability', 'Bodily Injury', 'Glass', 'Other']
field(C, 'Loss_Type__c', 'Loss Type', 'Picklist', picklist(LOSS), desc='The cause of loss. Claims only.')
field(C, 'Loss_Location__c', 'Loss Location', 'Text', '    <length>120</length>\n    <required>false</required>\n    <unique>false</unique>', desc='Where the loss happened.')
SEV = ['Low', 'Medium', 'High', 'Catastrophic']
field(C, 'Severity__c', 'Severity', 'Picklist', picklist(SEV), desc='How serious the loss is. Drives claim priority.')
field(C, 'Estimated_Loss__c', 'Estimated Loss', 'Currency', CURRENCY, desc='First estimate of the total loss, taken at intake.')
field(C, 'Reserve_Amount__c', 'Reserve', 'Currency', CURRENCY, desc='Money set aside to pay this claim.')
field(C, 'Paid_Amount__c', 'Paid to Date', 'Currency', CURRENCY, desc='Total paid on this claim so far.')
field(C, 'Outstanding_Reserve__c', 'Outstanding Reserve', 'Currency', '''    <formula><![CDATA[BLANKVALUE(Reserve_Amount__c, 0) - BLANKVALUE(Paid_Amount__c, 0)]]></formula>
    <formulaTreatBlanksAs>BlankAsZero</formulaTreatBlanksAs>
    <precision>14</precision>
    <required>false</required>
    <scale>0</scale>''', desc='Reserve minus what has been paid.')
field(C, 'SIU_Referral__c', 'SIU Referral', 'Checkbox', '    <defaultValue>false</defaultValue>', desc='The claim has been referred to the special investigations unit for possible fraud.')
field(C, 'Subrogation_Potential__c', 'Subrogation Potential', 'Checkbox', '    <defaultValue>false</defaultValue>', desc='Another party may be liable, so Antsurance may recover what it pays.')
REQ = ['Add Driver', 'Remove Driver', 'Add Vehicle', 'Change Address', 'Change Coverage', 'Billing Question', 'Certificate of Insurance', 'Policy Document Request', 'Cancel Policy']
field(C, 'Request_Type__c', 'Request Type', 'Picklist', picklist(REQ), desc='What the policyholder is asking for. Policy service requests only.')

def business_process(obj, name, values, default):
    write(f'objects/{obj}/businessProcesses/{name}.businessProcess-meta.xml', f'<BusinessProcess {NS}>\n    <fullName>{name}</fullName>\n    <isActive>true</isActive>\n' +
          ''.join(f'    <values>\n        <fullName>{v}</fullName>\n' + ('' if default is None else f'        <default>{"true" if v == default else "false"}</default>\n') + '    </values>\n' for v in values) + '</BusinessProcess>')
CLAIM_STATUS = ['New', 'Under Investigation', 'Appraisal', 'Approved', 'Payment Issued', 'Closed', 'Denied']
SERVICE_STATUS = ['New', 'In Progress', 'Waiting on Customer', 'Closed']
business_process(C, 'Claims', CLAIM_STATUS, 'New')
business_process(C, 'PolicyService', SERVICE_STATUS, 'New')

def rt_picklist(name, values, default=None):
    return f'    <picklistValues>\n        <picklist>{name}</picklist>\n' + ''.join(
        f'        <values>\n            <fullName>{v.replace(" ", "%20") if False else v}</fullName>\n            <default>{"true" if v == default else "false"}</default>\n        </values>\n' for v in values) + '    </picklistValues>\n'
def record_type(obj, name, label, process, desc, picklists, compact=None):
    write(f'objects/{obj}/recordTypes/{name}.recordType-meta.xml', f'<RecordType {NS}>\n    <fullName>{name}</fullName>\n    <active>true</active>\n    <businessProcess>{process}</businessProcess>\n' +
          (f'    <compactLayoutAssignment>{compact}</compactLayoutAssignment>\n' if compact else '') +
          f'    <description>{esc(desc)}</description>\n    <label>{label}</label>\n' + ''.join(picklists) + '</RecordType>')
ORIGIN = ['Phone', 'Email', 'Web', 'Agent', 'Mobile App']
PRIORITY = ['High', 'Medium', 'Low']
record_type(C, 'Claim', 'Claim', 'Claims', 'A reported loss under a policy, worked from first notice through payment or denial.',
            [rt_picklist('Loss_Type__c', LOSS), rt_picklist('Severity__c', SEV), rt_picklist('Origin', ORIGIN, 'Phone'), rt_picklist('Priority', PRIORITY, 'Medium')], compact='Claim_Compact')
record_type(C, 'Policy_Service', 'Policy Service', 'PolicyService', 'A policyholder request to change or ask about a policy, such as adding a driver or getting a certificate of insurance.',
            [rt_picklist('Request_Type__c', REQ), rt_picklist('Origin', ORIGIN, 'Phone'), rt_picklist('Priority', PRIORITY, 'Medium')], compact='Service_Compact')
write(f'objects/{C}/compactLayouts/Claim_Compact.compactLayout-meta.xml', f'''<CompactLayout {NS}>
    <fullName>Claim_Compact</fullName>
    <fields>CaseNumber</fields>
    <fields>Status</fields>
    <fields>Policy__c</fields>
    <fields>Loss_Type__c</fields>
    <fields>Date_of_Loss__c</fields>
    <fields>Reserve_Amount__c</fields>
    <fields>Severity__c</fields>
    <label>Claim Compact Layout</label>
</CompactLayout>''')
write(f'objects/{C}/compactLayouts/Service_Compact.compactLayout-meta.xml', f'''<CompactLayout {NS}>
    <fullName>Service_Compact</fullName>
    <fields>CaseNumber</fields>
    <fields>Status</fields>
    <fields>Request_Type__c</fields>
    <fields>Policy__c</fields>
    <fields>Priority</fields>
    <fields>ContactId</fields>
    <label>Policy Service Compact Layout</label>
</CompactLayout>''')
# Six columns: with a seventh the status column was too narrow for "Under Investigation".
CLAIM_COLS = ['CASES.CASE_NUMBER', 'CASES.SUBJECT', 'ACCOUNT.NAME', 'CASES.STATUS', 'Severity__c', 'Reserve_Amount__c']
listview(C, 'Open_Claims', 'Open Claims', CLAIM_COLS, flt('CASES.RECORDTYPE', 'equals', 'Case.Claim') + flt('CASES.CLOSED', 'equals', '0'))
listview(C, 'All_Claims', 'All Claims', CLAIM_COLS, flt('CASES.RECORDTYPE', 'equals', 'Case.Claim'))
listview(C, 'High_Severity_Claims', 'High Severity Claims', CLAIM_COLS, flt('CASES.RECORDTYPE', 'equals', 'Case.Claim') + flt('CASES.CLOSED', 'equals', '0') + flt('Severity__c', 'equals', 'High,Catastrophic'))
REQUEST_COLS = ['CASES.CASE_NUMBER', 'CASES.SUBJECT', 'ACCOUNT.NAME', 'Request_Type__c', 'CASES.STATUS', 'Reported_Date__c']
listview(C, 'Open_Service_Requests', 'Open Service Requests', REQUEST_COLS, flt('CASES.RECORDTYPE', 'equals', 'Case.Policy_Service') + flt('CASES.CLOSED', 'equals', '0'))
listview(C, 'All_Service_Requests', 'All Service Requests', REQUEST_COLS, flt('CASES.RECORDTYPE', 'equals', 'Case.Policy_Service'))

# ---------------- Account / Opportunity / Lead / Contact ----------------
A = 'Account'
field(A, 'Customer_Segment__c', 'Customer Segment', 'Picklist', picklist(['Personal Lines', 'Commercial Lines', 'Agency Partner']), desc='Which side of the business this customer belongs to.')
field(A, 'Customer_Since__c', 'Customer Since', 'Date', DATE, desc='When this customer first bought a policy from Antsurance.')
# A short label, because a number column in a list is narrow and "Active Policies" was cut off there.
field(A, 'Active_Policies__c', 'Policies', 'Summary', '''    <summaryFilterItems>
        <field>Policy__c.Status__c</field>
        <operation>equals</operation>
        <value>Active, Pending Renewal</value>
    </summaryFilterItems>
    <summaryForeignKey>Policy__c.Account__c</summaryForeignKey>
    <summaryOperation>count</summaryOperation>''', desc='Number of policies in force for this customer.')
field(A, 'Premium_in_Force__c', 'Premium in Force', 'Summary', '''    <summarizedField>Policy__c.Annual_Premium__c</summarizedField>
    <summaryFilterItems>
        <field>Policy__c.Status__c</field>
        <operation>equals</operation>
        <value>Active, Pending Renewal</value>
    </summaryFilterItems>
    <summaryForeignKey>Policy__c.Account__c</summaryForeignKey>
    <summaryOperation>sum</summaryOperation>''', desc='Total annual premium across policies in force.')
O = 'Opportunity'
field(O, 'Line_of_Business__c', 'Line of Business', 'Picklist', GLOBAL_LOB, desc='The coverage being quoted.')
field(O, 'Policy__c', 'Policy', 'Lookup', '''    <deleteConstraint>SetNull</deleteConstraint>
    <referenceTo>Policy__c</referenceTo>
    <relationshipLabel>Policy Sales</relationshipLabel>
    <relationshipName>Opportunities</relationshipName>
    <required>false</required>''', desc='For a renewal, the policy being renewed. For new business, the policy once bound.')
STAGES = ['Submission Received', 'Underwriting Review', 'Quote Issued', 'Bind Requested', 'Bound', 'Declined']
business_process(O, 'InsuranceSales', STAGES, None)
record_type(O, 'Policy_Sale', 'Policy Sale', 'InsuranceSales', 'A new business quote, renewal or cross-sell, tracked from submission to bound.',
            [rt_picklist('Type', ['New Business', 'Renewal', 'Cross-Sell'], 'New Business')])
field('Lead', 'Product_Interest__c', 'Product Interest', 'Picklist', GLOBAL_LOB, desc='The coverage this prospect asked about.')
field('Contact', 'Preferred_Contact_Method__c', 'Preferred Contact Method', 'Picklist', picklist(['Phone', 'Email', 'Text']), desc='How this person prefers to hear from Antsurance.')

# ---------------- Standard value sets ----------------
def svs(name, rows):
    write(f'standardValueSets/{name}.standardValueSet-meta.xml', f'<StandardValueSet {NS}>\n    <sorted>false</sorted>\n' + ''.join(
        '    <standardValue>\n' + ''.join(f'        <{k}>{v}</{k}>\n' for k, v in row.items()) + '    </standardValue>\n' for row in rows) + '</StandardValueSet>')
def status(label, closed=False, default=False):
    return {'fullName': label, 'default': str(default).lower(), 'label': label, 'closed': str(closed).lower()}
svs('CaseStatus', [status('New', default=True), status('Working'), status('Escalated'), status('In Progress'), status('Waiting on Customer'), status('Under Investigation'),
                   status('Appraisal'), status('Approved'), status('Payment Issued'), status('Closed', closed=True), status('Denied', closed=True)])
svs('CaseOrigin', [{'fullName': v, 'default': 'false', 'label': v} for v in ORIGIN])
svs('OpportunityType', [{'fullName': v, 'default': 'false', 'label': v} for v in ['New Business', 'Renewal', 'Cross-Sell', 'Existing Customer - Upgrade', 'Existing Customer - Replacement', 'Existing Customer - Downgrade', 'New Customer']])
def stage(label, prob, cat, closed=False, won=False):
    return {'fullName': label, 'default': 'false', 'label': label, 'closed': str(closed).lower(), 'forecastCategory': cat, 'probability': prob, 'won': str(won).lower()}
svs('OpportunityStage', [
    stage('Submission Received', 10, 'Pipeline'), stage('Underwriting Review', 30, 'Pipeline'), stage('Quote Issued', 60, 'BestCase'), stage('Bind Requested', 90, 'Forecast'),
    stage('Bound', 100, 'Closed', closed=True, won=True), stage('Declined', 0, 'Omitted', closed=True),
    stage('Prospecting', 10, 'Pipeline'), stage('Qualification', 10, 'Pipeline'), stage('Needs Analysis', 20, 'Pipeline'), stage('Value Proposition', 50, 'Pipeline'),
    stage('Id. Decision Makers', 60, 'Pipeline'), stage('Perception Analysis', 70, 'Pipeline'), stage('Proposal/Price Quote', 75, 'Pipeline'), stage('Negotiation/Review', 90, 'Pipeline'),
    stage('Closed Won', 100, 'Closed', closed=True, won=True), stage('Closed Lost', 0, 'Omitted', closed=True)])

# ---------------- Permission set ----------------
FLS = {  # field: editable
    'Policy__c.Primary_Insured__c': True, 'Policy__c.Line_of_Business__c': True, 'Policy__c.Status__c': True, 'Policy__c.Effective_Date__c': True,
    'Policy__c.Expiration_Date__c': True, 'Policy__c.Annual_Premium__c': True, 'Policy__c.Coverage_Limit__c': True, 'Policy__c.Deductible__c': True,
    'Policy__c.Billing_Frequency__c': True, 'Policy__c.Payment_Status__c': True, 'Policy__c.Insured_Item__c': True, 'Policy__c.Agency__c': True, 'Policy__c.Days_to_Renewal__c': False,
    'Case.Policy__c': True, 'Case.Date_of_Loss__c': True, 'Case.Loss_Type__c': True, 'Case.Loss_Location__c': True, 'Case.Severity__c': True, 'Case.Estimated_Loss__c': True,
    'Case.Reserve_Amount__c': True, 'Case.Paid_Amount__c': True, 'Case.Outstanding_Reserve__c': False, 'Case.SIU_Referral__c': True, 'Case.Subrogation_Potential__c': True, 'Case.Request_Type__c': True,
    'Account.Customer_Segment__c': True, 'Account.Customer_Since__c': True, 'Account.Active_Policies__c': False, 'Account.Premium_in_Force__c': False,
    'Opportunity.Line_of_Business__c': True, 'Opportunity.Policy__c': True, 'Lead.Product_Interest__c': True, 'Contact.Preferred_Contact_Method__c': True}
ps = f'<PermissionSet {NS}>\n    <description>Work with Antsurance policies, claims and policy service requests.</description>\n'
for f, editable in sorted(FLS.items()):
    ps += f'    <fieldPermissions>\n        <editable>{str(editable).lower()}</editable>\n        <field>{f}</field>\n        <readable>true</readable>\n    </fieldPermissions>\n'
ps += '''    <hasActivationRequired>false</hasActivationRequired>
    <label>Antsurance CRM</label>
''' + ''.join(f'''    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>true</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>{o}</object>
        <viewAllFields>false</viewAllFields>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
''' for o in ['Account', 'Case', 'Contact', 'Lead', 'Opportunity', 'Policy__c']) + '''    <recordTypeVisibilities>
        <recordType>Case.Claim</recordType>
        <visible>true</visible>
    </recordTypeVisibilities>
    <recordTypeVisibilities>
        <recordType>Case.Policy_Service</recordType>
        <visible>true</visible>
    </recordTypeVisibilities>
    <recordTypeVisibilities>
        <recordType>Opportunity.Policy_Sale</recordType>
        <visible>true</visible>
    </recordTypeVisibilities>
    <tabSettings>
        <tab>Policy__c</tab>
        <visibility>Visible</visibility>
    </tabSettings>
</PermissionSet>'''
write('permissionsets/Antsurance_CRM.permissionset-meta.xml', ps)
print('generated')
