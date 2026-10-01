package com.eia.ui.config;

import com.core.az.EnvSanitizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.registration.InMemoryClientRegistrationRepository;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.oidc.IdTokenClaimNames;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
public class SecurityConfig {

    /**
     * Builds the OIDC client registration from environment variables at startup,
     * bypassing Spring Boot's OAuth2ClientProperties validation entirely.
     * When the required vars are absent the returned repository is empty and
     * the security chain falls back to no-auth mode (local dev).
     */
    @Bean
    ClientRegistrationRepository clientRegistrationRepository() {
        String clientId = resolveEnv("AZURE_CLIENT_ID", "WEBAPP_CLIENT_ID");
        String clientSecret = resolveEnv("AZURE_CLIENT_SECRET", "WEBAPP_CLIENT_SECRET");
        String tenantId = resolveEnv("AZURE_TENANT_ID", "TENANT_ID");
        if (tenantId == null || tenantId.isBlank()) {
            tenantId = "common";
        }

        if (clientId == null || clientId.isBlank()) {
            // Return an empty repository — oauth2Login will not be activated below.
            return registrationId -> null;
        }

        ClientRegistration registration = ClientRegistration.withRegistrationId("azure")
                .clientId(clientId)
                .clientSecret(clientSecret)
                .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                .redirectUri("{baseUrl}/login/oauth2/code/{registrationId}")
            .scope("openid", "profile", "email", "User.Read", "User.ReadWrite")
                .authorizationUri("https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/authorize")
                .tokenUri("https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/token")
                .jwkSetUri("https://login.microsoftonline.com/" + tenantId + "/discovery/v2.0/keys")
                .userInfoUri("https://graph.microsoft.com/oidc/userinfo")
                .userNameAttributeName(IdTokenClaimNames.SUB)
                .clientName("Azure")
                .build();

        return new InMemoryClientRegistrationRepository(registration);
    }

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http,
            ClientRegistrationRepository clientRegistrationRepository) throws Exception {

        boolean oidcConfigured = clientRegistrationRepository.findByRegistrationId("azure") != null;

        if (oidcConfigured) {
            http
                    .authorizeHttpRequests(auth -> auth
                            .requestMatchers("/error", "/logout-success", "/favicon.ico", "/*.css", "/*.js",
                                    "/webjars/**", "/actuator/health", "/actuator/health/**").permitAll()
                            .anyRequest().authenticated())
                            .oauth2Login(oauth2 -> {})
                    .logout(logout -> logout
                            .invalidateHttpSession(true)
                            .clearAuthentication(true)
                            .deleteCookies("JSESSIONID")
                            .logoutSuccessUrl("/logout-success")
                            .permitAll());
        } else {
            // No OIDC credentials configured — allow all traffic (local / offline dev).
            http
                    .authorizeHttpRequests(auth -> auth.anyRequest().permitAll())
                    .csrf(csrf -> csrf.disable());
        }

        return http.build();
    }

    private static String resolveEnv(String... names) {
        for (String name : names) {
            String val = EnvSanitizer.sanitize(System.getenv(name));
            if (val != null && !val.isBlank()) {
                return val;
            }
        }
        return null;
    }
}
