/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 001-002-createTable-alleTabellen.sql
  Zweck   : Legt alle 14 Tabellen der Datenbank an. Die Reihenfolge folgt den
            Abhaengigkeiten: eine Tabelle steht immer hinter der, auf die ihr
            Fremdschluessel verweist.
  Technik : CREATE TABLE, PRIMARY KEY, FOREIGN KEY, CHECK, DEFAULT, UNIQUE,
            IDENTITY
==============================================================================*/

USE dbGERDSS;
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

/*------------------------------------------------------------------------------
  1. Countries
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Countries')
BEGIN
    CREATE TABLE Countries
    (
        CountryID           INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        CountryName         NVARCHAR(100)                   NOT NULL,   -- offizieller Landesname
        CountryCode         CHAR(2)                         NOT NULL,   -- ISO 3166-1 alpha-2
        GridOperator        NVARCHAR(150)                   NOT NULL,   -- nationaler Netzbetreiber
        CreditLimitEUR      DECIMAL(15,2)                   NOT NULL    -- zugewiesener Kreditrahmen in EUR
            CONSTRAINT DF_Countries_CreditLimit DEFAULT (0.00),
        IsExporter          BIT                             NOT NULL    -- 1 = darf Energie exportieren
            CONSTRAINT DF_Countries_IsExporter DEFAULT (0),
        GridEmissionFactor  DECIMAL(6,4)                    NOT NULL    -- CO2-Emissionsfaktor des Netzes (tCO2/MWh)
            CONSTRAINT DF_Countries_GridEmissionFactor DEFAULT (0.0000),
            
        CONSTRAINT PK_Countries              PRIMARY KEY (CountryID),
        CONSTRAINT UQ_Countries_Name         UNIQUE (CountryName),
        CONSTRAINT UQ_Countries_Code         UNIQUE (CountryCode),
        CONSTRAINT CK_Countries_CreditLimit  CHECK (CreditLimitEUR >= 0),      -- Darf nicht negativ sein
        CONSTRAINT CK_Countries_GridEmission CHECK (GridEmissionFactor >= 0)   -- Darf nicht negativ sein
    );
END;
GO

/*------------------------------------------------------------------------------
  2. PowerPlantTypes
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'PowerPlantTypes')
BEGIN
    CREATE TABLE PowerPlantTypes
    (
        PlantTypeID         INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        TypeName            NVARCHAR(50)                    NOT NULL,   -- z. B. Wind Onshore
        CO2EmissionFactor   DECIMAL(6,4)                    NOT NULL    -- Tonnen CO2 je MWh
            CONSTRAINT DF_PowerPlantTypes_CO2 DEFAULT (0.0000),
        IsRenewable         BIT                             NOT NULL    -- 1 = erneuerbare Energie
            CONSTRAINT DF_PowerPlantTypes_IsRenewable DEFAULT (1),
            
        CONSTRAINT PK_PowerPlantTypes_PlantTypeID  PRIMARY KEY CLUSTERED (PlantTypeID),
        CONSTRAINT UQ_PowerPlantTypes_TypeName     UNIQUE (TypeName),
        CONSTRAINT CK_PowerPlantTypes_CO2EmissionFactor CHECK (CO2EmissionFactor >= 0) -- Darf nicht negativ sein
    );
END;
GO

/*------------------------------------------------------------------------------
  3. GridNodes
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'GridNodes')
BEGIN
    CREATE TABLE GridNodes
    (
        NodeID              INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        NodeName            NVARCHAR(100)                   NOT NULL,   -- technische Bezeichnung
        CountryID           INT             NOT NULL,                   -- Standortland (Fremdschluessel)
        VoltageLevelIKV     DECIMAL(6,2)                    NOT NULL,   -- Nennspannung in Kilovolt

        CONSTRAINT PK_GridNodes              PRIMARY KEY (NodeID),
        CONSTRAINT UQ_GridNodes_Name         UNIQUE (NodeName),                                 -- kein Knotenname doppelt
        CONSTRAINT FK_GridNodes_Countries    FOREIGN KEY (CountryID) REFERENCES Countries(CountryID),
        CONSTRAINT CK_GridNodes_VoltageLevel CHECK (VoltageLevelIKV > 0)                        -- Spannung muss positiv sein
    );
END;
GO

/*------------------------------------------------------------------------------
  4. PowerPlants
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'PowerPlants')
BEGIN
    CREATE TABLE PowerPlants
    (
        PlantID             INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        PlantName           NVARCHAR(120)                   NOT NULL,   -- Name des Kraftwerks
        PlantTypeID         INT                             NOT NULL,   -- Fremdschluessel zur Technologie
        MaxCapacityMW       DECIMAL(10,2)                   NOT NULL,   -- Nennleistung in Megawatt
        NodeID              INT                             NOT NULL,   -- Fremdschluessel zum Netzknoten
            
        CONSTRAINT PK_PowerPlants_PlantID           PRIMARY KEY CLUSTERED (PlantID),
        CONSTRAINT FK_PowerPlants_PowerPlantTypes   FOREIGN KEY (PlantTypeID) REFERENCES PowerPlantTypes(PlantTypeID),
        CONSTRAINT FK_PowerPlants_GridNodes         FOREIGN KEY (NodeID) REFERENCES GridNodes(NodeID),
        CONSTRAINT CK_PowerPlants_MaxCapacityMW     CHECK (MaxCapacityMW > 0) -- Leistung muss positiv sein
    );
END;
GO

/*------------------------------------------------------------------------------
  5. TransmissionLines
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'TransmissionLines')
BEGIN
    CREATE TABLE TransmissionLines
    (
        LineID              INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        FromNodeID          INT             NOT NULL,                   -- Startknoten
        ToNodeID            INT             NOT NULL,                   -- Zielknoten
        MaxCapacityMW       DECIMAL(10,2)                   NOT NULL,   -- maximale Uebertragungsleistung
        LossPercentage      DECIMAL(5,2)                    NOT NULL    -- Uebertragungsverlust in Prozent
            CONSTRAINT DF_TransmissionLines_Loss DEFAULT (0.00),
        LengthKM            DECIMAL(8,2)                    NOT NULL,   -- tatsaechliche Leitungslaenge
        IsActive            BIT                             NOT NULL    -- 0 = ausser Betrieb
            CONSTRAINT DF_TransmissionLines_IsActive DEFAULT (1),
        BookedMWh           DECIMAL(12,2)                   NOT NULL    -- vom Trigger fortgeschrieben
            CONSTRAINT DF_TransmissionLines_BookedMWh DEFAULT (0.00),
            
        CONSTRAINT PK_TransmissionLines_LineID          PRIMARY KEY CLUSTERED (LineID),
        CONSTRAINT UQ_TransmissionLines_From_To         UNIQUE (FromNodeID, ToNodeID),
        CONSTRAINT FK_TransmissionLines_FromNode        FOREIGN KEY (FromNodeID) REFERENCES GridNodes(NodeID),
        CONSTRAINT FK_TransmissionLines_ToNode          FOREIGN KEY (ToNodeID) REFERENCES GridNodes(NodeID),
        CONSTRAINT CK_TransmissionLines_DifferentNodes  CHECK (FromNodeID <> ToNodeID),
        CONSTRAINT CK_TransmissionLines_MaxCapacityMW   CHECK (MaxCapacityMW > 0),
        CONSTRAINT CK_TransmissionLines_LengthKM        CHECK (LengthKM > 0),
        CONSTRAINT CK_TransmissionLines_LossPercentage  CHECK (LossPercentage >= 0 AND LossPercentage <= 100)
    );
END;
GO

/*------------------------------------------------------------------------------
  6. ExportContracts
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'ExportContracts')
BEGIN
    CREATE TABLE ExportContracts
    (
        ContractID          INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        ExporterCountryID   INT             NOT NULL,                   -- Exportierendes Land (Fremdschluessel)
        ImporterCountryID   INT             NOT NULL,                   -- Importierendes Land (Fremdschluessel)
        ContractStartDate   DATETIME2(0)                    NOT NULL,   -- Beginn des Vertrags
        ContractEndDate     DATETIME2(0)                    NULL,       -- Ende des Vertrags (optional)
        AgreedPricePerMWh   DECIMAL(10,2)                   NOT NULL,   -- Vereinbarter Preis je MWh in EUR
            
        CONSTRAINT PK_ExportContracts_ContractID    PRIMARY KEY CLUSTERED (ContractID),
        CONSTRAINT FK_ExportContracts_Exporter      FOREIGN KEY (ExporterCountryID) REFERENCES Countries(CountryID),
        CONSTRAINT FK_ExportContracts_Importer      FOREIGN KEY (ImporterCountryID) REFERENCES Countries(CountryID),
        CONSTRAINT CK_ExportContracts_DifferentCountries CHECK (ExporterCountryID <> ImporterCountryID), -- Land kann nicht an sich selbst exportieren
        CONSTRAINT CK_ExportContracts_Dates         CHECK (ContractEndDate IS NULL OR ContractEndDate > ContractStartDate), -- Enddatum muss nach Startdatum liegen
        CONSTRAINT CK_ExportContracts_AgreedPrice   CHECK (AgreedPricePerMWh > 0) -- Preis muss positiv sein
    );
END;
GO

/*------------------------------------------------------------------------------
  7. MarketPrices
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'MarketPrices')
BEGIN
    CREATE TABLE MarketPrices
    (
        PriceID         BIGINT          IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel (Bigint wegen hoher Datenmenge)
        TimeSlot        DATETIME2(0)                    NOT NULL,   -- Zeitfenster der Preisgueltigkeit
        CountryID       INT             NOT NULL,                   -- Fremdschluessel zur Tabelle Countries
        PricePerMWh     DECIMAL(10,2)                   NOT NULL,   -- Marktpreis in EUR je MWh
            
        CONSTRAINT PK_MarketPrices_PriceID          PRIMARY KEY CLUSTERED (PriceID),
        CONSTRAINT UQ_MarketPrices_Country_TimeSlot UNIQUE (CountryID, TimeSlot), -- Eindeutiger Preis je Land und Zeitfenster
        CONSTRAINT FK_MarketPrices_Countries        FOREIGN KEY (CountryID) REFERENCES Countries(CountryID),
        CONSTRAINT CK_MarketPrices_PricePerMWh      CHECK (PricePerMWh >= 0)  -- Preis darf nicht negativ sein (Ausnahme Negativpreise moeglich, daher >= 0)
    );
END;
GO

/*------------------------------------------------------------------------------
  8. Transactions
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Transactions')
BEGIN
    CREATE TABLE Transactions
    (
        TransactionID       INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        ContractID          INT             NULL,                       -- Zugehoeriger Vertrag (optional, Fremdschluessel)
        LineID              INT             NOT NULL,                   -- Genutzte Uebertragungsleitung (Fremdschluessel)
        DeliveryTimeSlot    DATETIME2(0)                    NOT NULL,   -- Lieferzeitfenster
        TransactionTime     DATETIME2(0)                    NOT NULL    -- Zeitpunkt der Transaktion (Standard: aktuelles Systemdatum)
            CONSTRAINT DF_Transactions_Time DEFAULT (SYSDATETIME()),
        TotalMWh            DECIMAL(12,2)                   NOT NULL,   -- Uebertragene Energie in MWh
        TotalValueEUR       DECIMAL(15,2)                   NOT NULL,   -- Gesamtwert der Transaktion in EUR
        Status              VARCHAR(15)                     NOT NULL    -- Status der Transaktion (Gebucht, Geliefert, Storniert)
            CONSTRAINT DF_Transactions_Status DEFAULT ('Gebucht'),
            
        CONSTRAINT PK_Transactions_TransactionID    PRIMARY KEY CLUSTERED (TransactionID),
        CONSTRAINT FK_Transactions_ExportContracts  FOREIGN KEY (ContractID) REFERENCES ExportContracts(ContractID),
        CONSTRAINT FK_Transactions_TransmissionLines FOREIGN KEY (LineID) REFERENCES TransmissionLines(LineID),
        CONSTRAINT CK_Transactions_TotalMWh         CHECK (TotalMWh > 0),       -- Energiemenge muss positiv sein
        CONSTRAINT CK_Transactions_TotalValueEUR    CHECK (TotalValueEUR >= 0), -- Wert darf nicht negativ sein
        CONSTRAINT CK_Transactions_Status           CHECK (Status IN ('Gebucht', 'Geliefert', 'Storniert')) -- Gueltige Statuswerte
    );
END;
GO

/*------------------------------------------------------------------------------
  9. TransactionPlantAllocations
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'TransactionPlantAllocations')
BEGIN
    CREATE TABLE TransactionPlantAllocations
    (
        AllocationID    BIGINT          IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel (Bigint wegen hoher Datenmenge)
        TransactionID   INT             NOT NULL,                   -- Zugehoerige Transaktion (Fremdschluessel)
        PlantID         INT             NOT NULL,                   -- Genutztes Kraftwerk (Fremdschluessel)
        AllocatedMWh    DECIMAL(10,2)                   NOT NULL,   -- Vom Kraftwerk bereitgestellte Energiemenge in MWh
            
        CONSTRAINT PK_TransactionPlantAllocations_ID    PRIMARY KEY CLUSTERED (AllocationID),
        CONSTRAINT UQ_TransactionPlantAllocations_Tx_Plant UNIQUE (TransactionID, PlantID), -- Eindeutige Zuordnung je Transaktion und Kraftwerk
        CONSTRAINT FK_TPAllocations_Transactions        FOREIGN KEY (TransactionID) REFERENCES Transactions(TransactionID),
        CONSTRAINT FK_TPAllocations_PowerPlants         FOREIGN KEY (PlantID) REFERENCES PowerPlants(PlantID),
        CONSTRAINT CK_TPAllocations_AllocatedMWh        CHECK (AllocatedMWh > 0)    -- Zugeteilte Menge muss positiv sein
    );
END;
GO

/*------------------------------------------------------------------------------
  10. ReserveSchedules
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'ReserveSchedules')
BEGIN
    CREATE TABLE ReserveSchedules
    (
        ScheduleID          INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        StartTime           DATETIME2(0)                    NOT NULL,   -- Beginn des Zeitfensters
        EndTime             DATETIME2(0)                    NOT NULL,   -- Ende des Zeitfensters
        AvailableReserveMW  DECIMAL(10,2)                   NOT NULL,   -- tatsaechlich vorgehalten
        RequiredReserveMW   DECIMAL(10,2)                   NOT NULL,   -- vorgeschriebenes Minimum
            
        CONSTRAINT PK_ReserveSchedules_ScheduleID   PRIMARY KEY CLUSTERED (ScheduleID),
        CONSTRAINT UQ_ReserveSchedules_Start        UNIQUE (StartTime),
        CONSTRAINT CK_ReserveSchedules_Dates        CHECK (EndTime > StartTime),
        CONSTRAINT CK_ReserveSchedules_Available    CHECK (AvailableReserveMW >= 0),
        CONSTRAINT CK_ReserveSchedules_Required     CHECK (RequiredReserveMW >= 0)
    );
END;
GO

/*------------------------------------------------------------------------------
  11. GridBalanceLogs
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'GridBalanceLogs')
BEGIN
    CREATE TABLE GridBalanceLogs
    (
        LogID                       BIGINT          IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel (Bigint wegen hoher Protokollmenge)
        TransactionID               INT             NOT NULL,                   -- Zugehoerige Transaktion (Fremdschluessel)
        PostTransactionBalanceMW    DECIMAL(12,2)                   NOT NULL,   -- Verbleibende Netzlast/Bilanz nach der Transaktion in MW
        LoggedAt                    DATETIME2(0)                    NOT NULL    -- Zeitpunkt der Protokollierung (Standard: aktuelles Systemdatum)
            CONSTRAINT DF_GridBalanceLogs_LoggedAt DEFAULT (SYSDATETIME()),
            
        CONSTRAINT PK_GridBalanceLogs_LogID         PRIMARY KEY CLUSTERED (LogID),
        CONSTRAINT FK_GridBalanceLogs_Transactions  FOREIGN KEY (TransactionID) REFERENCES Transactions(TransactionID)
    );
END;
GO

/*------------------------------------------------------------------------------
  12. SystemLogs
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SystemLogs')
BEGIN
    CREATE TABLE SystemLogs
    (
        SystemLogID     BIGINT          IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel (Bigint wegen hoher Protokollmenge)
        LogLevel        NVARCHAR(20)                    NOT NULL,   -- Schweregrad des Logs (INFO, WARNING, ERROR, CRITICAL)
        Message         NVARCHAR(MAX)                   NOT NULL,   -- Detailbeschreibung des Ereignisses
        CreatedAt       DATETIME2(0)                    NOT NULL    -- Zeitpunkt der Protokollierung (Standard: aktuelles Systemdatum)
            CONSTRAINT DF_SystemLogs_CreatedAt DEFAULT (SYSDATETIME()),
            
        CONSTRAINT PK_SystemLogs_SystemLogID    PRIMARY KEY CLUSTERED (SystemLogID),
        CONSTRAINT CK_SystemLogs_LogLevel       CHECK (LogLevel IN ('INFO', 'WARNING', 'ERROR', 'CRITICAL')) -- Gueltige Log-Level
    );
END;
GO

/*------------------------------------------------------------------------------
  13. ContractAuditLogs
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'ContractAuditLogs')
BEGIN
    CREATE TABLE ContractAuditLogs
    (
        AuditID     INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        ContractID  INT                             NOT NULL,   -- betroffener Vertrag (Fremdschluessel)
        ActionType  VARCHAR(10)                     NOT NULL,   -- INSERT oder UPDATE
        ChangedBy   NVARCHAR(100)                   NOT NULL    -- Anmeldename des Verursachers
            CONSTRAINT DF_ContractAuditLogs_ChangedBy DEFAULT (ORIGINAL_LOGIN()),
        ChangedAt   DATETIME2(0)                    NOT NULL    -- Zeitpunkt der Aenderung
            CONSTRAINT DF_ContractAuditLogs_ChangedAt DEFAULT (SYSDATETIME()),
        Details     NVARCHAR(400)                   NULL,       -- Klartextbeschreibung

        CONSTRAINT PK_ContractAuditLogs_AuditID     PRIMARY KEY CLUSTERED (AuditID)
        -- Fremdschluessel und Einschraenkung folgen in 001-004 und 001-005
    );
END;
GO

/*------------------------------------------------------------------------------
  14. Allocations
  Schnittstellentabelle fuer das Ergebnis der externen Optimierung. Sie
  gehoert nicht zum fachlichen Modell, sondern ist ein Eingangspuffer: die
  Zeilen sind ungeprueft, in eine Buchung umgesetzt werden sie erst von
  spImportOptimizedResults.

  Name und Fachspalten folgen der Vorgabe der aufrufenden Schicht
  (db_manager.sync_csv_to_sql_server), damit dort keine Anpassung noetig ist.
  Schluessel und Eingangszeitstempel kommen hinzu, weil jede Tabelle dieser
  Datenbank einen Primaerschluessel hat und nachvollziehbar sein soll, wann
  eine Lieferung eingegangen ist.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Allocations')
BEGIN
    CREATE TABLE Allocations
    (
        AllocationRowID INT             IDENTITY(1,1)   NOT NULL,   -- Primaerschluessel
        PlantID         INT                             NULL,       -- Kraftwerk laut Optimierung
        PlantName       NVARCHAR(120)                   NULL,       -- Name laut Optimierung
        AllocatedMWh    DECIMAL(12,3)                   NULL,       -- zugeteilte Menge
        CO2Factor       DECIMAL(10,4)                   NULL,       -- verwendeter Emissionsfaktor
        CO2EmittedTons  DECIMAL(12,3)                   NULL,       -- errechnete Emission
        ExportedAt      NVARCHAR(30)                    NULL,       -- Zeitstempel der Optimierung
        ImportiertAm    DATETIME2(0)                    NOT NULL    -- Eingang in der Datenbank
            CONSTRAINT DF_Allocations_ImportiertAm DEFAULT (SYSDATETIME()),

        CONSTRAINT PK_Allocations_RowID PRIMARY KEY CLUSTERED (AllocationRowID)
        -- Bewusst ohne Fremdschluessel und ohne NOT NULL auf den Fachspalten:
        -- die Tabelle nimmt auch fehlerhafte Zeilen auf, damit der Import nicht
        -- an einer einzelnen Zeile scheitert. Geprueft wird beim Uebernehmen.
    );
END;
GO

/*------------------------------------------------------------------------------
  Kontrolle: erwartet werden 14 Tabellen
------------------------------------------------------------------------------*/
SELECT  Systemtabelle.name                              AS Tabelle,
        (SELECT COUNT(*) FROM sys.columns AS Spalte WHERE Spalte.object_id = Systemtabelle.object_id) AS Spalten
FROM sys.tables AS Systemtabelle
WHERE Systemtabelle.is_ms_shipped = 0
ORDER BY Systemtabelle.name;
GO
