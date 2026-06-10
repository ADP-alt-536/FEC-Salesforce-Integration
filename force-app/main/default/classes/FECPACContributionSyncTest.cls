/**
 * FECPACContributionSyncTest
 *
 * Unit tests for FECPACContributionSync.
 * Uses the @TestVisible FECAPIService constructor to bypass Custom Metadata.
 */
@IsTest
private class FECPACContributionSyncTest {

    /** Returns a test FECAPIService that bypasses Custom Metadata. */
    private static FECAPIService testApiService() {
        return new FECAPIService('TEST_API_KEY', 'https://api.open.fec.gov/v1', 120000, 100);
    }

    private static FECCommitteeSync testCommitteeSync() {
        return new FECCommitteeSync(testApiService());
    }

    @IsTest
    static void testSyncContributions_createsPACContribution() {
        // Ensure the recipient FEC_Committee__c exists so we can look it up
        FEC_Committee__c recipientComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00177436',
            Name                = 'Recipient Committee'
        );
        insert recipientComm;

        // The mock will serve:
        //  1st call (getScheduleAContributions) → ScheduleA with 1 COMMITTEE + 1 INDIVIDUAL
        //  Subsequent calls for ensureCommitteesExist → committee financials
        Test.setMock(HttpCalloutMock.class,
            new FECMultiMock(new List<HttpCalloutMock>{
                new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS),
                new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS)
            }));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, null);
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'Only 1 PAC (COMMITTEE entity_type) contribution expected');
        PAC_Contribution__c rec = results[0];
        System.assertEquals('TRN001',    rec.Transaction_ID__c,      'Transaction ID mismatch');
        System.assertEquals('ACME PAC',  rec.Source_Name__c,         'Source name mismatch');
        System.assertEquals('C00111111',  rec.Source_FEC_ID__c,       'Source FEC id mismatch');
        System.assertEquals('ACME PAC Committee', rec.Contributor_Committee_Name__c,
            'Contributor committee name mismatch');
        System.assertEquals('Recipient Committee', rec.Recipient_Committee_Name__c,
            'Recipient committee name mismatch');
        System.assertEquals(5000.00,     rec.Contribution_Amount__c, 'Amount mismatch');
        System.assertEquals(recipientComm.Id, rec.Recipient_Committee__c,
            'Recipient committee should be linked');
    }

    @IsTest
    static void testSyncContributions_emptyApiResult() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_EMPTY));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, null);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty API result should return empty list');
    }

    @IsTest
    static void testSyncContributions_linksAccount() {
        FEC_Committee__c contributorComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00111111',
            Name                = 'ACME PAC Committee'
        );
        insert contributorComm;

        FEC_Committee__c recipientComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00177436',
            Name                = 'Recipient Committee'
        );
        insert recipientComm;

        Account acc = new Account(
            Name                     = 'ACME Corp',
            Corporate_PAC_Committee__c = contributorComm.Id
        );
        insert acc;

        // Mock only the Schedule A call; ensureCommitteesExist will skip because
        // both committees already exist in Salesforce
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, null);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(acc.Id, results[0].Contributing_Account__c,
            'Contributing_Account__c should be set from Corporate_PAC_Committee__c lookup');
    }

    @IsTest
    static void testSyncContributions_linksAccountByFecId() {
        FEC_Committee__c contributorComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00111111',
            Name                = 'ACME PAC Committee'
        );
        insert contributorComm;

        FEC_Committee__c recipientComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00177436',
            Name                = 'Recipient Committee'
        );
        insert recipientComm;

        Account acc = new Account(Name = 'ACME Corp by FEC ID');
        acc.put('FEC_ID__c', 'C00111111');
        insert acc;

        // Mock only the Schedule A call; committee records already exist.
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, null);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(acc.Id, results[0].Contributing_Account__c,
            'Contributing_Account__c should be set by Account.FEC_ID__c');
    }

    @IsTest
    static void testSyncContributions_linksLegislator() {
        Legislator__c leg = new Legislator__c(
            FEC_Candidate_ID__c = 'H00001234'
        );
        insert leg;

        FEC_Committee__c recipientComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00177436',
            Name                = 'Recipient Committee'
        );
        insert recipientComm;

        Test.setMock(HttpCalloutMock.class,
            new FECMultiMock(new List<HttpCalloutMock>{
                new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS),
                new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS)
            }));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, leg.Id);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(leg.Id, results[0].Recipient_Legislator__c,
            'Recipient_Legislator__c should be set');
    }
}
