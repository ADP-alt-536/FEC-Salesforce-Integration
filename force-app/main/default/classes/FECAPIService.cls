/**
 * FECAPIService
 *
 * Core HTTP callout service for the Federal Election Commission (FEC) OpenFEC API.
 * Handles authentication via the FEC_API_Settings__mdt custom metadata type and
 * constructs/executes HTTP requests against the FEC REST endpoints.
 *
 * Usage:
 *   FECAPIService svc = new FECAPIService();
 *   FECAPIService.CommitteeFinancials fin = svc.getCommitteeFinancials('C00177436', 2024);
 *   List<FECAPIService.ScheduleAContribution> contribs =
 *       svc.getScheduleAContributions('C00177436', new Map<String,String>{'cycle'=>'2024'});
 */
public with sharing class FECAPIService {

    // ─── Inner Types ─────────────────────────────────────────────────────────

    /** Represents summarised financials for one FEC committee / filing cycle. */
    public class CommitteeFinancials {
        public String  committeeId;
        public String  committeeName;
        public String  committeeType;
        public String  designation;
        public Decimal cashOnHand;
        public Decimal totalReceipts;
        public Decimal totalDisbursements;
        public Integer cycle;
    }

    /** Represents a single Schedule A (receipts) contribution record. */
    public class ScheduleAContribution {
        public String  transactionId;
        public String  contributorCommitteeId;
        public String  contributorName;
        public String  recipientCommitteeId;
        public Decimal contributionAmount;
        public Date    contributionDate;
        public Date    filingDate;
        public Integer cycle;
        public String  entityType; // PAC, INDIVIDUAL, etc.
    }

    /** Paged window response for Schedule A sync in chained queueables. */
    public class ScheduleAWindowResult {
        public List<ScheduleAContribution> contributions;
        public Integer totalPages;
        public Integer startPage;
        public Integer endPage;
    }

    /** Lightweight wrapper used when a callout responds with a non-2xx status. */
    public class FECAPIException extends Exception {}

    // ─── Private members ─────────────────────────────────────────────────────

    private static final String NAMED_CREDENTIAL = 'callout:FEC_API';
    private static final String SETTINGS_KEY     = 'Default';
    private static final Integer SCHEDULE_A_SAMPLE_ROWS = 3;

    private String  apiKey;
    private String  baseUrl;
    private Integer timeoutMs;
    private Integer pageSize;

    // ─── Constructors ────────────────────────────────────────────────────────

    public FECAPIService() {
        loadSettings();
    }

    /**
     * Test-only constructor that injects settings directly, bypassing the
     * Custom Metadata query and API key validation.
     */
    @TestVisible
    private FECAPIService(String apiKey, String baseUrl, Integer timeoutMs, Integer pageSize) {
        this.apiKey    = apiKey;
        this.baseUrl   = baseUrl;
        this.timeoutMs = timeoutMs;
        this.pageSize  = pageSize;
    }

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Retrieves aggregated financial summary (cash on hand, receipts, disbursements)
     * for the specified FEC committee and election cycle.
     *
     * @param committeeId  FEC committee identifier, e.g. "C00177436"
     * @param cycle        Election cycle year, e.g. 2024
     * @return             Populated CommitteeFinancials or null if not found
     */
    public CommitteeFinancials getCommitteeFinancials(String committeeId, Integer cycle) {
        if (String.isBlank(committeeId)) {
            return null;
        }
        String path = '/v1/committee/' + EncodingUtil.urlEncode(committeeId, 'UTF-8')
                      + '/totals/?cycle=' + cycle
                      + '&api_key=' + EncodingUtil.urlEncode(apiKey, 'UTF-8');

        Map<String, Object> resp = makeGetRequest(path);
        if (resp == null) {
            return null;
        }

        List<Object> results = (List<Object>) resp.get('results');
        if (results == null || results.isEmpty()) {
            return null;
        }

        Map<String, Object> row = (Map<String, Object>) results[0];
        CommitteeFinancials fin = new CommitteeFinancials();
        fin.committeeId         = committeeId;
        fin.committeeName       = (String)  safeGet(row, 'committee_name');
        fin.committeeType       = mapCommitteeType((String) safeGet(row, 'committee_type_full'));
        fin.designation         = (String)  safeGet(row, 'designation_full');
        fin.cashOnHand          = firstDecimal(row, new List<String>{
            'ending_cash_on_hand',
            'cash_on_hand_end_period',
            'last_cash_on_hand_end_period',
            'cash_on_hand_close_ytd'
        });
        fin.totalReceipts       = toDecimal(safeGet(row, 'receipts'));
        fin.totalDisbursements  = toDecimal(safeGet(row, 'disbursements'));
        fin.cycle               = cycle;
        return fin;
    }

    /**
    * Retrieves Schedule A (receipts) contributions for the given committee.
    * Only records with a populated contributor_committee_id are returned,
    * which captures committee/PAC-origin contributions and excludes most
    * individual receipts.
     *
     * @param committeeId  FEC committee identifier of the RECIPIENT committee
     * @param params       Additional query-string filters (e.g. cycle, min_date)
     * @return             List of ScheduleAContribution records (may be empty)
     */
    public List<ScheduleAContribution> getScheduleAContributions(
            String committeeId,
            Map<String, String> params) {

        if (String.isBlank(committeeId)) {
            return new List<ScheduleAContribution>();
        }

        Map<String, String> requestParams = (params == null)
            ? new Map<String, String>()
            : new Map<String, String>(params);

        String queryString = buildQueryString(committeeId, requestParams);
        Map<String, Object> resp = makeGetRequest('/v1/schedules/schedule_a/' + queryString);
        if (resp == null) {
            return new List<ScheduleAContribution>();
        }

        Integer totalPages = getPaginationPages(resp);
        List<ScheduleAContribution> contributions = new List<ScheduleAContribution>();
        appendScheduleAResults(contributions, committeeId, resp, 1, totalPages);

        for (Integer pageNumber = 2; pageNumber <= totalPages; pageNumber++) {
            requestParams.put('page', String.valueOf(pageNumber));
            Map<String, Object> pageResp = makeGetRequest(
                '/v1/schedules/schedule_a/' + buildQueryString(committeeId, requestParams)
            );
            appendScheduleAResults(contributions, committeeId, pageResp, pageNumber, totalPages);
        }

        return contributions;
    }

    /**
     * Retrieves a bounded page window of Schedule A records.
     * Designed for chained async processing to avoid CPU and callout limits.
     */
    public ScheduleAWindowResult getScheduleAContributionsWindow(
            String committeeId,
            Map<String, String> params,
            Integer startPage,
            Integer maxPages) {

        ScheduleAWindowResult out = new ScheduleAWindowResult();
        out.contributions = new List<ScheduleAContribution>();
        out.totalPages = 1;
        out.startPage = (startPage == null || startPage < 1) ? 1 : startPage;
        out.endPage = out.startPage;

        if (String.isBlank(committeeId)) {
            return out;
        }

        Integer windowSize = (maxPages == null || maxPages < 1) ? 1 : maxPages;
        Map<String, String> requestParams = (params == null)
            ? new Map<String, String>()
            : new Map<String, String>(params);

        requestParams.put('page', String.valueOf(out.startPage));
        Map<String, Object> firstResp = makeGetRequest(
            '/v1/schedules/schedule_a/' + buildQueryString(committeeId, requestParams)
        );
        out.totalPages = getPaginationPages(firstResp);
        appendScheduleAResults(out.contributions, committeeId, firstResp, out.startPage, out.totalPages);

        Integer lastPageToFetch = Math.min(out.totalPages, out.startPage + windowSize - 1);
        for (Integer pageNumber = out.startPage + 1; pageNumber <= lastPageToFetch; pageNumber++) {
            requestParams.put('page', String.valueOf(pageNumber));
            Map<String, Object> pageResp = makeGetRequest(
                '/v1/schedules/schedule_a/' + buildQueryString(committeeId, requestParams)
            );
            appendScheduleAResults(out.contributions, committeeId, pageResp, pageNumber, out.totalPages);
        }

        out.endPage = lastPageToFetch;
        return out;
    }

    private void appendScheduleAResults(
            List<ScheduleAContribution> contributions,
            String committeeId,
            Map<String, Object> resp,
            Integer pageNumber,
            Integer totalPages) {

        List<Object> results = (List<Object>) resp.get('results');
        if (results == null) {
            System.debug(LoggingLevel.DEBUG,
                'FEC Schedule A diagnostics committee=' + committeeId
                + ' page=' + pageNumber + '/' + totalPages
                + ' results=0'
            );
            return;
        }

        Integer totalRows = 0;
        Integer withContributorCommitteeId = 0;
        Integer withContributorId = 0;
        Integer withCommitteeLikeContributorId = 0;
        Integer withFallbackCommitteeId = 0;
        Integer matchedRows = 0;
        List<String> samples = new List<String>();

        for (Object item : results) {
            Map<String, Object> row = (Map<String, Object>) item;
            totalRows++;

            // Filter: only committee-origin contributions.
            String contributorCommitteeId = (String) safeGet(row, 'contributor_committee_id');
            String contributorId = (String) safeGet(row, 'contributor_id');
            String entityType = (String) safeGet(row, 'entity_type');

            if (String.isNotBlank(contributorCommitteeId)) {
                withContributorCommitteeId++;
            }
            if (String.isNotBlank(contributorId)) {
                withContributorId++;
                if (contributorId.startsWith('C')) {
                    withCommitteeLikeContributorId++;
                }
            }

            // Some Schedule A rows omit contributor_committee_id but still
            // include a committee-like contributor_id (e.g., C########).
            if (String.isBlank(contributorCommitteeId)
                    && String.isNotBlank(contributorId)
                    && contributorId.startsWith('C')) {
                contributorCommitteeId = contributorId;
                withFallbackCommitteeId++;
            }

            if (samples.size() < SCHEDULE_A_SAMPLE_ROWS) {
                samples.add(
                    'sub_id=' + String.valueOf(safeGet(row, 'sub_id'))
                    + ', contributor_committee_id=' + contributorCommitteeId
                    + ', contributor_id=' + contributorId
                    + ', entity_type=' + entityType
                    + ', contributor_name=' + String.valueOf(safeGet(row, 'contributor_name'))
                );
            }

            if (String.isBlank(contributorCommitteeId)) {
                continue;
            }

            matchedRows++;

            ScheduleAContribution c = new ScheduleAContribution();
            c.transactionId           = (String)  safeGet(row, 'sub_id');
            c.contributorCommitteeId  = contributorCommitteeId;
            c.contributorName         = (String)  safeGet(row, 'contributor_name');
            c.recipientCommitteeId    = committeeId;
            c.contributionAmount      = toDecimal(safeGet(row, 'contribution_receipt_amount'));
            c.contributionDate        = toDate(safeGet(row, 'contribution_receipt_date'));
            c.filingDate              = toDate(safeGet(row, 'load_date'));
            c.cycle                   = toInteger(safeGet(row, 'cycle'));
            c.entityType              = entityType;
            contributions.add(c);
        }

        Boolean shouldLogDiagnostics =
            (pageNumber == 1)
            || (pageNumber == totalPages)
            || (Math.mod(pageNumber, 25) == 0);

        if (shouldLogDiagnostics) {
            System.debug(LoggingLevel.DEBUG,
                'FEC Schedule A diagnostics committee=' + committeeId
                + ' page=' + pageNumber + '/' + totalPages
                + ' totalRows=' + totalRows
                + ' withContributorCommitteeId=' + withContributorCommitteeId
                + ' withContributorId=' + withContributorId
                + ' withCommitteeLikeContributorId=' + withCommitteeLikeContributorId
                + ' withFallbackCommitteeId=' + withFallbackCommitteeId
                + ' matchedRows=' + matchedRows
            );
            if (!samples.isEmpty()) {
                System.debug(LoggingLevel.DEBUG,
                    'FEC Schedule A sample rows committee=' + committeeId
                    + ' page=' + pageNumber + '/' + totalPages
                    + ' samples=' + String.join(samples, ' || ')
                );
            }
        }
    }

    private Integer getPaginationPages(Map<String, Object> resp) {
        Map<String, Object> pagination = (Map<String, Object>) resp.get('pagination');
        Integer totalPages = toInteger(safeGet(pagination, 'pages'));
        return (totalPages == null || totalPages < 1) ? 1 : totalPages;
    }

    /**
     * Retrieves basic committee details (name, type, designation) from the FEC API.
     *
     * @param committeeId  FEC committee identifier
     * @return             Map of raw FEC fields, or null if not found
     */
    public Map<String, Object> getCommitteeDetails(String committeeId) {
        if (String.isBlank(committeeId)) {
            return null;
        }
        String path = '/v1/committee/' + EncodingUtil.urlEncode(committeeId, 'UTF-8')
                      + '/?api_key=' + EncodingUtil.urlEncode(apiKey, 'UTF-8');
        Map<String, Object> resp = makeGetRequest(path);
        if (resp == null) {
            return null;
        }
        List<Object> results = (List<Object>) resp.get('results');
        if (results == null || results.isEmpty()) {
            return null;
        }
        return (Map<String, Object>) results[0];
    }

    /**
     * Looks up the principal campaign committee for an FEC candidate.
     *
     * @param candidateId  FEC candidate identifier (e.g. H00001234)
     * @param cycle        Election cycle year
     * @return             FEC committee ID string, or null if not found
     */
    public String getPrincipalCommitteeId(String candidateId, Integer cycle) {
        if (String.isBlank(candidateId)) {
            return null;
        }
        String path = '/v1/candidate/' + EncodingUtil.urlEncode(candidateId, 'UTF-8')
                      + '/committees/?designation=P&cycle=' + cycle
                      + '&api_key=' + EncodingUtil.urlEncode(apiKey, 'UTF-8');
        Map<String, Object> resp = makeGetRequest(path);
        if (resp == null) {
            return null;
        }
        List<Object> results = (List<Object>) resp.get('results');
        if (results == null || results.isEmpty()) {
            return null;
        }
        Map<String, Object> row = (Map<String, Object>) results[0];
        return (String) safeGet(row, 'committee_id');
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────

    private void loadSettings() {
        FEC_API_Settings__mdt settings;
        List<FEC_API_Settings__mdt> settingsList = [
            SELECT API_Key__c, Base_URL__c, Request_Timeout__c, Batch_Size__c
            FROM FEC_API_Settings__mdt
            WHERE DeveloperName = :SETTINGS_KEY
            LIMIT 1
        ];
        if (!settingsList.isEmpty()) {
            settings = settingsList[0];
        }

        if (settings != null && String.isNotBlank(settings.API_Key__c)
                && settings.API_Key__c != 'REPLACE_WITH_YOUR_FEC_API_KEY') {
            apiKey    = settings.API_Key__c;
            baseUrl   = String.isNotBlank(settings.Base_URL__c)
                            ? settings.Base_URL__c
                            : 'https://api.open.fec.gov/v1';
            timeoutMs = settings.Request_Timeout__c != null
                            ? (Integer) settings.Request_Timeout__c
                            : 120000;
            pageSize  = settings.Batch_Size__c != null
                            ? (Integer) settings.Batch_Size__c
                            : 100;
        } else {
            // Throw a descriptive error when the API key has not been configured.
            // Replace the placeholder in FEC_API_Settings__mdt (Default record)
            // with a valid key obtained from https://api.data.gov/signup/
            throw new FECAPIException(
                'FEC API key is not configured. '
                + 'Please update FEC_API_Settings__mdt (Default record) '
                + 'with a valid API key from https://api.data.gov/signup/'
            );
        }
    }

    /** Executes an HTTP GET against the FEC API and returns the parsed JSON body. */
    @TestVisible
    private Map<String, Object> makeGetRequest(String relativePath) {
        Http http = new Http();
        HttpResponse res;

        // Prefer the non-duplicated path first (strip leading /v1) because many
        // orgs set the Named Credential endpoint to .../v1. If that fails with
        // 404, retry once with the original path for orgs that do not include
        // /v1 in Named Credential configuration.
        if (relativePath != null && relativePath.startsWith('/v1/')) {
            res = sendGet(http, relativePath, true);
            if (res != null && res.getStatusCode() == 404) {
                res = sendGet(http, relativePath, false);
            }
        } else {
            res = sendGet(http, relativePath, false);
        }

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new FECAPIException(
                'FEC API returned HTTP ' + res.getStatusCode()
                + ' for path: ' + relativePath
                + ' – ' + res.getBody()
            );
        }

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    private HttpResponse sendGet(Http http, String relativePath, Boolean stripV1Prefix) {
        HttpRequest req = new HttpRequest();
        req.setMethod('GET');
        req.setTimeout(timeoutMs);

        String path = relativePath;
        if (Boolean.valueOf(stripV1Prefix)
                && path != null
                && path.startsWith('/v1/')) {
            path = path.substring(3); // '/v1/foo' -> '/foo'
        }

        String endpoint;
        if (path != null && path.startsWith('callout:')) {
            endpoint = path;
        } else {
            endpoint = NAMED_CREDENTIAL + path;
        }
        req.setEndpoint(endpoint);
        req.setHeader('Accept', 'application/json');

        return http.send(req);
    }

    private String buildQueryString(String committeeId, Map<String, String> params) {
        String qs = '?committee_id=' + EncodingUtil.urlEncode(committeeId, 'UTF-8')
                  + '&per_page=' + pageSize
                  + '&api_key=' + EncodingUtil.urlEncode(apiKey, 'UTF-8');
        if (params != null) {
            for (String key : params.keySet()) {
                String val = params.get(key);
                if (String.isNotBlank(val)) {
                    qs += '&' + EncodingUtil.urlEncode(key, 'UTF-8')
                        + '=' + EncodingUtil.urlEncode(val, 'UTF-8');
                }
            }
        }
        return qs;
    }

    // ─── Type Conversion Utilities ────────────────────────────────────────────

    private static Object safeGet(Map<String, Object> m, String key) {
        return (m != null && m.containsKey(key)) ? m.get(key) : null;
    }

    private static Decimal toDecimal(Object val) {
        if (val == null) { return null; }
        if (val instanceof Decimal) { return (Decimal) val; }
        if (val instanceof Double)  { return Decimal.valueOf((Double) val); }
        if (val instanceof Long)    { return Decimal.valueOf((Long) val); }
        if (val instanceof Integer) { return Decimal.valueOf((Integer) val); }
        try { return Decimal.valueOf(String.valueOf(val)); }
        catch (Exception e) { return null; }
    }

    private static Date toDate(Object val) {
        if (val == null) { return null; }
        String s = String.valueOf(val);
        if (s.length() < 10) { return null; }
        s = s.substring(0, 10); // yyyy-MM-dd (handles both date and datetime strings)
        try { return Date.valueOf(s); }
        catch (Exception e) { return null; }
    }

    private static Integer toInteger(Object val) {
        if (val == null) { return null; }
        if (val instanceof Integer) { return (Integer) val; }
        if (val instanceof Decimal) { return ((Decimal) val).intValue(); }
        if (val instanceof Double)  { return ((Double)  val).intValue(); }
        if (val instanceof Long)    { return ((Long)    val).intValue(); }
        try { return Integer.valueOf(String.valueOf(val)); }
        catch (Exception e) { return null; }
    }

    /** Returns the first non-null decimal found among the given JSON keys. */
    private static Decimal firstDecimal(Map<String, Object> row, List<String> keys) {
        if (row == null || keys == null) {
            return null;
        }
        for (String key : keys) {
            Decimal parsed = toDecimal(safeGet(row, key));
            if (parsed != null) {
                return parsed;
            }
        }
        return null;
    }

    /**
     * Maps the FEC committee_type_full string to the picklist values on
     * FEC_Committee__c.Committee_Type__c.
     */
    @TestVisible
    private static String mapCommitteeType(String fecType) {
        if (fecType == null) { return null; }
        String t = fecType.toLowerCase();
        if (t.contains('house'))         { return 'House'; }
        if (t.contains('senate'))        { return 'Senate'; }
        if (t.contains('presidential')) { return 'Presidential'; }
        if (t.contains('super pac'))    { return 'Super PAC'; }
        if (t.contains('pac'))          { return 'PAC'; }
        if (t.contains('party'))        { return 'Party'; }
        return null;
    }
}
