BEGIN;

CREATE OR REPLACE VIEW v_ordenes_servicio AS
SELECT
    os.id,
    os.folio_os,
    os.fecha,
    os.estado,
    os.id_lote,
    os.id_tipo_servicio,
    os.id_cliente,
    os.id_tecnico,
    os.id_tipo_instrumento,
    os.id_clase_exactitud,
    os.sucursal_id,
    os.equipo_catalogo_id,
    cl.razon_social                         AS cliente,
    cl.direccion                            AS direccion_cliente,
    su.nombre_sucursal                      AS sucursal_nombre,
    su.direccion                            AS sucursal_direccion,
    ts.nombre                               AS tipo_servicio,
    tc.nombre_completo                      AS tecnico,
    tc.tiene_acreditacion_ema               AS tecnico_tiene_ema,
    tc.numero_cca_ema                       AS tecnico_numero_cca_ema,
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
    os.valor_repetibilidad,
    os.valor_excentricidad,
    ce.codigo                               AS clase_exactitud_codigo,
    ce.nombre                               AS clase_exactitud_nombre,
    ce.simbolo                              AS clase_exactitud_simbolo,
    os.modalidad,
    os.observaciones,
    os.firma_cliente_nombre,
    adj.nombre_archivo                      AS archivo_escaneado,
    adj.ruta_completa                       AS ruta_escaneado,
    adj.fecha_adjunto,
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

COMMENT ON VIEW v_ordenes_servicio IS 'Vista desnormalizada de OS v14 - incluye sucursal_nombre y sucursal_direccion.';

COMMIT;