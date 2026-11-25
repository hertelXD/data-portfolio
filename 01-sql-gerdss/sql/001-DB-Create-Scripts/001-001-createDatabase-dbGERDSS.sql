/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 001-001-createDatabase-dbGERDSS.sql
  Zweck   : Erstellung der Datenbank dbGERDSS
  Technik : CREATE DATABASE, DROP DATABASE, ALTER DATABASE, DB_ID, DB_NAME
==============================================================================*/

USE master;                                                  -- Wechsel in die Systemdatenbank
GO

-- Vorhandene Datenbank entfernen. Nur beim Neuaufbau verwenden.
IF DB_ID('dbGERDSS') IS NOT NULL                             -- Pruefung, ob die Datenbank existiert
BEGIN
    ALTER DATABASE dbGERDSS SET SINGLE_USER WITH ROLLBACK IMMEDIATE;  -- offene Verbindungen trennen
    DROP DATABASE dbGERDSS;                                  -- Datenbank loeschen
END
GO

CREATE DATABASE dbGERDSS;                                    -- Datenbank neu anlegen
GO

-- Einfaches Wiederherstellungsmodell: es werden keine Log-Sicherungen erstellt.
ALTER DATABASE dbGERDSS SET RECOVERY SIMPLE;
GO

USE dbGERDSS;                                                -- Wechsel in die neue Datenbank
GO

/*---------------- Kontrolle ----------------*/
SELECT  DB_NAME()                          AS AktuelleDatenbank,   -- muss dbGERDSS zeigen
        DATABASEPROPERTYEX('dbGERDSS','Recovery') AS Wiederherstellungsmodell,
        DATABASEPROPERTYEX('dbGERDSS','Collation') AS Sortierung;
GO
