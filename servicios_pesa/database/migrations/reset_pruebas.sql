-- ═══════════════════════════════════════════════════════════════════════════════
-- SERVICIOS PESA — Script de Reset de Datos de Prueba y Consecutivos de Folios
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- ⚠️  ADVERTENCIA: SOLO PARA ENTORNO DE DESARROLLO / PRUEBAS
-- ⚠️  NUNCA ejecutar en producción sin respaldo previo.
--
-- Qué hace este script:
--   1. Elimina todos los registros de datos transaccionales (OS, adjuntos, pruebas)
--   2. Resetea los consecutivos de folios en control_folios a 0
--   3. Crea/reemplaza la función fn_reset_pruebas() para usar desde Python
--
-- Tablas de catálogos (cat_clientes, cat_tecnicos, etc.) NO se tocan.
-- ═══════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- PASO 1: Eliminar datos transaccionales (orden respetando FK)
-- ─────────────────────────────────────────────────────────────────────────────

-- Tablas hijas primero (detalles de pruebas metrológicas)
DELETE FROM det_repetibilidad;
DELETE FROM det_excentricidad;
DELETE FROM det_exactitud;

-- Adjuntos / escaneos vinculados a OS
DELETE FROM adjuntos_os;

-- Tabla principal de órdenes de servicio
DELETE FROM ordenes_servicio;

-- Si existen tablas de RMA y RE en la BD actual (se agregan idempotente)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'remisiones') THEN
        DELETE FROM remisiones;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revisiones_bascula') THEN
        DELETE FROM revisiones_bascula;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'escaneos') THEN
        DELETE FROM escaneos;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'detalles_metrologicos') THEN
        DELETE FROM detalles_metrologicos;
    END IF;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- PASO 2: Reiniciar consecutivos de folios a 0 para el año actual
-- El próximo folio generado será OS-26-1, RMA-26-1, RE-26-1
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE control_folios
SET    ultimo_consecutivo = 0,
       updated_at         = NOW()
WHERE  anio = EXTRACT(YEAR FROM CURRENT_DATE)::SMALLINT;

-- Si las filas no existen aún, inicializarlas en 0 para los 3 tipos
INSERT INTO control_folios (tipo_folio, anio, ultimo_consecutivo)
VALUES
    ('OS',  EXTRACT(YEAR FROM CURRENT_DATE)::SMALLINT, 0),
    ('RMA', EXTRACT(YEAR FROM CURRENT_DATE)::SMALLINT, 0),
    ('RE',  EXTRACT(YEAR FROM CURRENT_DATE)::SMALLINT, 0)
ON CONFLICT (tipo_folio, anio) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- PASO 3: Resetear secuencias SERIAL de las tablas limpiadas
-- ─────────────────────────────────────────────────────────────────────────────

SELECT setval('ordenes_servicio_id_seq',        1, false);
SELECT setval('det_repetibilidad_id_seq',        1, false);
SELECT setval('det_excentricidad_id_seq',        1, false);
SELECT setval('det_exactitud_id_seq',            1, false);
SELECT setval('adjuntos_os_id_seq',              1, false);

-- ─────────────────────────────────────────────────────────────────────────────
-- PASO 4: Función reutilizable fn_reset_pruebas()
-- Llamada desde Python: SELECT fn_reset_pruebas();
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fn_reset_pruebas()
RETURNS TABLE (
    resultado   TEXT,
    os_borradas BIGINT,
    anio_reset  SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_os_count     BIGINT := 0;
    v_anio_actual  SMALLINT := EXTRACT(YEAR FROM CURRENT_DATE)::SMALLINT;
BEGIN
    -- Contar antes de borrar
    SELECT COUNT(*) INTO v_os_count FROM ordenes_servicio;

    -- Borrar detalles (hijos primero)
    DELETE FROM det_repetibilidad;
    DELETE FROM det_excentricidad;
    DELETE FROM det_exactitud;
    DELETE FROM adjuntos_os;
    DELETE FROM ordenes_servicio;

    -- Borrar tablas opcionales si existen
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'remisiones') THEN
        EXECUTE 'DELETE FROM remisiones';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'revisiones_bascula') THEN
        EXECUTE 'DELETE FROM revisiones_bascula';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'escaneos') THEN
        EXECUTE 'DELETE FROM escaneos';
    END IF;

    -- Resetear consecutivos del año actual
    UPDATE control_folios
    SET    ultimo_consecutivo = 0,
           updated_at         = NOW()
    WHERE  anio = v_anio_actual;

    -- Reinsertar si no existían
    INSERT INTO control_folios (tipo_folio, anio, ultimo_consecutivo)
    VALUES
        ('OS',  v_anio_actual, 0),
        ('RMA', v_anio_actual, 0),
        ('RE',  v_anio_actual, 0)
    ON CONFLICT (tipo_folio, anio) DO NOTHING;

    -- Resetear secuencias SERIAL
    PERFORM setval('ordenes_servicio_id_seq',   1, false);
    PERFORM setval('det_repetibilidad_id_seq',  1, false);
    PERFORM setval('det_excentricidad_id_seq',  1, false);
    PERFORM setval('det_exactitud_id_seq',      1, false);
    PERFORM setval('adjuntos_os_id_seq',        1, false);

    RETURN QUERY SELECT
        'Reset completado. Siguiente folio: OS-' ||
            LPAD((v_anio_actual % 100)::TEXT, 2, '0') || '-1'   AS resultado,
        v_os_count                                                AS os_borradas,
        v_anio_actual                                             AS anio_reset;
END;
$$;

COMMENT ON FUNCTION fn_reset_pruebas IS
    'Elimina todos los datos transaccionales de prueba y reinicia los '
    'consecutivos de folios a 0 para el año actual. '
    'SOLO USAR EN DESARROLLO. Llamar con: SELECT * FROM fn_reset_pruebas();';

-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICACIÓN — muestra el estado tras el reset
-- ─────────────────────────────────────────────────────────────────────────────

SELECT
    tipo_folio,
    anio,
    ultimo_consecutivo,
    'Siguiente: ' || tipo_folio || '-' ||
        LPAD((anio % 100)::TEXT, 2, '0') || '-1'  AS proximo_folio
FROM control_folios
WHERE anio = EXTRACT(YEAR FROM CURRENT_DATE)::SMALLINT
ORDER BY tipo_folio;

COMMIT;

-- Invocación rápida (alternativa al bloque anterior):
-- SELECT * FROM fn_reset_pruebas();
