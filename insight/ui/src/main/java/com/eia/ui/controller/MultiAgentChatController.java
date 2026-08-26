package com.eia.ui.controller;

import com.eia.ui.service.MultiAgentChatService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/multiagent")
public class MultiAgentChatController {

    private static final Logger LOG = LoggerFactory.getLogger(MultiAgentChatController.class);
    private final MultiAgentChatService chatService;

    public MultiAgentChatController(MultiAgentChatService chatService) {
        this.chatService = chatService;
    }

    @PostMapping("/chat")
    public ResponseEntity<Map<String, String>> chat(@RequestBody ChatRequest request) {
        if (request.prompt() == null || request.prompt().isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "prompt is required."));
        }
        try {
            return ResponseEntity.ok(Map.of("content",
                    chatService.chat(request.prompt(), request.domainKey())));
        } catch (Exception e) {
            LOG.error("Multi-agent chat failed: {}", e.getMessage(), e);
            return ResponseEntity.status(502).body(Map.of("error", e.getMessage()));
        }
    }

    record ChatRequest(String prompt, String domainKey) {}
}