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
  mvn test -Dtest=AzGetConnectionTest

4. Run integration tests
------------------------
  Either set the Key Vault URL as below, or run the 
  ..\deployment\config.cmd (or .ps1 or .sh)
  set KEY_VAULT_URL=https://your-vault.vault.azure.net
  mvn clean verify -Dgroups=integration

  Integration tests are run by the Failsafe plugin and require:
    - KEY_VAULT_URL environment variable pointing to your Key Vault
    - Active Azure credentials (az login or Managed Identity)
    - All secrets referenced in AzEnvNames present in Key Vault

5. Package the JAR (skip tests)
-------------------------------
  mvn clean package -DskipTests

6. Package and copy JAR to project-lib\java
--------------------------------------
  mvn clean package -Dlibrary

  Activates the "copy-to-project-lib" profile which copies the built JAR
  to ../project-lib/java/ after packaging.

7. Package and copy JAR to project-lib (skip tests)
----------------------------------------------------
  mvn clean package -Dlibrary -DskipTests

8. Full build (unit tests + integration tests)
-----------------------------------------------
  set KEY_VAULT_URL=https://your-vault.vault.azure.net
  mvn clean verify -Dgroups=integration

9. Debug integration tests (attach VS Code debugger)
-----------------------------------------------------
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
  - set KEY_VAULT_URL=https://your-vault.vault.azure.net
  - mvn verify -Dgroups=integration "-Dmaven.failsafe.debug=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"

  Then attach VS Code with a "Java Attach" launch config on port 5005.

10. Clean build artifacts
-------------------------
  mvn clean
