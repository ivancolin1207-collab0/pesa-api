-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  MIGRACIÓN v18 — PDF Snapshot + Vista completa de excentricidad            ║
-- ║  Fecha: 2026-09  |  Autor: Básculas PESA Dev                              ║
-- ║                                                                            ║
-- ║  Cambios:                                                                  ║
-- ║    1. ADD COLUMN datos_tecnicos_json TEXT (snapshot íntegro del formulario) ║
-- ║    2. Asegurar que pdf_path está disponible (ya existe en v17, idempotente) ║
-- ║    3. Asegurar columnas de excentricidad ya existentes en la tabla física   ║
-- ║       (aplica_excentricidad, filas_excentricidad, geometria_plataforma,    ║
-- ║        num_secciones, tipo_no_aplica_exc, indicadores_jia) — idempotente   ║
-- ║    4. Actualizar v_ordenes_servicio para exponer TODOS esos campos          ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

BEGIN;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Columna datos_tecnicos_json — snapshot completo del formulario en JSON
-- ═════════════════════════════════════════════════════════════════════════════
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS datos_tecnicos_json TEXT;

COMMENT ON COLUMN ordenes_servicio.datos_tecnicos_json
    IS 'Snapshot completo del payload del formulario en JSON (marca, serie, '
       'pruebas metrológicas, excentricidad, etc.). Se serializa al guardar/actualizar. '
       'Permite reconstruir el PDF exactamente como fue generado originalmente.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Columna pdf_path — ya existe en v17 pero la garantizamos idempotente
-- ═════════════════════════════════════════════════════════════════════════════
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS pdf_path TEXT;

COMMENT ON COLUMN ordenes_servicio.pdf_path
    IS 'Ruta absoluta del último PDF generado para esta OS. '
       'Usado por el botón "Ver PDF" del dashboard para abrir sin regenerar.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Columnas de excentricidad — pueden existir ya (digital_service_dialog las
--    crea via SQL directo). ADD IF NOT EXISTS garantiza idempotencia.
-- ═════════════════════════════════════════════════════════════════════════════
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS aplica_excentricidad  BOOLEAN;

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS filas_excentricidad   INTEGER;

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS geometria_plataforma  VARCHAR(50);

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS num_secciones         INTEGER;

ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS tipo_no_aplica_exc    VARCHAR(100);

-- indicadores_jia: {"J": bool, "I": bool, "A": bool}
ALTER TABLE ordenes_servicio
    ADD COLUMN IF NOT EXISTS indicadores_jia       JSONB;

COMMENT ON COLUMN ordenes_servicio.aplica_excentricidad
    IS 'TRUE = la prueba de excentricidad aplica para este instrumento.';
COMMENT ON COLUMN ordenes_servicio.filas_excentricidad
    IS 'Número de filas / puntos de excentricidad (típicamente 4 o 5).';
COMMENT ON COLUMN ordenes_servicio.geometria_plataforma
    IS 'Geometría de la plataforma: cuadrada, circular, camionera, tolva, etc.';
COMMENT ON COLUMN ordenes_servicio.num_secciones
    IS 'Número de secciones (solo aplica para geometría camionera).';
COMMENT ON COLUMN ordenes_servicio.tipo_no_aplica_exc
    IS 'Razón por la que no aplica excentricidad: grúa, tolva, etc.';
COMMENT ON COLUMN ordenes_servicio.indicadores_jia
    IS 'Indicadores JIA del resultado de exactitud: {"J": bool, "I": bool, "A": bool}.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Actualizar v_ordenes_servicio para exponer TODOS los campos relevantes
--    (incluyendo los de excentricidad, pdf_path y datos_tecnicos_json)
-- ═════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW v_ordenes_servicio AS
SELECT
    os.id,
    os.folio_os,
    os.fecha,
    os.estado,

    -- Claves foráneas (para lookups en el formulario)
    os.id_tipo_servicio,
    os.id_cliente,
    os.id_tecnico,
    os.id_tipo_instrumento,
    os.id_clase_exactitud,
    os.sucursal_id,
    os.equipo_catalogo_id,

    -- Cliente
    cl.razon_social                         AS cliente,
    cl.direccion                            AS direccion_cliente,

    -- Sucursal / Planta
    su.nombre_sucursal                      AS sucursal_nombre,
    su.direccion                            AS sucursal_direccion,

    -- Tipo de servicio y técnico
    ts.nombre                               AS tipo_servicio,
    tc.nombre_completo                      AS tecnico,
    tc.nombre_completo                      AS tecnico_nombre,
    tc.tiene_acreditacion_ema               AS tecnico_tiene_ema,
    tc.numero_cca_ema                       AS tecnico_numero_cca_ema,

    -- Datos del equipo
    os.marca,
    os.modelo,
    os.ns,
    os.ubicacion,
    os.alcance_max,
    os.div_minima,
    os.div_verificacion,
    os.id_equipo,
    ti.nombre                               AS tipo_instrumento,
    os.numero_cca,
    os.holograma_anterior,
    os.holograma_actualizado,

    -- Pruebas metrológicas — resúmenes
    os.valor_repetibilidad,
    os.valor_excentricidad,

    -- Excentricidad — configuración
    os.aplica_excentricidad,
    os.filas_excentricidad,
    os.geometria_plataforma,
    os.num_secciones,
    os.tipo_no_aplica_exc,

    -- Exactitud
    os.indicadores_jia,
    ce.codigo                               AS clase_exactitud_codigo,
    ce.nombre                               AS clase_exactitud_nombre,
    ce.simbolo                              AS clase_exactitud_simbolo,
    os.id_clase_exactitud                   AS id_clase_exactitud_num,

    -- Modalidad (si existe en la tabla)
    os.modalidad,

    -- Lote (si existe en la tabla)
    os.id_lote,

    -- Finalización y firmas
    os.observaciones,
    os.firma_cliente_nombre,

    -- Archivo adjunto (escaneado físico)
    adj.nombre_archivo                      AS archivo_escaneado,
    adj.ruta_completa                       AS ruta_escaneado,
    adj.fecha_adjunto,

    -- PDF generado y snapshot
    os.pdf_path,
    os.datos_tecnicos_json,

    -- Sincronización
    os.sync_status,

    -- Timestamps
    os.created_at,
    os.updated_at

FROM ordenes_servicio os
LEFT JOIN cat_clientes          cl  ON os.id_cliente          = cl.id
LEFT JOIN cliente_sucursales    su  ON os.sucursal_id          = su.id
LEFT JOIN cat_tipo_servicio     ts  ON os.id_tipo_servicio     = ts.id
LEFT JOIN cat_tecnicos          tc  ON os.id_tecnico           = tc.id
LEFT JOIN cat_tipo_instrumento  ti  ON os.id_tipo_instrumento  = ti.id
LEFT JOIN cat_clase_exactitud   ce  ON os.id_clase_exactitud   = ce.id
LEFT JOIN adjuntos_os           adj ON os.id                   = adj.id_os;

COMMENT ON VIEW v_ordenes_servicio
    IS 'Vista desnormalizada de OS v18 — incluye excentricidad, pdf_path y datos_tecnicos_json.';

COMMIT;
