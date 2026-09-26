BEGIN;

-- Agrega la columna numero_celdas para lógica de básculas camioneras
ALTER TABLE ordenes_servicio ADD COLUMN IF NOT EXISTS numero_celdas INTEGER;

COMMIT;
