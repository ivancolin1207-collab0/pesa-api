@echo off
chcp 65001 >nul
echo.
echo ========================================================
echo  MIGRACIÓN v18 — Persistencia PDF y Datos Técnicos
echo  Ejecutar como usuario POSTGRES en PostgreSQL
echo ========================================================
echo.
echo Ingrese la contraseña de PostgreSQL (usuario 'postgres'):
set /p PGPASSWORD=Contraseña:
set PGCLIENTENCODING=UTF8

"C:\Program Files\PostgreSQL\18\bin\psql.exe" ^
    -h localhost -p 5432 -U postgres -d servicios_pesa ^
    -f "%~dp0database\migration_v18_pdf_snapshot.sql"

if %ERRORLEVEL% == 0 (
    echo.
    echo [OK] Migracion v18 aplicada exitosamente.
) else (
    echo.
    echo [ERROR] La migracion fallo. Verifique la contrasena o ejecute el SQL
    echo         manualmente en pgAdmin con el usuario 'postgres'.
    echo.
    echo Archivo SQL: %~dp0database\migration_v18_pdf_snapshot.sql
)
pause
