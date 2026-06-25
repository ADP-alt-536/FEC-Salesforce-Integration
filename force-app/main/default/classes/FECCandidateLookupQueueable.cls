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
                Map<String, String> params = new Map<String, String>{ 'name' => toFecNameFormat(leg.Name__c) };
                String fecParty = toFecPartyCode(leg.Party__c);
                if (String.isNotBlank(fecParty))        params.put('party',    fecParty);
                String fecDistrict = toFecDistrict(leg.District__c);
                if (String.isNotBlank(fecDistrict))     params.put('district', fecDistrict);

                List<FECAPIService.CandidateSearchResult> matches = svc.searchCandidates(params);

                if (matches.size() == 1) {
                    toUpdate.add(new Legislator__c(
                        Id                  = leg.Id,
                        FEC_Candidate_ID__c = matches[0].candidateId
                    ));
                    System.debug(LoggingLevel.INFO,
                        'FEC candidate lookup matched Legislator ' + leg.Id
                        + ' Name__c=' + leg.Name__c
                        + ' -> candidate_id=' + matches[0].candidateId);
                } else if (matches.isEmpty()) {
                    System.debug(LoggingLevel.WARN,
                        'FEC candidate lookup returned 0 results for Legislator ' + leg.Id
                        + ' Name__c=' + leg.Name__c + ' params=' + params);
                } else {
                    System.debug(LoggingLevel.WARN,
                        'FEC candidate lookup returned ' + matches.size() + ' results (ambiguous) for Legislator ' + leg.Id
                        + ' Name__c=' + leg.Name__c + ' params=' + params
                        + ' candidates=' + matchSummary(matches));
                }
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

    private static String matchSummary(List<FECAPIService.CandidateSearchResult> matches) {
        List<String> parts = new List<String>();
        for (FECAPIService.CandidateSearchResult r : matches) {
            parts.add(r.candidateId + '/' + r.name + '/' + r.state + '/' + r.office);
        }
        return String.join(parts, ', ');
    }

    // Converts "First Last" → "LAST, FIRST" to match FEC name storage format.
    // Names already containing a comma (e.g. "PELOSI, NANCY") pass through unchanged.
    // Single-word names pass through as-is.
    @TestVisible
    private static String toFecNameFormat(String name) {
        if (String.isBlank(name)) return null;
        String n = name.trim().toUpperCase();
        if (n.contains(',')) return n;          // already in FEC format
        Integer lastSpace = n.lastIndexOf(' ');
        if (lastSpace == -1) return n;          // single-word name, search as-is
        return n.substring(lastSpace + 1) + ', ' + n.substring(0, lastSpace).trim();
    }

    // Strips state prefix from District__c values like "CA-51" → "51".
    // Zero-pads single-digit districts: "1" → "01". Returns null for non-numeric values.
    @TestVisible
    private static String toFecDistrict(String district) {
        if (String.isBlank(district)) return null;
        Integer hyphen = district.lastIndexOf('-');
        String num = (hyphen >= 0) ? district.substring(hyphen + 1).trim() : district.trim();
        if (!num.isNumeric()) return null;
        return num.length() == 1 ? '0' + num : num;
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
