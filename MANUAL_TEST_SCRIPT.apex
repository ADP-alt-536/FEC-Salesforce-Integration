System.debug('=== FEC Manual Trigger Test ===');

Integer cycleYear = (Math.mod(Date.today().year(), 2) == 0)
    ? Date.today().year()
    : Date.today().year() + 1;

List<Legislator__c> legs = [
    SELECT Id, Name, FEC_Candidate_ID__c
    FROM Legislator__c
    WHERE FEC_Candidate_ID__c != null
    ORDER BY LastModifiedDate DESC
    LIMIT 1
];
if (legs.isEmpty()) {
    System.debug('No Legislator__c found with a populated FEC_Candidate_ID__c.');
    return;
}

Legislator__c leg = legs[0];
String candidateId = leg.FEC_Candidate_ID__c;
System.debug('Legislator found: ' + leg.Name + ' (' + leg.Id + ')');
System.debug('Candidate ID from test record: ' + candidateId);

FEC_Committee__c committee = new FECCommitteeSync().syncLegislatorPrimaryCommittee(
    leg.Id,
    candidateId,
    cycleYear
);
if (committee == null) {
    System.debug('No principal committee returned by FEC API for candidate ' + candidateId + ' in cycle ' + cycleYear + '.');
    return;
}

Id queuedJobId = System.enqueueJob(new FECManualPACSyncQueueable(
    committee.FEC_Committee_ID__c,
    cycleYear,
    leg.Id
));

System.debug('Workflow triggered.');
System.debug('Cycle: ' + cycleYear);
System.debug('Committee: ' + committee.FEC_Committee_ID__c + ' | ' + committee.Committee_Name__c);
System.debug('PAC queueable job id: ' + queuedJobId);

// PAC inspection: show recent rows for this recipient context.
Map<String, Schema.SObjectField> pacFields = Schema.SObjectType.PAC_Contribution__c.fields.getMap();
Boolean hasRecipientCommittee = pacFields.containsKey('Recipient_Committee__c');
Boolean hasRecipientLegislator = pacFields.containsKey('Recipient_Legislator__c');

List<String> selectFields = new List<String>{ 'Id', 'LastModifiedDate' };
if (pacFields.containsKey('Transaction_ID__c')) { selectFields.add('Transaction_ID__c'); }
if (pacFields.containsKey('Contribution_Amount__c')) { selectFields.add('Contribution_Amount__c'); }
if (pacFields.containsKey('Contribution_Date__c')) { selectFields.add('Contribution_Date__c'); }
if (pacFields.containsKey('Source_FEC_ID__c')) { selectFields.add('Source_FEC_ID__c'); }
if (pacFields.containsKey('Source_Name__c')) { selectFields.add('Source_Name__c'); }
if (pacFields.containsKey('Contributor_Committee_Name__c')) { selectFields.add('Contributor_Committee_Name__c'); }
if (pacFields.containsKey('Recipient_Committee_Name__c')) { selectFields.add('Recipient_Committee_Name__c'); }
if (pacFields.containsKey('Contributing_Account__c')) { selectFields.add('Contributing_Account__c'); }
if (pacFields.containsKey('Last_Sync_Date__c')) { selectFields.add('Last_Sync_Date__c'); }
if (hasRecipientCommittee) { selectFields.add('Recipient_Committee__c'); }
if (hasRecipientLegislator) { selectFields.add('Recipient_Legislator__c'); }

String whereClause = '';
if (hasRecipientCommittee) {
    whereClause = 'Recipient_Committee__c = \'' + String.escapeSingleQuotes((String) committee.Id) + '\'';
} else if (hasRecipientLegislator) {
    whereClause = 'Recipient_Legislator__c = \'' + String.escapeSingleQuotes((String) leg.Id) + '\'';
}

if (String.isBlank(whereClause)) {
    System.debug('PAC inspection skipped: no Recipient_Committee__c or Recipient_Legislator__c field found.');
} else {
    String soql =
        'SELECT ' + String.join(selectFields, ', ') + ' '
        + 'FROM PAC_Contribution__c '
        + 'WHERE ' + whereClause + ' '
        + 'ORDER BY LastModifiedDate DESC '
        + 'LIMIT 10';

    List<SObject> pacRows = Database.query(soql);
    System.debug('PAC inspection rows found: ' + pacRows.size());

    for (SObject row : pacRows) {
        String txn = pacFields.containsKey('Transaction_ID__c') ? String.valueOf(row.get('Transaction_ID__c')) : String.valueOf(row.get('Id'));
        String amt = pacFields.containsKey('Contribution_Amount__c') ? String.valueOf(row.get('Contribution_Amount__c')) : '(n/a)';
        String dt = pacFields.containsKey('Contribution_Date__c') ? String.valueOf(row.get('Contribution_Date__c')) : '(n/a)';
        String srcFec = pacFields.containsKey('Source_FEC_ID__c') ? String.valueOf(row.get('Source_FEC_ID__c')) : '(n/a)';
        String srcName = pacFields.containsKey('Source_Name__c') ? String.valueOf(row.get('Source_Name__c')) : '(n/a)';
        String recipientName = pacFields.containsKey('Recipient_Committee_Name__c') ? String.valueOf(row.get('Recipient_Committee_Name__c')) : '(n/a)';
        String linkedAccount = pacFields.containsKey('Contributing_Account__c') ? String.valueOf(row.get('Contributing_Account__c')) : '(n/a)';
        System.debug('PAC => Txn: ' + txn
            + ' | Amount: ' + amt
            + ' | Date: ' + dt
            + ' | Source FEC: ' + srcFec
            + ' | Source Name: ' + srcName
            + ' | Recipient: ' + recipientName
            + ' | Linked Account: ' + linkedAccount
            + ' | LastModified: ' + String.valueOf(row.get('LastModifiedDate')));
    }
}

System.debug('=== Done ===');
