package com.core.az;

/**
 * Sanitizes values read from environment variables / App Service settings.
 * Azure Linux App Service's "@Microsoft.KeyVault(...)" reference resolution can
 * inject a UTF-8 BOM ahead of the resolved secret value; depending on which
 * charset decodes it, that shows up either as a single U+FEFF character or as
 * three mis-decoded Latin-1 characters ("ï»¿"). Either way it breaks anything
 * that parses the value as a URI, tenant id, or client id (e.g. AADSTS900023,
 * "Illegal character in scheme name"). Direct Key Vault SDK reads (see
 * {@link AzConnection#getSecret}) are unaffected — only values obtained via
 * {@code System.getenv(...)} need this.
 */
public final class EnvSanitizer {

    private EnvSanitizer() {}

    /**
     * Strips BOM/zero-width characters, surrounding whitespace, and any other
     * leading non-alphanumeric garbage. Every value this project reads this way
     * (tenant id, client id, endpoint URL, ...) starts with an ASCII letter or
     * digit, so trimming leading non-alphanumeric characters is a charset-agnostic
     * way to remove such prefixes without enumerating every possible mis-encoding.
     */
    public static String sanitize(String value) {
        if (value == null) return null;
        return value.replace("\uFEFF", "").replace("\u200B", "")
                .replaceFirst("^[^A-Za-z0-9]+", "")
                .trim();
    }
}
