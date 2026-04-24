java-core - Build Options
=========================

Prerequisites
-------------
- Java 21+
- Maven 3.9+
- For integration tests: az login (or Managed Identity) + KEY_VAULT_URL env var


1. Compile only (no tests)
--------------------------
  mvn clean compile

2. Run unit tests
-----------------
  mvn clean test

  Unit tests are run by the Surefire plugin.
  Integration tests (tagged @Tag("integration")) are automatically excluded.

3. Run a specific unit test class
---------------------------------
  mvn test -Dtest=AzConnectionTest

4. Run integration tests
------------------------
  Option A: Pass Key Vault URL as a Maven argument (recommended)
  mvn clean verify -Dgroups=integration -Dkey.vault.url=https://your-vault.vault.azure.net

  Option B: Set the Key Vault URL as an environment variable
  set KEY_VAULT_URL=https://your-vault.vault.azure.net
  mvn clean verify -Dgroups=integration

  Option C: Run ..\deployment\1.config.ps1 (or .cmd or .sh) first,
  which sets KEY_VAULT_URL from env.config, then run:
  mvn clean verify -Dgroups=integration

  Integration tests are run by the Failsafe plugin and require:
    - KEY_VAULT_URL environment variable pointing to your Key Vault
    - Active Azure credentials (az login or Managed Identity)
    - All secrets referenced in AzEnvNames present in Key Vault

5. Run a specific integration test class
-----------------------------------------
  mvn clean verify -Dgroups=integration -Dkey.vault.url=https://your-vault.vault.azure.net -Dit.test=AzContentUnderstandingIT

6. Package the JAR (skip tests)
-------------------------------
  mvn clean package -DskipTests

7. Install JAR to local Maven repo and copy to project-lib\java
---------------------------------------------------------------
  mvn clean install -Dlibrary

  This installs the JAR into ~/.m2/repository (so downstream projects
  like mailbox-to-queue and queue-to-db pick up the latest version)
  and copies it to project-lib\java.

  Activates the "copy-to-project-lib" profile which copies the built JAR
  to ../project-lib/java/ after packaging.

8. Package and copy JAR to project-lib (skip tests)
----------------------------------------------------
  mvn clean package -Dlibrary -DskipTests

9. Full build (unit tests + integration tests)
-----------------------------------------------
  mvn clean verify -Dgroups=integration -Dkey.vault.url=https://your-vault.vault.azure.net

10. Debug integration tests (attach VS Code debugger)
------------------------------------------------------
  - make sure you have .vscode\launch.json file as follows:
        {
        "version": "0.2.0",
        "configurations": [
            {
            "type": "java",
            "name": "Attach to Maven",
            "request": "attach",
            "hostName": "localhost",
            "port": 5005
            }
        ]
        }
  - mvn verify -Dgroups=integration -Dkey.vault.url=https://your-vault.vault.azure.net "-Dmaven.failsafe.debug=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"

  Then attach VS Code with a "Java Attach" launch config on port 5005.

11. Clean build artifacts
-------------------------
  mvn clean
