/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 005-001-createLoginUserUndRollen.sql
  Zweck   : Drei Serveranmeldungen mit Datenbankbenutzer und drei Rollen mit
            abgestuften Rechten. Der Grundsatz: ausser dem Administrator
            schreibt niemand direkt in Transactions - ein direkt eingefuegter
            Datensatz wuerde die Pruefstufen der Prozedur umgehen.
  Technik : CREATE LOGIN, CREATE USER, CREATE ROLE, ALTER ROLE ADD MEMBER,
            GRANT SELECT / INSERT / EXECUTE, DENY, Rechte auf Schemaebene
==============================================================================*/

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelt gesetzte Bezeichner
GO

-- Die Abschnitte wechseln bewusst zwischen master (Anmeldungen liegen auf
-- Serverebene) und dbGERDSS (Benutzer und Rollen liegen in der Datenbank).

/*------------------------------------------------------------------------------
  1. Anmeldung und Benutzer gerdssLeser
------------------------------------------------------------------------------*/
USE master;                                                  -- Anmeldungen liegen auf Serverebene
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'gerdssLeser')
    CREATE LOGIN gerdssLeser                                      -- Serveranmeldung anlegen
        WITH PASSWORD = 'Demo-Passwort-2026!',                     -- Kennwort, im Kurs bewusst einfach gehalten
             CHECK_POLICY = OFF,                             -- keine Kennwortrichtlinie erzwingen
             DEFAULT_DATABASE = dbGERDSS;                    -- Standarddatenbank nach der Anmeldung
GO

USE dbGERDSS;                                                -- Benutzer liegen auf Datenbankebene
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'gerdssLeser')
    CREATE USER gerdssLeser FOR LOGIN gerdssLeser;                     -- Benutzer mit der Anmeldung verknuepfen
GO

SELECT  Prinzipal.name         AS Benutzer,                         -- Kontrolle: eine Zeile erwartet
        Prinzipal.type_desc    AS Art,
        Prinzipal.create_date  AS Angelegt
FROM sys.database_principals AS Prinzipal
WHERE Prinzipal.name = 'gerdssLeser';
GO

/*------------------------------------------------------------------------------
  2. Anmeldung und Benutzer gerdssHaendler
------------------------------------------------------------------------------*/
USE master;                                                  -- Anmeldungen liegen auf Serverebene
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'gerdssHaendler')
    CREATE LOGIN gerdssHaendler                                      -- Serveranmeldung anlegen
        WITH PASSWORD = 'Demo-Passwort-2026!',                     -- Kennwort, im Kurs bewusst einfach gehalten
             CHECK_POLICY = OFF,                             -- keine Kennwortrichtlinie erzwingen
             DEFAULT_DATABASE = dbGERDSS;                    -- Standarddatenbank nach der Anmeldung
GO

USE dbGERDSS;                                                -- Benutzer liegen auf Datenbankebene
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'gerdssHaendler')
    CREATE USER gerdssHaendler FOR LOGIN gerdssHaendler;                     -- Benutzer mit der Anmeldung verknuepfen
GO

SELECT  Prinzipal.name         AS Benutzer,                         -- Kontrolle: eine Zeile erwartet
        Prinzipal.type_desc    AS Art,
        Prinzipal.create_date  AS Angelegt
FROM sys.database_principals AS Prinzipal
WHERE Prinzipal.name = 'gerdssHaendler';
GO

/*------------------------------------------------------------------------------
  3. Anmeldung und Benutzer gerdssSchnittstelle
------------------------------------------------------------------------------*/
USE master;                                                  -- Anmeldungen liegen auf Serverebene
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'gerdssSchnittstelle')
    CREATE LOGIN gerdssSchnittstelle                                      -- Serveranmeldung anlegen
        WITH PASSWORD = 'Demo-Passwort-2026!',                     -- Kennwort, im Kurs bewusst einfach gehalten
             CHECK_POLICY = OFF,                             -- keine Kennwortrichtlinie erzwingen
             DEFAULT_DATABASE = dbGERDSS;                    -- Standarddatenbank nach der Anmeldung
GO

USE dbGERDSS;                                                -- Benutzer liegen auf Datenbankebene
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'gerdssSchnittstelle')
    CREATE USER gerdssSchnittstelle FOR LOGIN gerdssSchnittstelle;                     -- Benutzer mit der Anmeldung verknuepfen
