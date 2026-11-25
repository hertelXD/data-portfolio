/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 001-004-addConstraintForeignKey-ContractAuditLogs.sql
  Zweck   : Legt den Fremdschluessel von ContractAuditLogs auf ExportContracts an.
            Jeder Protokolleintrag muss zu einem existierenden Vertrag gehoeren.
  Technik : ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY ... REFERENCES,
            WITH CHECK zur Pruefung des Bestands, sys.foreign_keys
==============================================================================*/

USE dbGERDSS;
GO

IF NOT EXISTS (SELECT * FROM sys.foreign_keys WHERE name = 'FK_ContractAuditLogs_Contracts')
BEGIN
    ALTER TABLE ContractAuditLogs WITH CHECK        -- vorhandene Zeilen werden geprueft
        ADD CONSTRAINT FK_ContractAuditLogs_Contracts
        FOREIGN KEY (ContractID) REFERENCES ExportContracts(ContractID);
END;
GO

/*---------------- Kontrolle ----------------*/
SELECT  Fremdschluessel.name                     AS Fremdschluessel,
        OBJECT_NAME(Fremdschluessel.parent_object_id)     AS Tabelle,
        OBJECT_NAME(Fremdschluessel.referenced_object_id) AS VerweistAuf,
        Fremdschluessel.is_not_trusted           AS NichtGeprueft   -- muss 0 sein
FROM sys.foreign_keys AS Fremdschluessel
WHERE Fremdschluessel.name = 'FK_ContractAuditLogs_Contracts';
GO

/*---------------- Test: der Fremdschluessel greift ----------------*/
BEGIN TRY
    INSERT INTO ContractAuditLogs (ContractID, ActionType, Details)
    VALUES (999999, 'INSERT', 'Test mit ungueltiger Vertragsnummer');

    SELECT 'Fehler: der Eintrag wurde angenommen' AS Ergebnis;
END TRY
BEGIN CATCH
    SELECT 'Richtig abgewiesen' AS Ergebnis, ERROR_MESSAGE() AS Meldung;
END CATCH
GO
