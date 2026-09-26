-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  MIGRACIÓN v9 — Módulo de Recepción / Entrega Semanal de OS               ║
-- ║  Fecha: 2026-08  |  Autor: Básculas PESA Dev                              ║
-- ║                                                                            ║
-- ║  Cambios:                                                                  ║
-- ║    1. ordenes_servicio → Agregar estado 'COMPLETADA' al CHECK              ║
-- ║    2. Crear tabla lotes_recepcion (control de entrega por lote/fecha)      ║
-- ║    3. Crear tabla lotes_recepcion_items (detalle por OS individual)        ║
-- ║    4. Crear vista v_recepcion_semanal (vista desnormalizada para UI)       ║
-- ║    5. Índices de rendimiento                                               ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Ampliar el CHECK de estado en ordenes_servicio
--    Agrega 'COMPLETADA' como estado final válido.
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE ordenes_servicio
    DROP CONSTRAINT IF EXISTS chk_os_estado;

ALTER TABLE ordenes_servicio
    ADD CONSTRAINT chk_os_estado
        CHECK (estado IN ('PROCESO', 'CANCELADA', 'ESCANEADA', 'COMPLETADA'));

COMMENT ON COLUMN ordenes_servicio.estado IS
    'PROCESO = activa, CANCELADA = anulada, ESCANEADA = con archivo adjunto, '
    'COMPLETADA = entrega física confirmada por Recepción.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Tabla principal de recepción por lote / fecha
