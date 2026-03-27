package com.core.az;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.junit.jupiter.api.extension.TestWatcher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * End-to-end integration tests for {@link AzContentUnderstanding}.
 *
 * <p>These tests exercise the full Content Understanding lifecycle against the
 * live Azure service:</p>
 * <ol>
 *   <li>List existing analyzers</li>
 *   <li>Create a test analyzer (prebuilt-document, document scenario)</li>
 *   <li>Poll until the analyzer creation succeeds</li>
 *   <li>Submit a text document for analysis</li>
 *   <li>Poll until analysis completes</li>
 *   <li>Retrieve analysis results</li>
 *   <li>Delete the test analyzer</li>
 *   <li>Verify the analyzer is no longer listed</li>
 * </ol>
 *
 * <p><b>Prerequisites:</b></p>
 * <ul>
 *   <li>Set the environment variable {@code KEY_VAULT_URL} to your Key Vault URL
 *       (e.g. {@code https://my-vault.vault.azure.net}).</li>
 *   <li>Authenticate via {@code az login} or run on a host with Managed Identity.</li>
 *   <li>The Key Vault must contain the secret
 *       {@code ContentUnderstandingEndpoint}.</li>
 * </ul>
 *
 * <p><b>Run with:</b></p>
 * <pre>
 *   mvn verify -Dgroups=integration
 * </pre>
 *
 * <p>Test resource files loaded from {@code src/test/resources/}:</p>
 * <ul>
 *   <li>{@code analyzer-schema.json} – simple prebuilt-document document analyzer</li>
 *   <li>{@code sample-document.txt} – plain-text document submitted for analysis</li>
 * </ul>
 */
@Tag("integration")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AzContentUnderstandingIT {

    private static final Logger LOG = LoggerFactory.getLogger(AzContentUnderstandingIT.class);

    /** Unique analyzer ID for this test run – timestamped to avoid collisions.
     *  Note: Content Understanding analyzer IDs must not contain hyphens. */
    private static final String TEST_ANALYZER_ID =
            "itTestAnalyzer" + System.currentTimeMillis();

    /** Maximum number of poll attempts before giving up. */
    private static final int MAX_POLL_ATTEMPTS = 30;

    /** Delay between poll attempts in milliseconds. */
    private static final long POLL_INTERVAL_MS = 2_000;

    private static AzConnection connection;
    private static AzContentUnderstanding cu;

    /** Operation ID from the createContentAnalyzer call – shared across tests. */
    private static String createOperationId;

    /** Operation ID from the analyze call – shared across tests. */
    private static String analyzeOperationId;

    // ---------------------------------------------------------------
    //  Test lifecycle
    // ---------------------------------------------------------------

    @RegisterExtension
    TestWatcher testResultLogger = new TestWatcher() {
        private int getOrder(ExtensionContext ctx) {
            return ctx.getTestMethod()
                    .map(m -> m.getAnnotation(Order.class))
                    .map(Order::value)
                    .orElse(-1);
        }

        @Override
        public void testSuccessful(ExtensionContext ctx) {
            LOG.info("<<< END  : Test #{} - {} - PASSED", getOrder(ctx), ctx.getDisplayName());
        }

        @Override
        public void testFailed(ExtensionContext ctx, Throwable cause) {
            LOG.error("<<< END  : Test #{} - {} - FAILED", getOrder(ctx), ctx.getDisplayName(), cause);
        }

        @Override
        public void testAborted(ExtensionContext ctx, Throwable cause) {
            LOG.warn("<<< END  : Test #{} - {} - ABORTED", getOrder(ctx), ctx.getDisplayName());
        }
    };

    @BeforeEach
    void logTestStart(TestInfo testInfo) {
        int order = testInfo.getTestMethod()
                .map(m -> m.getAnnotation(Order.class))
                .map(Order::value)
                .orElse(-1);
        LOG.info(">>> START: Test #{} - {}", order, testInfo.getDisplayName());
    }

    @BeforeAll
    static void initConnection() {
        String kvUrl = System.getenv("KEY_VAULT_URL");
        assumeTrue(kvUrl != null && !kvUrl.isBlank(),
                "Skipping integration tests: KEY_VAULT_URL environment variable is not set");

        connection = new AzConnection(kvUrl);
        cu = new AzContentUnderstanding(connection);
        LOG.info("Test analyzer ID for this run: {}", TEST_ANALYZER_ID);
    }

    @AfterAll
    static void cleanupAnalyzer() {
        // Best-effort cleanup – delete the test analyzer if it still exists
        if (cu != null) {
            try {
                cu.deleteContentAnalyzer(TEST_ANALYZER_ID);
                LOG.info("AfterAll cleanup: deleted test analyzer '{}'", TEST_ANALYZER_ID);
            } catch (Exception e) {
                LOG.warn("AfterAll cleanup: could not delete analyzer '{}' (may already be deleted): {}",
                        TEST_ANALYZER_ID, e.getMessage());
            }
            cu.close();
        }
        if (connection != null) {
            connection.close();
        }
    }

    // ---------------------------------------------------------------
    //  Helpers
    // ---------------------------------------------------------------

    /**
     * Loads a classpath resource as a UTF-8 string.
     */
    private static String loadResource(String name) throws IOException {
        try (InputStream is = AzContentUnderstandingIT.class
                .getClassLoader().getResourceAsStream(name)) {
            assertNotNull(is, "Resource not found: " + name);
            return new String(is.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    /**
     * Polls an operation until its status is {@code "succeeded"} or
     * {@code "failed"}, or the maximum number of attempts is exceeded.
     *
     * @return the final status string
     */
    private String pollUntilTerminal(String analyzerId, String operationId)
            throws InterruptedException {
        String status = "notStarted";
        for (int i = 1; i <= MAX_POLL_ATTEMPTS; i++) {
            String json = cu.getOperationStatus(analyzerId, operationId);
            status = AzContentUnderstanding.getContentAnalyzerStatusFromJson(json);
            LOG.info("  Poll {}/{} – status: {}", i, MAX_POLL_ATTEMPTS, status);
            if ("succeeded".equalsIgnoreCase(status)
                    || "failed".equalsIgnoreCase(status)) {
                return status;
            }
            Thread.sleep(POLL_INTERVAL_MS);
        }
        return status;
    }

    // ---------------------------------------------------------------
    //  Tests
    // ---------------------------------------------------------------

    @Test
    @Order(1)
    @DisplayName("List analyzers – baseline count before test")
    void listAnalyzers_baseline() {
        String body = cu.listContentAnalyzers();
        assertNotNull(body);
        assertTrue(body.contains("\"value\""),
                "Response should contain a 'value' array");

        LOG.info("  Baseline list response length: {} chars", body.length());
    }

    @Test
    @Order(2)
    @DisplayName("Create test analyzer from analyzer-schema.json")
    void createAnalyzer() throws IOException {
        String schema = loadResource("analyzer-schema.json");
        assertNotNull(schema);
        assertFalse(schema.isBlank(), "Analyzer schema should not be blank");
        LOG.info("  Analyzer schema loaded ({} chars)", schema.length());

        String response = cu.createContentAnalyzer(TEST_ANALYZER_ID, schema);
        assertNotNull(response);
        LOG.info("  Create response: {}", response);

        createOperationId = AzContentUnderstanding.getOperationIdFromJson(response);
        assertNotNull(createOperationId, "operationId should be present in the response");
        assertFalse(createOperationId.isBlank());
        LOG.info("  Create operation ID: {}", createOperationId);
    }

    @Test
    @Order(3)
    @DisplayName("Poll until analyzer creation succeeds")
    void pollAnalyzerCreation() throws InterruptedException {
        assertNotNull(createOperationId,
                "createOperationId must be set by test #2");

        String status = pollUntilTerminal(TEST_ANALYZER_ID, createOperationId);
        assertEquals("succeeded", status.toLowerCase(),
                "Analyzer creation should succeed within the polling window");
        LOG.info("  Analyzer '{}' creation completed with status: {}", TEST_ANALYZER_ID, status);
    }

    @Test
    @Order(4)
    @DisplayName("List analyzers – test analyzer should appear")
    void listAnalyzers_afterCreate() {
        String body = cu.listContentAnalyzers();
        assertNotNull(body);
        assertTrue(body.contains(TEST_ANALYZER_ID),
                "Analyzer list should contain the test analyzer '"
                        + TEST_ANALYZER_ID + "'");
        LOG.info("  Test analyzer '{}' found in list", TEST_ANALYZER_ID);
    }

    @Test
    @Order(5)
    @DisplayName("Submit a public document URL for analysis")
    void analyzeDocument() {
        // The Content Understanding analyze API requires a "url" property
        // pointing to a publicly accessible document.
        String publicDocUrl =
                "https://raw.githubusercontent.com/Azure-Samples/cognitive-services-REST-api-samples/master/curl/form-recognizer/rest-api/read.png";

        String analyzePayload = String.format("{\"inputs\":[{\"url\":\"%s\"}]}", publicDocUrl);

        LOG.info("  Submitting URL for analysis: {}", publicDocUrl);

        String response = cu.analyze(TEST_ANALYZER_ID, analyzePayload);
        assertNotNull(response);
        LOG.info("  Analyze response: {}", response);

        analyzeOperationId = AzContentUnderstanding.getOperationIdFromJson(response);
        assertNotNull(analyzeOperationId, "operationId should be present in the analyze response");
        assertFalse(analyzeOperationId.isBlank());
        LOG.info("  Analyze operation ID: {}", analyzeOperationId);
    }

    @Test
    @Order(6)
    @DisplayName("Poll until analysis completes")
    void pollAnalysis() throws InterruptedException {
        assertNotNull(analyzeOperationId,
                "analyzeOperationId must be set by test #5");

        // The GA API uses /analyzerResults/{id} for both polling and results
        String status = "notStarted";
        for (int i = 1; i <= MAX_POLL_ATTEMPTS; i++) {
            String json = cu.getAnalyzeResultsByOperationId(
                    TEST_ANALYZER_ID, analyzeOperationId);
            status = AzContentUnderstanding.getContentAnalyzerStatusFromJson(json);
            LOG.info("  Poll {}/{} – status: {}", i, MAX_POLL_ATTEMPTS, status);
            if ("succeeded".equalsIgnoreCase(status)
                    || "failed".equalsIgnoreCase(status)) {
                break;
            }
            Thread.sleep(POLL_INTERVAL_MS);
        }
        assertEquals("succeeded", status.toLowerCase(),
                "Analysis should succeed within the polling window");
        LOG.info("  Analysis completed with status: {}", status);
    }

    @Test
    @Order(7)
    @DisplayName("Retrieve analysis results")
    void getAnalyzeResults() {
        assertNotNull(analyzeOperationId,
                "analyzeOperationId must be set by test #5");

        String results = cu.getAnalyzeResultsByOperationId(
                TEST_ANALYZER_ID, analyzeOperationId);
        assertNotNull(results);
        assertFalse(results.isBlank(), "Results body should not be blank");

        // The prebuilt-document analyzer should return content with a "status" field
        assertTrue(results.contains("\"status\""),
                "Results should contain a 'status' field");
        LOG.info("  Results length: {} chars", results.length());
        LOG.info("  Results (truncated): {}",
                results.substring(0, Math.min(results.length(), 500)));
    }

    @Test
    @Order(8)
    @DisplayName("Delete the test analyzer")
    void deleteAnalyzer() {
        String response = cu.deleteContentAnalyzer(TEST_ANALYZER_ID);
        assertNotNull(response);
        LOG.info("  Delete response: {}", response);
    }

    @Test
    @Order(9)
    @DisplayName("List analyzers – test analyzer should be gone")
    void listAnalyzers_afterDelete() {
        String body = cu.listContentAnalyzers();
        assertNotNull(body);
        assertFalse(body.contains("\"" + TEST_ANALYZER_ID + "\""),
                "Analyzer list should no longer contain the test analyzer '"
                        + TEST_ANALYZER_ID + "'");
        LOG.info("  Test analyzer '{}' is no longer in the list", TEST_ANALYZER_ID);
    }

    // ---------------------------------------------------------------
    //  Static JSON parser smoke tests (run against real API responses)
    // ---------------------------------------------------------------

    @Test
    @Order(10)
    @DisplayName("getContentAnalyzerIdsFromJson – parses live list response")
    void parseAnalyzerIds_fromLiveResponse() {
        String body = cu.listContentAnalyzers();
        assertNotNull(body);

        Map<String, String> ids =
                AzContentUnderstanding.getContentAnalyzerIdsFromJson(body);
        // After deletion there may be zero analyzers, so just verify parsing works
        assertNotNull(ids, "Parsed map should not be null");
        LOG.info("  Parsed analyzer IDs: {}", ids);
    }
}
