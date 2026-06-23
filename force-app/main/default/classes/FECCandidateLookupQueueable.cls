/**
 * FECCandidateLookupQueueable
 *
 * Async job triggered after Legislator__c insert. Searches the FEC candidate
 * API by Name, Party, and District and writes FEC_Candidate_ID__c when exactly
 * one match is returned. Zero or multiple matches leave the field blank.
 */
public class FECCandidateLookupQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> legislatorIds;

    @TestVisible
    private FECAPIService apiService;

    public FECCandidateLookupQueueable(List<Id> legislatorIds) {
        this.legislatorIds = legislatorIds;
    }

    @TestVisible
    private FECCandidateLookupQueueable(List<Id> legislatorIds, FECAPIService apiService) {
        this.legislatorIds = legislatorIds;
        this.apiService    = apiService;
    }

    public void execute(QueueableContext ctx) {
        FECAPIService svc = apiService != null ? apiService : new FECAPIService();

        // Re-query for latest values. ORDER BY Name keeps ordering predictable in tests.
        // Records where FEC_Candidate_ID__c was manually filled after the trigger fired are skipped.
        List<Legislator__c> legislators = [
            SELECT Id, Name__c, Party__c, District__c
            FROM Legislator__c
            WHERE Id IN :legislatorIds
              AND FEC_Candidate_ID__c = null
            ORDER BY Name__c
        ];

        List<Legislator__c> toUpdate = new List<Legislator__c>();

        for (Legislator__c leg : legislators) {
            try {
                Map<String, String> params = new Map<String, String>{ 'name' => leg.Name__c };
                String fecParty = toFecPartyCode(leg.Party__c);
                if (String.isNotBlank(fecParty))        params.put('party',    fecParty);
                if (String.isNotBlank(leg.District__c)) params.put('district', leg.District__c);

                List<FECAPIService.CandidateSearchResult> matches = svc.searchCandidates(params);

                if (matches.size() == 1) {
                    toUpdate.add(new Legislator__c(
                        Id                  = leg.Id,
                        FEC_Candidate_ID__c = matches[0].candidateId
                    ));
                }
                // 0 or 2+ matches — leave blank for manual resolution
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'FEC candidate lookup failed for Legislator ' + leg.Id
                    + ': ' + e.getMessage());
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // Maps Party__c picklist labels to FEC 3-letter party codes.
    // Unrecognised values return null so the param is omitted from the search.
    @TestVisible
    private static String toFecPartyCode(String party) {
        if (String.isBlank(party)) return null;
        switch on party {
            when 'Democrat'    { return 'DEM'; }
            when 'Republican'  { return 'REP'; }
            when 'Independent' { return 'IND'; }
            when else          { return null;  }
        }
    }
}
