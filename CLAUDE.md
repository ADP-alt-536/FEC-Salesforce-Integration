# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FEC-Salesforce-Integration** is a Salesforce DX project that syncs Federal Election Commission (FEC) campaign finance data into Salesforce. It pulls committee financial data and PAC contributions from the OpenFEC API and stores them in custom Salesforce objects (`FEC_Committee__c` and `PAC_Contribution__c`).

### Key Business Objects

- **Legislator__c**: Representatives/senators; linked to their primary campaign committees
- **FEC_Committee__c**: FEC committees (campaigns, PACs, parties) with financials (cash on hand, receipts, disbursements)
- **PAC_Contribution__c**: Individual Schedule A contributions from one PAC/committee to a recipient committee
- **Account**: Can be linked to contributing PACs via `FEC_ID__c` custom field

## Architecture

### Sync Patterns

The integration uses three complementary sync patterns:

1. **Batch Sync (FECDataSyncBatch + FECDataSyncScheduler)**
   - Iterates all `Legislator__c` records with `FEC_Candidate_ID__c` populated
   - Syncs their principal campaign committee and all PAC contributions in one pass
   - Small batch size (5 records) due to API callout limits
   - Scheduled nightly via `FECDataSyncScheduler` (Schedulable)

2. **Manual Async Sync (FECManualPACSyncQueueable)**
   - On-demand queueable for full PAC contribution syncs with pagination support
   - Processes large result sets (100+ pages) across chained queueables
   - Implements distributed locking (`PAC_Sync_Chain_Token__c`) to prevent parallel chains for the same committee/cycle
   - Handles rate limiting and callout timeouts with exponential backoff
   - Uses `FEC_Committee__c` fields to track chain state (`In_Progress` flag, `Lock_Expires` timestamp)

3. **Direct Service Layer (FECAPIService, FECCommitteeSync, FECPACContributionSync)**
   - Low-level classes for reuse in tests and one-off operations
   - Can be instantiated directly without batch/scheduler context

### HTTP Callout & Configuration

