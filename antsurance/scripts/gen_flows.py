"""One-off generator for the Antsurance flows and the quick actions that launch them."""
import os, sys
ROOT = sys.argv[1]
NS = 'xmlns="http://soap.sforce.com/2006/04/metadata"'
HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'

def esc(s):
    return str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

def write(path, body):
    full = os.path.join(ROOT, path); os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'w').write(HEAD + body.strip('\n') + '\n')

# ---- values -------------------------------------------------------------
def ref(name): return f'<elementReference>{name}</elementReference>'
def s(text): return f'<stringValue>{esc(text)}</stringValue>'
def b(flag): return f'<booleanValue>{"true" if flag else "false"}</booleanValue>'
def n(number): return f'<numberValue>{number}</numberValue>'
def value(v, tag='value', pad=12):
    sp = ' ' * pad
    return f'{sp}<{tag}>\n{sp}    {v}\n{sp}</{tag}>\n'
def connector(target, tag='connector', pad=8):
    sp = ' ' * pad
    return f'{sp}<{tag}>\n{sp}    <targetReference>{target}</targetReference>\n{sp}</{tag}>\n' if target else ''
def label_of(name): return name.replace('_', ' ')

class Flow:
    ORDER = ['assignments', 'choices', 'decisions', 'dynamicChoiceSets', 'formulas', 'loops', 'recordCreates', 'recordLookups', 'recordUpdates', 'screens', 'variables']
    def __init__(self, name, label, description, process_type='Flow'):
        self.name, self.label, self.description, self.process_type = name, label, description, process_type
        self.parts = {k: [] for k in self.ORDER}
        self.start = ''
        self.y = 0
    def loc(self):
        self.y += 108
        return f'        <locationX>176</locationX>\n        <locationY>{self.y}</locationY>\n'
    def head(self, name, label=None):
        return f'        <name>{name}</name>\n        <label>{esc(label or label_of(name))}</label>\n' + self.loc()
    def filters(self, conditions, pad=8):
        sp = ' ' * pad
        out = f'{sp}<filterLogic>and</filterLogic>\n'
        for field, op, val in conditions:
            out += f'{sp}<filters>\n{sp}    <field>{field}</field>\n{sp}    <operator>{op}</operator>\n' + value(val, pad=pad + 4) + f'{sp}</filters>\n'
        return out
    def assignments_xml(self, fields, pad=8):
        sp = ' ' * pad
        return ''.join(f'{sp}<inputAssignments>\n{sp}    <field>{f}</field>\n' + value(v, pad=pad + 4) + f'{sp}</inputAssignments>\n' for f, v in fields)

    # ---- elements ------------------------------------------------------
    def variable(self, name, data_type='String', is_input=False, scale=None, collection=False):
        self.parts['variables'].append(f'    <variables>\n        <name>{name}</name>\n        <dataType>{data_type}</dataType>\n        <isCollection>{"true" if collection else "false"}</isCollection>\n'
                                       f'        <isInput>{"true" if is_input else "false"}</isInput>\n        <isOutput>false</isOutput>\n'
                                       + (f'        <scale>{scale}</scale>\n' if scale is not None else '') + '    </variables>\n')
    def formula(self, name, data_type, expression, scale=None):
        self.parts['formulas'].append(f'    <formulas>\n        <name>{name}</name>\n        <dataType>{data_type}</dataType>\n        <expression>{esc(expression)}</expression>\n'
                                      + (f'        <scale>{scale}</scale>\n' if scale is not None else '') + '    </formulas>\n')
    def lookup(self, name, obj, conditions, then, label=None, every=False):
        # `every` returns all matching records as a collection instead of the first one.
        self.parts['recordLookups'].append('    <recordLookups>\n' + self.head(name, label) + '        <assignNullValuesIfNoRecordsFound>true</assignNullValuesIfNoRecordsFound>\n'
            + connector(then) + self.filters(conditions) + f'        <getFirstRecordOnly>{"false" if every else "true"}</getFirstRecordOnly>\n        <object>{obj}</object>\n'
            '        <storeOutputAutomatically>true</storeOutputAutomatically>\n    </recordLookups>\n')
    def create(self, name, obj, fields, then, fault=None, label=None):
        self.parts['recordCreates'].append('    <recordCreates>\n' + self.head(name, label) + connector(then) + connector(fault, 'faultConnector')
            + self.assignments_xml(fields) + f'        <object>{obj}</object>\n        <storeOutputAutomatically>true</storeOutputAutomatically>\n    </recordCreates>\n')
    def update(self, name, obj, conditions, fields, then, fault=None, label=None):
        self.parts['recordUpdates'].append('    <recordUpdates>\n' + self.head(name, label) + connector(then) + connector(fault, 'faultConnector')
            + self.filters(conditions) + self.assignments_xml(fields) + f'        <object>{obj}</object>\n    </recordUpdates>\n')
    def loop(self, name, collection, each, done, label=None):
        """Visits each record in a collection: `each` runs per record and must lead back here; `done` runs afterwards."""
        self.parts['loops'].append('    <loops>\n' + self.head(name, label) + f'        <collectionReference>{collection}</collectionReference>\n        <iterationOrder>Asc</iterationOrder>\n'
            + connector(each, 'nextValueConnector') + connector(done, 'noMoreValuesConnector') + '    </loops>\n')
    def assign(self, name, items, then, label=None, operator='Assign'):
        body = ''.join(f'        <assignmentItems>\n            <assignToReference>{to}</assignToReference>\n            <operator>{operator}</operator>\n' + value(v) + '        </assignmentItems>\n' for to, v in items)
        self.parts['assignments'].append('    <assignments>\n' + self.head(name, label) + body + connector(then) + '    </assignments>\n')
    def decision(self, name, rules, default, default_label, label=None):
        body = connector(default, 'defaultConnector') + f'        <defaultConnectorLabel>{esc(default_label)}</defaultConnectorLabel>\n'
        for rule_name, rule_label, logic, conditions, then in rules:
            body += f'        <rules>\n            <name>{rule_name}</name>\n            <conditionLogic>{logic}</conditionLogic>\n'
            for left, op, right in conditions:
                body += f'            <conditions>\n                <leftValueReference>{left}</leftValueReference>\n                <operator>{op}</operator>\n' + value(right, 'rightValue', 16) + '            </conditions>\n'
            body += connector(then, pad=12) + f'            <label>{esc(rule_label)}</label>\n        </rules>\n'
        self.parts['decisions'].append('    <decisions>\n' + self.head(name, label) + body + '    </decisions>\n')
    def picklist_choices(self, name, obj, field):
        self.parts['dynamicChoiceSets'].append(f'    <dynamicChoiceSets>\n        <name>{name}</name>\n        <dataType>Picklist</dataType>\n        <picklistField>{field}</picklistField>\n'
                                               f'        <picklistObject>{obj}</picklistObject>\n    </dynamicChoiceSets>\n')
    def choices(self, prefix, values):
        """Fixed choices for a dropdown or radio group, so one of them can be chosen by default. Returns their names."""
        names = []
        for text in values:
            name = prefix + '_' + ''.join(ch if ch.isalnum() else '_' for ch in text)
            self.parts['choices'].append(f'    <choices>\n        <name>{name}</name>\n        <choiceText>{esc(text)}</choiceText>\n        <dataType>String</dataType>\n'
                                         + value(s(text), pad=8) + '    </choices>\n')
            names.append(name)
        return names
    def record_choices(self, name, obj, display, conditions, sort='Name', value_field='Id'):
        self.parts['dynamicChoiceSets'].append(f'    <dynamicChoiceSets>\n        <name>{name}</name>\n        <dataType>String</dataType>\n        <displayField>{display}</displayField>\n'
            + self.filters(conditions) + f'        <object>{obj}</object>\n        <sortField>{sort}</sortField>\n        <sortOrder>Asc</sortOrder>\n        <valueField>{value_field}</valueField>\n    </dynamicChoiceSets>\n')
    def screen(self, name, fields, then=None, label=None, back=True, action=None):
        # `action` names what the screen's button does ("File Claim"), in place of the stock "Next".
        button = f'        <nextOrFinishButtonLabel>{esc(action)}</nextOrFinishButtonLabel>\n' if action else ''
        self.parts['screens'].append('    <screens>\n' + self.head(name, label) + f'        <allowBack>{"true" if back else "false"}</allowBack>\n        <allowFinish>true</allowFinish>\n'
            '        <allowPause>false</allowPause>\n' + connector(then) + ''.join(fields) + button + '        <showFooter>true</showFooter>\n        <showHeader>true</showHeader>\n    </screens>\n')

    def xml(self, start, status='Active'):
        body = f'<Flow {NS}>\n    <apiVersion>67.0</apiVersion>\n'
        tail_order = [('assignments',), ('decisions',)]
        out = []
        for key in ['assignments', 'choices', 'decisions']:
            out += self.parts[key]
        out.append(f'    <description>{esc(self.description)}</description>\n')
        out += self.parts['dynamicChoiceSets']
        out.append('    <environments>Default</environments>\n')
        out += self.parts['formulas']
        out.append(f'    <interviewLabel>{esc(self.label)} {{!$Flow.CurrentDateTime}}</interviewLabel>\n    <label>{esc(self.label)}</label>\n')
        for key, val in [('BuilderType', 'LightningFlowBuilder'), ('CanvasMode', 'AUTO_LAYOUT_CANVAS'), ('OriginBuilderType', 'LightningFlowBuilder')]:
            out.append(f'    <processMetadataValues>\n        <name>{key}</name>\n        <value>\n            <stringValue>{val}</stringValue>\n        </value>\n    </processMetadataValues>\n')
        out.append(f'    <processType>{self.process_type}</processType>\n')
        for key in ['loops', 'recordCreates', 'recordLookups', 'recordUpdates', 'screens']:
            out += self.parts[key]
        out.append(start)
        out.append(f'    <status>{status}</status>\n')
        out += self.parts['variables']
        write(f'flows/{self.name}.flow-meta.xml', body + ''.join(out) + '</Flow>')

