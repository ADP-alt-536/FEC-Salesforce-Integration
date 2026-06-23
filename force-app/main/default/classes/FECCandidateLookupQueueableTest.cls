/**
 * FECCandidateLookupQueueableTest
 *
 * Unit tests for FECCandidateLookupQueueable and LegislatorTrigger.
 * HTTP callouts are intercepted by FECAPIMock. The @TestVisible constructor
 * injects a pre-configured FECAPIService instance to avoid hitting Custom Metadata.
 */
@IsTest
private class FECCandidateLookupQueueableTest {

    private static FECAPIService testService() {
        return new FECAPIService('TEST_KEY', 'https://api.open.fec.gov/v1', 120000, 100);
    }

    // ─── toFecNameFormat ──────────────────────────────────────────────────────

    @IsTest
    static void testToFecNameFormat_conversions() {
        System.assertEquals('PELOSI, NANCY',    FECCandidateLookupQueueable.toFecNameFormat('Nancy Pelosi'));
        System.assertEquals('SMITH, JOHN',      FECCandidateLookupQueueable.toFecNameFormat('John Smith'));
        System.assertEquals('SMITH, MARY JO',   FECCandidateLookupQueueable.toFecNameFormat('Mary Jo Smith'));
        System.assertEquals('PELOSI, NANCY',    FECCandidateLookupQueueable.toFecNameFormat('PELOSI, NANCY'));  // already FEC format
        System.assertEquals('PELOSI',           FECCandidateLookupQueueable.toFecNameFormat('Pelosi'));         // single word
        System.assertEquals(null,               FECCandidateLookupQueueable.toFecNameFormat(null));
        System.assertEquals(null,               FECCandidateLookupQueueable.toFecNameFormat(''));
    }

    // ─── toFecDistrict ────────────────────────────────────────────────────────

    @IsTest
    static void testToFecDistrict_conversions() {
        System.assertEquals('51', FECCandidateLookupQueueable.toFecDistrict('CA-51'));  // strips state prefix
        System.assertEquals('01', FECCandidateLookupQueueable.toFecDistrict('CA-1'));   // zero-pads single digit
        System.assertEquals('51', FECCandidateLookupQueueable.toFecDistrict('51'));     // no prefix, passes through
        System.assertEquals('01', FECCandidateLookupQueueable.toFecDistrict('1'));      // no prefix, zero-pads
        System.assertEquals(null, FECCandidateLookupQueueable.toFecDistrict('CA-AL')); // non-numeric (at-large)
        System.assertEquals(null, FECCandidateLookupQueueable.toFecDistrict(null));
        System.assertEquals(null, FECCandidateLookupQueueable.toFecDistrict(''));
    }

    // ─── toFecPartyCode ───────────────────────────────────────────────────────

    @IsTest
    static void testToFecPartyCode_mappings() {
        System.assertEquals('DEM', FECCandidateLookupQueueable.toFecPartyCode('Democrat'));
        System.assertEquals('REP', FECCandidateLookupQueueable.toFecPartyCode('Republican'));
        System.assertEquals('IND', FECCandidateLookupQueueable.toFecPartyCode('Independent'));
        System.assertEquals(null,  FECCandidateLookupQueueable.toFecPartyCode('Green'));
        System.assertEquals(null,  FECCandidateLookupQueueable.toFecPartyCode(null));
        System.assertEquals(null,  FECCandidateLookupQueueable.toFecPartyCode(''));
    }

    // ─── execute: single match ────────────────────────────────────────────────

