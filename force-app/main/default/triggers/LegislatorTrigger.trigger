trigger LegislatorTrigger on Legislator__c (after insert) {
    List<Id> idsToLookup = new List<Id>();
    for (Legislator__c leg : Trigger.new) {
        if (String.isBlank(leg.FEC_Candidate_ID__c)) {
            idsToLookup.add(leg.Id);
        }
    }
    if (!idsToLookup.isEmpty()) {
        System.enqueueJob(new FECCandidateLookupQueueable(idsToLookup));
    }
}