# ---- screen fields ---------------------------------------------------------
def display(name, html):
    return f'        <fields>\n            <name>{name}</name>\n            <fieldText>{esc(html)}</fieldText>\n            <fieldType>DisplayText</fieldType>\n        </fields>\n'
def rule(formula, message):
    return f'            <validationRule>\n                <errorMessage>{esc("<p>" + message + "</p>")}</errorMessage>\n                <formulaExpression>{esc(formula)}</formulaExpression>\n            </validationRule>\n'
def input_field(name, label, data_type='String', required=False, default=None, scale=None, validation='', help_text=None):
    out = f'        <fields>\n            <name>{name}</name>\n            <dataType>{data_type}</dataType>\n'
    if default: out += value(default, 'defaultValue', 12)
    out += f'            <fieldText>{esc(label)}</fieldText>\n            <fieldType>InputField</fieldType>\n'
    if help_text: out += f'            <helpText>{esc("<p>" + help_text + "</p>")}</helpText>\n'
    if data_type != 'Boolean':  # a checkbox cannot carry isRequired
        out += f'            <isRequired>{"true" if required else "false"}</isRequired>\n'
    if scale is not None: out += f'            <scale>{scale}</scale>\n'
    return out + validation + '        </fields>\n'
def long_text(name, label, required=False):
    return f'        <fields>\n            <name>{name}</name>\n            <fieldText>{esc(label)}</fieldText>\n            <fieldType>LargeTextArea</fieldType>\n            <isRequired>{"true" if required else "false"}</isRequired>\n        </fields>\n'
def choice_field(name, label, choices, kind='DropdownBox', required=True, default=None):
    # `choices` is one choice set, or a list of fixed choices; `default` names the fixed choice selected to begin with.
    refs = ''.join(f'            <choiceReferences>{c}</choiceReferences>\n' for c in ([choices] if isinstance(choices, str) else choices))
    chosen = f'            <defaultSelectedChoiceReference>{default}</defaultSelectedChoiceReference>\n' if default else ''
    return (f'        <fields>\n            <name>{name}</name>\n' + refs + f'            <dataType>String</dataType>\n' + chosen +
            f'            <fieldText>{esc(label)}</fieldText>\n            <fieldType>{kind}</fieldType>\n            <isRequired>{"true" if required else "false"}</isRequired>\n        </fields>\n')