    @IsTest
    static void testSingleMatch_populatesCandidateId() {
        Legislator__c leg = new Legislator__c(Name__c = 'DOE, JOHN');
        insert leg;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_SINGLE));

        Test.startTest();
        new FECCandidateLookupQueueable(
            new List<Id>{ leg.Id }, testService()
        ).execute(null);
        Test.stopTest();

        Legislator__c updated = [SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id = :leg.Id];
        System.assertEquals('H00001234', updated.FEC_Candidate_ID__c,
            'Single match should populate FEC_Candidate_ID__c');
    }

    // ─── execute: no match ────────────────────────────────────────────────────

    @IsTest
    static void testNoMatch_leavesFieldBlank() {
        Legislator__c leg = new Legislator__c(Name__c = 'NOBODY, UNKNOWN');
        insert leg;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_EMPTY));

        Test.startTest();
        new FECCandidateLookupQueueable(
            new List<Id>{ leg.Id }, testService()
        ).execute(null);
        Test.stopTest();

        Legislator__c updated = [SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id = :leg.Id];
        System.assertEquals(null, updated.FEC_Candidate_ID__c,
            'No match should leave FEC_Candidate_ID__c blank');
    }

    // ─── execute: multiple matches ────────────────────────────────────────────

    @IsTest
    static void testMultipleMatches_leavesFieldBlank() {
        Legislator__c leg = new Legislator__c(Name__c = 'SMITH, JOHN');
        insert leg;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_MULTI));

        Test.startTest();
        new FECCandidateLookupQueueable(
            new List<Id>{ leg.Id }, testService()
        ).execute(null);
        Test.stopTest();

        Legislator__c updated = [SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id = :leg.Id];
        System.assertEquals(null, updated.FEC_Candidate_ID__c,
            'Multiple matches should leave FEC_Candidate_ID__c blank');
    }

    // ─── execute: already populated ───────────────────────────────────────────

    @IsTest
    static void testAlreadyPopulated_skipsRecord() {
        Legislator__c leg = new Legislator__c(
            Name__c             = 'PRE, POPULATED',
            FEC_Candidate_ID__c = 'H99999999'
        );
        insert leg;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_SINGLE));

        Test.startTest();
        new FECCandidateLookupQueueable(
            new List<Id>{ leg.Id }, testService()
        ).execute(null);
        Test.stopTest();

        Legislator__c updated = [SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id = :leg.Id];
        System.assertEquals('H99999999', updated.FEC_Candidate_ID__c,
            'Pre-populated ID should not be overwritten');
    }

    // ─── execute: API error ───────────────────────────────────────────────────

    @IsTest
    static void testApiException_swallowedAndFieldRemainsNull() {
        Legislator__c leg = new Legislator__c(Name__c = 'ERROR, TEST');
        insert leg;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.ERROR_500));

        Test.startTest();
        Boolean exceptionEscaped = false;
        try {
            new FECCandidateLookupQueueable(
                new List<Id>{ leg.Id }, testService()
            ).execute(null);
        } catch (Exception e) {
            exceptionEscaped = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionEscaped, 'API exception should be swallowed');
        Legislator__c updated = [SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id = :leg.Id];
        System.assertEquals(null, updated.FEC_Candidate_ID__c,
            'FEC_Candidate_ID__c should remain null after API error');
    }

    // ─── execute: bulk ────────────────────────────────────────────────────────

    @IsTest
    static void testBulkInsert_allLegislatorsPopulated() {
        List<Legislator__c> legs = new List<Legislator__c>{
            new Legislator__c(Name__c = 'ALPHA, ONE'),
            new Legislator__c(Name__c = 'BETA, TWO'),
            new Legislator__c(Name__c = 'GAMMA, THREE')
        };
        insert legs;

        // One CANDIDATE_SEARCH_SINGLE mock response per legislator (3 total)
        Test.setMock(HttpCalloutMock.class,
            new FECMultiMock(new List<HttpCalloutMock>{
                new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_SINGLE),
                new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_SINGLE),
                new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_SINGLE)
            }));

        List<Id> ids = new List<Id>();
        for (Legislator__c l : legs) ids.add(l.Id);

        Test.startTest();
        new FECCandidateLookupQueueable(ids, testService()).execute(null);
        Test.stopTest();

        List<Legislator__c> updated = [
            SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id IN :ids
        ];
        for (Legislator__c l : updated) {
            System.assertEquals('H00001234', l.FEC_Candidate_ID__c,
                'All legislators should be populated in a bulk run');
        }
    }

    // ─── trigger integration ──────────────────────────────────────────────────

    @IsTest
    static void testTrigger_enqueuesJobAndPopulatesId() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_SINGLE));

        Legislator__c leg = new Legislator__c(Name__c = 'TRIGGER, TEST');
        Test.startTest();
        insert leg;
        Test.stopTest(); // async job executes here

        Legislator__c updated = [SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id = :leg.Id];
        System.assertEquals('H00001234', updated.FEC_Candidate_ID__c,
            'Trigger should enqueue lookup job that populates FEC_Candidate_ID__c');
    }

    @IsTest
    static void testTrigger_skipsRecordsWithExistingId() {
        Legislator__c leg = new Legislator__c(
            Name__c             = 'ALREADY, SET',
            FEC_Candidate_ID__c = 'H11111111'
        );
        Test.startTest();
        insert leg;
        Test.stopTest();

        // No mock needed — trigger should not enqueue a job for this record
        Legislator__c updated = [SELECT FEC_Candidate_ID__c FROM Legislator__c WHERE Id = :leg.Id];
        System.assertEquals('H11111111', updated.FEC_Candidate_ID__c,
            'Trigger should not overwrite an existing FEC_Candidate_ID__c');
    }
}
