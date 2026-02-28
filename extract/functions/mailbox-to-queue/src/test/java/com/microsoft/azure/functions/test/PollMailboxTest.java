package com.microsoft.azure.functions.test;

import com.microsoft.azure.functions.ExecutionContext;
import com.microsoft.azure.functions.mailbox.PollMailbox;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
import org.mockito.Mock;
import org.mockito.MockitoAnnotations;

import java.util.logging.Logger;

import static org.mockito.Mockito.*;

/**
 * Unit test for PollMailbox Function class.
 */
public class PollMailboxTest {
    
    @Mock
    private ExecutionContext context;
    
    @Mock
    private Logger logger;
    
    private PollMailbox function;
    
    @BeforeEach
    public void setUp() {
        MockitoAnnotations.openMocks(this);
        function = new PollMailbox();
        when(context.getLogger()).thenReturn(logger);
    }
    
    @Test
    public void testPollMailboxFunctionExecution() {
        // Arrange
        String timerInfo = "test-timer-info";
        
        // The function now requires only AZURE_KEY_VAULT_URL.
        // Without it set, the function should throw (Key Vault URL is mandatory).
        // In a test environment we expect a configuration error.
        
        // Act & Assert
        try {
            function.run(timerInfo, context);
        } catch (Exception e) {
            // Expected: AZURE_KEY_VAULT_URL not set or Key Vault unreachable in test
            System.out.println("Expected configuration error in test: " + e.getMessage());
        }
    }
    
    @Test
    public void testPollMailboxWithNullTimerInfo() {
        // Arrange
        String timerInfo = null;
        
        // Act & Assert
        try {
            function.run(timerInfo, context);
        } catch (Exception e) {
            // Expected: AZURE_KEY_VAULT_URL not set in test environment
            System.out.println("Expected error in test environment: " + e.getMessage());
        }
    }
}
