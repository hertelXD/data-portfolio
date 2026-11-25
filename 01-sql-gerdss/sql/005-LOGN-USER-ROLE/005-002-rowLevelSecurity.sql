/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 005-002-rowLevelSecurity.sql
  Zweck   : Zusatzleistung. Ein nationaler Netzbetreiber soll nur die
            Lieferungen sehen, die sein eigenes Land betreffen - nicht die
            der Konkurrenz. Die Einschraenkung steckt nicht in der Abfrage,
            sondern in der Datenbank.
  Technik : CREATE SCHEMA, Praedikatfunktion mit SCHEMABINDING,
            CREATE SECURITY POLICY mit FILTER- und BLOCK-Praedikat,
            SESSION_CONTEXT, EXECUTE AS USER / REVERT
==============================================================================*/

USE dbGERDSS;                                                -- Wechsel in die GERDSS-Datenbank
GO

IF SCHEMA_ID('sec') IS NULL                                  -- eigenes Schema fuer Sicherheitsobjekte
    EXEC('CREATE SCHEMA sec');
GO

/*----------------------------------------------------------------------------
  Zuerst die Richtlinie loesen. Solange sie auf die Funktion verweist,
  laesst sich die Funktion nicht aendern.
----------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'ExportAccessPolicy')
    DROP SECURITY POLICY ExportAccessPolicy;
GO

/*----------------------------------------------------------------------------
  Praedikatfunktion: wird bei jedem Zugriff auf Transactions automatisch je
  Zeile aufgerufen. Liefert sie eine Zeile, ist der Zugriff erlaubt.
  SCHEMABINDING ist Pflicht, damit die zugrunde liegenden Tabellen nicht
  veraendert und die Pruefung ausgehebelt werden kann.
----------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION sec.fnAccessByCountry (@LineID INT)  -- Parameter: Leitung der Transaktion
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS ZugriffErlaubt
    WHERE IS_MEMBER('db_owner') = 1                          -- Administratoren sehen alles
       OR USER_NAME() = 'dbo'                                -- ebenso der Eigentuemer
       OR CAST(SESSION_CONTEXT(N'CountryCode') AS CHAR(2)) = -- sonst: Landescode der Sitzung
          (
            SELECT Land.CountryCode                             -- gegen das Zielland der Leitung pruefen
            FROM dbo.TransmissionLines AS Leitung
            INNER JOIN dbo.GridNodes AS Netzknoten ON Netzknoten.NodeID   = Leitung.ToNodeID
            INNER JOIN dbo.Countries AS Land  ON Land.CountryID = Netzknoten.CountryID
            WHERE Leitung.LineID = @LineID
          );
GO

/*----------------------------------------------------------------------------
  Die Richtlinie verbindet die Funktion mit der Tabelle.
  FILTER blendet fremde Zeilen beim Lesen aus.
  BLOCK verhindert das Einfuegen von Zeilen fuer ein fremdes Land.
----------------------------------------------------------------------------*/
CREATE SECURITY POLICY ExportAccessPolicy
    ADD FILTER PREDICATE sec.fnAccessByCountry(LineID) ON dbo.Transactions,
    ADD BLOCK  PREDICATE sec.fnAccessByCountry(LineID) ON dbo.Transactions AFTER INSERT
WITH (STATE = ON);                                           -- Richtlinie sofort aktiv
GO

/*==============================================================================
  NACHWEIS - diesen Block am Stueck ausfuehren.
  Dieselbe Abfrage liefert je nach Kontext unterschiedlich viele Zeilen.
==============================================================================*/

SELECT COUNT(*) AS A_AlsAdministrator FROM Transactions;     -- Ausgangswert: alle Zeilen
GO

EXEC sp_set_session_context @key = N'CountryCode', @value = N'NL';   -- Kontext Niederlande
GO

EXECUTE AS USER = 'gerdssLeser';                             -- Kontextwechsel
    SELECT COUNT(*) AS B_ImKontextNiederlande FROM Transactions;
REVERT;                                                      -- zurueck zum eigenen Konto
GO

EXEC sp_set_session_context @key = N'CountryCode', @value = N'AT';   -- Kontext Oesterreich
GO

EXECUTE AS USER = 'gerdssLeser';
    SELECT COUNT(*) AS C_ImKontextOesterreich FROM Transactions;
REVERT;
GO

EXEC sp_set_session_context @key = N'CountryCode', @value = NULL;    -- Kontext zuruecksetzen
GO

SELECT  Richtlinie.name                           AS Richtlinie,
        Richtlinie.is_enabled                     AS Aktiv,          -- 1 = eingeschaltet
        OBJECT_NAME(Praedikat.target_object_id) AS Tabelle,        -- geschuetzte Tabelle
        Praedikat.predicate_type_desc           AS Praedikatstyp   -- FILTER oder BLOCK
FROM sys.security_policies AS Richtlinie
INNER JOIN sys.security_predicates AS Praedikat ON Praedikat.object_id = Richtlinie.object_id;
GO

/*----------------------------------------------------------------------------
  Zum voruebergehenden Abschalten:
      ALTER SECURITY POLICY ExportAccessPolicy WITH (STATE = OFF);
  Wieder einschalten:
      ALTER SECURITY POLICY ExportAccessPolicy WITH (STATE = ON);
----------------------------------------------------------------------------*/
