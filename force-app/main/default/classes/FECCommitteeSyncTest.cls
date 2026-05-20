/**
 * FECCommitteeSyncTest
 *
 * Unit tests for FECCommitteeSync.
 * Uses FECAPIMock to stub HTTP callouts and the @TestVisible FECAPIService
 * constructor to bypass Custom Metadata configuration.
 */
@IsTest
private class FECCommitteeSyncTest {

    /** Returns a test FECAPIService that bypasses Custom Metadata. */
    private static FECAPIService testApiService() {
        return new FECAPIService('TEST_API_KEY', 'https://api.open.fec.gov/v1', 120000, 100);
    }

    @IsTest
    static void testSyncCommittee_createsRecord() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS));

        Test.startTest();
        FECCommitteeSync sync = new FECCommitteeSync(testApiService());
        FEC_Committee__c result = sync.syncCommittee('C00177436', 2024, null);
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Committee record should have been upserted');
        System.assertEquals('C00177436',     result.FEC_Committee_ID__c);
        System.assertEquals('Test Committee', result.Committee_Name__c);
        System.assertEquals('House',          result.Committee_Type__c);
        System.assertEquals(500000.00,        result.Cash_on_Hand__c);
        System.assertEquals(1000000.00,       result.Total_Receipts__c);
        System.assertEquals(500000.00,        result.Total_Disbursements__c);
        System.assertNotEquals(null,          result.Last_Sync_Date__c);
    }

    @IsTest
    static void testSyncCommittee_emptyFinancials_stillCreatesRecord() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS_EMPTY));

        Test.startTest();
        FECCommitteeSync sync = new FECCommitteeSync(testApiService());
        FEC_Committee__c result = sync.syncCommittee('C00177436', 2024, null);
        Test.stopTest();

        // Even with no FEC data the record should be upserted with just the ID
        System.assertNotEquals(null, result.Id, 'Committee record should be created even without financials');
        System.assertEquals('C00177436', result.FEC_Committee_ID__c);
    }

    @IsTest
    static void testSyncCommittees_multipleIds() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS));

        Test.startTest();
        FECCommitteeSync sync   = new FECCommitteeSync(testApiService());
        List<FEC_Committee__c> results =
            sync.syncCommittees(new List<String>{'C00177436', 'C00222222'}, 2024);
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should sync both committees');
    }

    @IsTest
    static void testSyncLegislatorPrimaryCommittee_linksLegislator() {
        // Need a Legislator__c record – create a minimal one
        Legislator__c leg = new Legislator__c(
            FEC_Candidate_ID__c = 'H00001234'
        );
        insert leg;

        // Two-call mock: first for getPrincipalCommitteeId, then for getCommitteeFinancials
        Test.setMock(HttpCalloutMock.class,
            new FECMultiMock(new List<HttpCalloutMock>{
                new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE),
                new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS)
            }));

        Test.startTest();
        FECCommitteeSync sync   = new FECCommitteeSync(testApiService());
        FEC_Committee__c result =
            sync.syncLegislatorPrimaryCommittee(leg.Id, 'H00001234', 2024);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return the synced committee');
        System.assertEquals('C00177436', result.FEC_Committee_ID__c);

        // Verify Legislator__c.Primary_Committee__c was updated
        Legislator__c updatedLeg = [
            SELECT Primary_Committee__c FROM Legislator__c WHERE Id = :leg.Id
        ];
        System.assertEquals(result.Id, updatedLeg.Primary_Committee__c,
            'Primary_Committee__c should be updated on the legislator');
    }

    @IsTest
    static void testSyncLegislatorPrimaryCommittee_blankCandidateId_returnsNull() {
        Legislator__c leg = new Legislator__c();
        insert leg;

        Test.startTest();
        FECCommitteeSync sync   = new FECCommitteeSync(testApiService());
        FEC_Committee__c result =
            sync.syncLegislatorPrimaryCommittee(leg.Id, '', 2024);
        Test.stopTest();

        System.assertEquals(null, result,
            'Blank candidateId should return null without making callouts');
    }

    @IsTest
    static void testSyncLegislatorPrimaryCommittee_noCommitteeFound_returnsNull() {
        Legislator__c leg = new Legislator__c(
            FEC_Candidate_ID__c = 'H99999999'
        );
        insert leg;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE_EMPTY));

        Test.startTest();
        FECCommitteeSync sync   = new FECCommitteeSync(testApiService());
        FEC_Committee__c result =
            sync.syncLegislatorPrimaryCommittee(leg.Id, 'H99999999', 2024);
        Test.stopTest();

        System.assertEquals(null, result,
            'Should return null when no principal committee is found');
    }
}
