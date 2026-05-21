package com.eia.ui.controller;

import com.eia.ui.model.AttachmentView;
import com.eia.ui.model.EmailDetailView;
import com.eia.ui.service.AgentChatService;
import com.eia.ui.service.AzureEmailStore;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Map;

@RestController
@RequestMapping("/api/agent")
public class AgentChatController {

    private static final Logger LOG = LoggerFactory.getLogger(AgentChatController.class);

    @Autowired
    private AgentChatService agentChatService;

    @Autowired
    private AzureEmailStore emailStore;

    @PostMapping("/chat")
    public ResponseEntity<Map<String, String>> chat(@RequestBody ChatRequest req) {
        if (!agentChatService.isAvailable()) {
            String reason = agentChatService.getUnavailableReason();
            String msg = reason != null ? reason : "AI agent is not configured on this server.";
            return ResponseEntity.status(503).body(Map.of("error", msg));
        }
        if (req.emailId() == null || req.emailId().isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "emailId is required."));
        }
        if (req.prompt() == null || req.prompt().isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "prompt is required."));
        }
        try {
            String fullPrompt = buildPrompt(req);
            String reply = agentChatService.chat(req.emailId(), fullPrompt, req.reasoningEffort());
            return ResponseEntity.ok(Map.of("content", reply));
        } catch (Throwable e) {
            LOG.error("Agent chat failed for emailId={}: {}", req.emailId(), e.getMessage(), e);
            return ResponseEntity.status(500)
                    .body(Map.of("error", "Agent error: " + e.getMessage()));
        }
    }

    private String buildPrompt(ChatRequest req) {
        if (!req.isFirstMessage()) {
            return req.prompt();
        }
        // First message: prepend email body + attachment analysis as context
        EmailDetailView email = emailStore.findEmail(req.emailId()).orElse(null);
        if (email == null) {
            return req.prompt();
        }
        var sb = new StringBuilder();
        sb.append("=== EMAIL CONTEXT ===\n");
        sb.append("Subject : ").append(email.subject()).append("\n");
        sb.append("From    : ").append(email.fromName())
          .append(" <").append(email.fromAddress()).append(">\n");
        sb.append("Received: ").append(email.receivedDateTime()).append("\n");
        sb.append("\nBody:\n");
        sb.append(email.bodyContent() != null && !email.bodyContent().isBlank()
                  ? email.bodyContent() : email.bodyPreview());
        if (email.attachments() != null && !email.attachments().isEmpty()) {
            sb.append("\n\n=== ATTACHMENTS ===\n");
            for (AttachmentView att : email.attachments()) {
                sb.append("\nAttachment: ").append(att.attachmentName()).append("\n");
                if (att.analyzeResult() != null && !att.analyzeResult().isBlank()) {
                    sb.append("Analysis result:\n").append(att.analyzeResult()).append("\n");
                }
            }
        }
        sb.append("\n\n=== USER QUESTION ===\n").append(req.prompt());
        return sb.toString();
    }

    record ChatRequest(String emailId, String prompt, boolean isFirstMessage, String reasoningEffort) {}
}
