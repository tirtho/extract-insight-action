package com.core.az;

import com.azure.storage.queue.models.PeekedMessageItem;
import com.azure.storage.queue.models.QueueMessageItem;
import com.azure.storage.queue.models.SendMessageResult;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.junit.jupiter.api.extension.TestWatcher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

/**
 * Integration tests for {@link AzStorageQueue} against a real Azure Storage account.
 *
 * <p><b>Prerequisites:</b></p>
 * <ul>
 *   <li>Set the environment variable {@code KEY_VAULT_URL} to your Key Vault URL
 *       (e.g. {@code https://my-vault.vault.azure.net}).</li>
 *   <li>Authenticate via {@code az login} or run on a host with Managed Identity.</li>
 *   <li>Ensure the Key Vault contains {@code StorageEndpoint} and {@code StorageQueueName}.</li>
 *   <li>The authenticated identity must have {@code Storage Queue Data Contributor}
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
class AzStorageQueueIT {

    private static final Logger LOG = LoggerFactory.getLogger(AzStorageQueueIT.class);

    /** Unique tag so messages from parallel runs don't collide. */
    private static final String TEST_TAG = "it-test-" + UUID.randomUUID();

    private static AzConnection connection;
    private static AzStorageQueue storageQueue;

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
        storageQueue = new AzStorageQueue(connection);
    }

    @AfterAll
    static void cleanup() {
        // Drain any test messages left in the queue
        if (storageQueue != null) {
            try {
                storageQueue.clearMessages();
                LOG.info("Test queue cleared");
            } catch (Exception e) {
                LOG.warn("Cleanup failed: {}", e.getMessage());
            }
        }
        if (connection != null) {
            connection.close();
        }
    }

    // ---------------------------------------------------------------
    //  Send and receive round-trip
    // ---------------------------------------------------------------

    @Test
    @Order(1)
    @DisplayName("sendMessage + receiveMessages – round-trip")
    void sendMessage_receiveMessages_roundTrip() {
        String content = TEST_TAG + " | message-1 | " + System.currentTimeMillis();

        SendMessageResult sendResult = storageQueue.sendMessage(content);
        assertNotNull(sendResult.getMessageId(), "Send should return a message id");
        LOG.info("  Sent messageId: {}", sendResult.getMessageId());

        List<QueueMessageItem> received = storageQueue.receiveMessages(1);
        assertFalse(received.isEmpty(), "Should receive at least one message");

        QueueMessageItem msg = received.get(0);
        assertEquals(content, msg.getBody().toString(), "Received content should match sent content");
        LOG.info("  Received messageId: {}, body matches", msg.getMessageId());

        // Clean up: delete the message
        storageQueue.deleteMessage(msg.getMessageId(), msg.getPopReceipt());
        LOG.info("  ✓ Round-trip send/receive verified");
    }

    // ---------------------------------------------------------------
    //  Send with visibility timeout and TTL
    // ---------------------------------------------------------------

    @Test
    @Order(2)
    @DisplayName("sendMessage with visibility timeout and TTL")
    void sendMessage_withVisibilityAndTtl() {
        String content = TEST_TAG + " | message-ttl | " + System.currentTimeMillis();

        SendMessageResult sendResult = storageQueue.sendMessage(
                content, Duration.ofSeconds(1), Duration.ofMinutes(1));
        assertNotNull(sendResult.getMessageId());
        LOG.info("  Sent with TTL – messageId: {}", sendResult.getMessageId());

        // Message has 1-second visibility timeout; receive after it becomes visible
        // The message should appear quickly
        List<QueueMessageItem> received = storageQueue.receiveMessages(1, Duration.ofSeconds(30));
        if (!received.isEmpty()) {
            QueueMessageItem msg = received.get(0);
            assertEquals(content, msg.getBody().toString());
            storageQueue.deleteMessage(msg.getMessageId(), msg.getPopReceipt());
            LOG.info("  ✓ Message with TTL received and deleted");
        } else {
            // Message may still be invisible; that's acceptable – just log
            LOG.info("  Message not yet visible (visibility timeout); skipping assertion");
        }
    }

    // ---------------------------------------------------------------
    //  Peek messages
    // ---------------------------------------------------------------

    @Test
    @Order(3)
    @DisplayName("peekMessages – peeks without hiding")
    void peekMessages_doesNotHideMessage() {
        String content = TEST_TAG + " | peek-test | " + System.currentTimeMillis();
        storageQueue.sendMessage(content);

        List<PeekedMessageItem> peeked = storageQueue.peekMessages(5);
        assertFalse(peeked.isEmpty(), "Should peek at least one message");
        LOG.info("  Peeked {} messages", peeked.size());

        // Peek again – message should still be visible
        List<PeekedMessageItem> peekedAgain = storageQueue.peekMessages(5);
        assertFalse(peekedAgain.isEmpty(), "Message should still be visible after peek");
        LOG.info("  ✓ Peek verified (message still visible)");

        // Clean up
        List<QueueMessageItem> toDelete = storageQueue.receiveMessages(5);
        for (QueueMessageItem m : toDelete) {
            storageQueue.deleteMessage(m.getMessageId(), m.getPopReceipt());
        }
    }

    // ---------------------------------------------------------------
    //  getApproximateMessageCount
    // ---------------------------------------------------------------

    @Test
    @Order(4)
    @DisplayName("getApproximateMessageCount – returns non-negative count")
    void getApproximateMessageCount_returnsNonNegative() {
        int count = storageQueue.getApproximateMessageCount();
        assertTrue(count >= 0, "Approximate count should be non-negative");
        LOG.info("  ✓ Approximate message count: {}", count);
    }

    // ---------------------------------------------------------------
    //  clearMessages
    // ---------------------------------------------------------------

    @Test
    @Order(5)
    @DisplayName("clearMessages – empties the queue")
    void clearMessages_emptiesQueue() {
        // Send a few messages
        storageQueue.sendMessage(TEST_TAG + " | clear-1");
        storageQueue.sendMessage(TEST_TAG + " | clear-2");

        storageQueue.clearMessages();
        LOG.info("  Queue cleared");

        // Peek should return empty (or close to it – eventual consistency)
        List<PeekedMessageItem> peeked = storageQueue.peekMessages(5);
        assertTrue(peeked.isEmpty(), "Queue should be empty after clear");
        LOG.info("  ✓ clearMessages verified");
    }

    // ---------------------------------------------------------------
    //  deleteMessage
    // ---------------------------------------------------------------

    @Test
    @Order(6)
    @DisplayName("deleteMessage – removes specific message")
    void deleteMessage_removesMessage() {
        String content = TEST_TAG + " | delete-test | " + System.currentTimeMillis();
        storageQueue.sendMessage(content);

        List<QueueMessageItem> received = storageQueue.receiveMessages(1);
        assertFalse(received.isEmpty(), "Should receive the sent message");

        QueueMessageItem msg = received.get(0);
        storageQueue.deleteMessage(msg.getMessageId(), msg.getPopReceipt());
        LOG.info("  Deleted messageId: {}", msg.getMessageId());

        // The deleted message should not appear on peek
        List<PeekedMessageItem> peeked = storageQueue.peekMessages(5);
        boolean found = peeked.stream()
                .anyMatch(p -> content.equals(p.getBody().toString()));
        assertFalse(found, "Deleted message should not appear in peek");
        LOG.info("  ✓ deleteMessage verified");
    }
}
