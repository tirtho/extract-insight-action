package com.core.az;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.junit.jupiter.api.extension.TestWatcher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Integration tests for {@link AzStorageBlob} against a real Azure Storage account.
 *
 * <p><b>Prerequisites:</b></p>
 * <ul>
 *   <li>Set the environment variable {@code KEY_VAULT_URL} to your Key Vault URL
 *       (e.g. {@code https://my-vault.vault.azure.net}).</li>
 *   <li>Authenticate via {@code az login} or run on a host with Managed Identity.</li>
 *   <li>Ensure the Key Vault contains {@code StorageEndpoint} and {@code StorageContainerName}.</li>
 *   <li>The authenticated identity must have {@code Storage Blob Data Contributor}
 *       (or higher) on the target storage account.</li>
 * </ul>
 *
 * <p><b>Run with:</b></p>
 * <pre>
 *   mvn verify -Dgroups=integration
 * </pre>
 */
@Tag("integration")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class AzStorageBlobIT {

    private static final Logger LOG = LoggerFactory.getLogger(AzStorageBlobIT.class);

    /** Unique prefix so parallel test runs don't collide. */
    private static final String TEST_PREFIX = "it-test/" + UUID.randomUUID() + "/";

    private static AzConnection connection;
    private static AzStorageBlob storageBlob;

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
        storageBlob = new AzStorageBlob(connection);
    }

    @AfterAll
    static void cleanup() {
        // Clean up all test blobs
        if (storageBlob != null) {
            String[] testBlobs = {
                    TEST_PREFIX + "write-string.txt",
                    TEST_PREFIX + "write-bytes.bin",
                    TEST_PREFIX + "write-stream.txt",
                    TEST_PREFIX + "overwrite.txt",
                    TEST_PREFIX + "delete-me.txt"
            };
            for (String blob : testBlobs) {
                try {
                    storageBlob.delete(blob);
                } catch (Exception e) {
                    LOG.warn("Cleanup failed for blob '{}': {}", blob, e.getMessage());
                }
            }
            LOG.info("Test blob cleanup complete");
        }
        if (connection != null) {
            connection.close();
        }
    }

    // ---------------------------------------------------------------
    //  Write string and read back
    // ---------------------------------------------------------------

    @Test
    @Order(1)
    @DisplayName("writeString + readString – round-trip")
    void writeString_readString_roundTrip() {
        String blobName = TEST_PREFIX + "write-string.txt";
        String content = "Hello from AzStorageBlobIT – " + System.currentTimeMillis();

        storageBlob.writeString(blobName, content);
        LOG.info("  Written blob: {}", blobName);

        String readBack = storageBlob.readString(blobName);
        assertEquals(content, readBack, "Read-back content should match written content");
        LOG.info("  ✓ Round-trip string verified ({} chars)", content.length());
    }

    // ---------------------------------------------------------------
    //  Write bytes and read back
    // ---------------------------------------------------------------

    @Test
    @Order(2)
    @DisplayName("writeBytes + readBytes – binary round-trip")
    void writeBytes_readBytes_roundTrip() {
        String blobName = TEST_PREFIX + "write-bytes.bin";
        byte[] data = new byte[256];
        for (int i = 0; i < data.length; i++) {
            data[i] = (byte) i;
        }

        storageBlob.writeBytes(blobName, data);
        LOG.info("  Written blob: {} ({} bytes)", blobName, data.length);

        byte[] readBack = storageBlob.readBytes(blobName);
        assertArrayEquals(data, readBack, "Read-back bytes should match written bytes");
        LOG.info("  ✓ Round-trip bytes verified ({} bytes)", data.length);
    }

    // ---------------------------------------------------------------
    //  Write stream and read stream
    // ---------------------------------------------------------------

    @Test
    @Order(3)
    @DisplayName("writeStream + readStream – stream round-trip")
    void writeStream_readStream_roundTrip() throws Exception {
        String blobName = TEST_PREFIX + "write-stream.txt";
        String content = "Stream content – " + System.currentTimeMillis();
        byte[] contentBytes = content.getBytes(StandardCharsets.UTF_8);

        storageBlob.writeStream(blobName, new ByteArrayInputStream(contentBytes), contentBytes.length);
        LOG.info("  Written blob via stream: {}", blobName);

        try (InputStream is = storageBlob.readStream(blobName)) {
            byte[] readBack = is.readAllBytes();
            assertEquals(content, new String(readBack, StandardCharsets.UTF_8));
            LOG.info("  ✓ Round-trip stream verified ({} bytes)", readBack.length);
        }
    }

    // ---------------------------------------------------------------
    //  Overwrite existing blob
    // ---------------------------------------------------------------

    @Test
    @Order(4)
    @DisplayName("writeString overwrites existing blob")
    void writeString_overwritesExisting() {
        String blobName = TEST_PREFIX + "overwrite.txt";

        storageBlob.writeString(blobName, "original");
        storageBlob.writeString(blobName, "replaced");

        String readBack = storageBlob.readString(blobName);
        assertEquals("replaced", readBack, "Content should be the overwritten value");
        LOG.info("  ✓ Overwrite verified");
    }

    // ---------------------------------------------------------------
    //  exists
    // ---------------------------------------------------------------

    @Test
    @Order(5)
    @DisplayName("exists – returns true for written blob, false for missing blob")
    void exists_trueForWritten_falseForMissing() {
        String blobName = TEST_PREFIX + "write-string.txt"; // written in test #1
        assertTrue(storageBlob.exists(blobName), "Blob written in test #1 should exist");

        String missing = TEST_PREFIX + "does-not-exist-" + UUID.randomUUID() + ".txt";
        assertFalse(storageBlob.exists(missing), "Random blob name should not exist");
        LOG.info("  ✓ exists() verified");
    }

    // ---------------------------------------------------------------
    //  delete
    // ---------------------------------------------------------------

    @Test
    @Order(6)
    @DisplayName("delete – removes blob and returns correct boolean")
    void delete_removesBlobAndReturnsCorrectly() {
        String blobName = TEST_PREFIX + "delete-me.txt";
        storageBlob.writeString(blobName, "to be deleted");
        assertTrue(storageBlob.exists(blobName), "Blob should exist before delete");

        boolean deleted = storageBlob.delete(blobName);
        assertTrue(deleted, "delete() should return true for existing blob");
        assertFalse(storageBlob.exists(blobName), "Blob should not exist after delete");

        boolean deletedAgain = storageBlob.delete(blobName);
        assertFalse(deletedAgain, "delete() should return false for already-deleted blob");
        LOG.info("  ✓ delete() verified");
    }
}
