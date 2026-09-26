-- ============================================================================
-- Migration v17 — Soporte Offline-First / Sincronización SQLite ↔ PostgreSQL
-- Servicios PESA
-- Ejecutar con: python run_migration_v17.py
-- ============================================================================

-- 1. Columna sync_status: rastrea si el registro fue originado en tablet
--    y aún no ha sido confirmado en el servidor central.
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS sync_status VARCHAR(20) NOT NULL DEFAULT 'SYNCED';

-- 2. Columna updated_at: timestamp UTC de la última modificación.
--    Usado para detectar conflictos durante la sincronización.
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- 3. Columna pdf_path: ruta local/remota al PDF generado por la tablet.
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS pdf_path TEXT;

-- 4. Columna firma_tecnico_b64: firma del técnico capturada en tablet (PNG base64).
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS firma_tecnico_b64 TEXT;

-- 5. Columna firma_cliente_b64: firma del cliente capturada en tablet (PNG base64).
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS firma_cliente_b64 TEXT;

-- 6. Índice para búsquedas rápidas de registros pendientes de sincronización.
CREATE INDEX IF NOT EXISTS idx_os_sync_status ON ordenes_servicio(sync_status);

-- 7. Índice en updated_at para sincronización incremental.
CREATE INDEX IF NOT EXISTS idx_os_updated_at ON ordenes_servicio(updated_at DESC);

-- 8. Constraint: valores válidos para sync_status.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ck_os_sync_status'
    ) THEN
        ALTER TABLE ordenes_servicio
            ADD CONSTRAINT ck_os_sync_status
            CHECK (sync_status IN ('SYNCED', 'PENDING', 'CONFLICT'));
    END IF;
END $$;

-- 9. Función trigger para actualizar updated_at automáticamente.
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 10. Trigger en ordenes_servicio.
DROP TRIGGER IF EXISTS trg_os_updated_at ON ordenes_servicio;
CREATE TRIGGER trg_os_updated_at
    BEFORE UPDATE ON ordenes_servicio
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 11. Actualizar registros existentes con updated_at si es NULL.
UPDATE ordenes_servicio
SET updated_at = COALESCE(created_at, NOW())
WHERE updated_at IS NULL;

-- Verificación
SELECT
    column_name, data_type, column_default, is_nullable
FROM information_schema.columns
WHERE table_name = 'ordenes_servicio'
  AND column_name IN ('sync_status','updated_at','pdf_path','firma_tecnico_b64','firma_cliente_b64')
ORDER BY column_name;
