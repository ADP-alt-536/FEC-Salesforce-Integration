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
    static void testSyncContributions_skipsContributionWithoutAccountMatch() {
        // Ensure the recipient FEC_Committee__c exists so we can look it up
        FEC_Committee__c recipientComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00177436',
            Name                = 'Recipient Committee'
        );
        insert recipientComm;

        // Mock only the Schedule A call. Contributor committees should not be
        // materialized when no Account.FEC_ID__c match exists.
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, null);
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'PAC contribution should be skipped when no Account.FEC_ID__c match exists');
        System.assertEquals(0, [
            SELECT COUNT()
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c = 'C00111111'
        ], 'Contributor committee should not be created without Account.FEC_ID__c linkage');
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
    static void testSyncContributions_skipsCorporatePacFallbackOnlyAccount() {
        FEC_Committee__c recipientComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00177436',
            Name                = 'Recipient Committee'
        );
        insert recipientComm;

        FEC_Committee__c contributorComm = new FEC_Committee__c(
            FEC_Committee_ID__c = 'C00111111',
            Name                = 'ACME PAC Committee'
        );
        insert contributorComm;

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

        System.assertEquals(0, results.size(),
            'PAC contribution should be skipped when only Corporate_PAC_Committee__c is populated');
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
        System.assertEquals('TRN001', results[0].Transaction_ID__c);
        System.assertEquals('ACME PAC', results[0].Source_Name__c);
        System.assertEquals('C00111111', results[0].Source_FEC_ID__c);
        System.assertEquals(5000.00, results[0].Contribution_Amount__c);
        System.assertEquals(recipientComm.Id, results[0].Recipient_Committee__c);
        System.assertEquals(acc.Id, results[0].Contributing_Account__c,
            'Contributing_Account__c should be set by Account.FEC_ID__c');
    }

    @IsTest
    static void testSyncContributions_linksAccountByNormalizedFecId() {
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

        Account acc = new Account(Name = 'ACME Corp normalized FEC ID');
        acc.put('FEC_ID__c', ' c00111111 ');
        insert acc;

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, null);
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'Contribution should be created when Account.FEC_ID__c only differs by case/whitespace');
        System.assertEquals('C00111111', results[0].Source_FEC_ID__c,
            'Source_FEC_ID__c should be normalized for consistent linkage');
        System.assertEquals(acc.Id, results[0].Contributing_Account__c);
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
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

        Test.startTest();
        FECAPIService apiSvc = testApiService();
        FECPACContributionSync sync = new FECPACContributionSync(apiSvc, new FECCommitteeSync(apiSvc));
        List<PAC_Contribution__c> results =
            sync.syncContributions('C00177436', 2024, leg.Id);
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'Legislator should not be linked when no Account.FEC_ID__c-matched contribution is created');
        System.assertEquals(0, [
            SELECT COUNT()
            FROM FEC_Committee__c
            WHERE FEC_Committee_ID__c = 'C00111111'
        ], 'Contributor committee should not be created when no linked account exists');
    }

    @IsTest
    static void testSyncContributions_linksLegislatorWhenAccountMatchesFecId() {
        Legislator__c leg = new Legislator__c(
            FEC_Candidate_ID__c = 'H00001234'
        );
        insert leg;

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

        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

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