- **Named Credential**: `callout:FEC_API` (https://api.open.fec.gov/v1)
- **Remote Site**: `FEC_API` configured for API access
- **Custom Metadata**: `FEC_API_Settings__mdt` (Default record) stores API key, base URL, timeout (120s), page size (100)
- API key stored as encrypted field in metadata; obtain from https://api.data.gov/signup/

### Data Filter Logic

`FECAPIService.getScheduleAContributions()` filters Schedule A contributions:
- Returns only committee-origin contributions (not individual donors)
- Prefers `contributor_committee_id` field; falls back to `contributor_id` if it starts with `'C'`
- Handles FEC API field variations (`ending_cash_on_hand` vs `cash_on_hand_end_period`, etc.)

`FECPACContributionSync` then applies secondary filtering:
- Only creates `PAC_Contribution__c` when contributor maps to an Account via `Account.FEC_ID__c`
- Skips duplicate transaction IDs within a sync window
- Normalizes FEC IDs (trim, uppercase)
- Detects and skips ambiguous FEC IDs (multiple Accounts with same `FEC_ID__c`)

### External ID Pattern

Uses external ID upserts to avoid duplicates:
- **FEC_Committee__c**: Upsert on `FEC_Committee_ID__c` (FEC identifier like `"C00177436"`)
- **PAC_Contribution__c**: Upsert on `Transaction_ID__c` (FEC Schedule A `sub_id`)

## Development Workflow

### Deployment & Testing

**Deploy to Salesforce:**
```bash
# Authenticate to the staging org (configured in sfdx-project.json)
sf org login web --set-default

# Deploy all metadata
sf project deploy start

# Deploy specific components
sf project deploy start --source-dir force-app/main/default/classes
```

**Run Tests:**
```bash
# Run all Apex tests
sf apex run test --wait 60 --test-level RunAllTestsInOrg

# Run a specific test class
sf apex run test --tests FECAPIServiceTest --wait 60

# Run with code coverage summary
sf apex run test --code-coverage --wait 60
```

**Execute Code in Dev Org:**
```bash
# Run a script file
sf apex run --file MANUAL_TEST_SCRIPT.apex

# Interactive REPL
sf apex run
```

### Test Architecture

- **FECAPIMock** and **FECMultiMock**: Mock HTTP responses for `FECAPIService`
- **`@TestVisible` constructors** on `FECAPIService` and service classes allow tests to inject pre-configured instances without hitting the FEC API or querying Custom Metadata
- Pattern in tests: `new FECAPIService('TEST_API_KEY', 'https://api.open.fec.gov/v1', 120000, 100)`

### Key Classes & Responsibilities

| Class | Purpose |
|-------|---------|
| **FECAPIService** | Core FEC API HTTP client; parses JSON responses into typed DTOs (`CommitteeFinancials`, `ScheduleAContribution`, etc.) |
| **FECCommitteeSync** | Upserts `FEC_Committee__c` records; links to `Legislator__c.Primary_Committee__c` |
| **FECPACContributionSync** | Filters, enriches, and upserts `PAC_Contribution__c`; maps contributors to Accounts |
| **FECDataSyncBatch** | Batchable for scheduled nightly syncs; calls `FECCommitteeSync` then `FECPACContributionSync` per legislator |
| **FECDataSyncScheduler** | Schedulable to kick off `FECDataSyncBatch` on cron schedule |
| **FECManualPACSyncQueueable** | Queueable for large async jobs; chains continuations; implements distributed locking and retry logic |

## Common Tasks

### Trigger a Full Sync for a Legislator

Execute **MANUAL_TEST_SCRIPT.apex** in the Developer Console:
- Finds the most recently modified `Legislator__c` with `FEC_Candidate_ID__c`
- Syncs their principal committee
- Enqueues `FECManualPACSyncQueueable` to fetch all PAC contributions
- Displays recent `PAC_Contribution__c` records for inspection

### Schedule Nightly Sync

Execute in Developer Console:
```apex
System.schedule(
    'FEC Data Sync - Nightly',
    '0 0 2 * * ?',  // 2 AM daily
    new FECDataSyncScheduler(2026)  // or omit cycle for auto-detection
);
```

### Debug & Inspect API Calls

Set debug log level to DEBUG and check logs for:
- `FEC Schedule A diagnostics`: Row counts and field presence per page
- `FEC Schedule A sample rows`: First 3 rows per page with field values
- Exception logs when API returns non-2xx or callout fails

## Important Patterns & Conventions

### Cycle Year Handling

- FEC cycles are even-numbered (2024, 2026, etc.)
- `FECDataSyncBatch.currentCycle()` auto-detects: if current year is odd, returns next even year
- Always pass cycle explicitly when testing specific election cycles

### Null Safety in Type Conversions

`FECAPIService` includes robust converters (`toDecimal`, `toDate`, `toInteger`) that return null rather than throw:
- Handles FEC API JSON variations (fields named differently across endpoints)
- `firstDecimal()` helper tries multiple field names in priority order
- Callers must check for null when financial fields are missing

### Callout Resilience

`FECManualPACSyncQueueable` detects and handles:
- **Rate limits (HTTP 429)**: Reduces page size, waits 65 minutes, retries
- **Callout timeouts**: Reduces page size, retries immediately (up to 2 retries)
- Rate limiting detected by: `'HTTP 429'`, `'over_rate_limit'`, or `'rate limit'` in exception message
- Timeout detected by: `'maximum time allotted for callout'` or `'read timed out'`

## Configuration & Environment

**sfdx-project.json** settings:
- `sourceApiVersion`: 59.0 (Salesforce API version)
- `sfdcLoginUrl`: Points to staging sandbox (`califesciences--staging.sandbox.my.salesforce.com`)
- `namespace`: Empty (no managed package)

**FEC_API_Settings__mdt** (Custom Metadata):
- Centralized configuration for API key, base URL, timeout, batch size
- If `API_Key__c` is not set or equals placeholder, `FECAPIService` throws `FECAPIException` during construction

## Governance & Limits

- **Batch size**: Keep at 5–10 to stay within 100 callouts per transaction limit
- **Page size**: Default 100 records per FEC API page; adjustable in `FEC_API_Settings__mdt`
- **Request timeout**: 120 seconds (configurable)
- **Distributed locking**: Chain lock valid for 60 minutes by default (`LOCK_MINUTES` constant in `FECManualPACSyncQueueable`)
- **Rate limit backoff**: 65 minutes before retry (`RATE_LIMIT_BACKOFF_MINUTES` constant)
