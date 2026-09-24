package com.eia.ui.controller;

import com.eia.ui.service.MultiAgentChatService;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

@RestController
@RequestMapping("/api/multiagent/admin")
public class MultiAgentAdminController {

    private final MultiAgentChatService service;

    public MultiAgentAdminController(MultiAgentChatService service) {
        this.service = service;
    }

    @GetMapping(value = "/agents", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> agents() {
        return proxy("agents");
    }

    @GetMapping(value = "/calls", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> calls(@RequestParam(defaultValue = "30") int sinceDays) {
        return proxy("calls?sinceDays=" + Math.max(1, sinceDays));
    }

    @GetMapping(value = "/performance", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> performance(@RequestParam(defaultValue = "30") int sinceDays) {
        return proxy("performance?sinceDays=" + Math.max(1, sinceDays));
    }

    @GetMapping(value = "/calls/{requestId}/graph", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> graph(@PathVariable String requestId) {
        return proxy("calls/" + requestId + "/graph");
    }

    @GetMapping(value = "/mailboxes", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> mailboxes() {
        return proxy("mailboxes");
    }

    @PostMapping(value = "/mailboxes", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> addMailbox(@RequestBody(required = false) String body) {
        try {
            return ResponseEntity.ok(service.postAdmin("mailboxes", body));
        } catch (Exception e) {
            return ResponseEntity.internalServerError()
                    .contentType(MediaType.APPLICATION_JSON)
                    .body("{\"error\":\"" + escape(e.getMessage()) + "\"}");
        }
    }

    @DeleteMapping(value = "/mailboxes/{emailAddress}", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<String> deleteMailbox(@PathVariable String emailAddress) {
        try {
            String encoded = URLEncoder.encode(emailAddress, StandardCharsets.UTF_8);
            return ResponseEntity.ok(service.deleteAdmin("mailboxes/" + encoded));
        } catch (Exception e) {
            return ResponseEntity.internalServerError()
                    .contentType(MediaType.APPLICATION_JSON)
                    .body("{\"error\":\"" + escape(e.getMessage()) + "\"}");
        }
    }

    private ResponseEntity<String> proxy(String path) {
        try {
            return ResponseEntity.ok(service.getAdmin(path));
        } catch (Exception e) {
            String message = e.getMessage();
            return ResponseEntity.internalServerError()
                    .contentType(MediaType.APPLICATION_JSON)
                    .body("{\"error\":\"" + escape(message) + "\"}");
        }
    }

    private static String escape(String value) {
        return value == null ? "Unknown admin service error." : value.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}