def columns(name, left, right):
    """Two fields, or two short stacks of fields, side by side, so a screen is not one long column."""
    def column(side, fields):
        return (f'            <fields>\n                <name>{name}_{side}</name>\n                <fieldType>Region</fieldType>\n' + ''.join(fields)
                + '                <inputParameters>\n                    <name>width</name>\n                    <value>\n                        <stringValue>6</stringValue>\n'
                  '                    </value>\n                </inputParameters>\n                <isRequired>false</isRequired>\n            </fields>\n')
    return (f'        <fields>\n            <name>{name}</name>\n            <fieldType>RegionContainer</fieldType>\n' + column('Left', left) + column('Right', right)
            + '            <isRequired>false</isRequired>\n            <regionContainerType>SectionWithoutHeader</regionContainerType>\n        </fields>\n')
US_STATES = 'AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'.split()
def screen_start(target):
    return f'    <start>\n        <locationX>50</locationX>\n        <locationY>0</locationY>\n' + connector(target) + '    </start>\n'
def money(expr):
    """Flow formula text for a whole-dollar amount with thousands separators."""
    v = f'ROUND(BLANKVALUE({expr}, 0), 0)'
    last = f'LPAD(TEXT(MOD(FLOOR({v}), 1000)), 3, "0")'
    return (f'"$" & IF({v} >= 1000000, TEXT(FLOOR({v} / 1000000)) & "," & LPAD(TEXT(MOD(FLOOR({v} / 1000), 1000)), 3, "0") & "," & {last}, '
            f'IF({v} >= 1000, TEXT(FLOOR({v} / 1000)) & "," & {last}, TEXT(FLOOR({v}))))')
TODAY = ref('$Flow.CurrentDate')
ERROR_SCREEN = lambda f: f.screen('Could_Not_Save', [display('Save_Error', '<p><strong>That could not be saved.</strong></p><p>{!$Flow.FaultMessage}</p>')], label='Could not save', back=True)

# ============================================================== 1. File a Claim
f = Flow('File_a_Claim', 'File a Claim',
         'First notice of loss. Started from a policy it uses that policy; started from a customer it asks which policy. It records the loss and opens a claim, and the claim automation then checks coverage and assigns the follow-up.')
f.variable('recordId', is_input=True); f.variable('policyId')
f.record_choices('CustomerPolicies', 'Policy__c', 'Policy_Summary__c', [('Account__c', 'EqualTo', ref('recordId'))])
f.picklist_choices('LossTypes', 'Case', 'Loss_Type__c'); f.picklist_choices('Severities', 'Case', 'Severity__c')
f.lookup('Get_Policy', 'Policy__c', [('Id', 'EqualTo', ref('recordId'))], 'Started_From_a_Policy', label='Is this a policy?')
f.decision('Started_From_a_Policy', [('From_Policy', 'Yes', 'and', [('Get_Policy', 'IsNull', b(False))], 'Use_This_Policy')], 'Choose_Policy', 'No, from a customer', label='Started from a policy?')
f.assign('Use_This_Policy', [('policyId', ref('recordId'))], 'Load_Policy')
f.screen('Choose_Policy', [choice_field('Chosen_Policy', 'Which policy does the loss fall under?', 'CustomerPolicies', 'RadioButtons')], 'Use_Chosen_Policy', label='Choose the policy')
f.assign('Use_Chosen_Policy', [('policyId', ref('Chosen_Policy'))], 'Load_Policy')
f.lookup('Load_Policy', 'Policy__c', [('Id', 'EqualTo', ref('policyId'))], 'Loss_Details')
f.screen('Loss_Details', [
    display('Policy_Banner', '<p><strong>{!Load_Policy.Name}</strong>, {!Load_Policy.Line_of_Business__c}, {!Load_Policy.Status__c}</p><p>{!Load_Policy.Insured_Item__c}</p>'),
    input_field('Summary', 'What happened, in a few words', required=True, help_text='This becomes the claim title, for example: Rear-ended at a red light.'),
    columns('When_and_What', [
        input_field('Date_of_Loss', 'Date of loss', 'Date', required=True, default=TODAY,
                    validation=rule('{!Date_of_Loss} <= {!$Flow.CurrentDate}', 'The date of loss cannot be in the future.'))], [
        choice_field('Loss_Type', 'Type of loss', 'LossTypes')]),
    columns('Where_and_How_Much', [
        input_field('Loss_Location', 'Where it happened')], [
        input_field('Estimated_Loss', 'Estimated loss, in dollars', 'Currency', scale=0, help_text='Leave blank if the customer has no figure yet.')]),
    choice_field('Severity', 'How serious is it?', 'Severities', 'RadioButtons'),
    long_text('What_Happened', 'Describe the loss', required=True)], 'Get_Claim_Record_Type', label='Loss details', action='File Claim')
f.lookup('Get_Claim_Record_Type', 'RecordType', [('SobjectType', 'EqualTo', s('Case')), ('DeveloperName', 'EqualTo', s('Claim'))], 'Create_Claim', label='Get the claim record type')
f.create('Create_Claim', 'Case', [('RecordTypeId', ref('Get_Claim_Record_Type.Id')), ('Policy__c', ref('policyId')), ('Subject', ref('Summary')), ('Description', ref('What_Happened')),
    ('Status', s('New')), ('Origin', s('Phone')), ('Date_of_Loss__c', ref('Date_of_Loss')), ('Loss_Type__c', ref('Loss_Type')), ('Severity__c', ref('Severity')),
    ('Loss_Location__c', ref('Loss_Location')), ('Estimated_Loss__c', ref('Estimated_Loss'))], 'Get_Claim', 'Could_Not_Save', label='Open the claim')
f.lookup('Get_Claim', 'Case', [('Id', 'EqualTo', ref('Create_Claim'))], 'Claim_Filed', label='Read back the claim')
f.screen('Claim_Filed', [display('Filed_Message',
    '<p><strong>Claim {!Get_Claim.CaseNumber} is open.</strong></p><p>Coverage check: {!Get_Claim.Coverage_Check__c}.</p><p>Priority: {!Get_Claim.Priority}.</p>'
    '<p>A task to contact the insured has been assigned to you.</p><p><a href="/lightning/r/Case/{!Create_Claim}/view">Open the claim</a></p>')], label='Claim filed', back=False)
