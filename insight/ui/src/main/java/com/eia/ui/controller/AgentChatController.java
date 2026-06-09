package com.eia.ui.controller;

import com.eia.ui.model.AttachmentView;
import com.eia.ui.model.EmailDetailView;
import com.eia.ui.service.AgentChatService;
import com.eia.ui.service.AzureEmailStore;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.http.MediaType;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

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

    @PostMapping("/reset")
    public ResponseEntity<Map<String, Object>> reset(@RequestBody ResetRequest req) {
        if (!agentChatService.isAvailable()) {
            String reason = agentChatService.getUnavailableReason();
            String msg = reason != null ? reason : "AI agent is not configured on this server.";
            return ResponseEntity.status(503).body(Map.of("error", msg));
        }
        if (req.emailId() == null || req.emailId().isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "emailId is required."));
        }
        try {
            boolean cleared = agentChatService.clearConversation(req.emailId());
            String message = cleared
                    ? "Conversation history cleared for this email."
                    : "No prior conversation history was found for this email.";
            return ResponseEntity.ok(Map.of("cleared", cleared, "message", message));
        } catch (Throwable e) {
            LOG.error("Agent reset failed for emailId={}: {}", req.emailId(), e.getMessage(), e);
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
    record ResetRequest(String emailId) {}

    /**
     * Server-Sent Events endpoint. The browser receives:
     *   event: delta  — each text token from the model
     *   event: done   — end of stream
     *   event: error  — plain-text error message
     */
    @PostMapping(value = "/chat/stream", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    public SseEmitter chatStream(@RequestBody ChatRequest req) {
        if (!agentChatService.isAvailable()) {
            SseEmitter err = new SseEmitter(0L);
            try {
                String reason = agentChatService.getUnavailableReason();
                err.send(SseEmitter.event().name("error")
                        .data(reason != null ? reason : "AI agent is not configured."));
            } catch (Exception ignore) {}
            err.complete();
            return err;
        }
        if (req.emailId() == null || req.emailId().isBlank()
                || req.prompt() == null || req.prompt().isBlank()) {
            SseEmitter err = new SseEmitter(0L);
            try { err.send(SseEmitter.event().name("error").data("emailId and prompt are required.")); }
            catch (Exception ignore) {}
            err.complete();
            return err;
        }
        // 280 s — slightly under the 300 s server async timeout
        SseEmitter emitter = new SseEmitter(280_000L);
        ExecutorService executor = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "agent-stream");
            t.setDaemon(true);
            return t;
        });
        executor.submit(() -> {
            try {
                String fullPrompt = buildPrompt(req);
                agentChatService.streamChat(req.emailId(), fullPrompt, req.reasoningEffort(),
                        chunk -> {
                            try {
                                emitter.send(SseEmitter.event().name("delta").data(chunk));
                            } catch (Exception e) {
                                throw new RuntimeException(e);
                            }
                        });
                emitter.send(SseEmitter.event().name("done").data(""));
                emitter.complete();
            } catch (Throwable e) {
                LOG.error("Agent stream failed for emailId={}: {}", req.emailId(), e.getMessage(), e);
                try { emitter.send(SseEmitter.event().name("error").data(e.getMessage())); }
                catch (Exception ignore) {}
                emitter.completeWithError(e);
            } finally {
                executor.shutdown();
            }
        });
        return emitter;
    }
}