package com.eia.ui.controller;

import com.eia.ui.model.EmailDetailView;
import com.eia.ui.service.AzureEmailStore;
import org.springframework.security.core.Authentication;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.security.oauth2.core.user.OAuth2User;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.server.ResponseStatusException;

import java.security.Principal;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

@Controller
public class EmailController {

    private final AzureEmailStore azureEmailStore;

    public EmailController(AzureEmailStore azureEmailStore) {
        this.azureEmailStore = azureEmailStore;
    }

    @GetMapping({"/", "/emails"})
    public String emails(@RequestParam(value = "emailId", required = false) String emailId,
                         @RequestParam(value = "filterEmail", required = false, defaultValue = "") String filterEmail,
                         @RequestParam(value = "filterSubject", required = false, defaultValue = "") String filterSubject,
                         Authentication authentication,
                         Model model) {
        List<String> userIdentifiers = resolveUserIdentifiers(authentication);
        var allEmails = azureEmailStore.listEmails(userIdentifiers);
        
        // Use final local variables for lambda expressions
        final String email_filter = filterEmail;
        final String subject_filter = filterSubject;
        
        // Apply filters if provided
        var emails = allEmails;
        if (!email_filter.isBlank() || !subject_filter.isBlank()) {
            emails = allEmails.stream()
                    .filter(e -> email_filter.isBlank() || matchesWildcard(e.fromAddress(), email_filter))
                    .filter(e -> subject_filter.isBlank() || matchesWildcard(e.subject(), subject_filter))
                    .toList();
        }
        
        EmailDetailView selectedEmail = null;

        if (!emails.isEmpty()) {
            String selectedEmailId = (emailId != null && !emailId.isBlank()) ? emailId : emails.getFirst().id();
            selectedEmail = azureEmailStore.findEmail(selectedEmailId)
                    .orElseGet(() -> azureEmailStore.findEmail(allEmails.getFirst().id()).orElse(null));
        }

        model.addAttribute("emails", emails);
        model.addAttribute("selectedEmail", selectedEmail);
        model.addAttribute("filterEmail", filterEmail);
        model.addAttribute("filterSubject", filterSubject);
        model.addAttribute("isAuthenticated", isUserAuthenticated(authentication));
        model.addAttribute("oidcEnabled", isOidcConfigured());
        model.addAttribute("userDisplayName", resolveUserDisplayName(authentication));
        model.addAttribute("userLogin", resolveUserLogin(authentication));
        return "emails";
    }

    private boolean isUserAuthenticated(Authentication authentication) {
        return authentication != null
                && authentication.isAuthenticated()
                && !(authentication instanceof AnonymousAuthenticationToken);
    }

    private boolean isOidcConfigured() {
        return hasAnyNonBlankEnv("AZURE_CLIENT_ID", "WEBAPP_CLIENT_ID")
                && hasAnyNonBlankEnv("AZURE_TENANT_ID", "TENANT_ID");
    }

    private boolean hasAnyNonBlankEnv(String... envNames) {
        for (String envName : envNames) {
            String value = System.getenv(envName);
            if (value != null && !value.isBlank()) {
                return true;
            }
        }
        return false;
    }

    private String resolveUserDisplayName(Authentication authentication) {
        if (authentication instanceof OAuth2AuthenticationToken oauthToken
                && oauthToken.getPrincipal() instanceof OidcUser oidcUser) {
            String name = oidcUser.getFullName();
            if (name != null && !name.isBlank()) {
                return name;
            }
        }

        if (authentication instanceof OAuth2AuthenticationToken oauthToken
                && oauthToken.getPrincipal() instanceof OAuth2User oauth2User) {
            Object name = oauth2User.getAttributes().get("name");
            if (name instanceof String value && !value.isBlank()) {
                return value;
            }
        }

        if (authentication != null && authentication.getName() != null && !authentication.getName().isBlank()) {
            return authentication.getName();
        }

        return "Guest";
    }

    private String resolveUserLogin(Authentication authentication) {
        if (authentication instanceof OAuth2AuthenticationToken oauthToken
                && oauthToken.getPrincipal() instanceof OidcUser oidcUser) {
            String preferredUsername = oidcUser.getPreferredUsername();
            if (preferredUsername != null && !preferredUsername.isBlank()) {
                return preferredUsername;
            }
            String email = oidcUser.getEmail();
            if (email != null && !email.isBlank()) {
                return email;
            }
        }

        if (authentication instanceof OAuth2AuthenticationToken oauthToken
                && oauthToken.getPrincipal() instanceof OAuth2User oauth2User) {
            Object preferredUsername = oauth2User.getAttributes().get("preferred_username");
            if (preferredUsername instanceof String value && !value.isBlank()) {
                return value;
            }
            Object email = oauth2User.getAttributes().get("email");
            if (email instanceof String value && !value.isBlank()) {
                return value;
            }
        }

        if (authentication != null && authentication.getName() != null && !authentication.getName().isBlank()) {
            return authentication.getName();
        }

        return "Not signed in";
    }