ERROR_SCREEN(f)
f.xml(screen_start('Get_Policy'))

# ============================================================== 2. Record a Claim Payment
f = Flow('Record_Claim_Payment', 'Record a Claim Payment',
         'Records a payment against a claim reserve. It will not pay more than is outstanding, moves the claim to Payment Issued or closes it on a final payment, and logs the payment as a completed task.')
f.variable('recordId', is_input=True)
f.formula('ReserveText', 'String', money('{!Get_Claim.Reserve_Amount__c}'))
f.formula('PaidText', 'String', money('{!Get_Claim.Paid_Amount__c}'))
f.formula('OutstandingText', 'String', money('{!Get_Claim.Outstanding_Reserve__c}'))
f.formula('PaymentText', 'String', money('{!Payment_Amount}'))
f.formula('NewPaid', 'Currency', 'BLANKVALUE({!Get_Claim.Paid_Amount__c}, 0) + {!Payment_Amount}', scale=2)
f.formula('NewReserve', 'Currency', 'IF({!Final_Payment}, BLANKVALUE({!Get_Claim.Paid_Amount__c}, 0) + {!Payment_Amount}, {!Get_Claim.Reserve_Amount__c})', scale=2)
f.formula('NewStatus', 'String', 'IF({!Final_Payment}, "Closed", "Payment Issued")')
f.formula('PaymentTaskSubject', 'String', '"Payment of " & {!PaymentText} & " issued to " & {!Payee}')
f.formula('DefaultPayee', 'String', 'IF(ISBLANK({!Get_Claim.ContactId}), "", {!Get_Claim.Contact.FirstName} & " " & {!Get_Claim.Contact.LastName})')
f.lookup('Get_Claim', 'Case', [('Id', 'EqualTo', ref('recordId'))], 'Is_There_Reserve_to_Pay', label='Get the claim')
f.decision('Is_There_Reserve_to_Pay', [('Has_Reserve', 'Yes', 'and', [('Get_Claim.Outstanding_Reserve__c', 'GreaterThan', n('0.0'))], 'Payment_Details')],
           'No_Reserve', 'No', label='Is there reserve to pay from?')
f.screen('No_Reserve', [display('No_Reserve_Message', '<p><strong>There is no outstanding reserve on this claim.</strong></p><p>Set or raise the reserve before recording a payment.</p>')], label='No reserve')
f.screen('Payment_Details', [
    display('Claim_Position', '<p><strong>{!Get_Claim.CaseNumber}: {!Get_Claim.Subject}</strong></p><p>Reserved {!ReserveText}. Paid so far {!PaidText}. Outstanding {!OutstandingText}.</p>'),
    input_field('Payment_Amount', 'Payment amount, up to {!OutstandingText}', 'Currency', required=True, scale=2,
                validation=rule('{!Payment_Amount} > 0 && {!Payment_Amount} <= {!Get_Claim.Outstanding_Reserve__c}', 'Enter an amount above zero and no more than the outstanding reserve.')),
    input_field('Payee', 'Pay to', required=True, default=ref('DefaultPayee')),
    input_field('Final_Payment', 'This is the final payment. Close the claim and release any reserve left.', 'Boolean')], 'Update_Claim', label='Payment details', action='Record Payment')
f.update('Update_Claim', 'Case', [('Id', 'EqualTo', ref('recordId'))], [('Paid_Amount__c', ref('NewPaid')), ('Reserve_Amount__c', ref('NewReserve')), ('Status', ref('NewStatus'))],
         'Log_Payment', 'Could_Not_Save', label='Update the claim')
f.create('Log_Payment', 'Task', [('WhatId', ref('recordId')), ('WhoId', ref('Get_Claim.ContactId')), ('Subject', ref('PaymentTaskSubject')), ('Status', s('Completed')),
    ('Priority', s('Normal')), ('ActivityDate', TODAY)], 'Payment_Recorded', 'Could_Not_Save', label='Log the payment')
f.screen('Payment_Recorded', [display('Recorded_Message', '<p><strong>{!PaymentText} recorded, payable to {!Payee}.</strong></p><p>The claim is now {!NewStatus}.</p>')], label='Payment recorded', back=False)
ERROR_SCREEN(f)
f.xml(screen_start('Get_Claim'))

# ============================================================== 3. Add a Driver
f = Flow('Add_Driver', 'Add a Driver',
         'Adds a household member to an auto policy as a rated driver: captures the license and three-year driving record, works out the rating tier, and creates a task to re-rate the policy.')
f.variable('recordId', is_input=True)
f.variable('existingDriverIds', collection=True)
# Only people in the household who are not already drivers on this policy.
f.record_choices('HouseholdMembers', 'Contact', 'Name', [('AccountId', 'EqualTo', ref('Get_Policy.Account__c')), ('Id', 'NotIn', ref('existingDriverIds'))])
f.record_choices('PolicyVehicles', 'Policy_Asset__c', 'Name', [('Policy__c', 'EqualTo', ref('recordId')), ('Asset_Type__c', 'EqualTo', s('Vehicle'))], value_field='Name')
STATE_CHOICES = f.choices('State', US_STATES)
f.picklist_choices('Relationships', 'Policy_Participant__c', 'Relationship_to_Insured__c')
f.formula('ParticipantName', 'String', '{!Get_Driver.FirstName} & " " & {!Get_Driver.LastName} & ", Driver"')
f.formula('DriverRating', 'String', 'IF(({!$Flow.CurrentDate} - {!Date_Licensed}) / 365.25 < 3, "Inexperienced Operator", IF({!Violations} + {!Accidents} = 0, "Preferred", IF({!Violations} + {!Accidents} <= 2, "Standard", "Non-Standard")))')
f.formula('RerateDue', 'Date', '{!$Flow.CurrentDate} + 2')
f.formula('RerateTaskSubject', 'String', '"Re-rate policy for added driver: " & {!Get_Driver.FirstName} & " " & {!Get_Driver.LastName}')
f.lookup('Get_Policy', 'Policy__c', [('Id', 'EqualTo', ref('recordId'))], 'Is_This_an_Auto_Policy', label='Get the policy')
f.decision('Is_This_an_Auto_Policy', [('Auto', 'Yes', 'or', [('Get_Policy.Line_of_Business__c', 'EqualTo', s('Personal Auto')), ('Get_Policy.Line_of_Business__c', 'EqualTo', s('Commercial Auto'))], 'Get_Current_Drivers')],
           'Not_an_Auto_Policy', 'No', label='Is this an auto policy?')
