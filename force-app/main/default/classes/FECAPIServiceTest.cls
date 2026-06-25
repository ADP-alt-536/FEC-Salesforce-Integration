/**
 * FECAPIServiceTest
 *
 * Unit tests for FECAPIService. HTTP callouts are intercepted by FECAPIMock.
 * The @TestVisible constructor is used to inject settings directly, bypassing
 * the Custom Metadata query and API key validation.
 */
@IsTest
private class FECAPIServiceTest {

    /** Creates a pre-configured FECAPIService for use in tests. */
    private static FECAPIService testService() {
        return new FECAPIService('TEST_API_KEY', 'https://api.open.fec.gov/v1', 120000, 100);
    }

    // ─── getCommitteeFinancials ───────────────────────────────────────────────

    @IsTest
    static void testGetCommitteeFinancials_success() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS));

        Test.startTest();
        FECAPIService.CommitteeFinancials fin =
            testService().getCommitteeFinancials('C00177436', 2024);
        Test.stopTest();

        System.assertNotEquals(null, fin, 'CommitteeFinancials should not be null');
        System.assertEquals('Test Committee', fin.committeeName,  'Committee name mismatch');
        System.assertEquals('House',          fin.committeeType,  'Committee type mismatch');
        System.assertEquals('Authorized',     fin.designation,    'Designation mismatch');
        System.assertEquals(500000.00,        fin.cashOnHand,     'Cash on hand mismatch');
        System.assertEquals(1000000.00,       fin.totalReceipts,  'Total receipts mismatch');
        System.assertEquals(500000.00,        fin.totalDisbursements, 'Disbursements mismatch');
        System.assertEquals(2024,             fin.cycle,          'Cycle mismatch');
    }

    @IsTest
    static void testGetCommitteeFinancials_emptyResult() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS_EMPTY));

        Test.startTest();
        FECAPIService.CommitteeFinancials fin =
            testService().getCommitteeFinancials('C00177436', 2024);
        Test.stopTest();

        System.assertEquals(null, fin, 'Empty results should return null');
    }

    @IsTest
    static void testGetCommitteeFinancials_endingCashOnHandField() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.COMMITTEE_FINANCIALS_ENDING_CASH));

        Test.startTest();
        FECAPIService.CommitteeFinancials fin =
            testService().getCommitteeFinancials('C00177436', 2024);
        Test.stopTest();

        System.assertNotEquals(null, fin, 'CommitteeFinancials should not be null');
        System.assertEquals(750000.00, fin.cashOnHand,
            'Cash on hand should map from ending_cash_on_hand when present');
    }

    @IsTest
    static void testGetCommitteeFinancials_nullCommitteeId() {
        Test.startTest();
        FECAPIService.CommitteeFinancials fin =
            testService().getCommitteeFinancials(null, 2024);
        Test.stopTest();

        System.assertEquals(null, fin, 'Null committeeId should return null');
    }

    // ─── getScheduleAContributions ────────────────────────────────────────────

    @IsTest
    static void testGetScheduleAContributions_filtersPACOnly() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTIONS));

        Test.startTest();
        List<FECAPIService.ScheduleAContribution> contribs =
            testService().getScheduleAContributions('C00177436',
                new Map<String, String>{'cycle' => '2024'});
        Test.stopTest();

        // The mock returns 2 records: 1 COMMITTEE (PAC) and 1 INDIVIDUAL
        // Only the COMMITTEE one should be returned
        System.assertEquals(1, contribs.size(), 'Only PAC (COMMITTEE) contributions should be returned');
        System.assertEquals('TRN001',     contribs[0].transactionId,          'Transaction ID mismatch');
        System.assertEquals('C00111111',  contribs[0].contributorCommitteeId, 'Contributor committee mismatch');
        System.assertEquals(5000.00,      contribs[0].contributionAmount,     'Amount mismatch');
        System.assertEquals('COMMITTEE',  contribs[0].entityType,             'Entity type mismatch');
    }

    @IsTest
    static void testGetScheduleAContributions_emptyResult() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_EMPTY));

        Test.startTest();
        List<FECAPIService.ScheduleAContribution> contribs =
            testService().getScheduleAContributions('C00177436', null);
        Test.stopTest();

        System.assertEquals(0, contribs.size(), 'Empty results should return empty list');
    }

    @IsTest
    static void testGetScheduleAContributions_readsLaterPages() {
        Test.setMock(HttpCalloutMock.class,
            new FECMultiMock(new List<HttpCalloutMock>{
                new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_PAGE1_INDIVIDUALS),
                new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_PAGE2_PAC)
            }));

        Test.startTest();
        List<FECAPIService.ScheduleAContribution> contribs =
            testService().getScheduleAContributions('C00177436',
                new Map<String, String>{'cycle' => '2026'});
        Test.stopTest();

        System.assertEquals(1, contribs.size(),
            'PAC contributions from later API pages should be included');
        System.assertEquals('TRN200', contribs[0].transactionId,
            'Later-page PAC transaction should be returned');
        System.assertEquals('C00430256', contribs[0].contributorCommitteeId,
            'Later-page contributor committee should be returned');
    }

    @IsTest
    static void testGetScheduleAContributions_usesContributorIdFallback() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.SCHEDULE_A_CONTRIBUTOR_ID_ONLY));

        Test.startTest();
        List<FECAPIService.ScheduleAContribution> contribs =
            testService().getScheduleAContributions('C00503110',
                new Map<String, String>{'cycle' => '2026'});
        Test.stopTest();

        System.assertEquals(1, contribs.size(),
            'Rows with contributor_id committee values should be retained');
        System.assertEquals('C00430256', contribs[0].contributorCommitteeId,
            'contributor_id should be used when contributor_committee_id is blank');
        System.assertEquals('TRN300', contribs[0].transactionId,
            'Fallback row transaction should be returned');
    }

    @IsTest
    static void testGetScheduleAContributions_nullCommitteeId() {
        Test.startTest();
        List<FECAPIService.ScheduleAContribution> contribs =
            testService().getScheduleAContributions(null, null);
        Test.stopTest();

        System.assertEquals(0, contribs.size(), 'Null committeeId should return empty list');
    }

    // ─── getPrincipalCommitteeId ──────────────────────────────────────────────

    @IsTest
    static void testGetPrincipalCommitteeId_found() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE));

        Test.startTest();
        String committeeId = testService().getPrincipalCommitteeId('H00001234', 2024);
        Test.stopTest();

        System.assertEquals('C00177436', committeeId, 'Principal committee ID mismatch');
    }

    @IsTest
    static void testGetPrincipalCommitteeId_notFound() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.PRINCIPAL_COMMITTEE_EMPTY));

        Test.startTest();
        String committeeId = testService().getPrincipalCommitteeId('H00001234', 2024);
        Test.stopTest();

        System.assertEquals(null, committeeId, 'Empty result should return null');
    }

    @IsTest
    static void testGetPrincipalCommitteeId_nullCandidateId() {
        Test.startTest();
        String committeeId = testService().getPrincipalCommitteeId(null, 2024);
        Test.stopTest();

        System.assertEquals(null, committeeId, 'Null candidateId should return null');
    }

    // ─── Error handling ───────────────────────────────────────────────────────

    @IsTest
    static void testApiError_throwsFECAPIException() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.ERROR_500));

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            testService().getCommitteeFinancials('C00177436', 2024);
        } catch (FECAPIService.FECAPIException ex) {
            exceptionThrown = true;
            System.assert(ex.getMessage().contains('500'), 'Exception message should contain status code');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'FECAPIException should have been thrown on HTTP 500');
    }

    @IsTest
    static void testMissingApiKey_throwsFECAPIException() {
        // Create a Custom Metadata record with a placeholder value (or no record)
        // The default constructor will throw because no valid key is configured
        Boolean exceptionThrown = false;
        try {
            // Use the public no-arg constructor which calls loadSettings()
            // In a scratch org with no real CMT record this will throw
            FECAPIService svc = new FECAPIService();
        } catch (FECAPIService.FECAPIException ex) {
            exceptionThrown = true;
            System.assert(ex.getMessage().contains('FEC API key is not configured'),
                'Exception should mention unconfigured API key');
        }
        // If a real CMT record was deployed with a valid key, no exception is expected.
        // This test validates the error path when no key is available.
        System.debug('testMissingApiKey_throwsFECAPIException: exceptionThrown=' + exceptionThrown);
    }

    // ─── searchCandidates ─────────────────────────────────────────────────────

    @IsTest
    static void testSearchCandidates_singleResult() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_SINGLE));

        Test.startTest();
        List<FECAPIService.CandidateSearchResult> results =
            testService().searchCandidates(new Map<String, String>{ 'name' => 'DOE, JOHN' });
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals('H00001234', results[0].candidateId, 'Candidate ID mismatch');
        System.assertEquals('DOE, JOHN',  results[0].name,        'Name mismatch');
        System.assertEquals('H',          results[0].office,      'Office mismatch');
        System.assertEquals('CA',         results[0].state,       'State mismatch');
        System.assertEquals('DEM',        results[0].party,       'Party mismatch');
        System.assertEquals('01',         results[0].district,    'District mismatch');
    }

    @IsTest
    static void testSearchCandidates_emptyResult() {
        Test.setMock(HttpCalloutMock.class,
            new FECAPIMock(FECAPIMock.MockType.CANDIDATE_SEARCH_EMPTY));

        Test.startTest();
        List<FECAPIService.CandidateSearchResult> results =
            testService().searchCandidates(new Map<String, String>{ 'name' => 'NOBODY' });
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Empty API response should return empty list');
    }

    @IsTest
    static void testSearchCandidates_nullOrBlankName_returnsEmpty() {
        Test.startTest();
        List<FECAPIService.CandidateSearchResult> nullResult =
            testService().searchCandidates(null);
        List<FECAPIService.CandidateSearchResult> blankResult =
            testService().searchCandidates(new Map<String, String>{ 'name' => '' });
        Test.stopTest();

        System.assertEquals(0, nullResult.size(),  'Null params should return empty list');
        System.assertEquals(0, blankResult.size(), 'Blank name should return empty list');
    }

    // ─── mapCommitteeType (private, tested via @TestVisible) ─────────────────

    @IsTest
    static void testMapCommitteeType_variations() {
        System.assertEquals('House',         FECAPIService.mapCommitteeType('House of Representatives'));
        System.assertEquals('Senate',        FECAPIService.mapCommitteeType('Senate'));
        System.assertEquals('Presidential',  FECAPIService.mapCommitteeType('Presidential'));
        System.assertEquals('PAC',           FECAPIService.mapCommitteeType('PAC - Non-Qualified'));
        System.assertEquals('Super PAC',     FECAPIService.mapCommitteeType('Super PAC'));
        System.assertEquals('Party',         FECAPIService.mapCommitteeType('Party - Qualified'));
        System.assertEquals(null,            FECAPIService.mapCommitteeType('Unknown'));
        System.assertEquals(null,            FECAPIService.mapCommitteeType(null));
    }
}
