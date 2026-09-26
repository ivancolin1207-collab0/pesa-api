-- ============================================================
-- Migración: Agregar columnas requeridas a ordenes_servicio
-- Ejecutar con superusuario (postgres) o el dueño de la tabla
-- ============================================================
BEGIN;

ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS consecutivo          INT DEFAULT 0;
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS tipo_documento        VARCHAR(10) DEFAULT 'OS';
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS modalidad             VARCHAR(20) DEFAULT 'FISICO';
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS cliente               TEXT;
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS observaciones_tecnico TEXT;

-- Actualizar registros existentes que no tengan tipo_documento
UPDATE ordenes_servicio
SET tipo_documento = 'OS'
WHERE tipo_documento IS NULL OR tipo_documento = '';

-- Otorgar permisos al usuario de la aplicación
GRANT SELECT, INSERT, UPDATE, DELETE ON ordenes_servicio TO pesa_app;

COMMIT;

-- Verificar resultado
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'ordenes_servicio'
ORDER BY ordinal_position;