f.screen('Not_an_Auto_Policy', [display('Not_Auto_Message', '<p><strong>Drivers can only be added to auto policies.</strong></p><p>{!Get_Policy.Name} is a {!Get_Policy.Line_of_Business__c} policy.</p>')], label='Not an auto policy')
f.lookup('Get_Current_Drivers', 'Policy_Participant__c', [('Policy__c', 'EqualTo', ref('recordId')), ('Role__c', 'EqualTo', s('Driver'))], 'Each_Current_Driver', label='Get the drivers already on the policy', every=True)
f.loop('Each_Current_Driver', 'Get_Current_Drivers', 'Note_Current_Driver', 'Driver_Details', label='For each current driver')
f.assign('Note_Current_Driver', [('existingDriverIds', ref('Each_Current_Driver.Contact__c'))], 'Each_Current_Driver', label='Leave them out of the list', operator='Add')
f.screen('Driver_Details', [
    display('Driver_Intro', '<p><strong>{!Get_Policy.Name}</strong>, {!Get_Policy.Insured_Item__c}</p>'),
    choice_field('Driver', 'Who is being added?', 'HouseholdMembers', 'RadioButtons'),
    columns('Relationship_and_Vehicle', [
        choice_field('Relationship', 'Relationship to the named insured', 'Relationships')], [
        choice_field('Primary_Vehicle', 'Vehicle they will mainly drive', 'PolicyVehicles', required=False)]),
    input_field('Effective_Date', 'Effective date', 'Date', required=True, default=TODAY)], 'License_and_Record', label='Who is being added')
f.screen('License_and_Record', [
    display('License_Intro', '<p><strong>License and driving record</strong></p><p>The rating tier comes from these answers.</p>'),
    columns('License', [
        input_field('License_Number', 'License number', required=True)], [
        choice_field('License_State', 'License state', STATE_CHOICES, default='State_IL')]),
    input_field('Date_Licensed', 'Date first licensed', 'Date', required=True, validation=rule('{!Date_Licensed} <= {!$Flow.CurrentDate}', 'The date first licensed cannot be in the future.')),
    columns('Record', [
        input_field('Violations', 'Moving violations in the past 3 years', 'Number', required=True, default=n('0.0'), scale=0)], [
        input_field('Accidents', 'At-fault accidents in the past 3 years', 'Number', required=True, default=n('0.0'), scale=0)]),
    input_field('Good_Student', 'Good student discount applies', 'Boolean')], 'Get_Driver', label='License and driving record', action='Add Driver')
f.lookup('Get_Driver', 'Contact', [('Id', 'EqualTo', ref('Driver'))], 'Find_Existing_Driver', label='Get the person')
f.lookup('Find_Existing_Driver', 'Policy_Participant__c', [('Policy__c', 'EqualTo', ref('recordId')), ('Contact__c', 'EqualTo', ref('Driver')), ('Role__c', 'EqualTo', s('Driver'))],
         'Already_a_Driver', label='Already on the policy?')
f.decision('Already_a_Driver', [('Listed', 'Yes', 'and', [('Find_Existing_Driver', 'IsNull', b(False))], 'Already_Listed')], 'Create_Participant', 'No', label='Already a driver on this policy?')
f.screen('Already_Listed', [display('Already_Message', '<p><strong>{!Get_Driver.FirstName} {!Get_Driver.LastName} is already a driver on this policy.</strong></p>')], label='Already a driver')
f.create('Create_Participant', 'Policy_Participant__c', [('Name', ref('ParticipantName')), ('Policy__c', ref('recordId')), ('Contact__c', ref('Driver')), ('Role__c', s('Driver')),
    ('Status__c', s('Active')), ('Relationship_to_Insured__c', ref('Relationship')), ('Is_Primary__c', b(False)), ('Effective_Date__c', ref('Effective_Date')),
    ('License_Number__c', ref('License_Number')), ('License_State__c', ref('License_State')), ('Date_Licensed__c', ref('Date_Licensed')), ('Driver_Rating__c', ref('DriverRating')),
    ('Violations_Past_3_Years__c', ref('Violations')), ('Accidents_Past_3_Years__c', ref('Accidents')), ('Good_Student_Discount__c', ref('Good_Student')),
    ('Primary_Vehicle__c', ref('Primary_Vehicle'))], 'Mark_as_Licensed', 'Could_Not_Save', label='Add the driver')
f.update('Mark_as_Licensed', 'Contact', [('Id', 'EqualTo', ref('Driver'))], [('Licensed_Driver__c', b(True))], 'Create_Rerate_Task', 'Could_Not_Save', label='Mark the person as licensed')
f.create('Create_Rerate_Task', 'Task', [('WhatId', ref('recordId')), ('WhoId', ref('Driver')), ('Subject', ref('RerateTaskSubject')), ('Status', s('Not Started')),
    ('Priority', s('Normal')), ('ActivityDate', ref('RerateDue'))], 'Driver_Added', 'Could_Not_Save', label='Ask for a re-rate')
f.screen('Driver_Added', [display('Added_Message', '<p><strong>{!Get_Driver.FirstName} {!Get_Driver.LastName} is now a driver on {!Get_Policy.Name}.</strong></p>'
    '<p>Rating tier: {!DriverRating}.</p><p>A task to re-rate the policy is due in two days.</p>')], label='Driver added', back=False)
ERROR_SCREEN(f)
f.xml(screen_start('Get_Policy'))

# ============================================================== 4. Bind Policy
LINE_CODE = ('CASE(TEXT({!Get_Opportunity.Line_of_Business__c}), "Personal Auto", "PA", "Homeowners", "HO", "Renters", "RN", "Umbrella", "UM", '
             '"Commercial Property", "CP", "General Liability", "GL", "Workers Compensation", "WC", "Commercial Auto", "CA", "NB")')
