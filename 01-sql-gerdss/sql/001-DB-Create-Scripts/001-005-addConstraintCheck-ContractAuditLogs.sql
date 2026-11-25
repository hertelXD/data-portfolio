/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 001-005-addConstraintCheck-ContractAuditLogs.sql
  Zweck   : Legt die Einschraenkung auf die zulaessigen Aktionsarten von
            ContractAuditLogs an. Erlaubt sind nur INSERT und UPDATE - geloescht
            werden Vertraege nicht, also gibt es dafuer auch keinen Eintrag.
  Technik : ALTER TABLE ... ADD CONSTRAINT ... CHECK, WITH CHECK,
            sys.check_constraints, TRY...CATCH

  Hinweis : Der Test am Ende braucht einen existierenden Vertrag, weil
            ContractID zugleich ein Fremdschluessel ist. Vertraege entstehen
            erst in 001-006. Laeuft dieses Skript in der normalen Reihenfolge,
            wird der Test deshalb uebersprungen und ist nach 001-006 erneut
            auszufuehren.
==============================================================================*/

USE dbGERDSS;
GO

IF NOT EXISTS (SELECT * FROM sys.check_constraints WHERE name = 'CK_ContractAuditLogs_ActionType')
BEGIN
    ALTER TABLE ContractAuditLogs WITH CHECK        -- vorhandene Zeilen werden geprueft
        ADD CONSTRAINT CK_ContractAuditLogs_ActionType
        CHECK (ActionType IN ('INSERT', 'UPDATE'));
END;
GO

/*---------------- Kontrolle ----------------*/
SELECT  Einschraenkung.name                          AS Einschraenkung,
        OBJECT_NAME(Einschraenkung.parent_object_id) AS Tabelle,
        Einschraenkung.definition                    AS Bedingung,
        Einschraenkung.is_not_trusted                AS NichtGeprueft   -- muss 0 sein
FROM sys.check_constraints AS Einschraenkung
WHERE Einschraenkung.name = 'CK_ContractAuditLogs_ActionType';
GO

/*---------------- Test: die Einschraenkung greift ----------------*/
IF NOT EXISTS (SELECT 1 FROM ExportContracts)
BEGIN
    PRINT 'Uebersprungen: es gibt noch keine Vertraege. Diesen Block nach 001-006 erneut ausfuehren.';
END
ELSE
BEGIN
    DECLARE @Vertrag INT = (SELECT TOP (1) ContractID FROM ExportContracts ORDER BY ContractID);

    BEGIN TRY
        INSERT INTO ContractAuditLogs (ContractID, ActionType, Details)
        VALUES (@Vertrag, 'DELETE', 'Test mit unzulaessiger Aktionsart');

        SELECT 'Fehler: der Eintrag wurde angenommen' AS Ergebnis;
    END TRY
    BEGIN CATCH
        SELECT 'Richtig abgewiesen' AS Ergebnis, ERROR_MESSAGE() AS Meldung;
        -- Erwartet: Konflikt mit CK_ContractAuditLogs_ActionType
    END CATCH
END
GO