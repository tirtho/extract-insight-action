package com.eia.ui.config;

import java.util.HashMap;
import java.util.Map;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.registration.InMemoryClientRegistrationRepository;
import org.springframework.security.oauth2.core.endpoint.OAuth2AuthorizationRequest;
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
                .scope("openid", "profile", "email")
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
                            .requestMatchers("/error", "/logout-success", "/favicon.ico", "/*.css", "/*.js", "/webjars/**").permitAll()
                            .anyRequest().authenticated())
                .oauth2Login(oauth2 -> oauth2
                    .authorizationEndpoint(authorization -> authorization
                        .authorizationRequestResolver(forcePromptLoginResolver(clientRegistrationRepository))))
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

    private OAuth2AuthorizationRequestResolver forcePromptLoginResolver(
            ClientRegistrationRepository clientRegistrationRepository) {
        DefaultOAuth2AuthorizationRequestResolver defaultResolver =
                new DefaultOAuth2AuthorizationRequestResolver(
                        clientRegistrationRepository,
                        "/oauth2/authorization");

        // OAuth2AuthorizationRequestResolver has two resolve() overloads so it
        // is NOT a functional interface — use an anonymous class, not a lambda.
        return new OAuth2AuthorizationRequestResolver() {
            @Override
            public OAuth2AuthorizationRequest resolve(jakarta.servlet.http.HttpServletRequest request) {
                return addPromptLogin(defaultResolver.resolve(request));
            }

            @Override
            public OAuth2AuthorizationRequest resolve(
                    jakarta.servlet.http.HttpServletRequest request, String clientRegistrationId) {
                return addPromptLogin(defaultResolver.resolve(request, clientRegistrationId));
            }

            private OAuth2AuthorizationRequest addPromptLogin(OAuth2AuthorizationRequest original) {
                if (original == null) {
                    return null;
                }
                Map<String, Object> extraParams = new HashMap<>(original.getAdditionalParameters());
                extraParams.put("prompt", "login");
                extraParams.put("max_age", "0");
                return OAuth2AuthorizationRequest.from(original)
                        .additionalParameters(extraParams)
                        .build();
            }
        };
    }

    private static String resolveEnv(String... names) {
        for (String name : names) {
            String val = System.getenv(name);
            if (val != null && !val.isBlank()) {
                return val;
            }
        }
        return null;
    }
}
