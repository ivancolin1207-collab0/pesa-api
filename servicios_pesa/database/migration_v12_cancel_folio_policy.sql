-- ══════════════════════════════════════════════════════════════════════════════
-- MIGRACIÓN v12 — Política de No-Reciclaje de Folios (documentación + verificación)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- PROPÓSITO:
--   Documenta y verifica que el consecutivo de folios es estrictamente
--   incremental y que las órdenes canceladas conservan su folio asignado.
--
-- REGLA DE NEGOCIO:
--   • Una OS con estado CANCELADA conserva su folio en ordenes_servicio.
--   • El campo control_folios.ultimo_consecutivo NUNCA decrece.
--   • generate_folio() siempre retorna ultimo_consecutivo + 1.
--   • Ejemplo: si existen OS-26-455 y OS-26-456 (aunque 456 esté CANCELADA),
--     la siguiente llamada a generate_folio('OS', 2026) retorna OS-26-457.
--
-- CAMBIOS ESTRUCTURALES: Ninguno.
--   La función generate_folio() ya implementa correctamente la política desde v6.
--   Las OS canceladas ya no se eliminan físicamente (cambio en UI, no en BD).
--
-- AUTOR: Sistema PESA v12
-- FECHA: 2026-08-06
-- ══════════════════════════════════════════════════════════════════════════════

-- ── 1. Actualizar comentario de control_folios para reflejar la política ─────
COMMENT ON TABLE control_folios IS
    'CRÍTICO: Controla los consecutivos de folios por tipo y año. '
    'El consecutivo NUNCA se recicla: una OS cancelada conserva su folio. '
    'ultimo_consecutivo = último folio asignado; el siguiente = ultimo_consecutivo + 1. '
    'NO modificar manualmente.';

COMMENT ON COLUMN control_folios.ultimo_consecutivo IS
    'Último consecutivo asignado. El siguiente folio será ultimo_consecutivo + 1. '
    'Este valor NUNCA decrece, independientemente del estado de las OS creadas.';

-- ── 2. Confirmar que el CHECK de ordenes_servicio.estado incluye CANCELADA ────
--    (ya incluido desde migration_v9; esta sección es solo verificación)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM   information_schema.check_constraints
        WHERE  constraint_schema = CURRENT_SCHEMA()
          AND  constraint_name ILIKE '%os_estado%'
          AND  check_clause ILIKE '%CANCELADA%'
    ) THEN
        RAISE NOTICE
            'AVISO: El CHECK de ordenes_servicio.estado no incluye CANCELADA. '
            'Revisar migration_v9_recepcion.sql.';
    ELSE
        RAISE NOTICE 'OK: ordenes_servicio.estado admite CANCELADA correctamente.';
    END IF;
END;
$$;

-- ── 3. Actualizar comentario de generate_folio para documentar la política ────
COMMENT ON FUNCTION generate_folio IS
    'Genera el siguiente folio consecutivo de forma atómica y segura. '
    'Usar siempre dentro de una transacción activa. '
    'El consecutivo es estrictamente incremental: los folios de OS canceladas '
    'NO se reutilizan. Ejemplo: si OS-26-456 está CANCELADA, el siguiente folio '
    'será OS-26-457. '
    'Ejemplo de uso: SELECT generate_folio(''OS'', 2026) → ''OS-26-1''';

-- ── 4. Registrar migración en historial (si existe la tabla) ──────────────────
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = CURRENT_SCHEMA()
          AND table_name = 'migraciones'
    ) THEN
        INSERT INTO migraciones (version, descripcion, ejecutada_at)
        VALUES (12, 'Política de no-reciclaje de folios — documentación y verificación', NOW())
        ON CONFLICT (version) DO NOTHING;
    END IF;
END;
$$;
