System.debug('=== Scott Peters FEC Manual Test ===');
String candidateId = 'H2CA52089';
Integer cycleYear = 2024;

List<Legislator__c> legs = [
    SELECT Id, Name, FEC_Candidate_ID__c, Primary_Committee__c
    FROM Legislator__c
    WHERE FEC_Candidate_ID__c = :candidateId
    LIMIT 1
];
if (legs.isEmpty()) {
    System.debug('No Legislator__c found for candidate ID ' + candidateId + '.');
    return;
}

Legislator__c leg = legs[0];
System.debug('Legislator: ' + leg.Name + ' (' + leg.Id + ')');

FEC_Committee__c committee = new FECCommitteeSync().syncLegislatorPrimaryCommittee(
    leg.Id,
    candidateId,
    cycleYear
);
if (committee == null) {
    System.debug('No principal committee returned by FEC API for candidate ' + candidateId + ' in cycle ' + cycleYear + '.');
    return;
}

System.debug('Committee synced: ' + committee.FEC_Committee_ID__c + ' | ' + committee.Committee_Name__c);

Id queuedJobId = System.enqueueJob(new FECManualPACSyncQueueable(
    committee.FEC_Committee_ID__c,
    cycleYear,
    leg.Id
));
System.debug('Queued PAC contribution sync job: ' + queuedJobId);
System.debug('Re-run this script after the queued job completes to view synced PAC rows.');

Map<String, Schema.SObjectField> pacFields = Schema.SObjectType.PAC_Contribution__c.fields.getMap();
String txnField = pacFields.containsKey('Transaction_ID__c') ? 'Transaction_ID__c' : 'Id';
String amtField = pacFields.containsKey('Contribution_Amount__c')
    ? 'Contribution_Amount__c'
    : (pacFields.containsKey('Amount__c') ? 'Amount__c' : null);
String dtField = pacFields.containsKey('Contribution_Date__c') ? 'Contribution_Date__c' : null;

List<String> selectFields = new List<String>{ 'Id' };
if (!selectFields.contains(txnField)) { selectFields.add(txnField); }
if (amtField != null && !selectFields.contains(amtField)) { selectFields.add(amtField); }
if (dtField != null && !selectFields.contains(dtField)) { selectFields.add(dtField); }
if (pacFields.containsKey('Recipient_Legislator__c')) {
    if (!selectFields.contains('Recipient_Legislator__c')) { selectFields.add('Recipient_Legislator__c'); }
}
if (pacFields.containsKey('Recipient_Committee__c')) {
    if (!selectFields.contains('Recipient_Committee__c')) { selectFields.add('Recipient_Committee__c'); }
}

String soql =
    'SELECT ' + String.join(selectFields, ', ') + ' '
    + 'FROM PAC_Contribution__c '
    + 'WHERE LastModifiedDate = TODAY '
    + 'ORDER BY LastModifiedDate DESC '
    + 'LIMIT 20';

List<SObject> rows = Database.query(soql);
System.debug('Recent PAC rows returned: ' + rows.size());
for (SObject row : rows) {
    if (pacFields.containsKey('Recipient_Legislator__c') && row.get('Recipient_Legislator__c') != leg.Id) {
        continue;
    }
    if (!pacFields.containsKey('Recipient_Legislator__c')
            && pacFields.containsKey('Recipient_Committee__c')
            && row.get('Recipient_Committee__c') != committee.Id) {
        continue;
    }
    String amountOut = (amtField != null) ? String.valueOf(row.get(amtField)) : '(amount field missing)';
    String dateOut = (dtField != null) ? String.valueOf(row.get(dtField)) : '(date field missing)';
    System.debug('PAC => Txn: ' + String.valueOf(row.get(txnField))
        + ' | Amount: ' + amountOut
        + ' | Date: ' + dateOut);
}

System.debug('=== Done ===');
