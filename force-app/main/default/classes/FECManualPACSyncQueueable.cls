public with sharing class FECManualPACSyncQueueable implements Queueable, Database.AllowsCallouts {

    private final String recipientCommitteeId;
    private final Integer cycleYear;
    private final Id legislatorId;

    public FECManualPACSyncQueueable(String recipientCommitteeId, Integer cycleYear, Id legislatorId) {
        this.recipientCommitteeId = recipientCommitteeId;
        this.cycleYear = cycleYear;
        this.legislatorId = legislatorId;
    }

    public void execute(QueueableContext context) {
        List<PAC_Contribution__c> synced = new FECPACContributionSync().syncContributions(
            recipientCommitteeId,
            cycleYear,
            legislatorId
        );

        System.debug('FECManualPACSyncQueueable complete. PAC contributions synced: ' + synced.size());
    }
}
