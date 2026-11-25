/*==============================================================================
  Projekt : GERDSS - German Energy Export Decision Support System
  Author  : Aileen Hertel
  Datei   : 006-001-spBackupDatenbank.sql
  Zweck   : Prozedur fuer die Datensicherung. Der Dateiname enthaelt einen
            Zeitstempel, damit sich Sicherungen nicht gegenseitig ueberschreiben.
  Technik : CREATE PROCEDURE, dynamisches SQL mit sp_executesql,
            BACKUP DATABASE ... WITH INIT, FORMAT, CHECKSUM

  Hinweis : Der SQL-Server-Dienst braucht Schreibrechte auf den Zielordner.
==============================================================================*/

USE dbGERDSS;                                                -- Wechsel in die GERDSS-Datenbank
GO

SET ANSI_NULLS ON;                                           -- ISO-Standard fuer NULL-Vergleiche aktivieren
GO

SET QUOTED_IDENTIFIER ON;                                    -- Erlaubt doppelte Anfuehrungszeichen fuer Bezeichner
GO

DROP PROCEDURE IF EXISTS dbo.spBackupDatenbank;             -- Loescht die Prozedur, falls sie existiert
GO

CREATE PROCEDURE dbo.spBackupDatenbank
    @Zielordner NVARCHAR(300) = N'C:\SQL-Kurs\SQL-GERDSS\006-BackUp\',  -- Zielverzeichnis
    @Dateiname  NVARCHAR(300) = NULL OUTPUT                            -- Rueckgabe: erzeugte Datei
AS
BEGIN
    SET NOCOUNT ON;                                          -- Unterdrueckt Mengenausgaben

    DECLARE @Stempel NVARCHAR(20) =                          -- Zeitstempel ohne Sonderzeichen
            REPLACE(REPLACE(REPLACE(CONVERT(NVARCHAR(19), SYSDATETIME(), 120), '-',''), ':',''), ' ','_');

    SET @Dateiname = @Zielordner + N'GERDSS_Backup_' + @Stempel + N'.bak';

    DECLARE @Befehl NVARCHAR(MAX) =                          -- Sicherungsbefehl zusammensetzen
            N'BACKUP DATABASE dbGERDSS TO DISK = @Pfad
              WITH INIT, FORMAT, CHECKSUM,
                   NAME = N''GERDSS Vollsicherung'';';

    BEGIN TRY
        EXEC sp_executesql @Befehl, N'@Pfad NVARCHAR(300)', @Pfad = @Dateiname;   -- dynamisch ausfuehren

        INSERT INTO SystemLogs (LogLevel, Message)           -- Erfolg protokollieren
        VALUES ('INFO', CONCAT(N'Sicherung erstellt: ', @Dateiname));
    END TRY
    BEGIN CATCH
        INSERT INTO SystemLogs (LogLevel, Message)           -- Fehler protokollieren
        VALUES ('ERROR', CONCAT(N'Sicherung fehlgeschlagen: ', ERROR_MESSAGE()));

        THROW;                                               -- Fehler an den Aufrufer weiterreichen
    END CATCH
END;
GO
