/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 006-002-anleitungGesamtskript.sql
  Zweck   : Anleitung, wie das Gesamtskript aus SSMS erzeugt wird.
  Technik : SSMS-Assistent "Skripts generieren"

  ABLAUF

    1. Objekt-Explorer, Rechtsklick auf dbGERDSS
    2. Aufgaben -> Skripts generieren
    3. "Gesamte Datenbank und alle Datenbankobjekte auswaehlen"
    4. Weiter, dann Schaltflaeche "Erweitert"
    5. Folgende Einstellungen setzen:

         Skript fuer DROP und CREATE       -> Skript CREATE
         Datentypen der zu schreibenden    -> Schema und Daten
         Skript fuer Indizes               -> True
         Skript fuer Trigger               -> True
         Skript fuer Pruefeinschraenkungen -> True
         Skript fuer Fremdschluessel       -> True
         Skript fuer Primaerschluessel     -> True
         Skript fuer eindeutige Schluessel -> True

    6. Ziel: In Datei speichern
    7. Dateiname: GERDSS_Gesamtskript.sql
    8. Fertigstellen

  KONTROLLE

    Die erzeugte Datei oeffnen und pruefen:
      - kein DROP TABLE, kein DROP DATABASE
      - alle 13 Tabellen enthalten
      - INSERT-Anweisungen fuer die Daten vorhanden
==============================================================================*/

USE dbGERDSS;
GO

/*---------------- Vor dem Erzeugen: Vollstaendigkeit pruefen ----------------*/
SELECT 'Tabellen'    AS Objektart, COUNT(*) AS Anzahl FROM sys.tables
UNION ALL SELECT 'Sichten',       COUNT(*) FROM sys.views WHERE is_ms_shipped = 0
UNION ALL SELECT 'Funktionen',    COUNT(*) FROM sys.objects WHERE type IN ('FN','IF','TF')
UNION ALL SELECT 'Prozeduren',    COUNT(*) FROM sys.procedures
UNION ALL SELECT 'Trigger',       COUNT(*) FROM sys.triggers WHERE parent_id > 0
UNION ALL SELECT 'Indizes (NC)',  COUNT(*) FROM sys.indexes WHERE type = 2 AND is_primary_key = 0;
GO
