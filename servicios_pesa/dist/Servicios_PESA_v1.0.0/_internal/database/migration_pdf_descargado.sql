-- ==================================================================
-- MIGRACION: Agregar columna pdf_descargado a ordenes_servicio
-- Ejecutar con el usuario SUPERUSUARIO de PostgreSQL (postgres)
-- psql -U postgres -d servicios_pesa -f migration_pdf_descargado.sql
-- ==================================================================

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS pdf_descargado BOOLEAN NOT NULL DEFAULT FALSE;

-- Verificar resultado:
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'ordenes_servicio'
  AND column_name = 'pdf_descargado';
