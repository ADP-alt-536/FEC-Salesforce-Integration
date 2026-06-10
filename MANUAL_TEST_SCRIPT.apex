System.debug('=== Scott Peters FEC Manual Test ===');
String candidateId = 'H2CA52089';
Integer cycleYear = (Math.mod(Date.today().year(), 2) == 0)
    ? Date.today().year()
    : Date.today().year() + 1;
System.debug('Using current election cycle: ' + cycleYear);

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
String srcFecField = pacFields.containsKey('Source_FEC_ID__c') ? 'Source_FEC_ID__c' : null;
String srcNameField = pacFields.containsKey('Source_Name__c') ? 'Source_Name__c' : null;
String contributorNameField = pacFields.containsKey('Contributor_Committee_Name__c')
    ? 'Contributor_Committee_Name__c'
    : null;
String recipientNameField = pacFields.containsKey('Recipient_Committee_Name__c')
    ? 'Recipient_Committee_Name__c'
    : null;
String contribAccountField = pacFields.containsKey('Contributing_Account__c')
    ? 'Contributing_Account__c'
    : null;

List<String> selectFields = new List<String>{ 'Id' };
if (!selectFields.contains(txnField)) { selectFields.add(txnField); }
if (amtField != null && !selectFields.contains(amtField)) { selectFields.add(amtField); }
if (dtField != null && !selectFields.contains(dtField)) { selectFields.add(dtField); }
if (srcFecField != null && !selectFields.contains(srcFecField)) { selectFields.add(srcFecField); }
if (srcNameField != null && !selectFields.contains(srcNameField)) { selectFields.add(srcNameField); }
if (contributorNameField != null && !selectFields.contains(contributorNameField)) {
    selectFields.add(contributorNameField);
}
if (recipientNameField != null && !selectFields.contains(recipientNameField)) {
    selectFields.add(recipientNameField);
}
if (contribAccountField != null && !selectFields.contains(contribAccountField)) {
    selectFields.add(contribAccountField);
}
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
Integer matchingRows = 0;
for (SObject row : rows) {
    if (pacFields.containsKey('Recipient_Legislator__c') && row.get('Recipient_Legislator__c') != leg.Id) {
        continue;
    }
    if (!pacFields.containsKey('Recipient_Legislator__c')
            && pacFields.containsKey('Recipient_Committee__c')
            && row.get('Recipient_Committee__c') != committee.Id) {
        continue;
    }
    matchingRows++;
    String amountOut = (amtField != null) ? String.valueOf(row.get(amtField)) : '(amount field missing)';
    String dateOut = (dtField != null) ? String.valueOf(row.get(dtField)) : '(date field missing)';
    String sourceFecOut = (srcFecField != null) ? String.valueOf(row.get(srcFecField)) : '(source FEC id field missing)';
    String sourceNameOut = (srcNameField != null) ? String.valueOf(row.get(srcNameField)) : '(source name field missing)';
    String contributorNameOut = (contributorNameField != null)
        ? String.valueOf(row.get(contributorNameField))
        : '(contributor committee name field missing)';
    String recipientNameOut = (recipientNameField != null)
        ? String.valueOf(row.get(recipientNameField))
        : '(recipient committee name field missing)';
    String accountLinkOut = (contribAccountField != null)
        ? String.valueOf(row.get(contribAccountField))
        : '(contributing account field missing)';
    System.debug('PAC => Txn: ' + String.valueOf(row.get(txnField))
        + ' | Amount: ' + amountOut
        + ' | Date: ' + dateOut
        + ' | Source FEC ID: ' + sourceFecOut
        + ' | Source Name: ' + sourceNameOut
        + ' | Contributor Committee: ' + contributorNameOut
        + ' | Recipient Committee: ' + recipientNameOut
        + ' | Linked Account: ' + accountLinkOut);
}

if (matchingRows == 0) {
    System.debug('No PAC_Contribution__c rows matched this legislator/committee in today\'s results.');
    System.debug('If the queueable finished successfully, this usually means the FEC API returned no current-cycle committee contributions for committee '
        + committee.FEC_Committee_ID__c + '.');
}

System.debug('=== Done ===');