    private List<String> resolveUserIdentifiers(Authentication authentication) {
        Set<String> identifiers = new LinkedHashSet<>();

        if (authentication instanceof OAuth2AuthenticationToken oauthToken
                && oauthToken.getPrincipal() instanceof OidcUser oidcUser) {
            addIfNonBlank(identifiers, oidcUser.getPreferredUsername());
            addIfNonBlank(identifiers, oidcUser.getEmail());
            Object upn = oidcUser.getClaims().get("upn");
            if (upn instanceof String value) {
                addIfNonBlank(identifiers, value);
            }
        }

        if (authentication instanceof OAuth2AuthenticationToken oauthToken
                && oauthToken.getPrincipal() instanceof OAuth2User oauth2User) {
            Object preferredUsername = oauth2User.getAttributes().get("preferred_username");
            if (preferredUsername instanceof String value) {
                addIfNonBlank(identifiers, value);
            }
            Object email = oauth2User.getAttributes().get("email");
            if (email instanceof String value) {
                addIfNonBlank(identifiers, value);
            }
            Object upn = oauth2User.getAttributes().get("upn");
            if (upn instanceof String value) {
                addIfNonBlank(identifiers, value);
            }
        }

        if (authentication != null) {
            addIfNonBlank(identifiers, authentication.getName());
        }

        return new ArrayList<>(identifiers);
    }

    private void addIfNonBlank(Set<String> target, String value) {
        if (value != null && !value.isBlank()) {
            target.add(value.trim());
        }
    }

    /**
     * Matches a string against a wildcard pattern.
     * Supports:
     * - * for any sequence of characters
     * - ? for any single character
     * - Case-insensitive matching
     * - If no wildcards are provided, treats input as a "contains" search
     */
    private boolean matchesWildcard(String text, String pattern) {
        if (text == null) text = "";
        if (pattern == null || pattern.isBlank()) return true;
        
        try {
            // If pattern contains no wildcards, treat it as a "contains" search
            if (!pattern.contains("*") && !pattern.contains("?")) {
                pattern = "*" + pattern + "*";
            }
            
            // Convert wildcard pattern to regex
            // Pattern.quote wraps in \Q...\E to escape all special characters
            String regex = java.util.regex.Pattern.quote(pattern)
                    .replace("*", "\\E.*\\Q")
                    .replace("?", "\\E.\\Q");
            
            // Remove adjacent \Q\E sequences from consecutive wildcards
            regex = regex.replace("\\Q\\E", "");
            
            // Add anchors
            regex = "^" + regex + "$";
            
            // Use CASE_INSENSITIVE flag instead of toLowerCase to preserve regex escape sequences
            return java.util.regex.Pattern.compile(regex, java.util.regex.Pattern.CASE_INSENSITIVE)
                    .matcher(text).matches();
        } catch (java.util.regex.PatternSyntaxException e) {
            // If regex is invalid, return false instead of throwing
            return false;
        }
    }

    @GetMapping("/email")
    public String emailDetail(@RequestParam("emailId") String emailId) {
        azureEmailStore.findEmail(emailId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Email not found"));
        return "redirect:/emails?emailId=" + emailId;
    }

    @GetMapping("/emails/{emailId}/attachments/{attachmentId}/download")
    public ResponseEntity<ByteArrayResource> downloadAttachment(
            @PathVariable("emailId") String emailId,
            @PathVariable("attachmentId") String attachmentId,
            Principal principal) {

        if (principal == null || principal.getName() == null || principal.getName().isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED, "Authentication required");
        }

        AzureEmailStore.AttachmentDownload attachment = azureEmailStore
                .downloadAttachment(emailId, attachmentId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Attachment not found"));

        MediaType mediaType = MediaType.APPLICATION_OCTET_STREAM;
        if (attachment.contentType() != null && !attachment.contentType().isBlank()) {
            try {
                mediaType = MediaType.parseMediaType(attachment.contentType());
            } catch (IllegalArgumentException ignored) {
            }
        }

        return ResponseEntity.ok()
                .contentType(mediaType)
                .header(HttpHeaders.CONTENT_DISPOSITION,
                        ContentDisposition.attachment().filename(attachment.fileName()).build().toString())
                .body(new ByteArrayResource(attachment.content()));
    }
}