GO

SELECT  Prinzipal.name         AS Benutzer,                         -- Kontrolle: eine Zeile erwartet
        Prinzipal.type_desc    AS Art,
        Prinzipal.create_date  AS Angelegt
FROM sys.database_principals AS Prinzipal
WHERE Prinzipal.name = 'gerdssSchnittstelle';
GO

/*------------------------------------------------------------------------------
  4. Drei Rollen mit abgestuften Rechten
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'RolleLeser' AND type = 'R')
    CREATE ROLE RolleLeser;                                  -- Rolle fuer reine Auswertung
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'RolleHaendler' AND type = 'R')
    CREATE ROLE RolleHaendler;                               -- Rolle fuer den Handel
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'RolleSchnittstelle' AND type = 'R')
    CREATE ROLE RolleSchnittstelle;                          -- Rolle fuer den Datenimport
GO

/*---------------- Leser: nur lesen ----------------*/
GRANT SELECT ON SCHEMA::dbo TO RolleLeser;                   -- Leserecht auf alle Objekte des Schemas
DENY  SELECT ON Countries   TO RolleLeser;                   -- Kreditrahmen bleiben gesperrt
GO

/*---------------- Haendler: lesen und buchen, aber nur ueber die Prozedur ----------------*/
GRANT SELECT  ON SCHEMA::dbo                 TO RolleHaendler;   -- Leserecht auf alle Objekte
GRANT EXECUTE ON dbo.sfCalculateNetPower    TO RolleHaendler;   -- Verlustberechnung erlaubt
-- Tabellenwertfunktionen brauchen SELECT, nicht EXECUTE
GRANT SELECT  ON dbo.tfGetRoutesInRadius    TO RolleHaendler;   -- Routensuche erlaubt
GRANT EXECUTE ON dbo.spExecuteEnergyExport   TO RolleHaendler;   -- dreistufige Pruefprozedur
GRANT EXECUTE ON dbo.sfGetAvailableCapacity  TO RolleHaendler;   -- freie Kapazitaet abfragen
GRANT EXECUTE ON dbo.sfCalculateTransmissionLoss TO RolleHaendler;   -- Verlust je Leitung
DENY  INSERT, UPDATE, DELETE ON Transactions TO RolleHaendler;   -- kein direkter Schreibzugriff
GO

/*---------------- Schnittstelle: Import ----------------*/
GRANT SELECT ON SCHEMA::dbo                  TO RolleSchnittstelle;  -- Leserecht auf alle Objekte
GRANT INSERT ON MarketPrices                 TO RolleSchnittstelle;  -- Preise einspielen erlaubt
-- Die externe Schicht darf die Schnittstellentabelle lesen, leeren und neu
-- befuellen - mehr nicht. Bewusst KEIN ALTER-Recht: das waere noetig, um
-- TRUNCATE auszufuehren, und wuerde zugleich erlauben, die Tabelle zu
-- veraendern. Zum Leeren genuegt DELETE.
GRANT SELECT, INSERT, DELETE ON dbo.Allocations TO RolleSchnittstelle;  -- Optimierungsergebnis einspielen
GRANT EXECUTE ON dbo.spImportOptimizedResults TO RolleSchnittstelle; -- Import ueber die Pruefprozedur

DENY  INSERT, UPDATE, DELETE ON Transactions TO RolleSchnittstelle;  -- kein direkter Schreibzugriff
GO

/*---------------- Mitgliedschaften ----------------*/
ALTER ROLE RolleLeser         ADD MEMBER gerdssLeser;        -- Benutzer der Rolle zuordnen
ALTER ROLE RolleHaendler      ADD MEMBER gerdssHaendler;
ALTER ROLE RolleSchnittstelle ADD MEMBER gerdssSchnittstelle;
GO

/*------------------------------------------------------------------------------
  Kontrolle: drei Anmeldungen, drei Benutzer, drei Rollen
------------------------------------------------------------------------------*/
SELECT name AS Anmeldung FROM sys.server_principals WHERE name LIKE 'gerdss%';
SELECT name AS Benutzer, type_desc FROM sys.database_principals WHERE name LIKE 'gerdss%';
SELECT name AS Rolle FROM sys.database_principals WHERE type = 'R' AND name LIKE 'Rolle%';
GO
