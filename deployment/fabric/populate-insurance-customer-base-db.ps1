#Requires -Version 7.0
<#
.SYNOPSIS
Adds ten fictional insurance customers and their addresses and policies to InsuranceCustomerBase.
.DESCRIPTION
Requires the existing InsuranceCustomerBaseDB.sql schema, SQL network access, Azure CLI
sign-in, and SqlServer module 22+. Stable demo IDs make reruns insert-only.
.EXAMPLE
.\populate-insurance-customer-base-db.ps1 -Environment dev -Suffix 1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z][a-z0-9-]{0,19}$')]
    [string]$Environment = 'dev',
    [ValidatePattern('^[0-9]{1,10}$')]
    [string]$Suffix = '1',
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$')]
    [string]$SqlServerName
)

$ErrorActionPreference = 'Stop'
if (-not $SqlServerName) { $SqlServerName = "sql-eia-$Environment-$Suffix" }
$databaseName = 'InsuranceCustomerBase'
if (-not $PSCmdlet.ShouldProcess("$SqlServerName.database.windows.net/$databaseName", 'Insert 10 fictional customers, addresses, address links, and insurance policies (skip existing demo IDs)')) { return }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in with az login first.' }
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) { throw 'Install the current SqlServer PowerShell module first.' }
if (-not (Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('Encrypt')) { throw 'Update the SqlServer module to version 22 or later.' }

$tokenJson = & az account get-access-token --resource https://database.windows.net/ --only-show-errors --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to acquire a SQL access token. Sign in with az login and select the intended subscription.' }
$token = ($tokenJson -join "`n") | ConvertFrom-Json
if (-not $token.accessToken) { throw 'Azure CLI did not return a SQL access token.' }

$customers = @(
    @{ FirstName = 'Avery'; LastName = 'Morgan'; Street = '101 Example Lane'; City = 'Seattle'; State = 'Washington'; PostalCode = '98101'; PolicyType = 'Auto'; BusinessLine = 'Personal'; Product = 'Comprehensive Auto'; Premium = 125.00; Coverage = 100000; Deductible = 500; Company = $null }
    @{ FirstName = 'Jordan'; LastName = 'Patel'; Street = '202 Sample Avenue'; City = 'Portland'; State = 'Oregon'; PostalCode = '97201'; PolicyType = 'Home'; BusinessLine = 'Personal'; Product = 'Homeowners Plus'; Premium = 185.00; Coverage = 450000; Deductible = 1500; Company = $null }
    @{ FirstName = 'Taylor'; LastName = 'Brooks'; Street = '303 Fictional Drive'; City = 'Austin'; State = 'Texas'; PostalCode = '78701'; PolicyType = 'Business'; BusinessLine = 'Commercial'; Product = 'Business Owners Package'; Premium = 310.00; Coverage = 1000000; Deductible = 2500; Company = 'Example Meadow Consulting' }
    @{ FirstName = 'Casey'; LastName = 'Nguyen'; Street = '404 Demo Court'; City = 'Denver'; State = 'Colorado'; PostalCode = '80202'; PolicyType = 'Auto'; BusinessLine = 'Personal'; Product = 'Comprehensive Auto'; Premium = 110.00; Coverage = 100000; Deductible = 750; Company = $null }
    @{ FirstName = 'Riley'; LastName = 'Thompson'; Street = '505 Example Way'; City = 'Boston'; State = 'Massachusetts'; PostalCode = '02108'; PolicyType = 'Home'; BusinessLine = 'Personal'; Product = 'Homeowners Plus'; Premium = 210.00; Coverage = 600000; Deductible = 2000; Company = $null }
    @{ FirstName = 'Morgan'; LastName = 'Rivera'; Street = '606 Sample Street'; City = 'Chicago'; State = 'Illinois'; PostalCode = '60601'; PolicyType = 'Business'; BusinessLine = 'Commercial'; Product = 'Commercial General Liability'; Premium = 275.00; Coverage = 2000000; Deductible = 1000; Company = 'Example Harbor Design' }
    @{ FirstName = 'Cameron'; LastName = 'Shah'; Street = '707 Fictional Place'; City = 'Phoenix'; State = 'Arizona'; PostalCode = '85004'; PolicyType = 'Auto'; BusinessLine = 'Personal'; Product = 'Comprehensive Auto'; Premium = 135.00; Coverage = 150000; Deductible = 500; Company = $null }
    @{ FirstName = 'Quinn'; LastName = 'Ellis'; Street = '808 Demo Boulevard'; City = 'Raleigh'; State = 'North Carolina'; PostalCode = '27601'; PolicyType = 'Home'; BusinessLine = 'Personal'; Product = 'Homeowners Plus'; Premium = 160.00; Coverage = 350000; Deductible = 1000; Company = $null }
    @{ FirstName = 'Reese'; LastName = 'Chen'; Street = '909 Example Road'; City = 'San Diego'; State = 'California'; PostalCode = '92101'; PolicyType = 'Business'; BusinessLine = 'Commercial'; Product = 'Professional Liability'; Premium = 340.00; Coverage = 1000000; Deductible = 5000; Company = 'Example Summit Analytics' }
    @{ FirstName = 'Skyler'; LastName = "O'Brien"; Street = '1010 Sample Terrace'; City = 'Atlanta'; State = 'Georgia'; PostalCode = '30303'; PolicyType = 'Auto'; BusinessLine = 'Personal'; Product = 'Comprehensive Auto'; Premium = 145.00; Coverage = 150000; Deductible = 750; Company = $null }
)

$effectiveDate = [datetime]::UtcNow.Date
$demoRows = for ($index = 0; $index -lt $customers.Count; $index++) {
    $customer = $customers[$index]
    $number = $index + 1
    [ordered]@{
        CustomerId = 'c0570000-0001-4000-8000-{0:D12}' -f $number
        AddressId = 'c0570000-0002-4000-8000-{0:D12}' -f $number
        PolicyId = 'c0570000-0003-4000-8000-{0:D12}' -f $number
        FirstName = $customer.FirstName
        LastName = $customer.LastName
        CompanyName = $customer.Company
        EmailAddress = 'customer{0:D2}@example.com' -f $number
        Phone = '+1-202-555-{0:D4}' -f (100 + $number)
        AddressLine1 = $customer.Street
        City = $customer.City
        StateProvince = $customer.State
        PostalCode = $customer.PostalCode
        PolicyNumber = 'DEMO-CB-{0:D3}' -f $number
        PolicyType = $customer.PolicyType
        BusinessLine = $customer.BusinessLine
        ProductName = $customer.Product
        PremiumAmount = $customer.Premium
        CoverageLimitAmount = $customer.Coverage
        DeductibleAmount = $customer.Deductible
        EffectiveDate = $effectiveDate.ToString('yyyy-MM-dd')
        ExpirationDate = $effectiveDate.AddYears(1).ToString('yyyy-MM-dd')
        PolicyDocumentUrl = 'https://example.com/policies/DEMO-CB-{0:D3}.pdf' -f $number
    }
}
$demoJson = (ConvertTo-Json -InputObject @($demoRows) -Depth 4 -Compress).Replace("'", "''")
$query = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @demo nvarchar(max) = N'$demoJson';
SELECT * INTO #DemoCustomers
FROM OPENJSON(@demo) WITH (
    CustomerId uniqueidentifier, AddressId uniqueidentifier, PolicyId uniqueidentifier,
    FirstName nvarchar(50), LastName nvarchar(50), CompanyName nvarchar(128),
    EmailAddress nvarchar(50), Phone nvarchar(25), AddressLine1 nvarchar(60),
    City nvarchar(30), StateProvince nvarchar(50), PostalCode nvarchar(15),
    PolicyNumber nvarchar(50), PolicyType nvarchar(20), BusinessLine nvarchar(20),
    ProductName nvarchar(150), PremiumAmount decimal(19,4),
    CoverageLimitAmount decimal(19,4), DeductibleAmount decimal(19,4),
    EffectiveDate date, ExpirationDate date, PolicyDocumentUrl nvarchar(2048)
);
DECLARE @customersInserted int, @addressesInserted int,
        @linksInserted int, @policiesInserted int;
BEGIN TRY
    BEGIN TRAN;
    INSERT INTO [obj].[Address]
        (Id, AddressLine1, City, StateProvince, CountryRegion, PostalCode)
    SELECT source.AddressId, source.AddressLine1, source.City,
           source.StateProvince, N'United States', source.PostalCode
    FROM #DemoCustomers AS source
    WHERE NOT EXISTS (SELECT 1 FROM [obj].[Address] WITH (UPDLOCK, HOLDLOCK)
                      WHERE Id = source.AddressId);
    SET @addressesInserted = @@ROWCOUNT;

    INSERT INTO [obj].[Customer]
        (Id, FirstName, LastName, CompanyName, EmailAddress, Phone, PasswordHash, PasswordSalt)
    SELECT source.CustomerId, source.FirstName, source.LastName, source.CompanyName,
           source.EmailAddress, source.Phone, 'DEMO-NOT-A-VALID-PASSWORD-HASH', 'DEMOONLY'
    FROM #DemoCustomers AS source
    WHERE NOT EXISTS (SELECT 1 FROM [obj].[Customer] WITH (UPDLOCK, HOLDLOCK)
                      WHERE Id = source.CustomerId);
    SET @customersInserted = @@ROWCOUNT;

    INSERT INTO [obj].[CustomerAddress] (CustomerId, AddressId, AddressType, ModifiedDate)
    SELECT source.CustomerId, source.AddressId,
           CASE WHEN source.BusinessLine = N'Commercial' THEN N'Business' ELSE N'Home' END,
           GETUTCDATE()
    FROM #DemoCustomers AS source
    WHERE NOT EXISTS (SELECT 1 FROM [obj].[CustomerAddress] WITH (UPDLOCK, HOLDLOCK)
                      WHERE CustomerId = source.CustomerId AND AddressId = source.AddressId);
    SET @linksInserted = @@ROWCOUNT;

    INSERT INTO [obj].[InsurancePolicy]
        (Id, PolicyNumber, CustomerId, PolicyType, BusinessLine, ProductName, PolicyStatus,
         EffectiveDate, ExpirationDate, PremiumAmount, PremiumFrequency, CurrencyCode,
         CoverageLimitAmount, DeductibleAmount, InsuredPropertyAddressId, InsuredBusinessName,
         PolicyDocumentUrl, CreatedAtUtc, UpdatedAtUtc)
    SELECT source.PolicyId, source.PolicyNumber, source.CustomerId, source.PolicyType,
           source.BusinessLine, source.ProductName, N'Active', source.EffectiveDate,
           source.ExpirationDate, source.PremiumAmount, N'Monthly', 'USD',
           source.CoverageLimitAmount, source.DeductibleAmount,
           CASE WHEN source.PolicyType = N'Home' THEN source.AddressId ELSE NULL END,
           source.CompanyName, source.PolicyDocumentUrl, SYSUTCDATETIME(), SYSUTCDATETIME()
    FROM #DemoCustomers AS source
    WHERE NOT EXISTS (SELECT 1 FROM [obj].[InsurancePolicy] WITH (UPDLOCK, HOLDLOCK)
                      WHERE Id = source.PolicyId);
    SET @policiesInserted = @@ROWCOUNT;
    COMMIT TRAN;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRAN;
    THROW;
END CATCH;
SELECT @customersInserted AS CustomersInserted, @addressesInserted AS AddressesInserted,
       @linksInserted AS CustomerAddressesInserted, @policiesInserted AS PoliciesInserted;
"@

Invoke-Sqlcmd -ServerInstance "$SqlServerName.database.windows.net" -Database $databaseName `
    -AccessToken $token.accessToken -Encrypt Mandatory -AbortOnError -ErrorAction Stop `
    -ConnectionTimeout 15 -QueryTimeout 120 -DisableVariables -Query $query