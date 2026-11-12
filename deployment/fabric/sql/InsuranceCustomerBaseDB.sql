BEGIN TRY
    BEGIN TRAN;

    -- Create target schema if missing
    IF SCHEMA_ID(N'obj') IS NULL
        EXEC(N'CREATE SCHEMA [obj] AUTHORIZATION [dbo];');

    -- Create Address table if missing
    IF OBJECT_ID(N'[obj].[Address]', N'U') IS NULL
        CREATE TABLE [obj].[Address]
    (
        [Id] uniqueidentifier NOT NULL
            CONSTRAINT [DF_Address_Id] DEFAULT (NEWSEQUENTIALID()),
        [AddressLine1] nvarchar(60) NOT NULL,
        [AddressLine2] nvarchar(60) NULL,
        [City] nvarchar(30) NOT NULL,
        [StateProvince] nvarchar(50) NULL,
        [CountryRegion] nvarchar(50) NULL,
        [PostalCode] nvarchar(15) NOT NULL,
        [ModifiedDate] datetime NOT NULL
            CONSTRAINT [DF_Address_ModifiedDate] DEFAULT (GETDATE()),
        CONSTRAINT [PK_Address_Id]
            PRIMARY KEY CLUSTERED ([Id]) 
    );

    -- Create Customer table if missing
    IF OBJECT_ID(N'[obj].[Customer]', N'U') IS NULL
        CREATE TABLE [obj].[Customer]
    (
        [Id] uniqueidentifier NOT NULL
            CONSTRAINT [DF_Customer_Id] DEFAULT (NEWSEQUENTIALID()),
        [NameStyle] bit NULL
            CONSTRAINT [DF_Customer_NameStyle] DEFAULT (0),
        [Title] nvarchar(8) NULL,
        [FirstName] nvarchar(50) NULL,
        [MiddleName] nvarchar(50) NULL,
        [LastName] nvarchar(50) NULL,
        [Suffix] nvarchar(10) NULL,
        [CompanyName] nvarchar(128) NULL,
        [EmailAddress] nvarchar(50) NULL,
        [Phone] nvarchar(25) NULL,
        [PasswordHash] varchar(128) NOT NULL,
        [PasswordSalt] varchar(10) NOT NULL,
        [ModifiedDate] datetime NOT NULL
            CONSTRAINT [DF_Customer_ModifiedDate] DEFAULT (GETDATE()),
        CONSTRAINT [PK_Customer_Id]
            PRIMARY KEY CLUSTERED ([Id])
    );

    -- Create CustomerAddress table if missing
    IF OBJECT_ID(N'[obj].[CustomerAddress]', N'U') IS NULL
        CREATE TABLE [obj].[CustomerAddress]
    (
        [CustomerId] uniqueidentifier NOT NULL,
        [AddressId] uniqueidentifier NOT NULL,
        [AddressType] [nvarchar](50) NULL,
        [ModifiedDate] [datetime] NOT NULL,
        CONSTRAINT [PK_CustomerAddress_CustomerId_AddressId] 
            PRIMARY KEY CLUSTERED ([CustomerId], [AddressId])
    );

    -- Create InsurancePolicy table if missing
    IF OBJECT_ID(N'[obj].[InsurancePolicy]', N'U') IS NULL
        CREATE TABLE [obj].[InsurancePolicy]
    (
        [Id] uniqueidentifier NOT NULL
            CONSTRAINT [DF_InsurancePolicy_Id] DEFAULT (NEWSEQUENTIALID()),
        [PolicyNumber] [nvarchar](50) NOT NULL,
        [CustomerId] uniqueidentifier NOT NULL,
        [PolicyType] [nvarchar](20) NOT NULL,
        [BusinessLine] [nvarchar](20) NOT NULL,
        [ProductName] [nvarchar](150) NOT NULL,
        [PolicyStatus] [nvarchar](20) NOT NULL,
        [EffectiveDate] [date] NOT NULL,
        [ExpirationDate] [date] NULL,
        [PremiumAmount] [decimal](19, 4) NOT NULL,
        [PremiumFrequency] [nvarchar](20) NOT NULL,
        [CurrencyCode] [char](3) NOT NULL,
        [CoverageLimitAmount] [decimal](19, 4) NOT NULL,
        [DeductibleAmount] [decimal](19, 4) NULL,
        [InsuredVehicleVIN] [varchar](17) NULL,
        [InsuredPropertyAddressId] uniqueidentifier NULL,
        [InsuredBusinessName] [nvarchar](200) NULL,
        [PolicyDocumentUrl] [nvarchar](2048) NOT NULL,
        [CreatedAtUtc] [datetime2](3) NOT NULL,
        [UpdatedAtUtc] [datetime2](3) NOT NULL,
        CONSTRAINT [PK_InsurancePolicy] 
            PRIMARY KEY CLUSTERED ([Id])
    );

    IF NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys
        WHERE [name] = N'FK_CustomerAddress_Customer'
          AND [parent_object_id] = OBJECT_ID(N'[obj].[CustomerAddress]')
    )
        ALTER TABLE [obj].[CustomerAddress] WITH CHECK
            ADD CONSTRAINT [FK_CustomerAddress_Customer]
            FOREIGN KEY ([CustomerId]) REFERENCES [obj].[Customer] ([Id]);

    IF NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys
        WHERE [name] = N'FK_CustomerAddress_Address'
          AND [parent_object_id] = OBJECT_ID(N'[obj].[CustomerAddress]')
    )
        ALTER TABLE [obj].[CustomerAddress] WITH CHECK
            ADD CONSTRAINT [FK_CustomerAddress_Address]
            FOREIGN KEY ([AddressId]) REFERENCES [obj].[Address] ([Id]);

    IF NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys
        WHERE [name] = N'FK_InsurancePolicy_Customer'
          AND [parent_object_id] = OBJECT_ID(N'[obj].[InsurancePolicy]')
    )
        ALTER TABLE [obj].[InsurancePolicy] WITH CHECK
            ADD CONSTRAINT [FK_InsurancePolicy_Customer]
            FOREIGN KEY ([CustomerId]) REFERENCES [obj].[Customer] ([Id]);

    IF NOT EXISTS (
        SELECT 1 FROM sys.foreign_keys
        WHERE [name] = N'FK_InsurancePolicy_InsuredPropertyAddress'
          AND [parent_object_id] = OBJECT_ID(N'[obj].[InsurancePolicy]')
    )
        ALTER TABLE [obj].[InsurancePolicy] WITH CHECK
            ADD CONSTRAINT [FK_InsurancePolicy_InsuredPropertyAddress]
            FOREIGN KEY ([InsuredPropertyAddressId]) REFERENCES [obj].[Address] ([Id]);

    COMMIT TRAN;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRAN;
    THROW;
END CATCH;
GO