f = Flow('Bind_Policy', 'Bind Policy',
         'Closes a policy sale on its accepted quote. A renewal rolls the existing policy into its next term at the agreed premium; new business issues a new policy with its named insured. '
         'Either way the sale moves to Bound and the quote is marked Bound.')
f.variable('recordId', is_input=True); f.variable('quoteId'); f.variable('saleId')
f.variable('quotePremium', 'Currency', scale=2); f.variable('quoteLimit', 'Currency', scale=2); f.variable('quoteDeductible', 'Currency', scale=2)
f.record_choices('AccountContacts', 'Contact', 'Name', [('AccountId', 'EqualTo', ref('Get_Opportunity.AccountId'))])
f.formula('SuggestedNumber', 'String', '"ANT-" & ' + LINE_CODE + ' & "-" & RIGHT(TEXT(FLOOR((NOW() - DATETIMEVALUE("2026-01-01 00:00:00")) * 86400)), 6)')
f.formula('NewExpiration', 'Date', 'ADDMONTHS({!Effective_Date}, 12)')
f.formula('RenewalExpiration', 'Date', 'ADDMONTHS({!Get_Renewing_Policy.Expiration_Date__c}, 12)')
f.formula('NamedInsuredName', 'String', '{!Get_Named_Insured.FirstName} & " " & {!Get_Named_Insured.LastName} & ", Named Insured"')
f.formula('PremiumText', 'String', money('{!Annual_Premium}'))
f.formula('RenewalPremiumText', 'String', money('{!Renewal_Premium}'))
f.formula('QuoteLine', 'String', 'IF(ISBLANK({!quoteId}), "There is no quote on this sale, so enter the terms the customer agreed.", "These terms come from the option the customer chose. Change them only if something different was agreed.")')
# Options that went to the customer and are still open, for when none has been marked accepted.
# Once the Quote has an option summary field (the option's name with its premium), the choices show it.
OPTION_DISPLAY = 'Option_Summary__c' if os.path.exists(os.path.join(ROOT, 'objects/Quote/fields/Option_Summary__c.field-meta.xml')) else 'Name'
f.record_choices('OpenOptions', 'Quote', OPTION_DISPLAY, [('OpportunityId', 'EqualTo', ref('saleId')), ('Status', 'NotEqualTo', s('Draft')), ('Status', 'NotEqualTo', s('Declined')),
                                                  ('Status', 'NotEqualTo', s('Expired')), ('Status', 'NotEqualTo', s('Bound'))], sort='QuoteNumber')
# The flow starts from a sale (Bind Policy) or from one of its quotes (Bind This Quote). From a quote, that quote is the
# option taken and the sale is the quote's; from a sale, the flow looks for the accepted option or asks which one.
f.lookup('Get_Launch_Quote', 'Quote', [('Id', 'EqualTo', ref('recordId'))], 'Where_It_Started', label='Was this started from a quote?')
f.decision('Where_It_Started', [
    ('From_Sale', 'From the sale', 'and', [('Get_Launch_Quote', 'IsNull', b(True))], 'Use_the_Sale'),
    ('Cannot_Bind', 'From a quote that cannot be bound', 'or', [('Get_Launch_Quote.Status', 'EqualTo', s('Draft')), ('Get_Launch_Quote.Status', 'EqualTo', s('Declined')),
                                                             ('Get_Launch_Quote.Status', 'EqualTo', s('Expired')), ('Get_Launch_Quote.Status', 'EqualTo', s('Bound'))], 'Quote_Cannot_Be_Bound')],
    'Use_Launch_Quote', 'From a quote', label='Where did this start?')
f.assign('Use_the_Sale', [('saleId', ref('recordId'))], 'Get_Opportunity', label='Bind this sale')
f.assign('Use_Launch_Quote', [('saleId', ref('Get_Launch_Quote.OpportunityId')), ('quoteId', ref('Get_Launch_Quote.Id')), ('quotePremium', ref('Get_Launch_Quote.Annual_Premium__c')),
                              ('quoteLimit', ref('Get_Launch_Quote.Coverage_Limit__c')), ('quoteDeductible', ref('Get_Launch_Quote.Deductible__c'))], 'Get_Opportunity', label='Bind this quote')
f.screen('Quote_Cannot_Be_Bound', [display('Cannot_Bind_Message', '<p><strong>This quote cannot be bound.</strong></p><p>Its status is {!Get_Launch_Quote.Status}. '
    'A quote can be bound once it has been issued and until it is bound, declined or expired.</p>')], label='Quote cannot be bound')
f.lookup('Get_Opportunity', 'Opportunity', [('Id', 'EqualTo', ref('saleId'))], 'Came_With_a_Quote', label='Get the sale')
f.decision('Came_With_a_Quote', [('With_Quote', 'Yes', 'and', [('quoteId', 'IsNull', b(False))], 'What_Kind_of_Sale')], 'Find_Accepted_Quote', 'No', label='Did it start from a quote?')
f.lookup('Find_Accepted_Quote', 'Quote', [('OpportunityId', 'EqualTo', ref('saleId')), ('Status', 'EqualTo', s('Accepted'))], 'Was_a_Quote_Accepted', label='Find the accepted quote')
f.decision('Was_a_Quote_Accepted', [('Accepted', 'Yes', 'and', [('Find_Accepted_Quote', 'IsNull', b(False))], 'Use_Quote_Terms')], 'Find_an_Open_Option', 'No', label='Was a quote accepted?')
f.lookup('Find_an_Open_Option', 'Quote', [('OpportunityId', 'EqualTo', ref('saleId')), ('Status', 'NotEqualTo', s('Draft')), ('Status', 'NotEqualTo', s('Declined')),
                                        ('Status', 'NotEqualTo', s('Expired')), ('Status', 'NotEqualTo', s('Bound'))], 'Is_There_an_Option', label='Is any option still open?')