-- ═════════════════════════════════════════════════════════════════════════════
--
--  Cada fila representa UN bloque de asignación tal como aparece en el Excel:
--    - PARTE 1 (Asignación inicial): cliente, servicio, cantidad, folios, técnico
--    - PARTE 2 (Cierre / Recepción): factura, certificados, confirmación, escaneo,
--              conteos y la REGLA ESTRICTA de entrega impresa.
--
--  El campo id_lote_ref enlaza con ordenes_servicio.id_lote (VARCHAR, no UUID).
--  Cuando las OS se generaron de forma individual (sin lote) el campo es NULL
--  y el agrupamiento se hace solo por fecha + técnico.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS lotes_recepcion (
    id                          SERIAL          PRIMARY KEY,

    -- ── Referencia al lote generado por BatchGeneratorWidget ─────────────────
    id_lote_ref                 VARCHAR(60),    -- id_lote de ordenes_servicio (puede ser NULL para lotes manuales)
    fecha_asignacion            DATE            NOT NULL DEFAULT CURRENT_DATE,

    -- ── PARTE 1: Asignación Inicial ─────────────────────────────────────────
    id_cliente                  INTEGER         REFERENCES cat_clientes(id)
                                                    ON UPDATE CASCADE ON DELETE SET NULL,
    id_tipo_servicio            INTEGER         REFERENCES cat_tipo_servicio(id)
                                                    ON UPDATE CASCADE ON DELETE SET NULL,
    cantidad_os_asignadas       SMALLINT        NOT NULL DEFAULT 1,
    folios_asignados            TEXT,           -- Rango ej. "26-363/02" o lista "26-344/11, 26-344/14"
    id_tecnico                  INTEGER         REFERENCES cat_tecnicos(id)
                                                    ON UPDATE CASCADE ON DELETE SET NULL,
    tecnicos_adicionales        TEXT,           -- Nombre(s) extra separados por coma

    -- ── PARTE 2: Cierre / Recepción Físico-Digital ──────────────────────────
    --   Factura: NULL = sin factura (alerta roja), 'N/A' = no aplica, otro = número
    numero_factura              VARCHAR(60),

    --   Certificados B&S: ej. "OS.CAL.26.00284, OS.CAL.26.00290" o "N/A"
    certificados_bs             TEXT,

    --   Confirmación de OS: TRUE=✓, FALSE=✗, NULL=pendiente
    confirmacion_os             BOOLEAN,

    --   Check OS Escaneada: 'OK'=✓ escaneada, 'NA'=digital/no aplica, 'PENDIENTE'=falta
    check_os_escaneada          VARCHAR(10)     DEFAULT 'PENDIENTE'
                                                CHECK (check_os_escaneada IN ('OK', 'NA', 'PENDIENTE')),

    --   Conteos de cierre
    no_os_realizadas            SMALLINT        NOT NULL DEFAULT 0,
    no_os_en_blanco             SMALLINT        NOT NULL DEFAULT 0,

    -- ── REGLA ESTRICTA: Entrega Impresa Obligatoria ──────────────────────────
    --   CRÍTICO: Una OS/lote NO puede marcarse COMPLETADA hasta que este campo
    --   sea TRUE. La lógica de bloqueo se aplica tanto en el modelo Python
    --   como en el widget de UI.
    entrega_impresa_recibida    BOOLEAN         NOT NULL DEFAULT FALSE,

    -- ── Notas internas de Recepción ──────────────────────────────────────────
    notas_recepcion             TEXT,

    -- ── Trazabilidad ─────────────────────────────────────────────────────────
    created_at                  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- Índices de rendimiento
CREATE INDEX IF NOT EXISTS idx_lrec_fecha
    ON lotes_recepcion (fecha_asignacion DESC);
CREATE INDEX IF NOT EXISTS idx_lrec_lote_ref
    ON lotes_recepcion (id_lote_ref);
CREATE INDEX IF NOT EXISTS idx_lrec_tecnico
    ON lotes_recepcion (id_tecnico);
CREATE INDEX IF NOT EXISTS idx_lrec_cliente
    ON lotes_recepcion (id_cliente);

-- Trigger para updated_at
CREATE TRIGGER trg_lrec_updated_at
    BEFORE UPDATE ON lotes_recepcion
    FOR EACH ROW EXECUTE FUNCTION fn_update_updated_at();

COMMENT ON TABLE  lotes_recepcion IS
    'Control de recepción semanal de OS. Cada fila es un bloque de asignación '
    'agrupado por fecha, emulando el Excel de Gestión de OS Digitalizadas.';
COMMENT ON COLUMN lotes_recepcion.entrega_impresa_recibida IS
    'CRÍTICO: Debe ser TRUE antes de poder marcar las OS del lote como COMPLETADAS. '
    'Representa la confirmación física de que el técnico entregó la versión impresa firmada.';
COMMENT ON COLUMN lotes_recepcion.check_os_escaneada IS
    'OK=Escaneada✓, NA=Digital/No Aplica, PENDIENTE=Falta escaneo.';
COMMENT ON COLUMN lotes_recepcion.numero_factura IS
    'NULL o vacío = sin factura (se muestra como alerta roja en la UI). '
    '''N/A'' = no aplica factura. Cualquier otro valor = número de factura.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Tabla de ítems por lote (detalle de OS individuales dentro del lote)
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS lotes_recepcion_items (
    id                          SERIAL          PRIMARY KEY,
    id_lote_recepcion           INTEGER         NOT NULL
                                                    REFERENCES lotes_recepcion(id)
                                                    ON DELETE CASCADE ON UPDATE CASCADE,
    id_os                       INTEGER         REFERENCES ordenes_servicio(id)
                                                    ON UPDATE CASCADE ON DELETE SET NULL,
    folio_os                    VARCHAR(25)     NOT NULL,

    -- Estado individual de esta OS dentro del lote
    confirmada                  BOOLEAN,            -- ✓/✗ confirmación individual
    impresa_entregada           BOOLEAN         NOT NULL DEFAULT FALSE,
    escaneada                   BOOLEAN,
    notas                       TEXT,

    created_at                  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_lrec_item_folio UNIQUE (id_lote_recepcion, folio_os)
);

CREATE INDEX IF NOT EXISTS idx_lrec_item_lote ON lotes_recepcion_items (id_lote_recepcion);
CREATE INDEX IF NOT EXISTS idx_lrec_item_os   ON lotes_recepcion_items (id_os);

COMMENT ON TABLE lotes_recepcion_items IS
    'Detalle de OS individuales dentro de un lote de recepción. '
    'Permite marcar confirmación y entrega a nivel de folio individual.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Vista desnormalizada para el widget de UI
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_recepcion_semanal AS
SELECT
    lr.id,
    lr.id_lote_ref,
    lr.fecha_asignacion,

    -- PARTE 1
    lr.id_cliente,
    cl.razon_social                         AS cliente,
    lr.id_tipo_servicio,
    ts.nombre                               AS tipo_servicio,
    lr.cantidad_os_asignadas,
    lr.folios_asignados,
    lr.id_tecnico,
    tc.nombre_completo                      AS tecnico,
    lr.tecnicos_adicionales,

    -- PARTE 2
    lr.numero_factura,
    lr.certificados_bs,
    lr.confirmacion_os,
    lr.check_os_escaneada,
    lr.no_os_realizadas,
    lr.no_os_en_blanco,

    -- REGLA ESTRICTA
    lr.entrega_impresa_recibida,

    -- Derivado: ¿puede marcarse COMPLETADA?
    (lr.entrega_impresa_recibida = TRUE
     AND lr.confirmacion_os = TRUE)         AS puede_completar,

    -- Derivado: ¿tiene alerta de factura?
    (lr.numero_factura IS NULL
     OR TRIM(lr.numero_factura) = '')       AS alerta_factura,

    lr.notas_recepcion,
    lr.created_at,
    lr.updated_at
FROM lotes_recepcion lr
LEFT JOIN cat_clientes      cl ON lr.id_cliente      = cl.id
LEFT JOIN cat_tipo_servicio ts ON lr.id_tipo_servicio = ts.id
LEFT JOIN cat_tecnicos      tc ON lr.id_tecnico       = tc.id;

COMMENT ON VIEW v_recepcion_semanal IS
    'Vista desnormalizada del módulo de Recepción. '
    'Incluye campos derivados: puede_completar, alerta_factura.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Función auxiliar: marcar_lote_completado
--    Solo actúa si entrega_impresa_recibida = TRUE.
--    Actualiza estado de todas las OS del lote a 'COMPLETADA'.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION marcar_lote_completado(p_id_lote_recepcion INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_lote      lotes_recepcion%ROWTYPE;
    v_count     INTEGER := 0;
BEGIN
    -- Obtener el lote
    SELECT * INTO v_lote
    FROM lotes_recepcion
    WHERE id = p_id_lote_recepcion;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Lote no encontrado');
    END IF;

    -- REGLA ESTRICTA: bloquear si no hay entrega impresa
    IF v_lote.entrega_impresa_recibida IS DISTINCT FROM TRUE THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error', 'No se puede completar: falta confirmar la entrega del documento impreso firmado.'
        );
    END IF;

    -- Marcar OS del lote como COMPLETADA (por id_lote_ref o por items)
    IF v_lote.id_lote_ref IS NOT NULL THEN
        UPDATE ordenes_servicio
        SET estado = 'COMPLETADA', updated_at = NOW()
        WHERE id_lote = v_lote.id_lote_ref
          AND estado NOT IN ('CANCELADA', 'COMPLETADA');
        GET DIAGNOSTICS v_count = ROW_COUNT;
    ELSE
        -- Sin id_lote_ref: actualizar por los items individuales
        UPDATE ordenes_servicio os
        SET estado = 'COMPLETADA', updated_at = NOW()
        FROM lotes_recepcion_items li
        WHERE li.id_lote_recepcion = p_id_lote_recepcion
          AND li.id_os = os.id
          AND os.estado NOT IN ('CANCELADA', 'COMPLETADA');
        GET DIAGNOSTICS v_count = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object('ok', true, 'os_actualizadas', v_count);
END;
$$;

COMMENT ON FUNCTION marcar_lote_completado IS
    'Marca todas las OS de un lote de recepción como COMPLETADA. '
    'BLOQUEA si entrega_impresa_recibida = FALSE.';

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────────
-- Verificación post-migración (ejecutar en pgAdmin para confirmar):
-- ─────────────────────────────────────────────────────────────────────────────
-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public'
--   AND table_name IN ('lotes_recepcion', 'lotes_recepcion_items');
--
-- SELECT * FROM v_recepcion_semanal LIMIT 5;
--
-- SELECT proname FROM pg_proc WHERE proname = 'marcar_lote_completado';
-- ─────────────────────────────────────────────────────────────────────────────
