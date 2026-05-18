/**
 * FECDataSyncBatchTest
 *
 * Unit tests for FECDataSyncBatch and FECDataSyncScheduler.
 * Uses the @TestVisible FECAPIService constructor and testApiServiceOverride
 * to bypass Custom Metadata configuration.
 */
@IsTest
private class FECDataSyncBatchTest {

    /** Returns a test FECAPIService that bypasses Custom Metadata. */
    private static FECAPIService testApiService() {
        return new FECAPIService('TEST_API_KEY', 'https://api.open.fec.gov/v1', 120000, 100);
    }

    @TestSetup
    static void setupTestData() {
        List<Legislator__c> legislators = new List<Legislator__c>{
            new Legislator__c(
                FEC_Candidate_ID__c = 'H00001111'
            ),
            new Legislator__c(
                FEC_Candidate_ID__c = 'H00002222'
            ),
            // This one has no FEC ID and should be skipped
            new Legislator__c(FEC_Candidate_ID__c = null)
        };
        insert legislators;
    }

    @IsTest
    static void testBatch_processesLegislatorsWithFECId() {
        // Each legislator triggers: getPrincipalCommitteeId + getCommitteeFinancials
        // + getScheduleAContributions (returns empty, so no PAC inserts)
        Test.setMock(HttpCalloutMock.class,
            new FECMultiMock(new List<HttpCalloutMock>{
                // Legislator 1 – principal committee lookup
                new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE),
                // Legislator 1 – committee financials
                new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS),
                // Legislator 1 – schedule A (empty)
                new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_EMPTY),
                // Legislator 2 – principal committee (returns empty, no committee synced)
                new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE_EMPTY)
            }));

        Test.startTest();
        FECDataSyncBatch batch = new FECDataSyncBatch(2024, 5);
        batch.testApiServiceOverride = testApiService();
        Database.executeBatch(batch, 5);
        Test.stopTest();

        // Legislator 1 should have a committee and Primary_Committee__c set
        List<FEC_Committee__c> committees = [SELECT FEC_Committee_ID__c FROM FEC_Committee__c];
        System.assertEquals(1, committees.size(),
            'One FEC_Committee__c should be created for Legislator 1');

        Legislator__c legWithCommittee = [
            SELECT Primary_Committee__c
            FROM Legislator__c
            WHERE FEC_Candidate_ID__c = 'H00001111'
        ];
        System.assertNotEquals(null, legWithCommittee.Primary_Committee__c,
            'Primary_Committee__c should be linked for Legislator 1');
    }

    @IsTest
    static void testBatch_defaultConstructorUsesCycle() {
        Test.startTest();
        FECDataSyncBatch batch = new FECDataSyncBatch();
        Test.stopTest();
        System.assertNotEquals(null, batch, 'Default constructor should succeed');
    }

    @IsTest
    static void testScheduler_executesWithCycle() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE_EMPTY));

        Test.startTest();
        FECDataSyncScheduler scheduler = new FECDataSyncScheduler(2024);
        String jobId = System.schedule(
            'FEC Test Sync',
            '0 0 2 * * ?',
            scheduler
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Scheduler job should be created');
    }

    @IsTest
    static void testScheduler_defaultConstructor() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE_EMPTY));

        Test.startTest();
        FECDataSyncScheduler scheduler = new FECDataSyncScheduler();
        String jobId = System.schedule(
            'FEC Test Sync Default',
            '0 0 3 * * ?',
            scheduler
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Scheduler job with default constructor should be created');
    }
}