f.decision('Is_There_an_Option', [('Open', 'Yes', 'and', [('Find_an_Open_Option', 'IsNull', b(False)), ('Get_Opportunity.IsClosed', 'EqualTo', b(False))], 'Choose_Option')], 'Use_Sale_Terms', 'No', label='Is there an option to choose?')
f.screen('Choose_Option', [choice_field('Chosen_Option', 'Which option is the customer taking?', 'OpenOptions', 'RadioButtons')], 'Get_Chosen_Option', label='Choose the option')
f.lookup('Get_Chosen_Option', 'Quote', [('Id', 'EqualTo', ref('Chosen_Option'))], 'Use_Chosen_Terms', label='Get the chosen option')
f.assign('Use_Chosen_Terms', [('quoteId', ref('Get_Chosen_Option.Id')), ('quotePremium', ref('Get_Chosen_Option.Annual_Premium__c')),
                              ('quoteLimit', ref('Get_Chosen_Option.Coverage_Limit__c')), ('quoteDeductible', ref('Get_Chosen_Option.Deductible__c'))], 'What_Kind_of_Sale', label='Use the chosen terms')
f.assign('Use_Quote_Terms', [('quoteId', ref('Find_Accepted_Quote.Id')), ('quotePremium', ref('Find_Accepted_Quote.Annual_Premium__c')),
                             ('quoteLimit', ref('Find_Accepted_Quote.Coverage_Limit__c')), ('quoteDeductible', ref('Find_Accepted_Quote.Deductible__c'))], 'What_Kind_of_Sale', label='Use the quote terms')
f.assign('Use_Sale_Terms', [('quotePremium', ref('Get_Opportunity.Amount'))], 'What_Kind_of_Sale', label='Use the sale amount')
f.decision('What_Kind_of_Sale', [
    ('Closed', 'Already closed', 'and', [('Get_Opportunity.IsClosed', 'EqualTo', b(True))], 'Already_Closed'),
    ('Renewal', 'Renewal of a policy', 'and', [('Get_Opportunity.Type', 'EqualTo', s('Renewal')), ('Get_Opportunity.Policy__c', 'IsNull', b(False))], 'Get_Renewing_Policy')],
    'New_Policy_Details', 'New policy', label='What kind of sale is this?')
f.screen('Already_Closed', [display('Closed_Message', '<p><strong>This sale is already closed.</strong></p><p>Its stage is {!Get_Opportunity.StageName}.</p>')], label='Already closed')
# renewal
f.lookup('Get_Renewing_Policy', 'Policy__c', [('Id', 'EqualTo', ref('Get_Opportunity.Policy__c'))], 'Renewal_Terms', label='Get the policy being renewed')
f.screen('Renewal_Terms', [
    display('Renewal_Summary', '<p><strong>Renew {!Get_Renewing_Policy.Name}</strong>, {!Get_Renewing_Policy.Line_of_Business__c}</p>'
            '<p>The current term ends {!Get_Renewing_Policy.Expiration_Date__c}. The new term runs to {!RenewalExpiration}.</p><p>{!QuoteLine}</p>'),
    input_field('Renewal_Premium', 'Renewal annual premium', 'Currency', required=True, default=ref('quotePremium'), scale=2,
                validation=rule('{!Renewal_Premium} > 0', 'Enter the renewal premium.'))], 'Renew_Policy', label='Renewal terms', action='Renew Policy')
f.update('Renew_Policy', 'Policy__c', [('Id', 'EqualTo', ref('Get_Opportunity.Policy__c'))], [('Effective_Date__c', ref('Get_Renewing_Policy.Expiration_Date__c')),
    ('Expiration_Date__c', ref('RenewalExpiration')), ('Annual_Premium__c', ref('Renewal_Premium')), ('Status__c', s('Active')), ('Payment_Status__c', s('Current'))],
    'Close_Renewal', 'Could_Not_Save', label='Roll the policy into its new term')
f.update('Close_Renewal', 'Opportunity', [('Id', 'EqualTo', ref('saleId'))], [('StageName', s('Bound')), ('Amount', ref('Renewal_Premium')), ('CloseDate', TODAY)],
         'Mark_Renewal_Quote_Bound', 'Could_Not_Save', label='Mark the sale as bound')
f.update('Mark_Renewal_Quote_Bound', 'Quote', [('Id', 'EqualTo', ref('quoteId'))], [('Status', s('Bound'))], 'Policy_Renewed', 'Could_Not_Save', label='Mark the quote as bound')
f.screen('Policy_Renewed', [display('Renewed_Message', '<p><strong>{!Get_Renewing_Policy.Name} is renewed at {!RenewalPremiumText} a year.</strong></p>'
    '<p>The new term runs to {!RenewalExpiration}.</p><p><a href="/lightning/r/Policy__c/{!Get_Renewing_Policy.Id}/view">Open the policy</a></p>')], label='Policy renewed', back=False)
# new business
BILLING_CHOICES = f.choices('Billing', ['Annual', 'Semi-Annual', 'Quarterly', 'Monthly'])
f.screen('New_Policy_Details', [
    display('New_Summary', '<p><strong>{!Get_Opportunity.Name}</strong>, {!Get_Opportunity.Line_of_Business__c}</p><p>{!QuoteLine}</p>'),
    input_field('Policy_Number', 'Policy number', required=True, default=ref('SuggestedNumber')),
    choice_field('Named_Insured', 'Named insured', 'AccountContacts', 'RadioButtons'),
    input_field('Effective_Date', 'Effective date', 'Date', required=True, default=TODAY),
    input_field('Annual_Premium', 'Annual premium', 'Currency', required=True, default=ref('quotePremium'), scale=2, validation=rule('{!Annual_Premium} > 0', 'Enter the annual premium.')),
    input_field('Coverage_Limit', 'Coverage limit', 'Currency', required=True, default=ref('quoteLimit'), scale=2, validation=rule('{!Coverage_Limit} > 0', 'Enter the coverage limit.')),
    input_field('Deductible', 'Deductible', 'Currency', default=ref('quoteDeductible'), scale=2),
    choice_field('Billing', 'Billing frequency', BILLING_CHOICES, default='Billing_Annual'),
    input_field('Insured_Item', 'What is insured', help_text='The vehicle, property address or business operation.')], 'Create_Policy', label='New policy details', action='Bind Policy')
f.create('Create_Policy', 'Policy__c', [('Name', ref('Policy_Number')), ('Account__c', ref('Get_Opportunity.AccountId')), ('Primary_Insured__c', ref('Named_Insured')),
    ('Line_of_Business__c', ref('Get_Opportunity.Line_of_Business__c')), ('Status__c', s('Active')), ('Effective_Date__c', ref('Effective_Date')), ('Expiration_Date__c', ref('NewExpiration')),
    ('Annual_Premium__c', ref('Annual_Premium')), ('Coverage_Limit__c', ref('Coverage_Limit')), ('Deductible__c', ref('Deductible')), ('Billing_Frequency__c', ref('Billing')),
    ('Payment_Status__c', s('Current')), ('Insured_Item__c', ref('Insured_Item'))], 'Get_Named_Insured', 'Could_Not_Save', label='Issue the policy')
f.lookup('Get_Named_Insured', 'Contact', [('Id', 'EqualTo', ref('Named_Insured'))], 'Create_Named_Insured', label='Get the named insured')
f.create('Create_Named_Insured', 'Policy_Participant__c', [('Name', ref('NamedInsuredName')), ('Policy__c', ref('Create_Policy')), ('Contact__c', ref('Named_Insured')),
    ('Role__c', s('Named Insured')), ('Status__c', s('Active')), ('Relationship_to_Insured__c', s('Self')), ('Is_Primary__c', b(True)), ('Effective_Date__c', ref('Effective_Date'))],
    'Close_Sale', 'Could_Not_Save', label='Add the named insured')
f.update('Close_Sale', 'Opportunity', [('Id', 'EqualTo', ref('saleId'))], [('StageName', s('Bound')), ('Policy__c', ref('Create_Policy')), ('Amount', ref('Annual_Premium')), ('CloseDate', TODAY)],
         'Mark_Quote_Bound', 'Could_Not_Save', label='Mark the sale as bound')
f.update('Mark_Quote_Bound', 'Quote', [('Id', 'EqualTo', ref('quoteId'))], [('Status', s('Bound'))], 'Policy_Bound', 'Could_Not_Save', label='Mark the quote as bound')
f.screen('Policy_Bound', [display('Bound_Message', '<p><strong>Policy {!Policy_Number} is bound at {!PremiumText} a year.</strong></p><p>Coverage runs from {!Effective_Date} to {!NewExpiration}.</p>'
    '<p>Its coverages, insured item and endorsements are on the policy.</p><p><a href="/lightning/r/Policy__c/{!Create_Policy}/view">Open the policy</a></p>')], label='Policy bound', back=False)
ERROR_SCREEN(f)
f.xml(screen_start('Get_Launch_Quote'))

# ============================================================== 5. Past due follow-up (record-triggered)
f = Flow('Policy_Past_Due_Follow_Up', 'Policy: Past Due Follow-Up',
         'When a policy becomes past due on its premium, the customer owner gets a task to call the policyholder before the policy lapses.', process_type='AutoLaunchedFlow')
f.formula('CallBy', 'Date', '{!$Flow.CurrentDate} + 2')
f.formula('TaskSubject', 'String', '"Call about past due premium on " & {!$Record.Name}')
f.create('Create_Call_Task', 'Task', [('WhatId', ref('$Record.Id')), ('WhoId', ref('$Record.Primary_Insured__c')), ('OwnerId', ref('$Record.Account__r.OwnerId')), ('Subject', ref('TaskSubject')),
    ('Status', s('Not Started')), ('Priority', s('High')), ('ActivityDate', ref('CallBy'))], None, label='Ask the owner to call')
f.xml('    <start>\n        <locationX>50</locationX>\n        <locationY>0</locationY>\n' + connector('Create_Call_Task') +
      '        <doesRequireRecordChangedToMeetCriteria>true</doesRequireRecordChangedToMeetCriteria>\n        <filterLogic>and</filterLogic>\n        <filters>\n            <field>Payment_Status__c</field>\n'
      '            <operator>EqualTo</operator>\n' + value(s('Past Due')) + '        </filters>\n        <object>Policy__c</object>\n        <recordTriggerType>CreateAndUpdate</recordTriggerType>\n'
      '        <triggerType>RecordAfterSave</triggerType>\n    </start>\n')

# ============================================================== quick actions that launch the flows
def flow_action(name, label, description, flow):
    write(f'quickActions/{name}.quickAction-meta.xml', f'<QuickAction {NS}>\n    <description>{esc(description)}</description>\n    <flowDefinition>{flow}</flowDefinition>\n'
          f'    <label>{label}</label>\n    <optionsCreateFeedItem>false</optionsCreateFeedItem>\n    <type>Flow</type>\n</QuickAction>')
flow_action('Policy__c.File_Claim', 'File a Claim', 'Guided first notice of loss for this policy.', 'File_a_Claim')
flow_action('Account.File_Claim', 'File a Claim', 'Guided first notice of loss: choose one of this customer\'s policies, then record the loss.', 'File_a_Claim')
flow_action('Case.Record_Payment', 'Record a Payment', 'Record a payment against this claim\'s reserve.', 'Record_Claim_Payment')
flow_action('Policy__c.Add_Driver', 'Add a Driver', 'Add a household member to this auto policy as a rated driver.', 'Add_Driver')
flow_action('Opportunity.Bind_Policy', 'Bind Policy', 'Issue the policy or roll the renewal, and close this sale as Bound.', 'Bind_Policy')
flow_action('Quote.Bind_Quote', 'Bind This Quote', 'Issue the policy on this option, or roll the renewal, and close its sale as Bound.', 'Bind_Policy')
def layout_item(name, behavior='Edit'):
    return f'            <quickActionLayoutItems>\n                <emptySpace>false</emptySpace>\n                <field>{name}</field>\n                <uiBehavior>{behavior}</uiBehavior>\n            </quickActionLayoutItems>\n'
# Generate Quote has no screen of its own: the LWC starts a draft quote and opens its configurator.
write('quickActions/Opportunity.Generate_Quote.quickAction-meta.xml', f'''<QuickAction {NS}>
    <description>Start a quote for this sale and walk through the questions with the customer.</description>
    <label>Generate Quote</label>
    <lightningWebComponent>antsuranceGenerateQuote</lightningWebComponent>
    <optionsCreateFeedItem>false</optionsCreateFeedItem>
    <type>LightningWebComponent</type>
</QuickAction>''')
print('flows generated')
